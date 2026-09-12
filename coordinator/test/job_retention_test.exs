defmodule Coordinator.JobRetentionTest do
  @moduledoc """
  Prompt/completion retention. Job rows carry the caller's prompt and the worker's completion
  verbatim; nothing used to expire them.
  """
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Coordinator.Repo

  import Ecto.Query

  alias Coordinator.JobRetention
  alias Coordinator.Jobs
  alias Coordinator.Jobs.JobRecord
  alias Coordinator.Repo

  @prompt "the caller's private prompt"
  @completion "the worker's completion"

  setup do
    Repo.delete_all(JobRecord)
    Repo.delete_all(Oban.Job)

    on_exit(fn ->
      Application.delete_env(:coordinator, :job_redact_after_hours)
      Application.delete_env(:coordinator, :job_retention_days)
      Repo.delete_all(JobRecord)
    end)

    :ok
  end

  # Persist a job in a terminal state whose lifecycle timestamps are `age_hours` old.
  defp aged_job(status, age_hours, attrs \\ %{}) do
    {:ok, record} =
      Jobs.enqueue(
        Map.merge(
          %{
            capability: "retention.test",
            privacy: "public",
            allow_external_providers: true,
            payload: %{"messages" => [%{"role" => "user", "content" => @prompt}]}
          },
          attrs
        )
      )

    at = DateTime.add(DateTime.utc_now(), -age_hours * 3600, :second)

    Repo.update_all(
      from(j in JobRecord, where: j.id == ^record.id),
      set: [
        status: status,
        result: %{"status" => "ok", "output" => %{"content" => @completion}},
        updated_at: at,
        inserted_at: at
      ]
    )

    Repo.get(JobRecord, record.id)
  end

  test "a terminal job past the redaction window loses its prompt and completion" do
    Application.put_env(:coordinator, :job_redact_after_hours, 24)
    Application.put_env(:coordinator, :job_retention_days, 0)

    job = aged_job("done", 48)
    assert Jason.encode!(job.payload) =~ @prompt

    assert JobRetention.redact_expired() == 1

    redacted = Repo.get(JobRecord, job.id)
    refute Jason.encode!(redacted.payload) =~ @prompt
    refute Jason.encode!(redacted.result) =~ @completion
    assert redacted.payload["redacted"] == true
    assert redacted.payload["bytes"] > 0
    assert %DateTime{} = redacted.redacted_at

    # Operational metadata a dashboard reads survives; caller content does not.
    assert redacted.result["status"] == "ok"
    assert redacted.status == "done"
  end

  test "redaction leaves updated_at alone so throughput still buckets on when the job finished" do
    Application.put_env(:coordinator, :job_redact_after_hours, 24)
    Application.put_env(:coordinator, :job_retention_days, 0)

    job = aged_job("done", 48)
    assert JobRetention.redact_expired() == 1

    assert DateTime.compare(Repo.get(JobRecord, job.id).updated_at, job.updated_at) == :eq
  end

  test "jobs inside the window, and jobs still running, are untouched" do
    Application.put_env(:coordinator, :job_redact_after_hours, 24)
    Application.put_env(:coordinator, :job_retention_days, 0)

    recent = aged_job("done", 1)
    # A long-running job whose row is old but which has not reached a terminal state.
    running = aged_job("leased", 96)

    assert JobRetention.redact_expired() == 0

    assert Jason.encode!(Repo.get(JobRecord, recent.id).payload) =~ @prompt
    assert Jason.encode!(Repo.get(JobRecord, running.id).payload) =~ @prompt
  end

  test "redaction is idempotent" do
    Application.put_env(:coordinator, :job_redact_after_hours, 24)
    Application.put_env(:coordinator, :job_retention_days, 0)

    aged_job("failed", 48)

    assert JobRetention.redact_expired() == 1
    assert JobRetention.redact_expired() == 0
  end

  test "a terminal job past the retention window is deleted" do
    Application.put_env(:coordinator, :job_redact_after_hours, 0)
    Application.put_env(:coordinator, :job_retention_days, 30)

    old = aged_job("done", 31 * 24)
    kept = aged_job("done", 29 * 24)

    assert JobRetention.delete_expired() == 1

    refute Repo.get(JobRecord, old.id)
    assert Repo.get(JobRecord, kept.id)
  end

  test "a window of zero disables that stage" do
    Application.put_env(:coordinator, :job_redact_after_hours, 0)
    Application.put_env(:coordinator, :job_retention_days, 0)

    job = aged_job("done", 365 * 24)

    assert JobRetention.redact_expired() == 0
    assert JobRetention.delete_expired() == 0
    assert Jason.encode!(Repo.get(JobRecord, job.id).payload) =~ @prompt
  end

  test "the Oban job runs both stages" do
    Application.put_env(:coordinator, :job_redact_after_hours, 24)
    Application.put_env(:coordinator, :job_retention_days, 30)

    _to_redact = aged_job("done", 48)
    _to_delete = aged_job("done", 31 * 24)

    assert {:ok, %{redacted: redacted, deleted: deleted}} = perform_job(JobRetention, %{})
    assert deleted == 1
    # The row being deleted is also past the redaction window, so it is redacted first.
    assert redacted == 2
  end
end
