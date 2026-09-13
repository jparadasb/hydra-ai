defmodule Coordinator.Models do
  @moduledoc """
  What a job can actually be routed to right now, aggregated from the live worker registry.

  Extracted from `Coordinator.ApiRouter` because the MCP surface needs the same list for a
  different reason: `/v1/models` answers a client's catalog request, while an MCP tool
  *description* has to name real models or the delegating agent invents one and the submission
  is refused. Both must mean the same thing, so both read it from here.

  The list reflects the front-door routing capability only (`:api_capability`, default `"chat"`),
  deduped by model name — first worker wins for `owned_by`. A model no connected worker
  advertises is simply absent, which is what makes `available?/1` a useful pre-flight check.
  """

  @doc """
  OpenAI-shaped model list, aggregated from the live worker registry.

  Carries the extended fields Codex's model loader requires alongside the OpenAI ones; they
  describe the catalog entry, not a per-request choice.
  """
  @spec list() :: [map()]
  def list do
    capability = Application.get_env(:coordinator, :api_capability, "chat")
    created = System.system_time(:second)

    Coordinator.WorkerRegistry.list()
    |> Enum.flat_map(fn worker ->
      worker.models
      |> Enum.filter(&(capability in &1.capabilities))
      |> Enum.map(fn model ->
        %{
          "id" => model.name,
          # Codex's model loader consumes the extended `models` list and requires a slug.
          # Keep it identical to the public model id for OpenAI-compatible clients.
          "slug" => model.name,
          "display_name" => model.name,
          "description" => "Hydra model #{model.name}",
          "default_reasoning_level" => "medium",
          "supported_reasoning_levels" => [
            %{"effort" => "low", "description" => "Fast responses with lighter reasoning"},
            %{"effort" => "medium", "description" => "Balances speed and reasoning depth"},
            %{"effort" => "high", "description" => "Deeper reasoning for difficult tasks"}
          ],
          "shell_type" => "unified_exec",
          "visibility" => "list",
          "supported_in_api" => true,
          "object" => "model",
          "created" => created,
          "owned_by" => worker.provider_name || "hydra"
        }
      end)
    end)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.sort_by(& &1["id"])
  end

  @doc "Just the model names, for a tool description or an error message."
  @spec names() :: [String.t()]
  def names, do: Enum.map(list(), & &1["id"])

  @doc """
  Whether a requested model can be served.

  An empty catalog means no worker has registered yet rather than "this model does not exist",
  so it is permissive: the job queues and `Coordinator.LeaseWorker` snoozes until a capable
  worker connects. Refusing here would break a caller that submits before its worker is up.
  """
  @spec available?(String.t()) :: boolean()
  def available?(model) when is_binary(model) do
    models = list()
    models == [] or Enum.any?(models, &(&1["id"] == model))
  end
end
