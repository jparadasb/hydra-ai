defmodule Coordinator.JobsInputRequiredTest do
  @moduledoc """
  A job that stops to ask its caller something.

  The interesting constraints are all about what a pause must *not* do: not burn a retry, not
  look like a wedged worker to the sweeper, not let the caller's thinking time expire the job,
  and not become a way to widen the privacy the job was submitted under.
  """
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Coordinator.Repo

  alias Coordinator.Jobs
  alias Coordinator.Jobs.JobRecord

  setup do
    Coordinator.Repo.delete_all(JobRecord)
    Coordinator.Repo.delete_all(Oban.Job)
    Application.delete_env(:coordinator, :max_input_rounds)
    Application.delete_env(:coordinator, :input_timeout_ms)

    on_exit(fn ->
      Application.delete_env(:coordinator, :max_input_rounds)
      Application.delete_env(:coordinator, :input_timeout_ms)
    end)

    :ok
  end

  defp leased(attrs \\ %{}) do
    {:ok, record} =
      Jobs.enqueue(
        Map.merge(
          %{
            capability: "chat",
            privacy: "local_only",
            payload: %{"messages" => [%{"role" => "user", "content" => "implement the parser"}]}
          },
          attrs
        )
      )

    {:ok, leased} = Jobs.mark_leased(record, "m40-01", "lease-1")
    leased
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        "job_id" => "ignored",
        "lease_id" => "lease-1",
        "request_id" => "ir-1",
        "requests" => [
          %{
            "tool_call_id" => "call_1",
            "arguments" => %{"kind" => "file", "path" => "src/foo.ex"}
          }
        ],
        "assistant_message" => %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [%{"id" => "call_1"}]
        }
      },
      overrides
    )
  end

  describe "parking" do
    test "the job leaves the lease behind without spending an attempt" do
      job = leased()

      {:ok, parked} = Jobs.park_for_input(job.id, request())

      assert parked.status == "awaiting_input"
      assert parked.state == "input_required"
      assert parked.attempts == 0
      assert parked.input_rounds == 1

      # The worker released it: a late result from that generation must not resurrect the job.
      assert is_nil(parked.lease_id)
      assert is_nil(parked.worker_id)
      assert parked.last_worker_id == "m40-01"
      assert %DateTime{} = parked.awaiting_input_until
    end

    test "the lease sweeper leaves it alone, because its worker is not the problem" do
      job = leased()
      {:ok, _} = Jobs.park_for_input(job.id, request())

      # Even long past any lease deadline: the job is waiting on a person, not a wedged worker.
      :ok = Jobs.reclaim_expired_leases()

      assert Jobs.get(job.id).status == "awaiting_input"
    end

    test "the question is appended to the conversation the model will resume" do
      job = leased()
      {:ok, parked} = Jobs.park_for_input(job.id, request())

      assert [%{"role" => "user"}, %{"role" => "assistant"}] = parked.payload["messages"]
    end

    test "a superseded generation cannot park a job another worker is running" do
      job = leased()
      {:ok, _} = Jobs.requeue(Jobs.get(job.id))
      {:ok, _} = Jobs.mark_leased(Jobs.get(job.id), "m40-02", "lease-2")

      assert {:error, :stale_lease} = Jobs.park_for_input(job.id, request())
      assert Jobs.get(job.id).status == "leased"
    end

    test "a model that keeps asking is eventually made to get on with it" do
      Application.put_env(:coordinator, :max_input_rounds, 1)

      job = leased()
      {:ok, _} = Jobs.park_for_input(job.id, request())
      {:ok, _} = Jobs.resume_with_input(job.id, "ir-1", %{"call_1" => "contents"})
      {:ok, again} = Jobs.mark_leased(Jobs.get(job.id), "m40-01", "lease-2")

      assert {:error, :too_many_rounds} =
               Jobs.park_for_input(
                 again.id,
                 request(%{"lease_id" => "lease-2", "request_id" => "ir-2"})
               )
    end
  end

  describe "resuming" do
    test "the answer arrives as the tool response the model was waiting for" do
      job = leased()
      {:ok, _} = Jobs.park_for_input(job.id, request())

      {:ok, resumed} =
        Jobs.resume_with_input(job.id, "ir-1", %{"call_1" => "defmodule Foo do end"})

      assert resumed.status == "pending"
      assert resumed.state == "queued"
      assert is_nil(resumed.input_request)
      assert is_nil(resumed.awaiting_input_until)

      tool_turn = List.last(resumed.payload["messages"])
      assert tool_turn["role"] == "tool"
      assert tool_turn["tool_call_id"] == "call_1"
      assert tool_turn["content"] =~ "defmodule Foo"
    end

    test "resuming is not a retry" do
      job = leased()
      {:ok, _} = Jobs.park_for_input(job.id, request())
      {:ok, resumed} = Jobs.resume_with_input(job.id, "ir-1", %{"call_1" => "x"})

      # Nothing failed, so nothing is spent — a job that asks three questions must not arrive at
      # its retry ceiling having never errored.
      assert resumed.attempts == 0
      assert [_lease_job] = all_enqueued(worker: Coordinator.LeaseWorker) |> Enum.take(1)
    end

    test "the caller's thinking time is given back" do
      # `expires_at` clamps the lease deadline and is checked before every lease. A job that kept
      # its original deadline while Hydra waited on a slow agent would be guaranteed to expire.
      job = leased()
      {:ok, parked} = Jobs.park_for_input(job.id, request())

      import Ecto.Query

      Coordinator.Repo.update_all(
        from(j in JobRecord, where: j.id == ^job.id),
        set: [updated_at: DateTime.add(DateTime.utc_now(), -120, :second)]
      )

      {:ok, resumed} = Jobs.resume_with_input(job.id, "ir-1", %{"call_1" => "x"})

      assert DateTime.compare(resumed.expires_at, parked.expires_at) == :gt
    end

    test "a duplicate answer is a no-op, not a second turn" do
      job = leased()
      {:ok, _} = Jobs.park_for_input(job.id, request())
      {:ok, first} = Jobs.resume_with_input(job.id, "ir-1", %{"call_1" => "x"})
      {:ok, second} = Jobs.resume_with_input(job.id, "ir-1", %{"call_1" => "x"})

      assert first.id == second.id
      assert length(first.payload["messages"]) == length(second.payload["messages"])
    end

    test "an answer to a question the job is not asking is refused" do
      job = leased()
      {:ok, _} = Jobs.park_for_input(job.id, request())

      assert {:error, :stale_input_request} =
               Jobs.resume_with_input(job.id, "ir-99", %{"call_1" => "x"})
    end

    test "a job that never parked cannot be resumed" do
      job = leased()
      assert {:error, :not_awaiting_input} = Jobs.resume_with_input(job.id, "ir-1", %{})
    end

    test "resuming cannot widen the privacy the job was submitted under" do
      # Otherwise a caller could submit as local_only and escalate on the way back in.
      job = leased()
      {:ok, _} = Jobs.park_for_input(job.id, request())
      {:ok, resumed} = Jobs.resume_with_input(job.id, "ir-1", %{"call_1" => "x"})

      assert resumed.privacy == "local_only"
      refute resumed.allow_external_providers
    end
  end

  describe "a caller who never answers" do
    test "the job fails rather than waiting forever" do
      # A parked job is not terminal, so retention skips it: without this the caller's prompt
      # would sit in the database indefinitely.
      Application.put_env(:coordinator, :input_timeout_ms, 0)

      job = leased()
      {:ok, _} = Jobs.park_for_input(job.id, request())

      :ok = Jobs.fail_unanswered_input()

      failed = Jobs.get(job.id)
      assert failed.status == "failed"
      assert failed.failure_reason == "input_timeout"
      # No attempt spent: asking the same unanswered question again would change nothing.
      assert failed.attempts == 0
    end

    test "a job still within its window is left alone" do
      job = leased()
      {:ok, _} = Jobs.park_for_input(job.id, request())

      :ok = Jobs.fail_unanswered_input()

      assert Jobs.get(job.id).status == "awaiting_input"
    end
  end

  test "a parked job can still be cancelled" do
    job = leased()
    {:ok, _} = Jobs.park_for_input(job.id, request())

    assert {:ok, :cancelled, cancelled} = Jobs.cancel(job.id)
    assert cancelled.status == "cancelled"
  end
end
