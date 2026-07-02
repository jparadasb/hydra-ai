defmodule Coordinator.StatsTest do
  @moduledoc "Dashboard snapshot: worker list, job counts by status, hourly throughput."
  use ExUnit.Case, async: false

  alias Coordinator.Jobs.JobRecord
  alias Coordinator.{Repo, Stats, WorkerRegistry}

  setup do
    for w <- WorkerRegistry.list(), do: WorkerRegistry.unregister(w.worker_id)
    on_exit(fn -> Repo.delete_all(JobRecord) end)
    :ok
  end

  defp insert_job(status, attrs \\ %{}) do
    %JobRecord{}
    |> JobRecord.changeset(
      Map.merge(
        %{
          "id" => "job-stats-#{System.unique_integer([:positive])}",
          "capability" => "chat",
          "privacy" => "public",
          "status" => status
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  test "job_counts groups by status with zero-filled defaults" do
    insert_job("pending")
    insert_job("done")
    insert_job("done")

    counts = Stats.job_counts()
    assert counts["pending"] >= 1
    assert counts["done"] >= 2
    assert is_integer(counts["leased"]) and is_integer(counts["failed"])
  end

  test "workers reflects the live registry (no secrets, plain maps)" do
    {:ok, _} =
      WorkerRegistry.register(WorkerRegistry, %{
        "worker_id" => "worker-stats-test",
        "execution_mode" => "local_model",
        "models" => [
          %{"name" => "llama3", "capabilities" => ["chat"], "uses_external_provider" => false}
        ]
      })

    on_exit(fn -> WorkerRegistry.unregister("worker-stats-test") end)

    assert [w] = Enum.filter(Stats.workers(), &(&1["worker_id"] == "worker-stats-test"))
    assert w["execution_mode"] == "local_model"
    assert w["models"] == 1
    assert w["capabilities"] == ["chat"]
    assert w["inflight"] == 0
  end

  test "throughput zero-fills the whole window and counts recent completions" do
    insert_job("done")
    insert_job("failed")

    buckets = Stats.throughput(6)
    assert length(buckets) == 6

    # The just-inserted jobs land in the newest (current-hour) bucket.
    latest = List.last(buckets)
    assert latest["done"] >= 1
    assert latest["failed"] >= 1

    # Older buckets exist and are zero-filled integers.
    assert Enum.all?(buckets, &(is_integer(&1["done"]) and is_integer(&1["failed"])))
  end

  test "snapshot bundles all sections" do
    snap = Stats.snapshot(2)
    assert is_list(snap["workers"])
    assert is_map(snap["jobs"])
    assert length(snap["throughput"]) == 2
    assert is_binary(snap["generated_at"])
  end
end
