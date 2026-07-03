ExUnit.start()

defmodule Coordinator.WorkerTestHelper do
  @moduledoc """
  Seed connected workers into `Coordinator.Presence` for tests, mirroring what a real
  `WorkerChannel` does. Each seeded worker is tracked by a dedicated process spawn_link'd to
  the test, so it is untracked automatically when the test ends (per-test isolation) or when
  `stop/1` is called (simulating a channel going down).
  """
  alias Coordinator.{Worker, WorkerRegistry}

  @doc "Track a worker (`%Worker{}` or a registration map). Returns the tracker pid."
  def track(worker_or_registration) do
    worker =
      case worker_or_registration do
        %Worker{} = w -> w
        map when is_map(map) -> Worker.from_registration(map)
      end

    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, _ref} = WorkerRegistry.track(self(), worker)
        send(parent, {:tracked, self()})
        receive(do: (:stop -> :ok))
      end)

    receive do
      {:tracked, ^pid} -> :ok
    after
      2000 -> raise "worker #{worker.worker_id} was not tracked in time"
    end

    wait_until(fn -> Enum.any?(WorkerRegistry.list(), &(&1.worker_id == worker.worker_id)) end)
    pid
  end

  @doc "Disconnect a tracked worker; blocks until it leaves Presence."
  def stop(pid) when is_pid(pid) do
    Process.unlink(pid)
    ref = Process.monitor(pid)
    send(pid, :stop)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      2000 -> :ok
    end

    :ok
  end

  defp wait_until(fun, tries \\ 100)
  defp wait_until(_fun, 0), do: :ok

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, tries - 1)
    end
  end

  @doc "Block until `worker_id` is gone from Presence (after `stop/1`)."
  def wait_gone(worker_id) do
    wait_until(fn -> not Enum.any?(WorkerRegistry.list(), &(&1.worker_id == worker_id)) end)
  end

  @doc "Block until `worker_id` appears in Presence (a real channel tracks it asynchronously)."
  def wait_present(worker_id) do
    wait_until(fn -> Enum.any?(WorkerRegistry.list(), &(&1.worker_id == worker_id)) end)
  end
end
