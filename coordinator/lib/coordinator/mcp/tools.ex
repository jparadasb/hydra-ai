defmodule Coordinator.Mcp.Tools do
  @moduledoc """
  The agent-facing verbs: submit a job, ask after it, cancel it, collect the result.

  These are thin. Everything that decides anything — privacy, routing, ownership, idempotency,
  the open-job ceiling — lives in `Coordinator.Delegation` and `Coordinator.Jobs`, so the native
  tasks extension can be added later as a different envelope over the same calls rather than as
  a second implementation.

  ## Errors

  A caller's mistake — an unknown job, a bad privacy level, too many jobs open — comes back as a
  tool result with `isError: true`, not as a JSON-RPC error. JSON-RPC errors mean the call could
  not be made at all; a tool that ran and has bad news for the model is a successful call. Models
  handle the first well and the second badly, and hand-rolled MCP servers get this backwards
  more often than not.
  """

  alias Coordinator.{Delegation, Models}
  alias Coordinator.Mcp.{ContextRequest, TaskView}

  @submit "hydra_submit_job"
  @get "hydra_get_job"
  @cancel "hydra_cancel_job"
  @result "hydra_get_result"
  @provide_input "hydra_provide_input"

  @doc "Tool definitions for `tools/list`."
  def list do
    [submit_tool(), get_tool(), cancel_tool(), result_tool(), provide_input_tool()]
  end

  def names, do: Enum.map(list(), & &1["name"])

  @doc """
  Run a tool.

  Returns `{:ok, tool_result}` — including for a caller's mistake — or `{:error, reason}` only
  when the call itself was malformed enough that no tool ran.
  """
  def call(name, args, ctx)

  def call(@submit, args, ctx) do
    with {:ok, messages} <- messages(args),
         {:ok, privacy} <-
           Delegation.resolve_privacy(args["privacy"], args["allow_external_providers"]) do
      payload = payload(args, messages)

      payload =
        if args["allow_context_requests"] == true do
          case ContextRequest.inject(payload) do
            {:ok, payload} -> payload
            {:error, :reserved_tool_name} -> :reserved_tool_name
          end
        else
          payload
        end

      request = %{
        caller: ctx.caller,
        privacy: privacy,
        timeout_ms: Delegation.resolve_timeout(args["timeout_ms"]),
        payload: payload,
        metadata: args["metadata"],
        idempotency_key: args["idempotency_key"],
        max_total_tokens: args["max_total_tokens"],
        priority: args["priority"],
        source: "mcp"
      }

      case submit_or_refuse(request) do
        {:ok, created, job} ->
          view = TaskView.render(job)

          ok(
            "Job #{job.id} #{if created == :existing, do: "already submitted", else: "accepted"}. " <>
              "Poll hydra_get_job with this id; expect it to run for a while.",
            %{
              "job_id" => job.id,
              "status" => view["status"],
              "state" => job.state,
              "created" => created == :created,
              "poll_after_ms" => view["pollIntervalMs"]
            }
          )

        {:error, {:model_unavailable, model}} ->
          err("No connected worker serves '#{model}'. Available now: #{available_models()}.")

        {:error, {:quota_exceeded, used, limit}} ->
          err(
            "This key has used #{used} of its #{limit} tokens for the last 30 days. " <>
              "Nothing will run until the window rolls or the limit is raised."
          )

        {:error, {:too_many_open_jobs, limit}} ->
          err(
            "You already have #{limit} jobs queued or running, which is the per-key limit. " <>
              "Wait for one to finish, or cancel one with #{@cancel}."
          )

        {:error, :idempotency_conflict} ->
          err("A job with this idempotency_key is being created right now. Retry shortly.")

        {:error, :reserved_tool_name} ->
          err(
            "'#{ContextRequest.tool_name()}' is reserved. Rename your tool, or drop " <>
              "allow_context_requests."
          )

        {:error, reason} ->
          err("The job could not be queued: #{inspect(reason)}")
      end
    else
      {:error, :no_prompt} ->
        err("Provide `prompt` (or a non-empty `messages` array).")

      {:error, {:bad_privacy, level}} ->
        err("'#{level}' is not a privacy level. Use public, private, sensitive or local_only.")
    end
  end

  def call(@get, args, ctx) do
    with_job(args, ctx, fn job ->
      view = TaskView.render(job)

      base = %{
        "job_id" => job.id,
        "status" => view["status"],
        "state" => job.state,
        "hydra" => view["_meta"][TaskView.meta_key()],
        "poll_after_ms" => view["pollIntervalMs"]
      }

      # A job that is waiting on the caller has to say so where the caller is looking, or it
      # sits in input_required while the agent politely keeps polling.
      case job.input_request do
        %{} = request ->
          ok(
            view["statusMessage"],
            Map.merge(base, %{
              "input_request" => %{
                "request_id" => request["request_id"],
                "requests" => ContextRequest.to_input_requests(request)
              }
            })
          )

        _ ->
          ok(view["statusMessage"], base)
      end
    end)
  end

  def call(@cancel, args, ctx) do
    job_id = args["job_id"]

    case Delegation.cancel(job_id, ctx.caller) do
      {:ok, outcome, job} ->
        ok(
          if(outcome == :cancelled,
            do: "Job #{job.id} cancelled.",
            else: "Job #{job.id} had already finished (#{job.state}); nothing to cancel."
          ),
          %{
            "job_id" => job.id,
            "status" => TaskView.render(job)["status"],
            "state" => job.state,
            "cancelled" => outcome == :cancelled,
            "already_terminal" => outcome == :already_terminal,
            # What it managed to do before stopping is still worth reporting.
            "hydra" => TaskView.hydra_meta(job)
          }
        )

      {:error, :unknown_job} ->
        unknown_job(job_id)
    end
  end

  def call(@result, args, ctx) do
    with_job(args, ctx, fn job -> {:ok, result_payload(job)} end)
  end

  def call(@provide_input, args, ctx) do
    with_job(args, ctx, fn job ->
      case Coordinator.Jobs.resume_with_input(
             job.id,
             args["request_id"],
             args["responses"] || args["response"]
           ) do
        {:ok, resumed} ->
          ok("Job #{resumed.id} resumed with your answer. Keep polling #{@get}.", %{
            "job_id" => resumed.id,
            "status" => TaskView.render(resumed)["status"],
            "state" => resumed.state
          })

        {:error, :not_awaiting_input} ->
          err("Job #{job.id} is #{job.state}, not waiting for input.")

        {:error, :stale_input_request} ->
          err(
            "That request_id is not the one job #{job.id} is waiting on. " <>
              "Call #{@get} to see the current request."
          )

        {:error, reason} ->
          err("The job could not be resumed: #{inspect(reason)}")
      end
    end)
  end

  def call(name, _args, _ctx), do: {:error, {:unknown_tool, name}}

  @doc """
  A finished job as a tool result.

  Public because the native tasks extension has to answer `tasks/get` with exactly this — the
  two surfaces must agree about what a job produced, and the cheapest way to guarantee that is
  for there to be one function.
  """
  def result_payload(job) do
    result = TaskView.result(job)

    {:ok, payload} =
      cond do
        not Coordinator.Jobs.State.terminal?(job.state) ->
          ok("Job #{job.id} is still running (#{job.state}). Poll again.", result)

        result["redacted"] ->
          ok(
            "Job #{job.id} finished, but its text has passed the retention window and is gone.",
            result
          )

        TaskView.error?(job) ->
          # A completed call carrying bad news, which is what isError is for.
          err("Job #{job.id} #{job.state}: #{job.failure_reason || "no reason recorded"}", result)

        true ->
          ok(result["text"] || "Job #{job.id} completed with no text output.", result)
      end

    payload
  end

  # ---- shared ---------------------------------------------------------------------------------

  defp with_job(args, ctx, fun) do
    case args["job_id"] do
      id when is_binary(id) and id != "" ->
        case Delegation.get(id, ctx.caller) do
          nil -> unknown_job(id)
          job -> fun.(job)
        end

      _ ->
        err("Provide `job_id`, the id #{@submit} returned.")
    end
  end

  # A job owned by someone else is reported exactly as one that never existed. Distinguishing
  # them would let a caller probe which ids are real.
  defp unknown_job(id), do: err("No job #{inspect(id)} belongs to you.")

  defp ok(text, structured) do
    {:ok,
     %{
       "content" => [%{"type" => "text", "text" => text}],
       "structuredContent" => structured,
       "isError" => false
     }}
  end

  defp err(text, structured \\ %{}) do
    {:ok,
     %{
       "content" => [%{"type" => "text", "text" => text}],
       "structuredContent" => structured,
       "isError" => true
     }}
  end

  defp messages(%{"messages" => messages}) when is_list(messages) and messages != [],
    do: {:ok, messages}

  defp messages(%{"prompt" => prompt} = args) when is_binary(prompt) and prompt != "" do
    system =
      case args["system"] do
        s when is_binary(s) and s != "" -> [%{"role" => "system", "content" => s}]
        _ -> []
      end

    # Structured context becomes an ordinary user turn rather than a payload field. No worker
    # knows what `context` is, and inventing one would mean a job that only new workers can run.
    context =
      case args["context"] do
        %{} = ctx when map_size(ctx) > 0 ->
          [%{"role" => "user", "content" => "Context:\n" <> Jason.encode!(ctx)}]

        _ ->
          []
      end

    {:ok, system ++ context ++ [%{"role" => "user", "content" => prompt}]}
  end

  defp messages(_), do: {:error, :no_prompt}

  # Built exactly as the OpenAI door builds it, so the worker's job parsing needs no change.
  defp payload(args, messages) do
    %{
      "messages" => messages,
      "model" => args["model"],
      "max_tokens" => args["max_tokens"],
      "temperature" => args["temperature"],
      # Routing reads this; the worker ignores what it does not recognize inside `payload`,
      # which is why a new instruction can ride here rather than as a job field older workers
      # would refuse outright.
      "model_policy" => args["model_policy"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp submit_or_refuse(%{payload: :reserved_tool_name}), do: {:error, :reserved_tool_name}
  defp submit_or_refuse(request), do: Delegation.submit(request)

  defp available_models do
    case Models.names() do
      [] -> "none — no worker is connected"
      names -> Enum.join(names, ", ")
    end
  end

  # ---- definitions ----------------------------------------------------------------------------

  defp submit_tool do
    %{
      "name" => @submit,
      "title" => "Delegate a job to Hydra",
      "description" => """
      Hand a long-running model job to Hydra and get an id back immediately. The job keeps
      running whether or not you stay connected, survives a coordinator restart, and is picked
      up by whichever worker is eligible under its privacy level.

      Use this for work that is token-heavy rather than judgement-heavy: implementing something
      specified, writing tests, summarising a large body of text. It returns before the job
      starts, so treat the id as the handle: poll #{@get} (it tells you how long to wait
      between polls), then collect with #{@result}.

      Privacy defaults to local_only, meaning the job will only run on a worker that keeps it on
      its own machine. Widen it deliberately if the work may be sent to an external provider.

      Models available right now: #{available_models()}.
      """,
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["prompt"],
        "properties" => %{
          "prompt" => %{
            "type" => "string",
            "minLength" => 1,
            "maxLength" => 1_000_000,
            "description" => "What the delegated model should do."
          },
          "system" => %{"type" => "string", "description" => "Optional system instruction."},
          "messages" => %{
            "type" => "array",
            "description" => "Full chat turns, instead of prompt/system/context.",
            "items" => %{"type" => "object"}
          },
          "context" => %{
            "type" => "object",
            "description" => "Structured context; sent as an additional user turn."
          },
          "model" => %{
            "type" => "string",
            "description" =>
              "Exact model name. Never substituted — an unavailable model is refused."
          },
          "privacy" => %{
            "enum" => ["public", "private", "sensitive", "local_only"],
            "default" => "local_only",
            "description" =>
              "sensitive and local_only never leave the machine that runs them, whatever else is asked for."
          },
          "allow_external_providers" => %{
            "type" => "boolean",
            "default" => false,
            "description" => "Ignored for sensitive and local_only."
          },
          "idempotency_key" => %{
            "type" => "string",
            "maxLength" => 255,
            "description" =>
              "Retry-safe key. A repeat returns the first job, whatever state it is in; payloads are not compared."
          },
          "timeout_ms" => %{
            "type" => "integer",
            "minimum" => 1000,
            "maximum" => Delegation.max_timeout_ms(),
            "default" => Delegation.default_timeout_ms(),
            "description" => "How long Hydra keeps trying before giving up on the job."
          },
          "metadata" => %{
            "type" => "object",
            "description" =>
              "Your correlation data. Stored with the job; never sent to the model."
          },
          "allow_context_requests" => %{
            "type" => "boolean",
            "default" => false,
            "description" =>
              "Let the delegated model pause and ask you for a file or a definition it was not given, instead of guessing. Disables live token streaming for the job, since a tool call cannot be recognized halfway through."
          },
          "model_policy" => %{
            "type" => "object",
            "additionalProperties" => false,
            "description" =>
              "How to choose a model when you do not want to name one. Prefer this to `model` for delegated work: naming a model that is not connected is refused, while a preference that cannot be met degrades to whatever else is eligible.",
            "properties" => %{
              "prefer" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" =>
                  "Model names in order of preference. Ordering, not a requirement."
              },
              "require_local" => %{
                "type" => "boolean",
                "description" =>
                  "Only workers that can serve this from a local model. A refusal to use an external provider, expressed as routing rather than as a privacy level."
              }
            }
          },
          "max_total_tokens" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" =>
              "Stop the job once it has consumed this many tokens in total, across retries and any rounds spent asking for context. Unbounded if omitted."
          },
          "priority" => %{
            "type" => "integer",
            "minimum" => 0,
            "maximum" => 3,
            "default" => 1,
            "description" =>
              "0 is highest. Orders this job's assignment against other queued work; it does not preempt a job already running."
          },
          "max_tokens" => %{"type" => "integer", "minimum" => 1},
          "temperature" => %{"type" => "number"}
        }
      },
      "annotations" => %{
        "readOnlyHint" => false,
        "destructiveHint" => false,
        "idempotentHint" => true,
        "openWorldHint" => true
      }
    }
  end

  defp get_tool do
    %{
      "name" => @get,
      "title" => "Check a delegated job",
      "description" => """
      Where a job has got to: its state, the worker and model running it, tokens generated so
      far and throughput. Cheap, and safe to call repeatedly — the response carries
      poll_after_ms, which is how long to wait before asking again.

      A job in `generating` may stay there for minutes on local hardware. Generated-token count
      rising is the sign it is working; there is no meaningful percentage to report, because
      generation has no known endpoint.
      """,
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["job_id"],
        "properties" => %{"job_id" => %{"type" => "string", "description" => "From #{@submit}."}}
      },
      "annotations" => %{"readOnlyHint" => true, "idempotentHint" => true}
    }
  end

  defp cancel_tool do
    %{
      "name" => @cancel,
      "title" => "Cancel a delegated job",
      "description" => """
      Stop a queued or running job. Safe to call more than once, and safe to call on a job that
      already finished — the reply says which happened. The worker is told to abort, and
      whatever the job measured before stopping is preserved.
      """,
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["job_id"],
        "properties" => %{
          "job_id" => %{"type" => "string"},
          "reason" => %{"type" => "string", "maxLength" => 200}
        }
      },
      "annotations" => %{
        "readOnlyHint" => false,
        "destructiveHint" => true,
        "idempotentHint" => true
      }
    }
  end

  defp provide_input_tool do
    %{
      "name" => @provide_input,
      "title" => "Answer a delegated job's question",
      "description" => """
      Give a paused job the context it asked for. #{@get} reports a job in `input_required`
      along with what it wants and the request_id to answer; pass that id and your answer here
      and the job continues from where it stopped, under the same job id.

      Safe to repeat: a second answer to a request already answered is a no-op rather than a
      second turn in the conversation.
      """,
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["job_id", "request_id", "responses"],
        "properties" => %{
          "job_id" => %{"type" => "string"},
          "request_id" => %{
            "type" => "string",
            "description" => "From the input_request that #{@get} reported."
          },
          "responses" => %{
            "type" => "object",
            "description" =>
              "Answers keyed by the request key #{@get} reported, or a single answer for a single question."
          }
        }
      },
      "annotations" => %{"readOnlyHint" => false, "idempotentHint" => true}
    }
  end

  defp result_tool do
    %{
      "name" => @result,
      "title" => "Collect a delegated job's result",
      "description" => """
      The finished job's output, artifacts and token usage. If the job is still running this
      says so rather than waiting, so keep polling #{@get} until it reports a terminal state.

      Results do not live forever: after the retention window the text is dropped and this
      reports the job as redacted, with its metadata intact.
      """,
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["job_id"],
        "properties" => %{"job_id" => %{"type" => "string"}}
      },
      "annotations" => %{"readOnlyHint" => true, "idempotentHint" => true}
    }
  end
end
