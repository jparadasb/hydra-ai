defmodule Coordinator.JobsTest do
  use ExUnit.Case, async: false

  use Oban.Testing,
    repo: Coordinator.Repo,
    engine: Oban.Engines.Lite,
    notifier: Oban.Notifiers.PG

  alias Coordinator.{Jobs, LeaseWorker}
  alias Coordinator.Jobs.JobRecord
  import Coordinator.WorkerTestHelper

  setup do
    Coordinator.Repo.delete_all(JobRecord)
    Coordinator.Repo.delete_all(Oban.Job)
    :ok
  end

  defp register_local_worker(id) do
    track(%{
      "worker_id" => id,
      "execution_mode" => "local_model",
      "models" => [
        %{
          "name" => "qwen",
          "capabilities" => ["text.extract_json"],
          "uses_external_provider" => false
        }
      ],
      "privacy" => %{
        "accepted_job_levels" => ["public", "private", "sensitive", "local_only"]
      }
    })
  end

  defp enqueue(privacy \\ "public") do
    Jobs.enqueue(%{
      capability: "text.extract_json",
      privacy: privacy,
      allow_external_providers: true,
      payload: %{"messages" => []}
    })
  end

  test "enqueue persists a pending job and schedules a lease" do
    {:ok, rec} = enqueue()
    assert rec.status == "pending"
    assert Jobs.get(rec.id).status == "pending"
    assert_enqueued(worker: LeaseWorker, args: %{job_id: rec.id})
  end

  test "lease worker assigns a pending job to an eligible worker" do
    register_local_worker("w1")
    {:ok, rec} = enqueue()

    assert :ok = perform_job(LeaseWorker, %{job_id: rec.id})

    leased = Jobs.get(rec.id)
    assert leased.status == "leased"
    assert leased.worker_id == "w1"
    assert leased.lease_id != nil
  end

  test "lease worker snoozes when no eligible worker is connected" do
    {:ok, rec} = enqueue("local_only")
    assert {:snooze, _} = perform_job(LeaseWorker, %{job_id: rec.id})
    assert Jobs.get(rec.id).status == "pending"
  end

  test "an OK result marks the job done" do
    register_local_worker("w1")
    {:ok, rec} = enqueue()
    perform_job(LeaseWorker, %{job_id: rec.id})

    {:ok, _} = Jobs.complete(rec.id, %{"status" => "ok", "output" => %{"content" => "x"}})
    assert Jobs.get(rec.id).status == "done"
  end

  test "a non-OK result re-queues the job, then fails after max attempts" do
    {:ok, rec} = enqueue()

    # First failure re-queues (back to pending, new lease scheduled).
    {:ok, _} = Jobs.complete(rec.id, %{"status" => "error", "reason" => "provider_error"})
    assert Jobs.get(rec.id).status == "pending"
    assert_enqueued(worker: LeaseWorker, args: %{job_id: rec.id})

    # Exhaust attempts -> failed.
    rec |> JobRecord.changeset(%{"attempts" => 5}) |> Coordinator.Repo.update!()
    {:ok, _} = Jobs.complete(rec.id, %{"status" => "error", "reason" => "provider_error"})
    assert Jobs.get(rec.id).status == "failed"
  end
end
