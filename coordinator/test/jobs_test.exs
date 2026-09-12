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

  test "lease worker fails an expired job instead of snoozing or dispatching it" do
    register_local_worker("w-expired")

    {:ok, rec} =
      Jobs.enqueue(%{
        capability: "text.extract_json",
        privacy: "public",
        allow_external_providers: true,
        expires_at: DateTime.add(DateTime.utc_now(), -1, :second),
        payload: %{"messages" => []}
      })

    assert {:ok, _} = perform_job(LeaseWorker, %{job_id: rec.id})

    failed = Jobs.get(rec.id)
    assert failed.status == "failed"
    assert failed.worker_id == nil
    assert failed.result["reason"] == "deadline_expired"
  end

  test "expired lease sweeper requeues an abandoned job" do
    register_local_worker("w-stale")
    {:ok, rec} = enqueue()
    assert :ok = perform_job(LeaseWorker, %{job_id: rec.id})

    rec = Jobs.get(rec.id)

    rec
    |> JobRecord.changeset(%{"lease_expires_at" => DateTime.add(DateTime.utc_now(), -1, :second)})
    |> Coordinator.Repo.update!()

    assert :ok = perform_job(Coordinator.LeaseSweeper, %{})

    reclaimed = Jobs.get(rec.id)
    assert reclaimed.status == "pending"
    assert reclaimed.worker_id == nil
    assert reclaimed.lease_id == nil
    assert reclaimed.lease_expires_at == nil
    assert_enqueued(worker: LeaseWorker, args: %{job_id: rec.id})
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

  test "cancel marks active job terminal and ignores a late worker result" do
    register_local_worker("w-cancel")
    {:ok, rec} = enqueue()
    perform_job(LeaseWorker, %{job_id: rec.id})

    assert {:ok, %{status: "cancelled"}} = Jobs.cancel(rec.id)

    assert {:ok, %{status: "cancelled"}} =
             Jobs.complete(rec.id, %{"status" => "ok", "output" => %{"content" => "late"}})

    assert Jobs.get(rec.id).status == "cancelled"
  end
end
