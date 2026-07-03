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
        "capabilities" => w.models |> Enum.flat_map(& &1.capabilities) |> Enum.uniq() |> Enum.sort(),
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
  Done/failed jobs per hour for the trailing `hours` window, oldest bucket first. Buckets are
  built in Elixir (not SQL date functions) so SQLite dev and Postgres prod behave identically.
  Every hour in the window is present, zero-filled, so charts don't skip quiet hours.
  """
  def throughput(hours \\ 24) do
    now = DateTime.utc_now()
    since = DateTime.add(now, -hours * 3600, :second)

    finished =
      from(j in JobRecord,
        where: j.status in ["done", "failed"] and j.updated_at > ^since,
        select: {j.status, j.updated_at}
      )
      |> Repo.all()
      |> Enum.group_by(fn {status, at} -> {hour_bucket(at), status} end)

    current = hour_bucket(now)

    for offset <- (hours - 1)..0//-1 do
      bucket = DateTime.add(current, -offset * 3600, :second)

      %{
        "hour" => DateTime.to_iso8601(bucket),
        "done" => finished |> Map.get({bucket, "done"}, []) |> length(),
        "failed" => finished |> Map.get({bucket, "failed"}, []) |> length()
      }
    end
  end

  defp hour_bucket(%DateTime{} = dt), do: %{dt | minute: 0, second: 0, microsecond: {0, 0}}
end
