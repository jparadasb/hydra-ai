defmodule Coordinator.JobsStateTest do
  @moduledoc """
  The `state` column is written by hand in every `update_all` in `Coordinator.Jobs`, because
  `update_all` bypasses changesets and nothing validates the pair at write time. These tests are
  what stands in for that validation: they drive each write path and assert the row it leaves
  behind could have passed the changeset.
  """
  use ExUnit.Case, async: false
  import Ecto.Query, only: [from: 2]

  alias Coordinator.Jobs
  alias Coordinator.Jobs.{JobRecord, State}

  setup do
    Coordinator.Repo.delete_all(JobRecord)
    Coordinator.Repo.delete_all(Oban.Job)
    :ok
  end

  defp enqueue(attrs \\ %{}) do
    {:ok, record} =
      Jobs.enqueue(
        Map.merge(
          %{capability: "chat", privacy: "public", payload: %{"messages" => []}},
          attrs
        )
      )

    record
  end

  defp assert_consistent(%JobRecord{} = record) do
    assert State.consistent?(record.status, record.state),
           "state #{inspect(record.state)} is not legal for status #{inspect(record.status)}"

    record
  end

  describe "the state/status pair" do
    test "every state maps to exactly one status, and back" do
      for state <- State.all() do
        status = State.status_for(state)
        assert status in State.statuses()
        assert state in State.states_for(status)
        assert State.consistent?(status, state)
      end

      # Every status must have somewhere to be, or a write path has no legal state to pick.
      for status <- State.statuses(), do: refute(State.states_for(status) == [])
    end

    test "a changeset refuses a pair that cannot occur" do
      changeset =
        JobRecord.changeset(%JobRecord{}, %{
          "id" => "job-bad-pair",
          "capability" => "chat",
          "privacy" => "public",
          "status" => "done",
          "state" => "generating"
        })

      refute changeset.valid?
      assert {"is not a valid state for status done", _} = changeset.errors[:state]
    end
  end

  describe "write paths" do
    test "enqueue starts queued" do
      record = enqueue() |> assert_consistent()
      assert record.status == "pending"
      assert record.state == "queued"
    end

    test "mark_routing moves within pending, and only once" do
      record = enqueue()

      assert :ok = Jobs.mark_routing(record)
      assert %{status: "pending", state: "routing"} = Jobs.get(record.id) |> assert_consistent()

      # The lease worker snoozes every 5s for up to 20 attempts; a second pass must not write.
      assert :noop = Jobs.mark_routing(Jobs.get(record.id))
    end

    test "mark_leased records when the job actually went out" do
      record = enqueue()
      {:ok, leased} = Jobs.mark_leased(record, "w-1", "lease-1")

      assert_consistent(leased)
      assert leased.status == "leased"
      assert leased.state == "leased"
      assert %DateTime{} = leased.leased_at
    end

    test "completion, failure and cancellation each land on their own state" do
      ok = enqueue()
      {:ok, ok} = Jobs.mark_leased(ok, "w-1", "l-1")
      {:ok, ok} = Jobs.complete(ok.id, %{"job_id" => ok.id, "status" => "ok", "output" => %{}})
      assert_consistent(ok)
      assert {ok.status, ok.state} == {"done", "completed"}
      assert %DateTime{} = ok.finished_at
      assert is_nil(ok.failure_reason)

      cancelled = enqueue()
      {:ok, cancelled} = Jobs.cancel(cancelled.id)
      assert_consistent(cancelled)
      assert {cancelled.status, cancelled.state} == {"cancelled", "cancelled"}
    end

    test "a job past its deadline is failed as expired, not merely failed" do
      record = enqueue(%{expires_at: DateTime.add(DateTime.utc_now(), -1, :second)})

      assert Jobs.expired?(record)
      {:ok, expired} = Jobs.fail_expired(record)

      assert_consistent(expired)
      assert {expired.status, expired.state} == {"failed", "expired"}
      assert expired.failure_reason == "deadline_expired"
    end

    test "requeue returns to queued and drops the failed attempt's measurements" do
      record = enqueue()
      {:ok, record} = Jobs.mark_leased(record, "w-1", "l-1")

      Coordinator.Repo.update_all(
        from(j in JobRecord, where: j.id == ^record.id),
        set: [output_tokens: 40, input_tokens: 7, progress_seq: 3, started_at: DateTime.utc_now()]
      )

      {:ok, _} = Jobs.requeue(Jobs.get(record.id))
      requeued = Jobs.get(record.id) |> assert_consistent()

      assert {requeued.status, requeued.state} == {"pending", "queued"}
      assert requeued.attempts == 1
      # Per-attempt measurements describe the attempt that failed.
      assert is_nil(requeued.output_tokens)
      assert is_nil(requeued.progress_seq)
      assert is_nil(requeued.started_at)
      assert is_nil(requeued.leased_at)
      # The prompt does not change between attempts.
      assert requeued.input_tokens == 7
    end

    test "a failure reason is recorded on the row, not only inside the result map" do
      record = enqueue()
      {:ok, record} = Jobs.mark_leased(record, "w-1", "l-1")

      for _ <- 1..6 do
        Jobs.complete(record.id, %{
          "job_id" => record.id,
          "status" => "error",
          "reason" => "provider_error"
        })
      end

      failed = Jobs.get(record.id) |> assert_consistent()
      assert failed.status == "failed"
      assert failed.failure_reason == "provider_error"
    end
  end

  describe "mcp_status/1" do
    test "collapses onto the five values the protocol defines" do
      assert State.mcp_status("queued") == "working"
      assert State.mcp_status("routing") == "working"
      assert State.mcp_status("generating") == "working"
      assert State.mcp_status("finalizing") == "working"
      assert State.mcp_status("completed") == "completed"
      assert State.mcp_status("cancelled") == "cancelled"
    end

    test "an exhausted job is a completed call that failed, not a protocol failure" do
      # MCP reserves `failed` for a JSON-RPC execution error. A worker that gave up after five
      # attempts against a 429 produced a well-formed result saying so, which the client renders
      # as an errored tool result.
      assert State.mcp_status("failed") == "completed"
      assert State.mcp_status("expired") == "completed"
    end
  end
end
