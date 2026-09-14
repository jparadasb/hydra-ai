defmodule Coordinator.McpTasksTest do
  @moduledoc """
  The native tasks extension.

  The property that matters most is not that any individual field is right, but that this and
  the tool path describe the same job. A client on either path must be able to reach the same
  answer, or the fallback quietly becomes a second implementation.
  """
  use ExUnit.Case, async: false

  alias Coordinator.Jobs
  alias Coordinator.Jobs.JobRecord
  alias Coordinator.Mcp.{Server, Tasks, TaskView, Tools}

  @caller %{token_id: "tok-tasks", key: {:token, "tok-tasks"}}
  @other %{token_id: "tok-other", key: {:token, "tok-other"}}

  setup do
    Coordinator.Repo.delete_all(JobRecord)
    Coordinator.Repo.delete_all(Oban.Job)
    Application.delete_env(:coordinator, :mcp_tasks_mode)
    on_exit(fn -> Application.delete_env(:coordinator, :mcp_tasks_mode) end)
    :ok
  end

  defp ctx(tasks?, caller \\ @caller),
    do: %{caller: caller, era: :modern, tasks?: tasks?, client_capabilities: %{}}

  defp rpc(method, params),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  defp submit(ctx) do
    {:reply, response} =
      Server.handle(
        rpc("tools/call", %{
          "name" => "hydra_submit_job",
          "arguments" => %{"prompt" => "delegate me"}
        }),
        ctx
      )

    response["result"]
  end

  describe "capability negotiation" do
    test "a client that declares the extension gets a task handle from a submission" do
      result = submit(ctx(true))

      assert result["resultType"] == "task"
      assert is_binary(result["taskId"])
      assert result["status"] == "working"
      assert is_integer(result["pollIntervalMs"])
      # Derived from the retention window: a made-up ttl produces a client polling a task whose
      # text was dropped out from under it.
      assert is_integer(result["ttlMs"])
    end

    test "a client that does not gets an ordinary tool result and never sees a task" do
      result = submit(ctx(false))

      refute result["resultType"] == "task"
      assert is_binary(result["structuredContent"]["job_id"])
    end

    test "the declaration is read from the client's per-request capabilities" do
      assert Tasks.enabled?(%{"extensions" => %{Tasks.extension() => %{}}})
      refute Tasks.enabled?(%{})
      refute Tasks.enabled?(%{"extensions" => %{"something.else" => %{}}})
    end

    test "the operator can refuse to hand out task handles regardless of the client" do
      # A client whose SDK advertises the extension but whose loop does not poll would sit
      # waiting for a tool result that never arrives.
      declared = %{"extensions" => %{Tasks.extension() => %{}}}

      Application.put_env(:coordinator, :mcp_tasks_mode, :never)
      refute Tasks.enabled?(declared)
      # And the transport's decision is what reaches the server, so such a client gets a plain
      # tool result even though it asked for tasks.
      assert submit(ctx(Tasks.enabled?(declared)))["structuredContent"]["job_id"]

      Application.put_env(:coordinator, :mcp_tasks_mode, :always)
      assert Tasks.enabled?(%{})
    end

    test "a submission that failed stays a tool result: there is no job to hand back" do
      {:reply, response} =
        Server.handle(
          rpc("tools/call", %{"name" => "hydra_submit_job", "arguments" => %{}}),
          ctx(true)
        )

      assert response["result"]["isError"]
      refute response["result"]["resultType"] == "task"
    end

    test "a read tool never becomes a task, even for a tasks client" do
      # Handing back a task for a read would mean polling a task to learn the result of a poll.
      job_id = submit(ctx(true))["taskId"]

      {:reply, response} =
        Server.handle(
          rpc("tools/call", %{"name" => "hydra_get_job", "arguments" => %{"job_id" => job_id}}),
          ctx(true)
        )

      refute response["result"]["resultType"] == "task"
      assert response["result"]["structuredContent"]["state"]
    end

    test "server/discover advertises the extension" do
      {:reply, response} = Server.handle(rpc("server/discover", %{}), ctx(false))

      assert response["result"]["capabilities"]["extensions"][Tasks.extension()]
    end
  end

  describe "tasks/get" do
    test "reports the same job the tools report, in the extension's shape" do
      job_id = submit(ctx(true))["taskId"]
      {:ok, _} = Jobs.mark_leased(Jobs.get(job_id), "m40-01", "lease-1")

      :ok =
        Jobs.record_progress(job_id, %{
          "lease_id" => "lease-1",
          "seq" => 0,
          "phase" => "generating",
          "output_tokens" => 120
        })

      {:reply, response} = Server.handle(rpc("tasks/get", %{"taskId" => job_id}), ctx(true))
      task = response["result"]

      assert task["resultType"] == "complete"
      assert task["status"] == "working"
      assert task["_meta"][TaskView.meta_key()]["tokens"]["generated"] == 120

      # The same execution detail the tool path reports, from the same projection.
      {:ok, tool} = Tools.call("hydra_get_job", %{"job_id" => job_id}, ctx(true))
      assert tool["structuredContent"]["hydra"] == task["_meta"][TaskView.meta_key()]
    end

    test "a completed task carries the result the tool path would return" do
      job_id = submit(ctx(true))["taskId"]
      {:ok, leased} = Jobs.mark_leased(Jobs.get(job_id), "m40-01", "lease-1")

      {:ok, _} =
        Jobs.complete(leased.id, %{
          "job_id" => leased.id,
          "lease_id" => "lease-1",
          "status" => "ok",
          "output" => %{"content" => "the delegated answer"}
        })

      {:reply, response} = Server.handle(rpc("tasks/get", %{"taskId" => job_id}), ctx(true))
      task = response["result"]

      assert task["status"] == "completed"
      assert task["result"]["structuredContent"]["text"] == "the delegated answer"

      {:ok, tool} = Tools.call("hydra_get_result", %{"job_id" => job_id}, ctx(true))
      assert tool == task["result"]
    end

    test "a job that gave up is a completed task carrying an error, not a failed task" do
      # The extension reserves `failed` for a JSON-RPC execution error. A worker that exhausted
      # its attempts against a 429 produced a perfectly good tool result saying so.
      job_id = submit(ctx(true))["taskId"]
      {:ok, leased} = Jobs.mark_leased(Jobs.get(job_id), "m40-01", "lease-1")

      for _ <- 1..6 do
        Jobs.complete(leased.id, %{
          "job_id" => leased.id,
          "status" => "error",
          "reason" => "provider_error"
        })
      end

      {:reply, response} = Server.handle(rpc("tasks/get", %{"taskId" => job_id}), ctx(true))

      assert response["result"]["status"] == "completed"
      assert response["result"]["result"]["isError"]
    end

    test "another caller's task is reported as unknown" do
      job_id = submit(ctx(true))["taskId"]

      {:reply, response} =
        Server.handle(rpc("tasks/get", %{"taskId" => job_id}), ctx(true, @other))

      assert response["error"]["message"] =~ "belongs to you"
    end

    test "a missing taskId is a parameter error" do
      {:reply, response} = Server.handle(rpc("tasks/get", %{}), ctx(true))
      assert response["error"]["code"] == -32_602
    end
  end

  describe "tasks/cancel" do
    test "stops the job and acknowledges, and is safe to repeat" do
      job_id = submit(ctx(true))["taskId"]

      {:reply, first} = Server.handle(rpc("tasks/cancel", %{"taskId" => job_id}), ctx(true))
      assert first["result"]["resultType"] == "complete"
      assert Jobs.get(job_id).status == "cancelled"

      {:reply, second} = Server.handle(rpc("tasks/cancel", %{"taskId" => job_id}), ctx(true))
      assert second["result"]["resultType"] == "complete"
    end

    test "a caller cannot cancel another caller's task" do
      job_id = submit(ctx(true))["taskId"]

      {:reply, response} =
        Server.handle(rpc("tasks/cancel", %{"taskId" => job_id}), ctx(true, @other))

      assert response["error"]
      assert Jobs.get(job_id).status == "pending"
    end
  end

  describe "tasks/update" do
    test "a job that is not waiting is told so rather than silently acknowledged" do
      # A bare acknowledgement would tell the caller their input had been accepted by something.
      job_id = submit(ctx(true))["taskId"]

      {:reply, response} =
        Server.handle(
          rpc("tasks/update", %{"taskId" => job_id, "inputResponses" => %{}}),
          ctx(true)
        )

      assert response["error"]["code"] == -32_602
      assert response["error"]["message"] =~ "not waiting for input"
    end
  end
end
