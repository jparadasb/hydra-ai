defmodule Coordinator.JobRetention do
  @moduledoc """
  Bounds how long the coordinator keeps job text.

  A `jobs` row stores the caller's prompt (`payload`) and the worker's completion (`result`)
  verbatim. Nothing expired them, so a deployment accumulated every prompt and completion that
  had ever crossed it — a materially different privacy posture than "the coordinator only ever
  sees capabilities and usage metadata".

  Two stages, both applied only to **terminal** jobs (`done` / `failed` / `cancelled`), so a
  job in flight is never touched:

    1. **Redaction** (`:job_redact_after_hours`, default 24) — `payload` and `result` are
       replaced with a non-identifying summary (byte size and, for the result, its status) and
       `redacted_at` is stamped. The row keeps everything the dashboard and the lease history
       need; the text is gone.
    2. **Deletion** (`:job_retention_days`, default 30) — the row itself is removed.

  Token accounting survives both: `Coordinator.Usage` rows are written when a job completes and
  are not pruned here, so "which key consumed whose GPU" outlives the prompt that asked.

  Set either knob to `0` to disable that stage.
  """
  use Oban.Worker, queue: :leases, max_attempts: 3, unique: [period: 300]

  import Ecto.Query, warn: false
  require Logger

  alias Coordinator.Jobs.JobRecord
  alias Coordinator.Repo

  @terminal ~w(done failed cancelled)

  @default_redact_after_hours 24
  @default_retention_days 30

  # Deleting or rewriting the whole backlog in one statement would hold a write lock for as
  # long as it takes; SQLite has exactly one writer. Work in bounded batches instead.
  @batch_size 500

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, %{redacted: redact_expired(), deleted: delete_expired()}}
  end

  @doc """
  Strip prompt and completion text from terminal jobs older than the redaction window.
  Returns how many rows were redacted.
  """
  def redact_expired(now \\ DateTime.utc_now()) do
    case redact_after_hours() do
      hours when is_integer(hours) and hours > 0 ->
        cutoff = DateTime.add(now, -hours * 3600, :second)
        redact_batch(cutoff, now, 0)

      _ ->
        0
    end
  end

  @doc "Delete terminal jobs older than the retention window. Returns how many rows were deleted."
  def delete_expired(now \\ DateTime.utc_now()) do
    case retention_days() do
      days when is_integer(days) and days > 0 ->
        cutoff = DateTime.add(now, -days * 86_400, :second)
        delete_batch(cutoff, 0)

      _ ->
        0
    end
  end

  # ---- internals ------------------------------------------------------------------------------

  defp redact_batch(cutoff, now, redacted) do
    ids =
      from(j in JobRecord,
        where: j.status in @terminal and j.updated_at < ^cutoff and is_nil(j.redacted_at),
        select: j.id,
        limit: @batch_size
      )
      |> Repo.all()

    case ids do
      [] ->
        redacted

      ids ->
        # Read the rows to summarize them, then write the summary back. One row at a time is
        # the honest cost of not keeping the text: each summary depends on that row's content.
        count =
          from(j in JobRecord, where: j.id in ^ids, select: {j.id, j.payload, j.result})
          |> Repo.all()
          |> Enum.reduce(0, fn {id, payload, result}, acc ->
            {n, _} =
              from(j in JobRecord, where: j.id == ^id and is_nil(j.redacted_at))
              # `updated_at` is deliberately left alone: it is when the job *finished*, which
              # is what the throughput chart buckets on. Redaction is not an update to the
              # job's lifecycle.
              |> Repo.update_all(
                set: [
                  payload: summarize(payload),
                  result: summarize_result(result),
                  redacted_at: now
                ]
              )

            acc + n
          end)

        # `redacted_at` is what excludes a row from the next batch.
        redact_batch(cutoff, now, redacted + count)
    end
  end

  defp delete_batch(cutoff, deleted) do
    ids =
      from(j in JobRecord,
        where: j.status in @terminal and j.updated_at < ^cutoff,
        select: j.id,
        limit: @batch_size
      )
      |> Repo.all()

    case ids do
      [] ->
        deleted

      ids ->
        {count, _} = from(j in JobRecord, where: j.id in ^ids) |> Repo.delete_all()
        delete_batch(cutoff, deleted + count)
    end
  end

  # What is left of a prompt after retention: its shape, not its content.
  defp summarize(nil), do: %{"redacted" => true}

  defp summarize(map) when is_map(map) do
    %{"redacted" => true, "bytes" => byte_size(Jason.encode!(map))}
  rescue
    _ -> %{"redacted" => true}
  end

  defp summarize(_), do: %{"redacted" => true}

  # The result's `status` and `reason` are operational metadata, not caller content, and the
  # dashboard reads them — keep those, drop the completion text.
  defp summarize_result(nil), do: nil

  defp summarize_result(map) when is_map(map) do
    map
    |> Map.take(["status", "reason"])
    |> Map.merge(summarize(map))
  end

  defp summarize_result(_), do: %{"redacted" => true}

  defp redact_after_hours,
    do: Application.get_env(:coordinator, :job_redact_after_hours, @default_redact_after_hours)

  defp retention_days,
    do: Application.get_env(:coordinator, :job_retention_days, @default_retention_days)
end
