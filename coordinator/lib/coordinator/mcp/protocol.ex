defmodule Coordinator.Mcp.Protocol do
  @moduledoc """
  JSON-RPC 2.0 framing for the MCP endpoint, and the protocol revisions this server speaks.

  Nothing here knows what a tool is. It decodes a message, tells you whether it is a request or
  a notification, and builds results and errors — so `Coordinator.Mcp.Server` can be a pure
  dispatch table and the HTTP concerns can stay in `Coordinator.Mcp.Transport`.

  ## Revisions

  MCP re-shaped its transport in `2026-07-28`: the `initialize` handshake and protocol-level
  sessions are gone, `server/discover` replaces them, the negotiated version travels in each
  request's `_meta`, and every result carries a `resultType`. The revisions before it
  (`2025-11-25` and earlier) still handshake and still expect a session id.

  Both eras are served, because the clients are split across them — so the era is resolved once,
  here, and everything downstream reads a single atom rather than sniffing version strings.
  """

  @modern "2026-07-28"
  @legacy ["2025-11-25", "2025-06-18", "2025-03-26"]
  @supported [@modern | @legacy]

  @meta_version "io.modelcontextprotocol/protocolVersion"
  @meta_client_info "io.modelcontextprotocol/clientInfo"
  @meta_client_capabilities "io.modelcontextprotocol/clientCapabilities"

  # JSON-RPC's own codes, plus the one MCP allocates from its reserved range.
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603
  @header_mismatch -32_020

  def modern_version, do: @modern
  def supported_versions, do: @supported
  def meta_version_key, do: @meta_version

  @doc "Whether this revision predates the handshake's removal."
  def legacy?(version), do: version in @legacy

  @doc "Which era a revision belongs to. Everything downstream branches on this, not on strings."
  def era(@modern), do: :modern
  def era(version) when version in @legacy, do: :legacy
  def era(_), do: :unsupported

  @doc """
  Classify a decoded body.

  A JSON-RPC *response* is not something a client may POST here, and an array is a batch, which
  was removed in `2025-06-18` — both are refused rather than half-handled.
  """
  def classify(%{"jsonrpc" => "2.0", "method" => method, "id" => id})
      when is_binary(method) and not is_nil(id),
      do: {:request, method, id}

  def classify(%{"jsonrpc" => "2.0", "method" => method}) when is_binary(method),
    do: {:notification, method}

  def classify(list) when is_list(list), do: {:error, :batch_unsupported}
  def classify(%{"result" => _}), do: {:error, :response_not_allowed}
  def classify(%{"error" => _}), do: {:error, :response_not_allowed}
  def classify(_), do: {:error, :invalid_request}

  @doc "The protocol version a request declares in `_meta`, if any."
  def declared_version(%{"params" => %{"_meta" => %{@meta_version => version}}})
      when is_binary(version),
      do: version

  def declared_version(_), do: nil

  @doc "What the client said about itself. Informational; never gates behaviour."
  def client_info(%{"params" => %{"_meta" => %{@meta_client_info => info}}}) when is_map(info),
    do: info

  def client_info(_), do: %{}

  @doc """
  The capabilities the client declared.

  On the modern revision these ride on every request; on the legacy one they arrive once, at
  `initialize`, and the transport carries them forward.
  """
  def client_capabilities(%{"params" => %{"_meta" => %{@meta_client_capabilities => caps}}})
      when is_map(caps),
      do: caps

  def client_capabilities(%{"params" => %{"capabilities" => caps}}) when is_map(caps), do: caps
  def client_capabilities(_), do: %{}

  @doc "A successful response. `result_type` is required from `2026-07-28` and harmless before it."
  def result(id, %{} = result, era \\ :modern) do
    result = if era == :modern, do: Map.put_new(result, "resultType", "default"), else: result
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  @doc "An error response. `id` is null for a failure that happened before one could be read."
  def error(id, code, message, data \\ nil) do
    body = %{"code" => code, "message" => message}
    body = if data, do: Map.put(body, "data", data), else: body

    %{"jsonrpc" => "2.0", "id" => id, "error" => body}
  end

  def parse_error(id \\ nil), do: error(id, @parse_error, "invalid JSON")
  def invalid_request(id, message), do: error(id, @invalid_request, message)
  def invalid_params(id, message), do: error(id, @invalid_params, message)
  def internal_error(id, message), do: error(id, @internal_error, message)

  def method_not_found(id, method),
    do: error(id, @method_not_found, "unknown method: #{method}")

  @doc """
  The header/body mismatch error, which the transport mirrors into HTTP 400.

  It exists because intermediaries route on the headers while the server executes the body: if
  the two disagree, a load balancer and this coordinator are acting on different requests.
  """
  def header_mismatch(id, message), do: error(id, @header_mismatch, message)

  @doc """
  The version-negotiation error. Listing what is supported is what lets a client retry rather
  than give up — and it is how a modern client tells this server from a legacy one.
  """
  def unsupported_version(id, requested) do
    error(id, @invalid_request, "unsupported protocol version: #{requested}", %{
      "type" => "UnsupportedProtocolVersionError",
      "supported" => @supported
    })
  end

  @doc """
  Decode the `Mcp-Name` header, which may arrive Base64-wrapped when the value is not safely
  representable as an ASCII header.
  """
  def decode_header_value("=?base64?" <> rest) do
    case String.split(rest, "?=", parts: 2) do
      [encoded, ""] ->
        case Base.decode64(encoded) do
          {:ok, decoded} -> decoded
          :error -> :invalid
        end

      _ ->
        :invalid
    end
  end

  def decode_header_value(value), do: value
end
