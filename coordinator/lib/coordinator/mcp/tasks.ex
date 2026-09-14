defmodule Coordinator.Mcp.Tasks do
  @moduledoc """
  The `io.modelcontextprotocol/tasks` extension, mapped onto Hydra jobs.

  A Hydra job already *is* a task: durable, pollable, cancellable, and outliving the connection
  that created it. So this is a projection, not a second lifecycle — `tasks/get` and
  `hydra_get_job` resolve to the same `Coordinator.Mcp.TaskView`, and `tasks/cancel` and
  `hydra_cancel_job` both call `Coordinator.Delegation.cancel/2`. The two differ only in the
  envelope, which is what keeps them from drifting apart.

  The extension has no creation method: a task comes into being when `tools/call` answers with a
  `CreateTaskResult` instead of a tool result. That only happens when the client declared the
  extension — a client that did not gets the ordinary result and polls the tools instead.

  ## Why this is not the default path

  Neither Claude Code nor Codex implements the extension at the time of writing, so the tool
  path is what actually runs and this is forward-looking. That ordering is deliberate: a client
  handed a task handle it does not understand will sit waiting for a result that never comes as
  a tool response, which is worse than never offering it. `:mcp_tasks_mode` exists so that can
  be switched off in production without a redeploy.
  """

  alias Coordinator.Jobs.{JobRecord, State}
  alias Coordinator.Mcp.{Protocol, TaskView, Tools}
  alias Coordinator.Delegation

  @extension "io.modelcontextprotocol/tasks"

  def extension, do: @extension

  @doc """
  Whether this request should be answered with task handles.

  `:auto` follows the client; `:never` and `:always` override it, which is the escape hatch for
  a client whose SDK advertises the extension but whose agent loop never polls.
  """
  def enabled?(client_capabilities) do
    case Application.get_env(:coordinator, :mcp_tasks_mode, :auto) do
      :never -> false
      :always -> true
      _ -> declared?(client_capabilities)
    end
  end

  defp declared?(%{"extensions" => %{@extension => _}}), do: true
  defp declared?(_), do: false

  @doc "What `server/discover` advertises. Unconditional: advertising is not the same as using."
  def capability, do: %{@extension => %{}}

  @doc """
  The handle returned from `tools/call` in place of a tool result.

  `ttlMs` and `pollIntervalMs` come from `TaskView`, which derives them from the retention
  window and the job's state rather than inventing them — a made-up ttl produces a client
  politely polling a task whose text was redacted out from under it.
  """
  def create_result(%JobRecord{} = job) do
    view = TaskView.render(job)

    %{
      "resultType" => "task",
      "taskId" => view["taskId"],
      "status" => status(job),
      "statusMessage" => view["statusMessage"],
      "createdAt" => view["createdAt"],
      "lastUpdatedAt" => view["lastUpdatedAt"],
      "ttlMs" => view["ttlMs"],
      "pollIntervalMs" => view["pollIntervalMs"],
      "_meta" => view["_meta"]
    }
  end

  @doc """
  Handle a `tasks/*` method.

  Returns a JSON-RPC response. Ownership is enforced the same way the tools enforce it: a task
  belonging to another caller is reported as unknown, so a task id cannot be used to probe.
  """
  def handle("tasks/get", params, id, ctx) do
    with_task(params, id, ctx, fn job ->
      Protocol.result(id, detailed(job), ctx.era)
    end)
  end

  def handle("tasks/cancel", params, id, ctx) do
    case Delegation.cancel(params["taskId"], ctx.caller) do
      {:ok, _outcome, _job} ->
        # An empty acknowledgement: the caller polls tasks/get for the new state. Cancelling
        # something already finished is still a success — repeating a cancel must not error.
        Protocol.result(id, %{"resultType" => "complete"}, ctx.era)

      {:error, :unknown_job} ->
        unknown_task(id, params["taskId"])
    end
  end

  def handle("tasks/update", params, id, ctx) do
    with_task(params, id, ctx, fn job ->
      # Resuming a parked job is Phase 3b. Until a job can enter `input_required` there is
      # nothing to resume, and answering with a bare acknowledgement would tell the caller their
      # input had been accepted when nothing received it.
      Protocol.invalid_params(
        id,
        "task #{job.id} is #{status(job)} and is not waiting for input"
      )
    end)
  end

  def handle(method, _params, id, _ctx), do: Protocol.method_not_found(id, method)

  @doc """
  Hydra's state as an MCP task status.

  Note what `failed` does *not* mean here. The extension reserves it for a JSON-RPC execution
  error — the server could not produce a tool result at all. A job that exhausted its attempts
  against a provider returning 429 produced a perfectly good tool result saying so, so it is
  `completed`, carrying a result with `isError: true`. Reporting it as `failed` would tell the
  client the protocol broke when what actually happened is that the work did not succeed.
  """
  def status(%JobRecord{state: state}), do: State.mcp_status(state)

  # The `tasks/get` body. Which fields appear depends on the status, per the extension.
  defp detailed(%JobRecord{} = job) do
    view = TaskView.render(job)

    base = %{
      "resultType" => "complete",
      "taskId" => view["taskId"],
      "status" => status(job),
      "statusMessage" => view["statusMessage"],
      "createdAt" => view["createdAt"],
      "lastUpdatedAt" => view["lastUpdatedAt"],
      "ttlMs" => view["ttlMs"],
      "pollIntervalMs" => view["pollIntervalMs"],
      "_meta" => view["_meta"]
    }

    case status(job) do
      "completed" -> Map.put(base, "result", Tools.result_payload(job))
      _ -> base
    end
  end

  defp with_task(params, id, ctx, fun) do
    case params["taskId"] do
      task_id when is_binary(task_id) and task_id != "" ->
        case Delegation.get(task_id, ctx.caller) do
          nil -> unknown_task(id, task_id)
          job -> fun.(job)
        end

      _ ->
        Protocol.invalid_params(id, "taskId is required")
    end
  end

  # Same wording whether the task never existed or belongs to someone else.
  defp unknown_task(id, task_id),
    do: Protocol.invalid_params(id, "no task #{inspect(task_id)} belongs to you")
end
