defmodule Coordinator.Job do
  @moduledoc """
  A job to be leased to a worker. Privacy level governs which workers are eligible
  (see `Coordinator.Router`). Mirrors `/proto/job.schema.json`.
  """

  @privacy_levels ~w(public private sensitive local_only)a

  @type privacy :: :public | :private | :sensitive | :local_only

  @type t :: %__MODULE__{
          job_id: String.t(),
          capability: String.t(),
          privacy: privacy(),
          allow_external_providers: boolean(),
          payload: map()
        }

  @enforce_keys [:job_id, :capability, :privacy]
  defstruct job_id: nil,
            capability: nil,
            privacy: :public,
            allow_external_providers: false,
            payload: %{}

  def privacy_levels, do: @privacy_levels

  @doc "Parse a privacy string into an atom, defaulting to the safest level on bad input."
  def parse_privacy(p) when p in ["public", "private", "sensitive", "local_only"],
    do: String.to_existing_atom(p)

  def parse_privacy(_), do: :local_only
end
