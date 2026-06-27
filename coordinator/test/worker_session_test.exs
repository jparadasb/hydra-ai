defmodule Coordinator.WorkerSessionTest do
  use ExUnit.Case, async: true
  alias Coordinator.{Job, WorkerRegistry, WorkerSession}

  setup do
    {:ok, reg} = WorkerRegistry.start_link(name: nil)
    %{reg: reg}
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
