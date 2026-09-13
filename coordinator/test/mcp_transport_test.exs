defmodule Coordinator.McpTransportTest do
  @moduledoc """
  The HTTP contract of the MCP endpoint.

  This is the half a client sees before any tool runs, and it is where a hand-rolled server gets
  things wrong in ways that show up as "Claude Code just won't connect" rather than as an error
  anyone can read. So the status codes and the refusals are asserted directly.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Coordinator.Jobs.JobRecord
  alias Coordinator.Mcp.Protocol
  alias Coordinator.Repo

  @parser_opts Plug.Parsers.init(
                 parsers: [:json],
                 pass: ["application/json"],
                 json_decoder: Jason
               )

  @version Protocol.modern_version()

  setup do
    Application.delete_env(:coordinator, :api_token)
    Application.delete_env(:coordinator, :require_api_token)
    Application.delete_env(:coordinator, :mcp_allowed_origins)
    Application.delete_env(:coordinator, :mcp_enabled)
    Repo.delete_all(JobRecord)

    on_exit(fn ->
      Application.delete_env(:coordinator, :api_token)
      Application.delete_env(:coordinator, :require_api_token)
      Application.delete_env(:coordinator, :mcp_allowed_origins)
      Application.delete_env(:coordinator, :mcp_enabled)
      Repo.delete_all(Coordinator.ApiToken)
    end)

    :ok
  end

  defp rpc(method, params \\ %{}, id \\ 1) do
    params =
      Map.put(params, "_meta", %{Protocol.meta_version_key() => @version})

    body = %{"jsonrpc" => "2.0", "method" => method, "params" => params}
    if is_nil(id), do: body, else: Map.put(body, "id", id)
  end

  defp send_rpc(body, headers \\ nil) do
    headers =
      headers ||
        [
          {"mcp-protocol-version", @version},
          {"mcp-method", body["method"]}
        ] ++ name_header(body)

    conn =
      conn(:post, "/mcp", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)

    conn
    |> Plug.Parsers.call(@parser_opts)
    |> Coordinator.Mcp.Transport.call([])
  end

  defp name_header(%{"method" => "tools/call", "params" => %{"name" => name}}),
    do: [{"mcp-name", name}]

  defp name_header(_), do: []

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  describe "discovery" do
    test "server/discover reports the versions, tools capability and how to use the server" do
      conn = send_rpc(rpc("server/discover"))

      assert conn.status == 200
      result = decode(conn)["result"]

      assert @version in result["protocolVersions"]
      assert result["serverInfo"]["name"] == "hydra"
      assert result["capabilities"]["tools"]
      # A client that reads nothing else reads this, so it has to say what the loop is.
      assert result["instructions"] =~ "hydra_submit_job"

      # Advertising something unimplemented means a client calling it and getting nothing.
      refute Map.has_key?(result["capabilities"], "resources")
      refute Map.has_key?(result["capabilities"], "prompts")
    end

    test "the older handshake still works, and is answered in the version it asked for" do
      # Clients are split across the revision that removed `initialize`. Refusing the old one
      # would refuse every client that has not caught up yet.
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-06-18", "capabilities" => %{}}
      }

      conn =
        send_rpc(body, [
          {"mcp-protocol-version", "2025-06-18"},
          {"mcp-method", "initialize"}
        ])

      assert conn.status == 200
      assert decode(conn)["result"]["protocolVersion"] == "2025-06-18"
    end

    test "tools/list offers the four verbs, each with a schema" do
      conn = send_rpc(rpc("tools/list"))
      tools = decode(conn)["result"]["tools"]

      assert Enum.map(tools, & &1["name"]) |> Enum.sort() ==
               ~w(hydra_cancel_job hydra_get_job hydra_get_result hydra_submit_job)

      for tool <- tools do
        assert tool["inputSchema"]["type"] == "object"
        assert is_binary(tool["description"]) and tool["description"] != ""
      end
    end
  end

  describe "protocol version" do
    test "a version this server does not speak is refused with the list it does" do
      # Listing them is what lets a client retry instead of giving up — and is how a modern
      # client tells a modern server from a legacy one.
      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{"_meta" => %{Protocol.meta_version_key() => "1999-01-01"}}
      }

      conn =
        send_rpc(body, [
          {"mcp-protocol-version", "1999-01-01"},
          {"mcp-method", "tools/list"}
        ])

      assert conn.status == 400
      error = decode(conn)["error"]
      assert error["data"]["type"] == "UnsupportedProtocolVersionError"
      assert @version in error["data"]["supported"]
    end

    test "a header that disagrees with the body is refused rather than guessed at" do
      body = rpc("tools/list")

      conn =
        send_rpc(body, [
          {"mcp-protocol-version", "2025-06-18"},
          {"mcp-method", "tools/list"}
        ])

      assert conn.status == 400
      assert decode(conn)["error"]["code"] == -32_020
    end

    test "a client predating the version header is read as the revision that introduced this transport" do
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}}

      conn = send_rpc(body, [])

      assert conn.status == 200
      assert decode(conn)["result"]["tools"] != []
    end
  end

  describe "request metadata headers" do
    test "Mcp-Method is required on the current revision" do
      conn = send_rpc(rpc("tools/list"), [{"mcp-protocol-version", @version}])

      assert conn.status == 400
      assert decode(conn)["error"]["code"] == -32_020
    end

    test "Mcp-Name must match the tool actually being called" do
      # Intermediaries route on the header while this server executes the body: if they
      # disagree, a load balancer and the coordinator are acting on different requests.
      body = rpc("tools/call", %{"name" => "hydra_get_job", "arguments" => %{"job_id" => "x"}})

      conn =
        send_rpc(body, [
          {"mcp-protocol-version", @version},
          {"mcp-method", "tools/call"},
          {"mcp-name", "hydra_cancel_job"}
        ])

      assert conn.status == 400
      assert decode(conn)["error"]["code"] == -32_020
    end

    test "a Base64-wrapped Mcp-Name is decoded before it is compared" do
      body = rpc("tools/call", %{"name" => "hydra_get_job", "arguments" => %{"job_id" => "x"}})
      encoded = "=?base64?" <> Base.encode64("hydra_get_job") <> "?="

      conn =
        send_rpc(body, [
          {"mcp-protocol-version", @version},
          {"mcp-method", "tools/call"},
          {"mcp-name", encoded}
        ])

      assert conn.status == 200
    end

    test "the older revision is not held to headers it never defined" do
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}}

      conn = send_rpc(body, [{"mcp-protocol-version", "2025-06-18"}])

      assert conn.status == 200
    end
  end

  describe "method and shape" do
    test "an unimplemented method is 404 with a JSON-RPC error, not a bare 404" do
      # The body is what tells a modern client this endpoint exists but lacks the method, rather
      # than that there is no MCP server here at all.
      conn = send_rpc(rpc("resources/list"))

      assert conn.status == 404
      assert decode(conn)["error"]["code"] == -32_601
    end

    test "a notification is accepted with no body" do
      conn = send_rpc(rpc("notifications/initialized", %{}, nil))

      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "a batch is refused: it was removed from the protocol" do
      conn =
        conn(:post, "/mcp", Jason.encode!([rpc("tools/list")]))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-protocol-version", @version)
        |> put_req_header("mcp-method", "tools/list")
        |> Plug.Parsers.call(@parser_opts)
        |> Coordinator.Mcp.Transport.call([])

      assert conn.status == 400
    end

    test "GET and DELETE are refused: both were session mechanisms this revision removed" do
      for method <- [:get, :delete] do
        conn =
          conn(method, "/mcp")
          |> Coordinator.Mcp.Transport.call([])

        assert conn.status == 405
        assert get_resp_header(conn, "allow") == ["POST"]
      end
    end
  end

  describe "the door" do
    test "the same gateway key as /v1 is required when the door is closed" do
      Application.put_env(:coordinator, :api_token, "secret-key")

      assert send_rpc(rpc("tools/list")).status == 401

      conn =
        send_rpc(rpc("tools/list"), [
          {"mcp-protocol-version", @version},
          {"mcp-method", "tools/list"},
          {"authorization", "Bearer secret-key"}
        ])

      assert conn.status == 200
    end

    test "a browser origin is refused unless it was configured" do
      # check_origin in the endpoint config governs sockets, not HTTP. Without this a page the
      # user visits can drive their own coordinator.
      conn =
        send_rpc(rpc("tools/list"), [
          {"mcp-protocol-version", @version},
          {"mcp-method", "tools/list"},
          {"origin", "https://evil.example"}
        ])

      assert conn.status == 403

      Application.put_env(:coordinator, :mcp_allowed_origins, ["https://good.example"])

      conn =
        send_rpc(rpc("tools/list"), [
          {"mcp-protocol-version", @version},
          {"mcp-method", "tools/list"},
          {"origin", "https://good.example"}
        ])

      assert conn.status == 200
    end

    test "an agent client sends no Origin at all and is unaffected" do
      assert send_rpc(rpc("tools/list")).status == 200
    end

    test "the endpoint can be turned off" do
      Application.put_env(:coordinator, :mcp_enabled, false)

      assert send_rpc(rpc("tools/list")).status == 404
    end
  end
end
