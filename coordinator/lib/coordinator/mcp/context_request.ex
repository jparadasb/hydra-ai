defmodule Coordinator.Mcp.ContextRequest do
  @moduledoc """
  The reserved tool a delegated model uses to ask its caller for something.

  A model given a repository summary and asked to implement a parser will sometimes need the
  actual file. The alternatives are sending the whole repository up front — which is the context
  cost delegation exists to avoid — or failing on a guess. This is the third option: the job
  pauses, the caller is asked for one specific thing, and the job resumes with it.

  ## Why a tool

  The model has to be able to express the request, so it must come from something the model can
  emit. A sentinel in the output means parsing prose for a marker prose can contain — the worker
  already carries `normalize_tool_markup/2` as evidence of how that goes. Tool calling is the
  mechanism models are trained for, every adapter already extracts it, and the worker needs only
  to recognize one reserved name.

  ## Why the translation lives here and not on the worker

  The worker forwards the model's tool-call arguments verbatim and knows nothing about MCP. Rust
  changes ship across a fleet of workers that update on their own schedule; Elixir changes ship
  with the coordinator. Putting the protocol shape here means a change to how a caller is asked
  never requires a worker rollout.

  ## What it costs

  Offering a tool disables live token streaming for that job — the worker buffers when tools are
  in play, because a tool call cannot be recognized halfway through. Progress reporting still
  flows, so the job remains legible; it just does not stream text. That is the right trade for
  delegated work, and it is why this is opt-in per submission rather than always on.
  """

  @tool_name "hydra_request_context"

  def tool_name, do: @tool_name

  @doc """
  The tool definition injected into a job's payload when the caller allows context requests.

  Deliberately narrow. A model handed an open-ended "ask for anything" tool asks constantly; one
  that must name a kind and a reason asks when it is actually stuck.
  """
  def tool do
    %{
      "type" => "function",
      "function" => %{
        "name" => @tool_name,
        "description" => """
        Ask the caller for context you were not given and cannot proceed without.

        Use this only when you are genuinely blocked — a file you must read, a definition you
        must see. Do not use it to confirm something you can reasonably infer, and do not use it
        to ask the caller to do the work. You will be given the answer and asked to continue.
        """,
        "parameters" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["kind", "reason"],
          "properties" => %{
            "kind" => %{
              "enum" => ["file", "search", "symbol", "question"],
              "description" => "What sort of thing you need."
            },
            "path" => %{"type" => "string", "description" => "For kind=file: the path you need."},
            "query" => %{
              "type" => "string",
              "description" => "For kind=search or symbol: what to look for."
            },
            "question" => %{
              "type" => "string",
              "description" => "For kind=question: what you need answered."
            },
            "reason" => %{
              "type" => "string",
              "description" => "Why you cannot continue without it."
            }
          }
        }
      }
    }
  end

  @doc "Whether a payload already carries the reserved tool."
  def present?(%{"tools" => tools}) when is_list(tools) do
    Enum.any?(tools, &(get_in(&1, ["function", "name"]) == @tool_name))
  end

  def present?(_), do: false

  @doc """
  Add the reserved tool to a job payload.

  Refuses if the caller already defined a tool by that name: silently shadowing it would mean
  their tool never being called and the job pausing when they expected an answer.
  """
  def inject(payload) do
    if present?(payload) do
      {:error, :reserved_tool_name}
    else
      {:ok, Map.update(payload, "tools", [tool()], &(&1 ++ [tool()]))}
    end
  end

  @doc """
  The model's questions, rendered for a caller.

  The worker forwards raw tool-call arguments; this is where they become something an agent can
  read and answer. Each is keyed by the tool call it belongs to, which is what the answer is
  matched back against on resume.
  """
  def to_input_requests(%{"requests" => requests}) when is_list(requests) do
    Map.new(requests, fn request ->
      args = request["arguments"] || %{}
      {request["tool_call_id"] || "request", describe(args)}
    end)
  end

  def to_input_requests(_), do: %{}

  defp describe(%{} = args) do
    %{
      "kind" => args["kind"],
      "reason" => args["reason"],
      "what" => args["path"] || args["query"] || args["question"],
      "prompt" => prompt(args)
    }
  end

  defp prompt(%{"kind" => "file", "path" => path} = args),
    do: "The model needs the contents of #{path}#{because(args)}"

  defp prompt(%{"kind" => "search", "query" => query} = args),
    do: "The model wants to search for #{inspect(query)}#{because(args)}"

  defp prompt(%{"kind" => "symbol", "query" => query} = args),
    do: "The model needs the definition of #{query}#{because(args)}"

  defp prompt(%{"kind" => "question", "question" => question} = args),
    do: "#{question}#{because(args)}"

  defp prompt(args), do: "The model needs more context#{because(args)}"

  defp because(%{"reason" => reason}) when is_binary(reason) and reason != "", do: ": #{reason}"
  defp because(_), do: "."
end
