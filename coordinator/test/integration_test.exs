defmodule Coordinator.IntegrationTest do
  @moduledoc """
  True end-to-end: starts the real `hydra-worker` binary, lets it connect to the live endpoint
  over a WebSocket, and drives a **real completion** through it — coordinator → lease → worker
  → provider adapter → result, blocking and streamed.

  The provider on the far end is `Coordinator.MockProvider` rather than a live model, so the
  test is deterministic and offline. Everything between the coordinator and it is the real
  thing: the real binary, the real socket, the real adapter, the real vault.

  This used to lease a capability no worker advertised so the worker rejected it immediately.
  That covered the socket round-trip and the secret-free contract and nothing else — no
  adapter, no completion, no stream, and never `LeaseWorker`'s routing path.
  """
  use ExUnit.Case, async: false

  alias Coordinator.{Jobs, MockProvider, WorkerRegistry}
  alias Coordinator.Jobs.JobRecord

  @moduletag timeout: 180_000

  setup_all do
    worker_dir = Path.expand("../../worker", __DIR__)
    target_dir = System.get_env("CARGO_TARGET_DIR", Path.join(worker_dir, "target"))
    bin = Path.join([target_dir, "debug", "hydra-worker"])

    unless File.exists?(bin) do
      {output, status} =
        System.cmd("cargo", ["build", "-p", "worker-cli"],
          cd: worker_dir,
          stderr_to_stdout: true
        )

      assert status == 0, "worker build failed:\n#{output}"
    end

    # The worker's id is derived from the machine and is therefore stable, but each run gets a
    # fresh device key (a fresh XDG_DATA_HOME). The coordinator pins the first key it sees for
    # an id — trust on first use — so a pin left by an earlier run rejects this run's key with
    # a 403 on the socket upgrade, and the worker never registers.
    #
    # That is exactly what made this test "flaky": it passed the first time on any machine and
    # failed every time after, while CI (a fresh database each run) never saw it.
    Coordinator.Repo.delete_all(Coordinator.WorkerKey)

    {:ok, provider_pid, provider_url} = MockProvider.start_link()

    tmp = Path.join(System.tmp_dir!(), "hydra-itest-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "cfg/worker"))

    # The worker derives its own machine-based worker_id and proves it with a device key, so
    # we don't pin one here — we discover whichever id it registers.
    File.write!(
      Path.join(tmp, "cfg/worker/config.json"),
      Jason.encode!(%{
        worker_id: "ignored-overridden-by-machine-id",
        execution_mode: "both",
        coordinator_url: "ws://127.0.0.1:4002",
        # The mock is an external provider, so the job must permit external *and* the worker's
        # policy must allow it at that level — `public` is not in the default policy.
        routing: %{
          preference: "prefer_external",
          fallback_to_external_provider: true,
          external_provider_allowed_privacy_levels: ["public", "private"]
        },
        privacy: %{
          accepted_job_levels: ["public", "private"],
          allow_private_jobs: true,
          allow_sensitive_jobs: false
        }
      })
    )

    env = [
      {~c"XDG_CONFIG_HOME", String.to_charlist(Path.join(tmp, "cfg"))},
      {~c"XDG_DATA_HOME", String.to_charlist(Path.join(tmp, "data"))},
      {~c"HYDRA_VAULT_PASSPHRASE", ~c"itest"}
    ]

    # Seed the vault through the real CLI rather than writing an encrypted file from Elixir —
    # `provider add` is part of what this exercises, and `HYDRA_PROVIDER_TOKEN` is the
    # documented automation path.
    {output, status} =
      System.cmd(bin, ["provider", "add", "custom", "--base-url", provider_url],
        env: [{"HYDRA_PROVIDER_TOKEN", "sk-itest-provider-token"} | stringify(env)],
        stderr_to_stdout: true
      )

    assert status == 0, "provider add failed:\n#{output}"
    # The CLI must never echo a token back, only a masked fingerprint.
    refute output =~ "sk-itest-provider-token"

    existing = MapSet.new(WorkerRegistry.list(), & &1.worker_id)

    port =
      Port.open({:spawn_executable, bin}, [
        :binary,
        :exit_status,
        args: ["run"],
        env: [{~c"HYDRA_COORDINATOR_URL", ~c"ws://127.0.0.1:4002"} | env]
      ])

    # Capture the OS pid now, while the port is still open. `on_exit` runs after the owning
    # process has exited, and Erlang closes that process's ports with it — so asking for
    # `Port.info(port, :os_pid)` there returns nil and the worker is never killed. It then
    # outlives the suite, holds the test runner's stdout pipe open, and goes on advertising
    # `chat` to every other test's jobs.
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    worker_id = wait_for_new_worker(existing, 100)

    # On failure, show what the worker said. Discarding its output is why a registration
    # timeout here was undiagnosable for so long: the message named the symptom and nothing
    # else, while the worker had been logging the cause the whole time.
    assert worker_id, """
    worker did not register within timeout.

    worker output:
    #{drain_port(port)}
    """

    on_exit(fn ->
      # Stop the worker, and wait for the coordinator to notice. A live worker advertising
      # `chat` is an eligible route for every other test's jobs, so leaving it running turns
      # this module into cross-test interference — which is what happens if the port is merely
      # left to be garbage collected.
      # Closing the port only closes our end of the pipe; `hydra-worker run` never reads stdin,
      # so it does not notice. Kill the process itself.
      if os_pid, do: System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
      wait_for_worker_gone(worker_id, 200)

      if Process.alive?(provider_pid), do: Process.exit(provider_pid, :normal)
      File.rm_rf(tmp)
    end)

    {:ok, worker_id: worker_id, port: port, tmp: tmp}
  end

  setup do
    MockProvider.reset()
    on_exit(fn -> Coordinator.Repo.delete_all(JobRecord) end)
    :ok
  end

  defp chat_job(extra \\ %{}) do
    Jobs.enqueue(%{
      capability: "chat",
      privacy: "public",
      allow_external_providers: true,
      payload:
        Map.merge(
          %{
            "model" => MockProvider.model(),
            "messages" => [%{"role" => "user", "content" => "hello"}]
          },
          extra
        )
    })
  end

  test "a job is routed, run against a real provider, and its result comes back" do
    # Submitted the way a caller submits, so `LeaseWorker` does the routing — the scheduler was
    # never part of this test before.
    {:ok, record} = chat_job()

    Phoenix.PubSub.subscribe(Coordinator.PubSub, Jobs.result_topic(record.id))
    assert :ok = drain_lease(record.id)

    assert_receive {:job_result, result}, 30_000
    assert result["job_id"] == record.id
    assert result["status"] == "ok"
    assert result["output"]["content"] =~ MockProvider.reply()

    # A real completion means real usage — reported by the provider, not invented.
    assert result["usage"]["input_tokens"] == 7
    assert result["usage"]["output_tokens"] == 5

    assert Jobs.get(record.id).status == "done"
  end

  test "the provider token is presented to the provider and never to the coordinator" do
    {:ok, record} = chat_job()

    Phoenix.PubSub.subscribe(Coordinator.PubSub, Jobs.result_topic(record.id))
    assert :ok = drain_lease(record.id)
    assert_receive {:job_result, result}, 30_000

    # The worker really did authenticate to the provider…
    assert MockProvider.last_authorization() == "Bearer sk-itest-provider-token"

    # …and none of it reached the coordinator. This is the project's central claim, and this is
    # the only place it is asserted against a token that was actually used for something.
    serialized = result |> Jason.encode!() |> String.downcase()

    for needle <- ["sk-itest-provider-token", "\"token\"", "api_key", "authorization", "bearer "] do
      refute String.contains?(serialized, needle), "result leaked #{needle}: #{serialized}"
    end

    stored = Jobs.get(record.id) |> Map.from_struct() |> inspect() |> String.downcase()
    refute stored =~ "sk-itest-provider-token"
  end

  test "a streamed job delivers chunks before the final result" do
    {:ok, record} = chat_job(%{"stream" => true})

    Phoenix.PubSub.subscribe(Coordinator.PubSub, "job_chunks:" <> record.id)
    Phoenix.PubSub.subscribe(Coordinator.PubSub, Jobs.result_topic(record.id))

    assert :ok = drain_lease(record.id)

    # Chunks arrive as chunks. A worker that buffered the whole body would still produce the
    # right final result, so the fragment is what distinguishes streaming from pretending.
    assert_receive {:job_chunk, chunk}, 30_000
    assert chunk["job_id"] == record.id
    assert is_binary(chunk["delta"]) and chunk["delta"] != ""

    assert_receive {:job_result, result}, 30_000
    assert result["status"] == "ok"
    assert result["output"]["content"] =~ MockProvider.reply()
  end

  # Run the queued lease job for `job_id`. Oban is in manual testing mode, so nothing drains
  # the queue on its own.
  defp drain_lease(job_id, tries \\ 50)
  defp drain_lease(_job_id, 0), do: {:error, :never_leased}

  defp drain_lease(job_id, tries) do
    case Coordinator.LeaseWorker.perform(%Oban.Job{args: %{"job_id" => job_id}}) do
      :ok ->
        :ok

      {:snooze, _} ->
        # No eligible worker yet — its registration or catalog probe is still in flight.
        Process.sleep(200)
        drain_lease(job_id, tries - 1)

      other ->
        other
    end
  end

  defp stringify(env) do
    Enum.map(env, fn {k, v} -> {List.to_string(k), List.to_string(v)} end)
  end

  # Everything the worker has written so far, without blocking.
  defp drain_port(port, acc \\ []) do
    receive do
      {^port, {:data, data}} -> drain_port(port, [data | acc])
    after
      200 -> acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp wait_for_worker_gone(_worker_id, 0), do: :timeout

  defp wait_for_worker_gone(worker_id, tries) do
    if Enum.any?(WorkerRegistry.list(), &(&1.worker_id == worker_id)) do
      Process.sleep(50)
      wait_for_worker_gone(worker_id, tries - 1)
    else
      :ok
    end
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
