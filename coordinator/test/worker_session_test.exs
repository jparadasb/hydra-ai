defmodule Coordinator.WorkerSessionTest do
  # async: false — handle_register reads admin policy from the repo, and workers are tracked in
  # the shared cluster-wide Presence.
  use ExUnit.Case, async: false
  alias Coordinator.{Job, Repo, WorkerKey, WorkerPolicies, WorkerRegistry, WorkerSession}
  import Coordinator.WorkerTestHelper

  setup do
    on_exit(fn -> Repo.delete_all(WorkerKey) end)
    :ok
  end

  defp enroll(worker_id, levels) do
    %WorkerKey{}
    |> WorkerKey.changeset(%{
      worker_id: worker_id,
      public_key: Base.encode64(:crypto.strong_rand_bytes(32)),
      status: "trusted",
      accepted_job_levels: levels
    })
    |> Repo.insert!()
  end

  defp registration do
    %{
      "worker_id" => "w-ext",
      "execution_mode" => "external_provider",
      "provider" => %{"name" => "openai", "api_type" => "openai_compatible"},
      "models" => [
        %{
          "name" => "gpt-4.1-mini",
          "capabilities" => ["wsess.extract"],
          "uses_external_provider" => true
        }
      ],
      "privacy" => %{"accepted_job_levels" => ["public", "private"]}
    }
  end

  test "registers a clean worker and makes it routable" do
    assert {:ok, worker} = WorkerSession.handle_register(registration())
    assert worker.worker_id == "w-ext"
    track(worker)
    assert Enum.any?(WorkerRegistry.list(), &(&1.worker_id == "w-ext"))

    job = %Job{job_id: "j", capability: "wsess.extract", privacy: :public}
    assert {:ok, %{worker_id: "w-ext"}} = WorkerRegistry.route(job)
  end

  test "worker-declared privacy levels are ignored: public-only until admin grants" do
    # Registration declares public+private, but there is no admin grant.
    assert {:ok, worker} = WorkerSession.handle_register(registration())
    assert worker.accepted_job_levels == [:public]
    track(worker)

    private = %Job{job_id: "j", capability: "wsess.extract", privacy: :private, allow_external_providers: true}
    assert {:error, :no_eligible_worker} = WorkerRegistry.route(private)
  end

  test "admin-granted levels apply at registration" do
    enroll("w-ext", ["public", "private"])

    assert {:ok, worker} = WorkerSession.handle_register(registration())
    assert worker.accepted_job_levels == [:public, :private]
    track(worker)

    private = %Job{job_id: "j", capability: "wsess.extract", privacy: :private, allow_external_providers: true}
    assert {:ok, %{worker_id: "w-ext"}} = WorkerRegistry.route(private)
  end

  test "set_accepted_levels persists and broadcasts a live-apply to the worker's channel" do
    enroll("w-ext", ["public"])
    # The worker's channel process subscribes to this control topic; stand in for it.
    Phoenix.PubSub.subscribe(Coordinator.PubSub, "worker_control:w-ext")

    assert {:ok, key} = WorkerPolicies.set_accepted_levels("w-ext", ["public", "sensitive"])
    assert key.accepted_job_levels == ["public", "sensitive"]
    assert WorkerPolicies.accepted_levels("w-ext") == ["public", "sensitive"]
    assert_receive {:set_accepted_levels, [:public, :sensitive]}

    assert {:error, :not_enrolled} = WorkerPolicies.set_accepted_levels("ghost", ["public"])
    assert WorkerPolicies.accepted_levels("ghost") == ["public"]
  end

  test "refuses a registration carrying a token; nothing is registered" do
    dirty = Map.put(registration(), "token", "sk-should-not-be-here-123")
    assert {:error, :secret_key_present} = WorkerSession.handle_register(dirty)
    refute Enum.any?(WorkerRegistry.list(), &(&1.worker_id == "w-ext"))
  end

  test "drops a worker when its channel process goes down" do
    {:ok, worker} = WorkerSession.handle_register(registration())
    pid = track(worker)
    assert Enum.any?(WorkerRegistry.list(), &(&1.worker_id == "w-ext"))

    stop(pid)
    wait_gone("w-ext")
    refute Enum.any?(WorkerRegistry.list(), &(&1.worker_id == "w-ext"))
  end

  test "usage report passes only when secret-free" do
    assert {:ok, _} =
             WorkerSession.handle_usage(%{
               "worker_id" => "w",
               "provider" => "openai",
               "model" => "gpt-4.1-mini",
               "period" => "2026-06",
               "requests" => 10
             })

    assert {:error, _} = WorkerSession.handle_usage(%{"authorization" => "Bearer xyzxyzxyz"})
  end

  test "handle_chunk broadcasts a sanitized fragment on the job's own topic" do
    Phoenix.PubSub.subscribe(Coordinator.PubSub, "job_chunks:job-chunk-test")

    assert {:ok, clean} =
             WorkerSession.handle_chunk(%{
               "job_id" => "job-chunk-test",
               "seq" => 0,
               "delta" => "my key is sk-abcdefghijkl and"
             })

    # Secret-shaped values are redacted, not rejected — a chunk is transient UX, never stored.
    assert clean["delta"] =~ "[REDACTED]"
    refute clean["delta"] =~ "sk-abcdefghijkl"
    assert_receive {:job_chunk, ^clean}

    # Chunks for other jobs don't land on this topic.
    assert {:ok, _} =
             WorkerSession.handle_chunk(%{"job_id" => "job-other", "seq" => 0, "delta" => "x"})

    refute_receive {:job_chunk, %{"job_id" => "job-other"}}, 50

    assert {:error, :invalid_chunk} = WorkerSession.handle_chunk(%{"delta" => "no id"})
  end
end
