defmodule Coordinator.Mcp.Server do
  @moduledoc """
  What each MCP method does, with no `conn` in sight.

  The same split `Coordinator.WorkerSession` has from `Coordinator.WorkerChannel`, for the same
  reason: the interesting behaviour is testable directly, and the transport is left with
  transport concerns.

  Two eras are served. `2026-07-28` answers `server/discover` and carries the negotiated version
  in each request; `2025-11-25` and earlier handshake with `initialize` first. They differ in
  how a client learns what this server is, and in nothing else — both reach the same tools.
  """
  require Logger

  alias Coordinator.Mcp.{Protocol, Tasks, Tools}

  @server_info %{"name" => "hydra", "title" => "Hydra", "version" => "1.2.0"}

  @instructions """
  Hydra runs model jobs on local hardware and hands them back asynchronously.

  Submit with hydra_submit_job and you get a job id straight away — the job then runs on its
  own. Poll hydra_get_job (it tells you how long to wait between polls), and collect the output
  with hydra_get_result once it reports a terminal state. hydra_cancel_job stops one.

  Delegate work that is token-heavy rather than judgement-heavy, and keep the deciding and the
  checking for yourself. Jobs can take minutes: a rising generated-token count means it is
  working, and there is no percentage to report because generation has no known endpoint.
  """

  @doc """
  Handle one decoded JSON-RPC message.

  Returns `{:reply, response}`, or `:noreply` for a notification — which the transport turns
  into a bare 202, since this revision defines no client notification worth answering.
  """
  def handle(message, ctx) do
    case Protocol.classify(message) do
      {:request, method, id} -> {:reply, dispatch(method, message["params"] || %{}, id, ctx)}
      {:notification, _method} -> :noreply
      {:error, reason} -> {:reply, Protocol.invalid_request(nil, to_string(reason))}
    end
  end

  defp dispatch("server/discover", _params, id, ctx) do
    Protocol.result(
      id,
      %{
        "protocolVersions" => Protocol.supported_versions(),
        "serverInfo" => @server_info,
        "capabilities" => capabilities(),
        "instructions" => @instructions,
        "resultType" => "discover"
      },
      ctx.era
    )
  end

  # The pre-2026-07-28 handshake. Echo the client's version when it is one this server speaks,
  # so a client that asked for an older revision is not silently upgraded under it.
  defp dispatch("initialize", params, id, ctx) do
    requested = params["protocolVersion"]

    negotiated =
      if requested in Protocol.supported_versions(),
        do: requested,
        else: Protocol.modern_version()

    Protocol.result(
      id,
      %{
        "protocolVersion" => negotiated,
        "serverInfo" => @server_info,
        "capabilities" => capabilities(),
        "instructions" => @instructions
      },
      ctx.era
    )
  end

  defp dispatch("ping", _params, id, ctx), do: Protocol.result(id, %{}, ctx.era)

  defp dispatch("tools/list", _params, id, ctx),
    do: Protocol.result(id, %{"tools" => Tools.list()}, ctx.era)

  defp dispatch("tools/call", params, id, ctx) do
    name = params["name"]
    args = params["arguments"] || %{}

    cond do
      not is_binary(name) ->
        Protocol.invalid_params(id, "tools/call requires a tool name")

      not is_map(args) ->
        Protocol.invalid_params(id, "arguments must be an object")

      true ->
        case Tools.call(name, args, ctx) do
          {:ok, result} ->
            Protocol.result(id, task_or_result(name, result, ctx), ctx.era)

          {:error, {:unknown_tool, name}} ->
            Protocol.method_not_found(id, "tools/call #{name}")
        end
    end
  rescue
    error ->
      # A crash here would otherwise take the request down with a bare 500 and no id, leaving
      # the client unable to tell which call failed.
      Logger.error("mcp tool crashed: #{Exception.format(:error, error, __STACKTRACE__)}")
      Protocol.internal_error(id, "the tool failed")
  end

  defp dispatch("tasks/" <> _ = method, params, id, ctx),
    do: Tasks.handle(method, params, id, ctx)

  defp dispatch(method, _params, id, _ctx), do: Protocol.method_not_found(id, method)

  # A submission that succeeded becomes a task handle for a client that speaks the extension:
  # the job it created already is one. Only submissions — the read tools answer immediately, and
  # handing back a task for a read would mean a client polling a task to learn the result of a
  # poll. A caller error stays an ordinary tool result, because no job exists to hand back.
  defp task_or_result(name, result, ctx) do
    with true <- ctx.tasks?,
         true <- name == "hydra_submit_job",
         false <- result["isError"] == true,
         job_id when is_binary(job_id) <- result["structuredContent"]["job_id"],
         %{} = job <- Coordinator.Delegation.get(job_id, ctx.caller) do
      Tasks.create_result(job)
    else
      _ -> result
    end
  end

  # Only what is actually implemented. Resources and prompts are not — advertising them means a
  # client calling them and getting method-not-found. The tasks extension is, so it is offered;
  # a client that does not declare it simply never receives a task handle.
  defp capabilities do
    %{
      "tools" => %{"listChanged" => false},
      "extensions" => Tasks.capability()
    }
  end
end
