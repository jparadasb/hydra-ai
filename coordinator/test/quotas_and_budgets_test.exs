defmodule Coordinator.QuotasAndBudgetsTest do
  @moduledoc """
  Two ceilings for two runaways: a key spending too much over time, and a single job that grows
  without ever failing. The second only became possible once a job could pause and resume, which
  is why the retry counter cannot be what stops it.
  """
  use ExUnit.Case, async: false

  alias Coordinator.{Delegation, Jobs, Usage}
  alias Coordinator.Jobs.JobRecord

  setup do
    Coordinator.Repo.delete_all(JobRecord)
    Coordinator.Repo.delete_all(Coordinator.Usage.UsageRecord)
    Coordinator.Repo.delete_all(Oban.Job)
    on_exit(fn -> Coordinator.Repo.delete_all(Coordinator.ApiToken) end)
    :ok
  end

  defp key(limit) do
    {:ok, _plaintext, record} = Coordinator.ApiTokens.create("quota-test")

    if limit do
      record
      |> Ecto.Changeset.change(%{monthly_token_limit: limit})
      |> Coordinator.Repo.update!()
    else
      record
    end
  end

  defp caller(token), do: %{token_id: token.id, key: {:token, token.id}}

  defp spend(token, tokens) do
    {:ok, job} =
      Jobs.enqueue(%{
        capability: "chat",
        privacy: "public",
        payload: %{},
        api_token_id: token.id
      })

    {:ok, leased} = Jobs.mark_leased(job, "w-1", "l-#{System.unique_integer([:positive])}")

    Usage.record_result(%{
      "job_id" => leased.id,
      "status" => "ok",
      "usage" => %{"input_tokens" => 0, "output_tokens" => tokens, "model" => "m"}
    })
  end

  defp submit(caller, extra \\ %{}) do
    Delegation.submit(
      Map.merge(
        %{
          caller: caller,
          privacy: %{level: "public", allow_external_providers: false},
          timeout_ms: 60_000,
          payload: %{"messages" => []}
        },
        extra
      )
    )
  end

  describe "per-key quota" do
    test "a key with no limit is unlimited, which is what every existing key is" do
      token = key(nil)
      spend(token, 1_000_000)

      assert {:ok, :created, _} = submit(caller(token))
    end

    test "a key that has spent its month is refused before the job queues" do
      token = key(100)
      spend(token, 150)

      assert {:error, {:quota_exceeded, 150, 100}} = submit(caller(token))
      # Refused before queueing: the only point at which refusing costs nothing.
      assert Coordinator.Repo.aggregate(JobRecord, :count) == 1
    end

    test "a key still inside its allowance is unaffected" do
      token = key(1000)
      spend(token, 10)

      assert {:ok, :created, _} = submit(caller(token))
    end

    test "spending outside the window does not count against it" do
      token = key(100)
      spend(token, 500)

      import Ecto.Query

      Coordinator.Repo.update_all(
        from(u in Coordinator.Usage.UsageRecord),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -60, :day)]
      )

      assert {:ok, :created, _} = submit(caller(token))
    end

    test "an unidentified caller has no quota to exceed" do
      refute Usage.quota_exceeded?(nil)
    end
  end

  describe "per-job budget" do
    test "a job that reaches its budget stops rather than retrying into it" do
      token = key(nil)
      {:ok, :created, job} = submit(caller(token), %{max_total_tokens: 100})
      {:ok, leased} = Jobs.mark_leased(job, "w-1", "l-1")

      :ok =
        Jobs.record_progress(leased.id, %{
          "lease_id" => "l-1",
          "seq" => 0,
          "phase" => "generating",
          "output_tokens" => 150
        })

      # A failure that would ordinarily be retried: the budget is what stops it instead.
      {:ok, _} =
        Jobs.complete(leased.id, %{
          "job_id" => leased.id,
          "lease_id" => "l-1",
          "status" => "error",
          "reason" => "provider_error"
        })

      final = Jobs.get(job.id)
      assert final.status == "failed"
      assert final.failure_reason == "budget_exceeded"
      # Stopped by the budget, not by exhausting retries.
      assert final.attempts == 0
    end

    test "a job inside its budget retries as usual" do
      token = key(nil)
      {:ok, :created, job} = submit(caller(token), %{max_total_tokens: 10_000})
      {:ok, leased} = Jobs.mark_leased(job, "w-1", "l-1")

      {:ok, _} =
        Jobs.complete(leased.id, %{
          "job_id" => leased.id,
          "lease_id" => "l-1",
          "status" => "error",
          "reason" => "provider_error"
        })

      assert Jobs.get(job.id).status == "pending"
      assert Jobs.get(job.id).attempts == 1
    end

    test "a job with no budget is unbounded" do
      token = key(nil)
      {:ok, :created, job} = submit(caller(token))
      {:ok, leased} = Jobs.mark_leased(job, "w-1", "l-1")

      :ok =
        Jobs.record_progress(leased.id, %{
          "lease_id" => "l-1",
          "seq" => 0,
          "phase" => "generating",
          "output_tokens" => 10_000_000
        })

      {:ok, _} =
        Jobs.complete(leased.id, %{
          "job_id" => leased.id,
          "lease_id" => "l-1",
          "status" => "error",
          "reason" => "provider_error"
        })

      assert Jobs.get(job.id).status == "pending"
    end
  end

  describe "priority" do
    test "a caller's priority reaches the queue" do
      token = key(nil)
      {:ok, :created, job} = submit(caller(token), %{priority: 0})

      assert Jobs.get(job.id).priority == 0
      assert [oban_job] = Coordinator.Repo.all(Oban.Job)
      assert oban_job.priority == 0
    end

    test "a caller who names priority and leaves it empty still gets the default" do
      # A Map.get default does not fire for a key present with a nil value, and the column is
      # NOT NULL — so every MCP submission (which always sets the key) failed to insert.
      token = key(nil)
      {:ok, :created, job} = submit(caller(token), %{priority: nil})

      assert Jobs.get(job.id).priority == 1
    end

    test "a priority outside Oban's range is clamped rather than refused" do
      token = key(nil)
      {:ok, :created, job} = submit(caller(token), %{priority: 99})

      assert [oban_job] = Coordinator.Repo.all(Oban.Job)
      assert oban_job.priority == 3
      assert Jobs.get(job.id).priority == 99
    end
  end
end
