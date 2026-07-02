defmodule Coordinator.WorkerSessionTest do
  # async: false — handle_register now reads the admin policy from the repo.
  use ExUnit.Case, async: false
  alias Coordinator.{Job, Repo, WorkerKey, WorkerPolicies, WorkerRegistry, WorkerSession}

  setup do
    {:ok, reg} = WorkerRegistry.start_link(name: nil)
    on_exit(fn -> Repo.delete_all(WorkerKey) end)
    %{reg: reg}
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
          "capabilities" => ["text.extract_json"],
          "uses_external_provider" => true
        }
      ],
      "privacy" => %{"accepted_job_levels" => ["public", "private"]}
    }
  end

  test "registers a clean worker and makes it routable", %{reg: reg} do
    assert {:ok, worker} = WorkerSession.handle_register(registration(), nil, reg)
    assert worker.worker_id == "w-ext"
    assert [%{worker_id: "w-ext"}] = WorkerRegistry.list(reg)

    job = %Job{job_id: "j", capability: "text.extract_json", privacy: :public}
    assert {:ok, %{worker_id: "w-ext"}} = WorkerRegistry.route(reg, job)
  end

  test "worker-declared privacy levels are ignored: public-only until admin grants", %{reg: reg} do
    # Registration declares public+private, but there is no admin grant.
    assert {:ok, worker} = WorkerSession.handle_register(registration(), nil, reg)
    assert worker.accepted_job_levels == [:public]

    private = %Job{job_id: "j", capability: "text.extract_json", privacy: :private, allow_external_providers: true}
    assert {:error, :no_eligible_worker} = WorkerRegistry.route(reg, private)
  end

  test "admin-granted levels apply at registration", %{reg: reg} do
    enroll("w-ext", ["public", "private"])

    assert {:ok, worker} = WorkerSession.handle_register(registration(), nil, reg)
    assert worker.accepted_job_levels == [:public, :private]

    private = %Job{job_id: "j", capability: "text.extract_json", privacy: :private, allow_external_providers: true}
    assert {:ok, %{worker_id: "w-ext"}} = WorkerRegistry.route(reg, private)
  end

  test "admin policy change applies to a connected worker immediately", %{reg: reg} do
    assert {:ok, _} = WorkerSession.handle_register(registration(), nil, reg)

    assert :ok = WorkerRegistry.update_accepted_levels(reg, "w-ext", ["public", "private"])
    assert [%{accepted_job_levels: [:public, :private]}] = WorkerRegistry.list(reg)

    assert {:error, :unknown_worker} =
             WorkerRegistry.update_accepted_levels(reg, "nope", ["public"])
  end

  test "set_accepted_levels persists for enrolled workers and rejects unknown ones" do
    enroll("w-ext", ["public"])

    assert {:ok, key} = WorkerPolicies.set_accepted_levels("w-ext", ["public", "sensitive"])
    assert key.accepted_job_levels == ["public", "sensitive"]
    assert WorkerPolicies.accepted_levels("w-ext") == ["public", "sensitive"]

    assert {:error, :not_enrolled} = WorkerPolicies.set_accepted_levels("ghost", ["public"])
    assert WorkerPolicies.accepted_levels("ghost") == ["public"]
  end

  test "refuses a registration carrying a token; nothing is registered", %{reg: reg} do
    dirty = Map.put(registration(), "token", "sk-should-not-be-here-123")
    assert {:error, :secret_key_present} = WorkerSession.handle_register(dirty, nil, reg)
    assert [] = WorkerRegistry.list(reg)
  end

  test "drops a worker when its channel process goes down", %{reg: reg} do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, _} = WorkerSession.handle_register(registration(), pid, reg)
    assert [_] = WorkerRegistry.list(reg)

    Process.exit(pid, :kill)
    # allow the DOWN message to be processed
    :sys.get_state(reg)
    Process.sleep(20)
    assert [] = WorkerRegistry.list(reg)
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
end
