defmodule Coordinator.Stats do
  @moduledoc """
  Read-only snapshot of the coordinator's operational state for the admin dashboard
  (`Coordinator.Web.DashboardController`): connected workers (from the live
  `Coordinator.WorkerRegistry`), job counts by status, and completed/failed throughput
  bucketed per hour.

  Nothing here mutates state, and nothing here carries a secret — worker snapshots are the
  already-sanitized registry entries (capabilities + usage metadata only).
  """

  import Ecto.Query, warn: false

  alias Coordinator.{Repo, Worker, WorkerRegistry}
  alias Coordinator.Jobs.JobRecord

  @doc "Full snapshot for the dashboard JSON endpoint."
  def snapshot(hours \\ 24) do
    %{
      "workers" => workers(),
      "jobs" => job_counts(),
      "throughput" => throughput(hours),
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc "Connected workers as plain maps (safe to render / serialize)."
  def workers do
    WorkerRegistry.list()
    |> Enum.map(fn %Worker{} = w ->
      %{
        "worker_id" => w.worker_id,
        "execution_mode" => to_string(w.execution_mode),
        "provider" => w.provider_name,
        "models" => length(w.models),
        "capabilities" =>
          w.models |> Enum.flat_map(& &1.capabilities) |> Enum.uniq() |> Enum.sort(),
        "inflight" => w.inflight,
        "avg_latency_ms" => w.avg_latency_ms,
        "available" => w.available,
        "accepted_job_levels" => Enum.map(w.accepted_job_levels, &to_string/1)
      }
    end)
    |> Enum.sort_by(& &1["worker_id"])
  end

  @doc ~s(Job counts by status: %{"pending" => n, "leased" => n, "done" => n, "failed" => n}.)
  def job_counts do
    counts =
      from(j in JobRecord, group_by: j.status, select: {j.status, count(j.id)})
      |> Repo.all()
      |> Map.new()

    Map.merge(%{"pending" => 0, "leased" => 0, "done" => 0, "failed" => 0}, counts)
  end

  @doc """
  Done/failed jobs per hour for the trailing `hours` window, oldest bucket first. Every hour in
  the window is present, zero-filled, so charts don't skip quiet hours.

  The counting happens in SQL. It used to load every done/failed row of the window into the
  dashboard process and group them in Elixir — on a page that polls every few seconds, against
  a table with no index on `updated_at`. The `(status, updated_at)` index makes the scan
  proportional to recent activity, and only one row per (hour, status) comes back.
  """
  def throughput(hours \\ 24) do
    now = DateTime.utc_now()
    since = DateTime.add(now, -hours * 3600, :second)
    counts = finished_per_hour(since)
    current_hour = div(DateTime.to_unix(now), 3600)

    for offset <- (hours - 1)..0//-1 do
      hour = current_hour - offset

      %{
        "hour" => hour |> Kernel.*(3600) |> DateTime.from_unix!() |> DateTime.to_iso8601(),
        "done" => Map.get(counts, {hour, "done"}, 0),
        "failed" => Map.get(counts, {hour, "failed"}, 0)
      }
    end
  end

  # `%{{epoch_hour, status} => count}` for the window, aggregated by the database.
  defp finished_per_hour(since) do
    since
    |> throughput_query()
    |> Repo.all()
    |> Map.new(fn {status, hour, count} -> {{hour, status}, count} end)
  end

  @doc """
  The aggregate behind `throughput/1`. Public only so a test can run it through the query
  planner and assert it still uses the `(status, updated_at)` index.

  Hour bucketing is the one place the two adapters cannot share an expression, so each gets
  its own. Both reduce the timestamp to whole hours since the epoch — an integer, so nothing
  downstream depends on how either database renders a datetime.
  """
  def throughput_query(%DateTime{} = since) do
    case Repo.__adapter__() do
      Ecto.Adapters.SQLite3 ->
        from(j in JobRecord,
          where: j.status in ["done", "failed"] and j.updated_at > ^since,
          group_by: [
            j.status,
            fragment("CAST(strftime('%s', ?) / 3600 AS INTEGER)", j.updated_at)
          ],
          select:
            {j.status, fragment("CAST(strftime('%s', ?) / 3600 AS INTEGER)", j.updated_at),
             count(j.id)}
        )

      _ ->
        from(j in JobRecord,
          where: j.status in ["done", "failed"] and j.updated_at > ^since,
          group_by: [
            j.status,
            fragment("floor(extract(epoch from ?) / 3600)::bigint", j.updated_at)
          ],
          select:
            {j.status, fragment("floor(extract(epoch from ?) / 3600)::bigint", j.updated_at),
             count(j.id)}
        )
    end
  end
end
