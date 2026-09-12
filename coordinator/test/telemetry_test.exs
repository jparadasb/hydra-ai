defmodule Coordinator.TelemetryTest do
  @moduledoc """
  Metrics and the scrape endpoint. Before this, every failure mode the coordinator has was
  invisible while it happened.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Coordinator.Telemetry

  test "the scrape renders Prometheus text including the worker gauge" do
    body = Telemetry.scrape()

    assert is_binary(body)
    # The gauge is sampled at scrape time rather than pushed, so it is present on a cold
    # process with no traffic.
    assert body =~ "hydra_workers_connected"
  end

  test "GET /metrics serves the scrape" do
    conn =
      conn(:get, "/metrics") |> Coordinator.ApiRouter.call(Coordinator.ApiRouter.init([]))

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
    assert conn.resp_body =~ "hydra_workers_connected"
  end

  test "/metrics is not advertised in the public API spec" do
    # It is an operational surface, not part of the caller-facing contract.
    conn =
      conn(:get, "/openapi.json") |> Coordinator.ApiRouter.call(Coordinator.ApiRouter.init([]))

    refute Jason.decode!(conn.resp_body)["paths"]["/metrics"]
  end

  test "job lifecycle events are defined, so a wedged worker is measurable" do
    names = Enum.map(Telemetry.metrics(), & &1.name)

    for expected <- [
          [:hydra, :job, :enqueued, :count],
          [:hydra, :job, :leased, :count],
          [:hydra, :job, :completed, :count],
          [:hydra, :job, :requeued, :count],
          # The abandoned-worker signal specifically.
          [:hydra, :lease, :reclaimed, :count],
          [:hydra, :api, :auth, :rejected, :count],
          [:hydra, :api, :rate_limited, :count],
          [:hydra, :secret_guard, :redacted, :count]
        ] do
      assert expected in names, "#{inspect(expected)} is not exposed"
    end
  end

  test "a completed job increments the completion counter" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:hydra, :job, :completed]])

    {:ok, job} =
      Coordinator.Jobs.enqueue(%{
        capability: "telemetry.test",
        privacy: "public",
        allow_external_providers: true,
        payload: %{"messages" => []}
      })

    {:ok, _} = Coordinator.Jobs.complete(job.id, %{"status" => "ok", "output" => %{}})

    assert_received {[:hydra, :job, :completed], ^ref, %{count: 1}, %{status: "done"}}

    :telemetry.detach(ref)
    Coordinator.Repo.delete_all(Coordinator.Jobs.JobRecord)
  end
end
