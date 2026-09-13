defmodule Coordinator.Mcp.Transport do
  @moduledoc """
  The MCP endpoint: Streamable HTTP, mounted at `/mcp`.

  A bare `Plug` rather than a `Plug.Router`, because the shape of this endpoint is a single path
  that branches on method — a router would add a matcher to express one `if`.

  What the revision requires, and why each is here rather than assumed:

    * **Origin is validated.** `check_origin` in the endpoint config governs sockets, not HTTP,
      so this is ours to do. Without it a page in someone's browser can drive their local
      coordinator (DNS rebinding), and the spec makes it a MUST.
    * **The headers must agree with the body.** `Mcp-Method` and `Mcp-Name` are mirrored out of
      the body so intermediaries can route without parsing it — which means a load balancer and
      this coordinator can be acting on different requests if they disagree. A mismatch is a
      400 with `-32020`, not a best-effort guess about which one was meant.
    * **GET and DELETE are 405.** They were the session and standalone-stream mechanisms of the
      older revisions, and both are gone.

  Authentication is `Coordinator.ApiAuth`, exactly as the OpenAI door uses it: the same gateway
  key, the same rate window, the same caller identity. What is deliberately *not* shared is
  `metered/3` — it holds a concurrency slot for the whole handler, which is right for a blocking
  completion and wrong for a client polling its own job, since that client would exhaust its own
  budget against itself. Only submission takes a slot.
  """
  @behaviour Plug

  import Plug.Conn
  require Logger

  alias Coordinator.{ApiAuth, Mcp}
  alias Coordinator.Mcp.Protocol

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    with :ok <- enabled(),
         :ok <- check_origin(conn) do
      handle_post(conn)
    else
      {:error, status, response} -> send_json(conn, status, response)
    end
  end

  # Both were removed in 2026-07-28: GET opened a standalone event stream, DELETE ended a
  # session. A client that tries either is speaking an older revision to a server that does not
  # implement that half of it, and 405 is what tells it so.
  def call(%Plug.Conn{method: method} = conn, _opts) when method in ["GET", "DELETE"] do
    conn
    |> put_resp_header("allow", "POST")
    |> send_json(405, Protocol.invalid_request(nil, "the MCP endpoint accepts POST"))
  end

  def call(conn, _opts) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_json(405, Protocol.invalid_request(nil, "the MCP endpoint accepts POST"))
  end

  defp handle_post(conn) do
    with {:ok, body} <- read_body_params(conn),
         {:ok, caller} <- authorize(conn),
         {:ok, version} <- negotiate(conn, body),
         :ok <- validate_headers(conn, body) do
      ctx = %{
        caller: caller,
        era: Protocol.era(version),
        version: version,
        client_info: Protocol.client_info(body),
        client_capabilities: Protocol.client_capabilities(body)
      }

      case Mcp.Server.handle(body, ctx) do
        # A notification is accepted and nothing is said back. The revision defines none over
        # this transport, but a client that sends one must not get an error for it.
        :noreply ->
          send_resp(conn, 202, "")

        {:reply, %{"error" => %{"code" => -32_601}} = response} ->
          # The revision asks for 404 on an unimplemented method, so a modern client can tell
          # this apart from a legacy server that does not host the endpoint at all.
          send_json(conn, 404, response)

        {:reply, response} ->
          send_json(conn, 200, response)
      end
    else
      {:error, status, response} -> send_json(conn, status, response)
    end
  end

  # The endpoint's parser has already run by the time this plug is reached.
  defp read_body_params(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}),
    do: {:error, 400, Protocol.parse_error()}

  defp read_body_params(%Plug.Conn{body_params: body}) when is_map(body), do: {:ok, body}
  defp read_body_params(_), do: {:error, 400, Protocol.parse_error()}

  defp authorize(conn) do
    case ApiAuth.admit(conn) do
      {:ok, caller} ->
        {:ok, caller}

      {:error, status, message, _type, _headers} ->
        {:error, status, Protocol.invalid_request(nil, message)}
    end
  end

  # A request that names no version is from a client predating the header. Reading it as the
  # revision that introduced Streamable HTTP is what the spec allows, and is the only way an
  # older client connects at all.
  defp negotiate(conn, body) do
    header = get_req_header(conn, "mcp-protocol-version") |> List.first()
    declared = Protocol.declared_version(body)
    id = body["id"]

    cond do
      is_binary(header) and is_binary(declared) and header != declared ->
        {:error, 400,
         Protocol.header_mismatch(
           id,
           "MCP-Protocol-Version header '#{header}' does not match the body's #{Protocol.meta_version_key()}"
         )}

      is_nil(header) and is_nil(declared) ->
        {:ok, "2025-03-26"}

      true ->
        version = header || declared

        if version in Protocol.supported_versions() do
          {:ok, version}
        else
          {:error, 400, Protocol.unsupported_version(id, version)}
        end
    end
  end

  # Only enforced where the revision requires them. An older client does not send these, and
  # demanding them would refuse every client that is not yet on 2026-07-28.
  defp validate_headers(conn, body) do
    if Protocol.era(header_version(conn, body)) == :modern do
      with :ok <- match_header(conn, body, "mcp-method", body["method"], "Mcp-Method"),
           :ok <- match_name_header(conn, body) do
        :ok
      end
    else
      :ok
    end
  end

  defp header_version(conn, body) do
    get_req_header(conn, "mcp-protocol-version")
    |> List.first()
    |> Kernel.||(Protocol.declared_version(body))
  end

  defp match_header(conn, body, header, expected, label) do
    case get_req_header(conn, header) do
      [value] ->
        if value == expected do
          :ok
        else
          {:error, 400,
           Protocol.header_mismatch(
             body["id"],
             "#{label} header '#{value}' does not match the body value '#{expected}'"
           )}
        end

      [] ->
        {:error, 400, Protocol.header_mismatch(body["id"], "#{label} header is required")}

      _ ->
        {:error, 400, Protocol.header_mismatch(body["id"], "#{label} appears more than once")}
    end
  end

  # Mcp-Name mirrors params.name, and only for the methods that have one.
  defp match_name_header(conn, %{"method" => "tools/call"} = body) do
    expected = get_in(body, ["params", "name"])

    case get_req_header(conn, "mcp-name") do
      [value] ->
        case Protocol.decode_header_value(value) do
          :invalid ->
            {:error, 400, Protocol.header_mismatch(body["id"], "Mcp-Name is not validly encoded")}

          decoded when decoded == expected ->
            :ok

          decoded ->
            {:error, 400,
             Protocol.header_mismatch(
               body["id"],
               "Mcp-Name header '#{decoded}' does not match the body value '#{expected}'"
             )}
        end

      [] ->
        {:error, 400,
         Protocol.header_mismatch(body["id"], "Mcp-Name header is required for tools/call")}

      _ ->
        {:error, 400, Protocol.header_mismatch(body["id"], "Mcp-Name appears more than once")}
    end
  end

  defp match_name_header(_conn, _body), do: :ok

  # A missing Origin is a non-browser client and is fine. A present one has to be allowed, or a
  # web page could drive this coordinator through the user's own browser.
  defp check_origin(conn) do
    case get_req_header(conn, "origin") do
      [] ->
        :ok

      [origin | _] ->
        if allowed_origin?(origin) do
          :ok
        else
          Logger.warning("mcp request refused: origin not allowed", origin: origin)
          {:error, 403, Protocol.invalid_request(nil, "origin not allowed")}
        end
    end
  end

  defp allowed_origin?(origin) do
    case Application.get_env(:coordinator, :mcp_allowed_origins) do
      list when is_list(list) and list != [] -> origin in list
      # Unset means no browser origin is trusted. An agent client sends no Origin at all, so the
      # safe default costs nothing until someone actually wants browser access.
      _ -> false
    end
  end

  defp enabled do
    if Application.get_env(:coordinator, :mcp_enabled, true) do
      :ok
    else
      {:error, 404, Protocol.invalid_request(nil, "the MCP endpoint is disabled")}
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end
