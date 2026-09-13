defmodule Coordinator.JobsIdempotencyTest do
  @moduledoc """
  An agent retries after a dropped connection. Without a key that means a second run of a job
  that may occupy a GPU for minutes — the expensive failure mode, and the one the caller cannot
  see happening.
  """
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Coordinator.Repo

  alias Coordinator.Jobs
  alias Coordinator.Jobs.JobRecord

  setup do
    Coordinator.Repo.delete_all(JobRecord)
    Coordinator.Repo.delete_all(Oban.Job)
    :ok
  end

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        capability: "chat",
        privacy: "public",
        payload: %{"messages" => []},
        owner_scope: "tok:caller-a"
      },
      overrides
    )
  end

  test "the same key returns the first job and queues no second run" do
    assert {:ok, :created, first} = Jobs.submit(attrs(%{idempotency_key: "retry-1"}))
    assert {:ok, :existing, second} = Jobs.submit(attrs(%{idempotency_key: "retry-1"}))

    assert first.id == second.id
    assert Coordinator.Repo.aggregate(JobRecord, :count) == 1

    # The expensive half: one lease job, not two.
    assert [_only_one] = all_enqueued(worker: Coordinator.LeaseWorker)
  end

  test "a reused key returns the first job even when the payload differs" do
    # Documented behaviour rather than an accident: comparing payloads would mean deciding what
    # counts as the same request, and a caller reusing a key for different work has a bug the
    # coordinator cannot fix by guessing.
    {:ok, :created, first} =
      Jobs.submit(attrs(%{idempotency_key: "k", payload: %{"messages" => ["a"]}}))

    {:ok, :existing, second} =
      Jobs.submit(attrs(%{idempotency_key: "k", payload: %{"messages" => ["completely other"]}}))

    assert first.id == second.id
    assert Jobs.get(first.id).payload == %{"messages" => ["a"]}
  end

  test "the same key returns a finished job rather than running it again" do
    {:ok, :created, first} = Jobs.submit(attrs(%{idempotency_key: "done-key"}))
    {:ok, leased} = Jobs.mark_leased(first, "w-1", "l-1")

    {:ok, _} =
      Jobs.complete(leased.id, %{"job_id" => leased.id, "status" => "ok", "output" => %{}})

    assert {:ok, :existing, again} = Jobs.submit(attrs(%{idempotency_key: "done-key"}))
    assert again.id == first.id
    assert again.status == "done"
  end

  test "two callers may use the same key without colliding" do
    {:ok, :created, a} = Jobs.submit(attrs(%{idempotency_key: "shared", owner_scope: "tok:a"}))
    {:ok, :created, b} = Jobs.submit(attrs(%{idempotency_key: "shared", owner_scope: "tok:b"}))

    refute a.id == b.id
  end

  test "jobs submitted without a key never collide with each other" do
    # Both adapters treat NULL as distinct in a unique index. If they did not, the second
    # keyless submission on this coordinator would fail rather than run.
    for _ <- 1..3, do: assert({:ok, :created, _} = Jobs.submit(attrs()))

    assert Coordinator.Repo.aggregate(JobRecord, :count) == 3
  end

  test "two concurrent submissions of one key produce one job" do
    key = "race-#{System.unique_integer([:positive])}"

    results =
      1..2
      |> Enum.map(fn _ -> Task.async(fn -> Jobs.submit(attrs(%{idempotency_key: key})) end) end)
      |> Task.await_many(5000)

    assert Enum.all?(results, &match?({:ok, _, _}, &1))
    assert [id] = results |> Enum.map(fn {:ok, _, r} -> r.id end) |> Enum.uniq()
    assert is_binary(id)
    assert Coordinator.Repo.aggregate(JobRecord, :count) == 1
  end

  describe "get_for_caller/2" do
    test "a job owned by someone else is indistinguishable from one that does not exist" do
      {:ok, :created, job} = Jobs.submit(attrs(%{owner_scope: "tok:owner"}))

      assert %JobRecord{} = Jobs.get_for_caller(job.id, "tok:owner")
      # Not an authorization error: telling the two apart would let a caller probe which ids
      # are real.
      assert is_nil(Jobs.get_for_caller(job.id, "tok:someone-else"))
      assert is_nil(Jobs.get_for_caller("job-does-not-exist", "tok:owner"))
    end
  end

  describe "open_job_count/1" do
    test "counts only this caller's unfinished work" do
      {:ok, :created, queued} = Jobs.submit(attrs(%{owner_scope: "tok:counted"}))
      {:ok, :created, finished} = Jobs.submit(attrs(%{owner_scope: "tok:counted"}))
      {:ok, :created, _other} = Jobs.submit(attrs(%{owner_scope: "tok:elsewhere"}))

      {:ok, leased} = Jobs.mark_leased(finished, "w-1", "l-1")

      {:ok, _} =
        Jobs.complete(leased.id, %{"job_id" => leased.id, "status" => "ok", "output" => %{}})

      assert Jobs.open_job_count("tok:counted") == 1
      assert Jobs.get(queued.id).status == "pending"
    end
  end
end
