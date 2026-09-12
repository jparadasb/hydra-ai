defmodule Coordinator.JobsTest do
  use ExUnit.Case, async: false

  use Oban.Testing,
    repo: Coordinator.Repo,
    engine: Oban.Engines.Lite,
    notifier: Oban.Notifiers.PG

  alias Coordinator.{Jobs, LeaseWorker}
  alias Coordinator.Jobs.JobRecord
  import Ecto.Query
  import Coordinator.WorkerTestHelper

  setup do
    Coordinator.Repo.delete_all(JobRecord)
    Coordinator.Repo.delete_all(Oban.Job)
    :ok
  end

  defp register_local_worker(id) do
    track(%{
      "worker_id" => id,
      "supports_lease_heartbeat" => true,
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
    before_lease = DateTime.utc_now()

    assert :ok = perform_job(LeaseWorker, %{job_id: rec.id})

    leased = Jobs.get(rec.id)
    assert leased.status == "leased"
    assert leased.worker_id == "w1"
    assert leased.lease_id != nil
    assert DateTime.compare(leased.lease_expires_at, leased.expires_at) == :lt
    assert DateTime.compare(leased.lease_expires_at, before_lease) == :gt
  end

  test "legacy worker lease lasts until caller deadline" do
    track(%{
      "worker_id" => "w-legacy",
      "execution_mode" => "local_model",
      "models" => [
        %{
          "name" => "qwen",
          "capabilities" => ["text.extract_json"],
          "uses_external_provider" => false
        }
      ],
      "privacy" => %{"accepted_job_levels" => ["public"]}
    })

    {:ok, rec} = enqueue()
    assert :ok = perform_job(LeaseWorker, %{job_id: rec.id})
    leased = Jobs.get(rec.id)
    assert leased.lease_expires_at == leased.expires_at
  end

  test "a stale pending snapshot cannot lease a cancelled job" do
    {:ok, rec} = enqueue()
    assert {:ok, %{status: "cancelled"}} = Jobs.cancel(rec.id)
    assert {:error, :not_pending} = Jobs.mark_leased(rec, "w-race", Jobs.gen_lease_id())
    assert Jobs.get(rec.id).status == "cancelled"
  end

  test "mark_leased does not spend an attempt — attempts count failures, not handoffs" do
    register_local_worker("w-attempts")
    {:ok, rec} = enqueue()

    assert {:ok, leased} = Jobs.mark_leased(rec, "w-attempts", Jobs.gen_lease_id())
    assert leased.attempts == 0
  end

  test "requeue counts the failure against the database's attempts, not a stale snapshot" do
    {:ok, stale} = enqueue()

    from(j in JobRecord, where: j.id == ^stale.id)
    |> Coordinator.Repo.update_all(set: [attempts: 3])

    # `stale` still says 0; the increment must apply to the row, not to this snapshot.
    assert {:ok, requeued} = Jobs.requeue(stale)
    assert requeued.attempts == 4
  end

  test "a job that keeps failing exhausts exactly @max_attempts, counting each failure" do
    {:ok, rec} = enqueue()

    # Five failures: each re-queues and spends one attempt.
    for expected <- 1..5 do
      {:ok, _} = Jobs.complete(rec.id, %{"status" => "error", "reason" => "provider_error"})
      job = Jobs.get(rec.id)
      assert job.status == "pending"
      assert job.attempts == expected
    end

    # The sixth result has no budget left.
    {:ok, _} = Jobs.complete(rec.id, %{"status" => "error", "reason" => "provider_error"})
    assert Jobs.get(rec.id).status == "failed"
  end

  test "a requeued job backs off instead of retrying immediately" do
    {:ok, rec} = enqueue()
    Coordinator.Repo.delete_all(Oban.Job)

    {:ok, _} = Jobs.complete(rec.id, %{"status" => "error", "reason" => "provider_error"})

    [oban_job] =
      Coordinator.Repo.all(from(o in Oban.Job, where: o.worker == "Coordinator.LeaseWorker"))

    assert DateTime.compare(oban_job.scheduled_at, DateTime.utc_now()) == :gt

    # Later attempts wait longer: a worker erroring deterministically used to burn the whole
    # budget in a fraction of a second.
    from(j in JobRecord, where: j.id == ^rec.id)
    |> Coordinator.Repo.update_all(set: [attempts: 3, status: "pending"])

    Coordinator.Repo.delete_all(Oban.Job)
    {:ok, _} = Jobs.complete(rec.id, %{"status" => "error", "reason" => "provider_error"})

    [later] =
      Coordinator.Repo.all(from(o in Oban.Job, where: o.worker == "Coordinator.LeaseWorker"))

    assert DateTime.diff(later.scheduled_at, oban_job.scheduled_at, :second) > 0
  end

  test "enqueue is atomic: a failure leaves neither a job row nor a lease job" do
    # The invariant: a `pending` row and its lease job are created together or not at all.
    # Previously the two writes were independent, so a failure between them left a row nothing
    # would ever pick up. This drives the insert side; the Oban side shares the transaction.
    job_id = Jobs.gen_id()

    assert {:error, _} =
             Jobs.enqueue(%{
               id: job_id,
               # `capability` is required by the changeset; omitting it fails the insert.
               privacy: "public",
               allow_external_providers: true,
               payload: %{"messages" => []}
             })

    refute Jobs.get(job_id)
    refute_enqueued(worker: LeaseWorker, args: %{job_id: job_id})
  end

  test "lease heartbeat renews only the active generation" do
    register_local_worker("w-renew")
    {:ok, rec} = enqueue()
    assert :ok = perform_job(LeaseWorker, %{job_id: rec.id})
    leased = Jobs.get(rec.id)
    old_deadline = DateTime.add(DateTime.utc_now(), -1, :second)

    from(j in JobRecord, where: j.id == ^rec.id)
    |> Coordinator.Repo.update_all(set: [lease_expires_at: old_deadline])

    assert {:error, :stale_lease} = Jobs.renew_lease("w-renew", rec.id, "stale")
    assert Jobs.get(rec.id).lease_expires_at == old_deadline
    assert :ok = Jobs.renew_lease("w-renew", rec.id, leased.lease_id)
    assert DateTime.compare(Jobs.get(rec.id).lease_expires_at, old_deadline) == :gt
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

    Phoenix.PubSub.subscribe(Coordinator.PubSub, Jobs.result_topic(rec.id))

    assert {:ok, _} = perform_job(LeaseWorker, %{job_id: rec.id})

    failed = Jobs.get(rec.id)
    assert failed.status == "failed"
    assert failed.worker_id == nil
    assert failed.result["reason"] == "deadline_expired"

    assert_receive {:job_result,
                    %{"job_id" => job_id, "status" => "error", "reason" => "deadline_expired"}}

    assert job_id == rec.id
    assert :ok = perform_job(LeaseWorker, %{job_id: rec.id})
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

  test "terminal updates refresh updated_at for throughput accounting" do
    {:ok, rec} = enqueue()
    old = DateTime.add(DateTime.utc_now(), -2, :hour)

    from(j in JobRecord, where: j.id == ^rec.id)
    |> Coordinator.Repo.update_all(set: [updated_at: old])

    {:ok, _} = Jobs.complete(rec.id, %{"status" => "ok", "output" => %{}})
    assert DateTime.compare(Jobs.get(rec.id).updated_at, old) == :gt
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

  test "an expired lease spends an attempt, so a job stuck in leasing cannot retry forever" do
    register_local_worker("w-lease-attempts")
    {:ok, rec} = enqueue()
    assert :ok = perform_job(LeaseWorker, %{job_id: rec.id})
    assert Jobs.get(rec.id).attempts == 0

    from(j in JobRecord, where: j.id == ^rec.id)
    |> Coordinator.Repo.update_all(
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert :ok = Jobs.reclaim_expired_leases()

    reclaimed = Jobs.get(rec.id)
    assert reclaimed.status == "pending"
    assert reclaimed.attempts == 1
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

  defp release(job_id, worker_id, lease_id) do
    from(j in JobRecord, where: j.id == ^job_id)
    |> Coordinator.Repo.update_all(set: [worker_id: worker_id, lease_id: lease_id])
  end

  test "an OK result from a superseded lease generation cannot decide the job" do
    register_local_worker("w-gen-ok")
    {:ok, rec} = enqueue()
    perform_job(LeaseWorker, %{job_id: rec.id})
    stale_lease = Jobs.get(rec.id).lease_id
    release(rec.id, "w-gen-2", "lease-gen-2")

    assert {:error, :stale_lease} =
             Jobs.complete(rec.id, %{
               "status" => "ok",
               "lease_id" => stale_lease,
               "output" => %{"content" => "late"}
             })

    live = Jobs.get(rec.id)
    assert live.status == "leased"
    assert live.lease_id == "lease-gen-2"
    assert live.result == nil
  end

  test "a non-OK result from a superseded lease generation does not requeue the live lease" do
    register_local_worker("w-gen-err")
    {:ok, rec} = enqueue()
    perform_job(LeaseWorker, %{job_id: rec.id})
    stale_lease = Jobs.get(rec.id).lease_id
    release(rec.id, "w-gen-2", "lease-gen-2")
    Coordinator.Repo.delete_all(Oban.Job)

    assert {:error, :stale_lease} =
             Jobs.complete(rec.id, %{
               "status" => "error",
               "reason" => "provider_error",
               "lease_id" => stale_lease
             })

    live = Jobs.get(rec.id)
    assert live.status == "leased"
    assert live.worker_id == "w-gen-2"
    assert live.lease_id == "lease-gen-2"
    refute_enqueued(worker: LeaseWorker, args: %{job_id: rec.id})
  end

  test "a result carrying the current lease generation completes the job" do
    register_local_worker("w-gen-live")
    {:ok, rec} = enqueue()
    perform_job(LeaseWorker, %{job_id: rec.id})
    lease_id = Jobs.get(rec.id).lease_id

    assert {:ok, _} =
             Jobs.complete(rec.id, %{
               "status" => "ok",
               "lease_id" => lease_id,
               "output" => %{"content" => "x"}
             })

    assert Jobs.get(rec.id).status == "done"
  end

  test "a reclaim that cannot re-queue leaves the worker's lease uncancelled" do
    Phoenix.PubSub.subscribe(Coordinator.PubSub, "worker:w-rollback")
    register_local_worker("w-rollback")
    {:ok, rec} = enqueue()
    perform_job(LeaseWorker, %{job_id: rec.id})

    from(j in JobRecord, where: j.id == ^rec.id)
    |> Coordinator.Repo.update_all(
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    # Break the Oban table so `enqueue_lease/1` fails inside the reclaim transaction.
    Coordinator.Repo.query!("ALTER TABLE oban_jobs RENAME TO oban_jobs_unavailable")

    try do
      catch_error(Jobs.reclaim_expired_leases())
    after
      Coordinator.Repo.query!("ALTER TABLE oban_jobs_unavailable RENAME TO oban_jobs")
    end

    refute_receive %Phoenix.Socket.Broadcast{event: "cancel"}, 100
    assert Jobs.get(rec.id).status == "leased"
    assert Jobs.get(rec.id).worker_id == "w-rollback"
  end

  test "a reclaim that re-queues cancels the superseded lease generation" do
    Phoenix.PubSub.subscribe(Coordinator.PubSub, "worker:w-reclaim-cancel")
    register_local_worker("w-reclaim-cancel")
    {:ok, rec} = enqueue()
    perform_job(LeaseWorker, %{job_id: rec.id})
    lease_id = Jobs.get(rec.id).lease_id

    from(j in JobRecord, where: j.id == ^rec.id)
    |> Coordinator.Repo.update_all(
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert :ok = Jobs.reclaim_expired_leases()

    assert_receive %Phoenix.Socket.Broadcast{
      event: "cancel",
      payload: %{"job_id" => cancelled_job, "lease_id" => cancelled_lease}
    }

    assert cancelled_job == rec.id
    assert cancelled_lease == lease_id
    assert Jobs.get(rec.id).status == "pending"
  end

  test "a job without a caller deadline still gets a sweepable lease deadline" do
    register_local_worker("w-no-deadline")

    {:ok, rec} =
      Jobs.enqueue(%{
        capability: "text.extract_json",
        privacy: "public",
        allow_external_providers: true,
        expires_at: nil,
        payload: %{"messages" => []}
      })

    assert rec.expires_at == nil
    assert {:ok, leased} = Jobs.mark_leased(rec, "w-no-deadline", Jobs.gen_lease_id())
    assert leased.lease_expires_at != nil
    assert DateTime.compare(leased.lease_expires_at, DateTime.utc_now()) == :gt
  end
end
