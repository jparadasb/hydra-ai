defmodule Coordinator.JobsCancellationTest do
  @moduledoc """
  Cancelling a delegated job is not the same as abandoning an HTTP request. The caller is still
  there, still holds the id, and will ask what happened — so the answer has to distinguish
  "I stopped it" from "it had already finished", and whatever the job managed to produce before
  it stopped has to survive.
  """
  use ExUnit.Case, async: false

  alias Coordinator.Jobs
  alias Coordinator.Jobs.JobRecord

  setup do
    Coordinator.Repo.delete_all(JobRecord)
    Coordinator.Repo.delete_all(Oban.Job)
    :ok
  end

  defp job do
    {:ok, record} =
      Jobs.enqueue(%{capability: "chat", privacy: "public", payload: %{"messages" => []}})

    record
  end

  defp leased do
    {:ok, record} = Jobs.mark_leased(job(), "w-1", "lease-1")
    record
  end

  test "says whether it stopped something, and is safe to repeat" do
    record = job()

    assert {:ok, :cancelled, cancelled} = Jobs.cancel(record.id)
    assert cancelled.status == "cancelled"
    assert cancelled.state == "cancelled"
    assert cancelled.failure_reason == "cancelled_by_client"
    assert %DateTime{} = cancelled.finished_at

    # Repeating it is a success that changed nothing — an agent retrying after a dropped
    # connection must not be told its cancel failed.
    assert {:ok, :already_terminal, again} = Jobs.cancel(record.id)
    assert again.finished_at == cancelled.finished_at
  end

  test "a job that already finished is reported as such, not silently re-cancelled" do
    record = leased()

    {:ok, _} =
      Jobs.complete(record.id, %{"job_id" => record.id, "status" => "ok", "output" => %{}})

    assert {:ok, :already_terminal, done} = Jobs.cancel(record.id)
    assert done.status == "done"
  end

  test "an unknown job is an error, not a silent success" do
    assert {:error, :unknown_job} = Jobs.cancel("job-never-existed")
  end

  test "what the job produced before it stopped stays on the row" do
    record = leased()

    :ok =
      Jobs.record_progress(record.id, %{
        "lease_id" => "lease-1",
        "seq" => 0,
        "phase" => "generating",
        "output_tokens" => 312,
        "model" => "qwen3-coder-30b"
      })

    {:ok, :cancelled, cancelled} = Jobs.cancel(record.id)

    # Cancelling overwrites the result and nothing else: a caller who watched this job burn
    # three hundred tokens is owed that number.
    assert cancelled.output_tokens == 312
    assert cancelled.actual_model == "qwen3-coder-30b"
    assert %DateTime{} = cancelled.started_at
  end

  test "a result arriving after cancellation does not become the job's answer" do
    # The worker had already begun responding when the cancel landed. Its output is not what the
    # caller asked for — they asked for it to stop — so a later reader must not be handed a
    # completion for a cancelled job.
    record = leased()
    {:ok, :cancelled, _} = Jobs.cancel(record.id)

    {:ok, after_cancel} =
      Jobs.complete(record.id, %{
        "job_id" => record.id,
        "lease_id" => "lease-1",
        "status" => "ok",
        "output" => %{"content" => "an answer nobody is waiting for"},
        "usage" => %{"input_tokens" => 91, "output_tokens" => 40, "model" => "qwen3-coder-30b"}
      })

    assert after_cancel.status == "cancelled"
    refute Jason.encode!(after_cancel.result) =~ "nobody is waiting"

    # The measurements are real, though, and are the last word on how far it got.
    assert after_cancel.input_tokens == 91
    assert after_cancel.output_tokens == 40
    assert after_cancel.actual_model == "qwen3-coder-30b"
  end

  test "a cancelled job is never requeued by a failing worker" do
    record = leased()
    {:ok, :cancelled, _} = Jobs.cancel(record.id)

    {:ok, _} =
      Jobs.complete(record.id, %{
        "job_id" => record.id,
        "lease_id" => "lease-1",
        "status" => "error",
        "reason" => "provider_error"
      })

    final = Jobs.get(record.id)
    assert final.status == "cancelled"
    assert final.attempts == 0
  end

  test "a cancelled job cannot be leased by an Oban attempt already in flight" do
    # The lease worker reads a pending row, the client cancels, and only then does the lease
    # write land. `mark_leased/4` is conditional on the row still being pending, so the write
    # matches nothing and the job stays cancelled.
    record = job()

    {:ok, :cancelled, _} = Jobs.cancel(record.id)

    assert {:error, :not_pending} = Jobs.mark_leased(record, "w-late", "lease-late")
    assert Jobs.get(record.id).status == "cancelled"
  end
end
