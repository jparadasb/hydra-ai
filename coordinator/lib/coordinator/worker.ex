defmodule Coordinator.Worker do
  @moduledoc """
  A registered worker's live, non-secret capability snapshot. Built from a worker's
  registration payload (`/proto/registration.schema.json`). Never holds a token.
  """

  @type execution_mode :: :local_model | :external_provider | :both

  @type model :: %{
          name: String.t(),
          capabilities: [String.t()],
          context_length: non_neg_integer() | nil,
          uses_external_provider: boolean()
        }

  @type t :: %__MODULE__{
          worker_id: String.t(),
          execution_mode: execution_mode(),
          provider_name: String.t() | nil,
          models: [model()],
          accepted_job_levels: [Coordinator.Job.privacy()],
          trust_level: String.t(),
          max_requests_per_hour: non_neg_integer() | nil,
          max_cost_per_day_usd: float() | nil,
          # live scheduling signals
          inflight: non_neg_integer(),
          avg_latency_ms: float(),
          available: boolean()
        }

  defstruct worker_id: nil,
            execution_mode: :local_model,
            provider_name: nil,
            models: [],
            accepted_job_levels: [:public],
            trust_level: "untrusted",
            max_requests_per_hour: nil,
            max_cost_per_day_usd: nil,
            inflight: 0,
            avg_latency_ms: 0.0,
            available: true

  @doc """
  Build a `Worker` from a sanitized registration map (string keys). The caller MUST have
  run `Coordinator.SecretGuard` first.
  """
  def from_registration(%{} = reg) do
    %__MODULE__{
      worker_id: reg["worker_id"],
      execution_mode: parse_mode(reg["execution_mode"]),
      provider_name: get_in(reg, ["provider", "name"]),
      models: Enum.map(reg["models"] || [], &parse_model/1),
      accepted_job_levels:
        (get_in(reg, ["privacy", "accepted_job_levels"]) || ["public"])
        |> Enum.map(&Coordinator.Job.parse_privacy/1),
      trust_level: reg["trust_level"] || "untrusted",
      max_requests_per_hour: get_in(reg, ["limits", "max_requests_per_hour"]),
      max_cost_per_day_usd: get_in(reg, ["limits", "max_cost_per_day_usd"])
    }
  end

  @doc "Does any of this worker's models serve `capability`?"
  def serves?(%__MODULE__{models: models}, capability),
    do: Enum.any?(models, &(capability in &1.capabilities))

  @doc "Does this worker advertise a model named `model_name` that serves `capability`?"
  def serves_model?(%__MODULE__{models: models}, capability, model_name),
    do: Enum.any?(models, &(&1.name == model_name and capability in &1.capabilities))

  @doc "Is this worker external-only (no local model available)?"
  def external_only?(%__MODULE__{models: models}),
    do: models != [] and Enum.all?(models, & &1.uses_external_provider)

  @doc "Does this worker have at least one local (non-external) model for `capability`?"
  def has_local?(%__MODULE__{models: models}, capability) do
    Enum.any?(models, &(capability in &1.capabilities and not &1.uses_external_provider))
  end

  @doc "Does this worker have an external model for `capability`?"
  def has_external?(%__MODULE__{models: models}, capability) do
    Enum.any?(models, &(capability in &1.capabilities and &1.uses_external_provider))
  end

  defp parse_mode("external_provider"), do: :external_provider
  defp parse_mode("both"), do: :both
  defp parse_mode(_), do: :local_model

  defp parse_model(%{} = m) do
    %{
      name: m["name"],
      capabilities: m["capabilities"] || [],
      context_length: m["context_length"],
      uses_external_provider: m["uses_external_provider"] || false
    }
  end
end
