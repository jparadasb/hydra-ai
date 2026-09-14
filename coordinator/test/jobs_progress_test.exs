defmodule Coordinator.JobsProgressTest do
  @moduledoc """
  Progress is fire-and-forget from the worker: nothing acknowledges a frame, and a re-leased job
  can have an old generation still talking. So the guards are the contract — a frame that should
  not count has to affect nothing rather than be rejected loudly.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Coordinator.Jobs
  alias Coordinator.Jobs.JobRecord

  setup do
    Coordinator.Repo.delete_all(JobRecord)
    Coordinator.Repo.delete_all(Oban.Job)
    :ok
  end

  defp leased_job do
    {:ok, record} =
      Jobs.enqueue(%{capability: "chat", privacy: "public", payload: %{"model" => "qwen3-coder"}})

    {:ok, leased} = Jobs.mark_leased(record, "w-1", "lease-1")
    leased
  end

  defp frame(attrs) do
    Map.merge(%{"lease_id" => "lease-1", "seq" => 0, "phase" => "generating"}, attrs)
  end

  describe "record_progress/2" do
    test "records counts, the phase and the model the worker actually used" do
      job = leased_job()

      assert :ok =
               Jobs.record_progress(
                 job.id,
                 frame(%{
                   "output_tokens" => 12,
                   "model" => "qwen3-coder-30b",
                   "provider" => "llama_cpp"
                 })
               )

      updated = Jobs.get(job.id)
      assert updated.output_tokens == 12
      assert updated.state == "generating"
      assert updated.actual_model == "qwen3-coder-30b"
      assert updated.provider == "llama_cpp"
      # Still leased: progress says where the job is, never that it is finished.
      assert updated.status == "leased"
    end

    test "the first frame of a generation starts the clock, later frames only move it" do
      job = leased_job()

      assert :ok = Jobs.record_progress(job.id, frame(%{"seq" => 0, "output_tokens" => 1}))
      first = Jobs.get(job.id)
      assert %DateTime{} = first.started_at

      assert :ok = Jobs.record_progress(job.id, frame(%{"seq" => 1, "output_tokens" => 90}))
      second = Jobs.get(job.id)

      assert second.started_at == first.started_at
      assert DateTime.compare(second.last_progress_at, first.last_progress_at) in [:gt, :eq]
    end

    test "a replayed or reordered frame does not rewind the count" do
      job = leased_job()

      assert :ok = Jobs.record_progress(job.id, frame(%{"seq" => 5, "output_tokens" => 500}))

      assert {:error, :stale_progress} =
               Jobs.record_progress(job.id, frame(%{"seq" => 2, "output_tokens" => 20}))

      # The same seq again is a replay, not progress.
      assert {:error, :stale_progress} =
               Jobs.record_progress(job.id, frame(%{"seq" => 5, "output_tokens" => 1}))

      assert Jobs.get(job.id).output_tokens == 500
    end

    test "a superseded lease generation cannot overwrite the live one" do
      # This is why lease_id is required on a progress frame but not on a chunk: after a requeue
      # another worker owns the job, and the old generation's task may still be winding down.
      job = leased_job()
      assert :ok = Jobs.record_progress(job.id, frame(%{"output_tokens" => 10}))

      {:ok, _} = Jobs.requeue(Jobs.get(job.id))
      {:ok, released} = Jobs.mark_leased(Jobs.get(job.id), "w-2", "lease-2")

      assert {:error, :stale_progress} =
               Jobs.record_progress(released.id, frame(%{"seq" => 99, "output_tokens" => 999}))

      assert is_nil(Jobs.get(job.id).output_tokens)
    end

    test "a job that is no longer leased stops accepting progress" do
      job = leased_job()
      {:ok, :cancelled, _} = Jobs.cancel(job.id)

      assert {:error, :stale_progress} =
               Jobs.record_progress(job.id, frame(%{"output_tokens" => 5}))
    end

    test "a frame without a lease or a sequence is refused rather than partially applied" do
      job = leased_job()

      assert {:error, :invalid_progress} = Jobs.record_progress(job.id, %{"output_tokens" => 5})

      assert {:error, :invalid_progress} =
               Jobs.record_progress(job.id, %{"lease_id" => "lease-1"})
    end

    test "a count the backend did not report does not erase one it reported earlier" do
      job = leased_job()

      assert :ok =
               Jobs.record_progress(
                 job.id,
                 frame(%{"seq" => 0, "input_tokens" => 800, "output_tokens" => 4})
               )

      # A later frame carrying only output tokens must not blank the prompt size.
      assert :ok = Jobs.record_progress(job.id, frame(%{"seq" => 1, "output_tokens" => 40}))

      assert %{input_tokens: 800, output_tokens: 40} = Jobs.get(job.id)
    end

    test "progress does not touch updated_at" do
      # JobRetention and the throughput chart both read `updated_at` as "when the job finished".
      # A long job that keeps reporting would otherwise keep pushing its own redaction window
      # out and skew the dashboard for as long as it runs.
      job = leased_job()
      before = Jobs.get(job.id).updated_at

      assert :ok = Jobs.record_progress(job.id, frame(%{"output_tokens" => 3}))

      assert Jobs.get(job.id).updated_at == before
    end

    test "progress does not renew the lease" do
      # `lease_heartbeat` is the explicit liveness signal. If progress renewed the lease too,
      # "the worker is alive" and "the worker is producing tokens" would be indistinguishable —
      # and a worker wedged mid-generation would never be reclaimed.
      job = leased_job()
      before = Jobs.get(job.id).lease_expires_at

      assert :ok = Jobs.record_progress(job.id, frame(%{"output_tokens" => 3}))

      assert Jobs.get(job.id).lease_expires_at == before
    end

    test "a write only happens when something changed" do
      job = leased_job()
      assert :ok = Jobs.record_progress(job.id, frame(%{"seq" => 1}))
      assert {:error, :stale_progress} = Jobs.record_progress(job.id, frame(%{"seq" => 0}))

      assert Jobs.get(job.id).progress_seq == 1
    end
  end

  describe "progress_view/1" do
    test "throughput is measured from the first token, not from when the job started" do
      # A job announces `loading_model` before it generates anything, and on a local backend
      # loading a large model can take most of a minute. Measured from the start of execution,
      # a job generating at 20 tok/s reported 0.06 on its first frame and climbed for the rest
      # of its life without ever reaching the truth — and an agent watching that has every
      # reason to cancel a healthy job.
      job = leased_job()

      # Announced, but nothing generated yet.
      assert :ok = Jobs.record_progress(job.id, frame(%{"seq" => 0, "phase" => "loading_model"}))
      assert is_nil(Jobs.get(job.id).first_token_at)
      assert is_nil(Jobs.progress_view(Jobs.get(job.id)).tokens_per_second)

      # 40s of model loading, then 100 tokens in 5s.
      import Ecto.Query

      first = DateTime.add(DateTime.utc_now(), -5, :second)

      Coordinator.Repo.update_all(
        from(j in JobRecord, where: j.id == ^job.id),
        set: [started_at: DateTime.add(first, -40, :second)]
      )

      assert :ok = Jobs.record_progress(job.id, frame(%{"seq" => 1, "output_tokens" => 100}))

      Coordinator.Repo.update_all(
        from(j in JobRecord, where: j.id == ^job.id),
        set: [first_token_at: first]
      )

      view = Jobs.progress_view(Jobs.get(job.id))

      # ~20/s over the generating window, not ~2/s over load-plus-generate.
      assert view.tokens_per_second > 15
      # Elapsed still means "how long has this been running", which includes the load.
      assert view.elapsed_seconds > 40
    end

    test "the first-token clock is set once, not reset by every later frame" do
      job = leased_job()

      assert :ok = Jobs.record_progress(job.id, frame(%{"seq" => 0, "output_tokens" => 5}))
      first = Jobs.get(job.id).first_token_at
      assert %DateTime{} = first

      assert :ok = Jobs.record_progress(job.id, frame(%{"seq" => 1, "output_tokens" => 200}))
      assert Jobs.get(job.id).first_token_at == first
    end

    test "a re-leased attempt measures its own generation, not the previous one's" do
      job = leased_job()
      assert :ok = Jobs.record_progress(job.id, frame(%{"seq" => 0, "output_tokens" => 5}))
      assert %DateTime{} = Jobs.get(job.id).first_token_at

      {:ok, _} = Jobs.requeue(Jobs.get(job.id))
      assert is_nil(Jobs.get(job.id).first_token_at)

      {:ok, _} = Jobs.mark_leased(Jobs.get(job.id), "w-2", "lease-2")
      assert is_nil(Jobs.get(job.id).first_token_at)
    end

    test "the model actually running is reported while the job runs" do
      # Which model is running is decided by the worker's gateway, not the caller — a job may
      # name none, or name one served under a different backend. Reporting it only at completion
      # left a job that runs for minutes unable to say what was producing it.
      job = leased_job()

      assert :ok =
               Jobs.record_progress(
                 job.id,
                 frame(%{
                   "seq" => 0,
                   "phase" => "prefill",
                   "model" => "qwen3.6-35b-a3b",
                   "provider" => "llama_swap"
                 })
               )

      view = Jobs.progress_view(Jobs.get(job.id))
      assert view.actual_model == "qwen3.6-35b-a3b"
      assert view.provider == "llama_swap"
      assert view.state == "prefill"
    end

    test "derives throughput rather than trusting the worker for it" do
      job = leased_job()
      started = DateTime.add(DateTime.utc_now(), -10, :second)

      Coordinator.Repo.update_all(
        from(j in JobRecord, where: j.id == ^job.id),
        set: [
          started_at: started,
          first_token_at: started,
          last_progress_at: DateTime.add(started, 10, :second),
          output_tokens: 78,
          actual_model: "qwen3-coder-30b"
        ]
      )

      view = Jobs.progress_view(Jobs.get(job.id))

      assert view.elapsed_seconds == 10.0
      assert view.tokens_per_second == 7.8
      assert view.requested_model == "qwen3-coder"
      assert view.actual_model == "qwen3-coder-30b"
      assert view.worker_id == "w-1"
    end

    test "reports no throughput rather than an infinite one on the first frame" do
      job = leased_job()
      now = DateTime.utc_now()

      Coordinator.Repo.update_all(
        from(j in JobRecord, where: j.id == ^job.id),
        set: [started_at: now, first_token_at: now, last_progress_at: now, output_tokens: 5]
      )

      assert Jobs.progress_view(Jobs.get(job.id)).tokens_per_second == nil
    end

    test "a job that has never reported has timings but no measurements" do
      view = Jobs.progress_view(leased_job())

      assert view.state == "leased"
      assert is_nil(view.output_tokens)
      assert is_nil(view.tokens_per_second)
      assert is_nil(view.elapsed_seconds)
      assert is_number(view.queue_seconds)
    end
  end
end
