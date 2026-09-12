defmodule Coordinator.Usage do
  @moduledoc """
  Per-key token accounting.

  Workers report an aggregated `usage` map with every result. That report used to be sanitized
  and then dropped on the floor, so a completed job left no trace of who paid for it. Each
  terminal result now writes one `usage_records` row, attributed to the `api_token_id` carried
  on the job the result belongs to.

  The row holds counts and a model name only — never prompt text, never a provider token.
  Writes are best-effort: accounting must never fail a caller's request, and a duplicate result
  for the same job is absorbed by the unique index on `job_id` rather than double-counted.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Coordinator.Jobs.JobRecord
  alias Coordinator.Repo
  alias Coordinator.Usage.UsageRecord

  @doc """
  Record one job's usage from a worker's normalized result.

  Looks up the job to find the submitting key (the result itself is worker-supplied and must
  not be trusted to name a key). Returns `{:ok, record}`, `{:error, reason}`, or `:ignored`
  when the job is unknown — ad-hoc jobs that were never persisted still report results.
  """
  def record_result(%{"job_id" => job_id} = result) when is_binary(job_id) do
    case Repo.get(JobRecord, job_id) do
      nil -> :ignored
      job -> insert(job, result)
    end
  rescue
    # Accounting is not worth failing a request over; a lost row is better than a 500.
    error ->
      Logger.warning("usage accounting failed for #{inspect(job_id)}: #{inspect(error)}")
      {:error, :exception}
  end

  def record_result(_), do: :ignored

  @doc """
  Total tokens a key consumed since `since`. The window query the `[:api_token_id,
  :inserted_at]` index exists for.
  """
  def tokens_since(api_token_id, %DateTime{} = since) when is_binary(api_token_id) do
    from(u in UsageRecord,
      where: u.api_token_id == ^api_token_id and u.inserted_at >= ^since,
      select: coalesce(sum(u.total_tokens), 0)
    )
    |> Repo.one()
  end

  @doc "Every usage row for a key, newest first. Used by the admin console and tests."
  def list_for_token(api_token_id, limit \\ 100) when is_binary(api_token_id) do
    from(u in UsageRecord,
      where: u.api_token_id == ^api_token_id,
      order_by: [desc: u.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "The usage row for one job, if it has completed."
  def get_by_job(job_id) when is_binary(job_id), do: Repo.get_by(UsageRecord, job_id: job_id)

  defp insert(%JobRecord{} = job, result) do
    usage = result["usage"] || %{}
    input = int(usage["input_tokens"])
    output = int(usage["output_tokens"])

    attrs = %{
      "id" => "use-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)),
      "job_id" => job.id,
      "api_token_id" => job.api_token_id,
      "worker_id" => job.worker_id,
      "model" => usage["model"] || job.payload["model"],
      "status" => result["status"],
      "input_tokens" => input,
      "output_tokens" => output,
      # Trust the worker's total when it sends one; otherwise derive it.
      "total_tokens" => int(usage["total_tokens"]) |> zero_to(input + output)
    }

    %UsageRecord{}
    |> UsageRecord.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, record} ->
        {:ok, record}

      {:error, %Ecto.Changeset{} = changeset} ->
        # A re-delivered result for a job already accounted for. Not an error.
        if duplicate_job?(changeset), do: :ignored, else: {:error, changeset}
    end
  end

  defp duplicate_job?(%Ecto.Changeset{errors: errors}) do
    case Keyword.get(errors, :job_id) do
      {_message, opts} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end
  end

  defp int(n) when is_integer(n) and n >= 0, do: n
  defp int(n) when is_float(n) and n >= 0, do: trunc(n)
  defp int(_), do: 0

  defp zero_to(0, fallback), do: fallback
  defp zero_to(n, _fallback), do: n
end
