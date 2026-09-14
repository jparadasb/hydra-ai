defmodule Coordinator.Sse do
  @moduledoc """
  Server-sent-event framing for the coordinator's streaming surfaces.

  Extracted from `Coordinator.ApiRouter` so the MCP transport streams over the same primitives
  rather than growing a second, subtly different SSE implementation — a divergence here shows up
  as a stream that works locally and stalls behind an edge proxy.

  Two properties are load-bearing and both are encoded here rather than left to call sites:

    * every response disables proxy buffering (`x-accel-buffering: no`), so a fragment reaches
      the client when it is written rather than when some buffer fills;
    * a stream that has nothing to say still says something every `heartbeat_ms/0`, because an
      edge proxy (Cloudflare's ~100s idle/TTFB window -> 524) kills a silent connection.

  What is *not* here: which events to send, and when. That is each surface's own logic — the
  OpenAI chat stream relays job chunks, MCP relays JSON-RPC messages — and the two have nothing
  in common beyond the wire format.
  """
  import Plug.Conn

  # Well under Cloudflare's ~100s idle window.
  @heartbeat_ms 15_000

  @doc "Open a chunked SSE response. Every streaming surface starts here."
  @spec open(Plug.Conn.t()) :: Plug.Conn.t()
  def open(conn) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    # Ask nginx/proxies not to buffer, so chunks flush immediately.
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
  end

  @doc "One `data:` frame carrying a JSON payload."
  @spec event(map()) :: binary()
  def event(map), do: "data: " <> Jason.encode!(map) <> "\n\n"

  @doc "The OpenAI end-of-stream sentinel."
  @spec done() :: binary()
  def done, do: "data: [DONE]\n\n"

  @doc """
  A comment frame. Clients ignore it; proxies count it as traffic, which is the whole point.
  """
  @spec ping() :: binary()
  def ping, do: ": ping\n\n"

  @doc "Encode + write each event, then `[DONE]`. Stops early if the client hung up."
  @spec send_events([map()], Plug.Conn.t()) :: Plug.Conn.t()
  def send_events(events, conn) do
    (Enum.map(events, &event/1) ++ [done()])
    |> Enum.reduce_while(conn, fn frame, conn ->
      case chunk(conn, frame) do
        {:ok, conn} -> {:cont, conn}
        {:error, _} -> {:halt, conn}
      end
    end)
  end

  @doc "How long a stream may stay silent. Overridable; tests use a tiny interval."
  @spec heartbeat_ms() :: pos_integer()
  def heartbeat_ms, do: Application.get_env(:coordinator, :api_heartbeat_ms, @heartbeat_ms)
end
