defmodule Coordinator.UsageTest do
  @moduledoc """
  Per-key token accounting. A worker's usage report used to be sanitized and then discarded,
  leaving no way to answer "which key consumed whose GPU" after a job completed.
  """
  # async: false — shares the Repo with the rest of the suite.
  use ExUnit.Case, async: false

  alias Coordinator.Jobs
  alias Coordinator.Jobs.JobRecord
  alias Coordinator.Repo
  alias Coordinator.Usage
  alias Coordinator.Usage.UsageRecord
  alias Coordinator.WorkerSession

  setup do
    on_exit(fn ->
      Repo.delete_all(UsageRecord)
      Repo.delete_all(JobRecord)
    end)

    :ok
  end

  defp enqueue(attrs \\ %{}) do
    {:ok, record} =
      Jobs.enqueue(
        Map.merge(
          %{
            capability: "usage.test",
            privacy: "public",
            allow_external_providers: true,
            payload: %{"model" => "test-model", "messages" => []}
          },
          attrs
        )
      )

    record
  end

  test "a completed job writes one usage row against the key that submitted it" do
    job = enqueue(%{api_token_id: "tok-owner"})

    assert {:ok, _} =
             WorkerSession.handle_result(%{
               "job_id" => job.id,
               "status" => "ok",
               "output" => %{"content" => "hi"},
               "usage" => %{
                 "input_tokens" => 11,
                 "output_tokens" => 7,
                 "model" => "llama-3-8b"
               }
             })

    assert %UsageRecord{} = row = Usage.get_by_job(job.id)
    assert row.api_token_id == "tok-owner"
    assert row.model == "llama-3-8b"
    assert row.input_tokens == 11
    assert row.output_tokens == 7
    # Derived when the worker reports no total of its own.
    assert row.total_tokens == 18
    assert row.status == "ok"
  end

  test "attribution comes from the job, not from the worker's result" do
    job = enqueue(%{api_token_id: "tok-real-owner"})

    assert {:ok, _} =
             WorkerSession.handle_result(%{
               "job_id" => job.id,
               "status" => "ok",
               "output" => %{"content" => "hi"},
               # A worker naming someone else's key must not be able to bill them.
               "api_token_id" => "tok-victim",
               "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
             })

    assert Usage.get_by_job(job.id).api_token_id == "tok-real-owner"
  end

  test "a re-delivered result does not double-count" do
    job = enqueue(%{api_token_id: "tok-dedupe"})

    result = %{
      "job_id" => job.id,
      "status" => "ok",
      "output" => %{"content" => "hi"},
      "usage" => %{"input_tokens" => 5, "output_tokens" => 5}
    }

    WorkerSession.handle_result(result)
    WorkerSession.handle_result(result)

    assert length(Usage.list_for_token("tok-dedupe")) == 1
    assert Usage.tokens_since("tok-dedupe", DateTime.add(DateTime.utc_now(), -60)) == 10
  end

  test "a result for a job we never persisted is ignored, not an error" do
    assert Usage.record_result(%{"job_id" => "no-such-job", "status" => "ok"}) == :ignored
  end

  test "a missing or malformed usage report still records the completion at zero" do
    job = enqueue(%{api_token_id: "tok-nousage"})

    assert {:ok, _} =
             WorkerSession.handle_result(%{
               "job_id" => job.id,
               "status" => "ok",
               "output" => %{"content" => "hi"},
               "usage" => %{"input_tokens" => "lots"}
             })

    row = Usage.get_by_job(job.id)
    assert row.input_tokens == 0
    assert row.output_tokens == 0
    assert row.total_tokens == 0
  end

  test "tokens_since only counts the window asked for" do
    job = enqueue(%{api_token_id: "tok-window"})

    assert {:ok, _} =
             WorkerSession.handle_result(%{
               "job_id" => job.id,
               "status" => "ok",
               "output" => %{"content" => "hi"},
               "usage" => %{"input_tokens" => 3, "output_tokens" => 4, "total_tokens" => 7}
             })

    assert Usage.tokens_since("tok-window", DateTime.add(DateTime.utc_now(), -60)) == 7
    assert Usage.tokens_since("tok-window", DateTime.add(DateTime.utc_now(), 60)) == 0
  end
end
