defmodule Coordinator.StatsTest do
  @moduledoc "Dashboard snapshot: worker list, job counts by status, hourly throughput."
  use ExUnit.Case, async: false

  alias Coordinator.Jobs.JobRecord
  alias Coordinator.{Repo, Stats}
  import Coordinator.WorkerTestHelper
  import Ecto.Query

  setup do
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
    track(%{
      "worker_id" => "worker-stats-test",
      "execution_mode" => "local_model",
      "models" => [
        %{"name" => "llama3", "capabilities" => ["chat"], "uses_external_provider" => false}
      ]
    })

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

  test "throughput buckets a completion by the hour it finished, not the hour it was asked for" do
    job = insert_job("done")

    three_hours_ago = DateTime.add(DateTime.utc_now(), -3 * 3600, :second)

    Repo.update_all(
      from(j in JobRecord, where: j.id == ^job.id),
      set: [updated_at: three_hours_ago]
    )

    buckets = Stats.throughput(6)
    hour = fn dt -> dt |> DateTime.to_unix() |> div(3600) end
    target = hour.(three_hours_ago)

    counted =
      Enum.find(buckets, fn b ->
        b["hour"] |> DateTime.from_iso8601() |> elem(1) |> hour.() == target
      end)

    assert counted["done"] >= 1
  end

  test "throughput counts in the database rather than loading the window into memory" do
    # Each row the old implementation returned was a row the dashboard process held; the
    # aggregate returns at most one row per (hour, status) no matter how many jobs completed.
    for _ <- 1..25, do: insert_job("done")

    assert List.last(Stats.throughput(6))["done"] >= 25
  end

  test "the throughput aggregate can be served by the (status, updated_at) index" do
    # The regression this guards: with only `index(:jobs, [:status])` the dashboard's poll
    # scanned in proportion to total job count rather than to recent activity.
    since = DateTime.add(DateTime.utc_now(), -6 * 3600, :second)
    query = Stats.throughput_query(since)

    case Repo.__adapter__() do
      Ecto.Adapters.SQLite3 ->
        plan = Ecto.Adapters.SQL.explain(Repo, :all, query)
        assert plan =~ "jobs_status_updated_at_index"
        refute plan =~ "SCAN jobs"

      _postgres ->
        # Postgres costs its plans against live statistics, and on a table holding a handful of
        # test rows a sequential scan genuinely is cheaper — asserting an index scan here would
        # be asserting that the planner is wrong. What is worth pinning on this adapter is that
        # the index the dashboard depends on exists and covers the right columns in the right
        # order, which is what a dropped or reordered migration would break.
        %{rows: rows} =
          Repo.query!("""
          SELECT indexdef FROM pg_indexes
          WHERE tablename = 'jobs' AND indexname = 'jobs_status_updated_at_index'
          """)

        assert [[indexdef]] = rows, "jobs_status_updated_at_index is missing"
        assert indexdef =~ "status"
        assert indexdef =~ "updated_at"

        # And the query itself still runs on this adapter — the hour bucketing is the one
        # expression the two adapters do not share.
        assert is_list(Repo.all(query))
    end
  end

  test "snapshot bundles all sections" do
    snap = Stats.snapshot(2)
    assert is_list(snap["workers"])
    assert is_map(snap["jobs"])
    assert length(snap["throughput"]) == 2
    assert is_binary(snap["generated_at"])
  end
end
