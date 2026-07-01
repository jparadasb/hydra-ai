defmodule Coordinator.IntegrationTest do
  @moduledoc """
  True end-to-end: starts the real `hydra-worker` binary, lets it connect to the live
  endpoint over a WebSocket, leases it a job, and observes the result come back — asserting
  the coordinator only ever sees metadata, never a token.
  """
  use ExUnit.Case, async: false

  alias Coordinator.{WorkerChannel, WorkerRegistry}

  setup_all do
    bin = Path.expand("../../worker/target/debug/hydra-worker", __DIR__)

    unless File.exists?(bin) do
      System.cmd("cargo", ["build", "-p", "worker-cli"],
        cd: Path.expand("../../worker", __DIR__),
        stderr_to_stdout: true
      )
    end

    {:ok, bin: bin}
  end

  @tag timeout: 120_000
  test "worker binary connects, is leased a job, and returns a secret-free result", %{bin: bin} do
    tmp = Path.join(System.tmp_dir!(), "hydra-itest-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "cfg/worker"))

    # The worker derives its own machine-based worker_id and proves it with a device key, so
    # we don't pin one here — we discover whichever id it registers.
    File.write!(
      Path.join(tmp, "cfg/worker/config.json"),
      Jason.encode!(%{
        worker_id: "ignored-overridden-by-machine-id",
        execution_mode: "both",
        coordinator_url: "ws://127.0.0.1:4002"
      })
    )

    existing = MapSet.new(WorkerRegistry.list(), & &1.worker_id)

    env = [
      {~c"XDG_CONFIG_HOME", String.to_charlist(Path.join(tmp, "cfg"))},
      {~c"XDG_DATA_HOME", String.to_charlist(Path.join(tmp, "data"))},
      {~c"HYDRA_VAULT_PASSPHRASE", ~c"itest"},
      {~c"HYDRA_COORDINATOR_URL", ~c"ws://127.0.0.1:4002"}
    ]

    port = Port.open({:spawn_executable, bin}, [:binary, :exit_status, args: ["run"], env: env])

    Phoenix.PubSub.subscribe(Coordinator.PubSub, "job_results")

    # Wait for the worker to register over the socket (device-authenticated), capturing the
    # machine-derived worker_id it chose.
    worker_id = wait_for_new_worker(existing, 50)
    assert worker_id, "worker did not register within timeout"

    # Use a capability the worker does not advertise so the gateway rejects immediately —
    # this keeps the e2e deterministic (no dependency on a live model's inference latency)
    # while still exercising the full socket round-trip and the secret-free result contract.
    job = %{
      "job_id" => "itest-job-1",
      "capability" => "capability.not.served",
      "privacy" => "public",
      "allow_external_providers" => true,
      "payload" => %{"messages" => [%{"role" => "user", "content" => "hi"}]}
    }

    WorkerChannel.lease(worker_id, job)

    assert_receive {:job_result, result}, 15_000
    assert result["job_id"] == "itest-job-1"
    assert result["status"] == "rejected"

    serialized = result |> Jason.encode!() |> String.downcase()

    for needle <- ["\"token\"", "api_key", "authorization", "bearer ", "sk-", "secret"] do
      refute String.contains?(serialized, needle), "result leaked #{needle}: #{serialized}"
    end

    Port.close(port)
    File.rm_rf(tmp)
  end

  defp wait_for_new_worker(_existing, 0), do: nil

  defp wait_for_new_worker(existing, tries) do
    case Enum.find(WorkerRegistry.list(), &(&1.worker_id not in existing)) do
      %{worker_id: id} ->
        id

      nil ->
        Process.sleep(100)
        wait_for_new_worker(existing, tries - 1)
    end
  end
end
