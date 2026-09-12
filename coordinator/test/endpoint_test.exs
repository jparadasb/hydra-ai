defmodule Coordinator.EndpointTest do
  @moduledoc """
  Endpoint-level limits that the router never sees, driven over real HTTP against the test
  endpoint (`config/test.exs` runs it with `server: true` on 127.0.0.1:4002).
  """
  use ExUnit.Case, async: false

  @base "http://127.0.0.1:4002"

  test "a body past the cap is refused instead of being persisted into a job row" do
    # Plug's default cap is 8 MB and the body lands verbatim in `jobs.payload`, so the cap is
    # the only thing standing between one caller and arbitrarily large rows.
    cap = Application.get_env(:coordinator, :max_body_bytes, 2_000_000)

    oversized =
      Jason.encode!(%{
        "model" => "test-model",
        "messages" => [%{"role" => "user", "content" => String.duplicate("x", cap + 1_000)}]
      })

    assert {:ok, %{status: 413}} =
             Req.post(@base <> "/v1/chat/completions",
               body: oversized,
               headers: [{"content-type", "application/json"}],
               retry: false
             )
  end

  test "a body within the cap is parsed normally" do
    body = %{"model" => "test-model", "messages" => []}

    # No worker is connected, so this is rejected on its merits (empty messages) rather than
    # on its size — which is the point: the parser accepted it.
    assert {:ok, %{status: 400}} =
             Req.post(@base <> "/v1/chat/completions", json: body, retry: false)
  end
end
