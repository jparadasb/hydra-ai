defmodule Coordinator.Jobs.State do
  @moduledoc """
  The observational half of a job's lifecycle.

  A job carries two columns. `status` is the transactional one: five values, and every
  compare-and-swap in `Coordinator.Jobs` keys on it (`mark_leased/4` matches `"pending"`,
  `update_status/3` and `requeue/1` match `["pending", "leased"]`, the lease sweeper matches
  `"leased"`). It is the only real concurrency safety in the system, so it does not grow.

  `state` is the observational one: where inside a status the job actually is, which is what a
  delegating agent polls for and what issue #85 asks to expose. Widening `status` to carry it
  would turn every one of those guards into an N-value `in` list that has to stay in sync, and a
  forgotten one is a guard that silently stops matching.

  The two are written together, always in the same `set:` list. `Coordinator.Jobs.JobRecord`
  validates the pair on the changeset path; the `update_all` paths bypass changesets by design,
  so `consistent?/2` exists for the test that walks every write site.

  MCP sees neither column directly — `mcp_status/1` collapses both onto the five values the
  protocol defines, and everything finer travels as metadata.
  """

  @by_status %{
    "pending" => ~w(queued routing),
    "leased" => ~w(leased loading_model prefill generating finalizing),
    "awaiting_input" => ~w(input_required),
    "done" => ~w(completed),
    "failed" => ~w(failed expired),
    "cancelled" => ~w(cancelled)
  }

  @states @by_status |> Map.values() |> List.flatten()
  @statuses Map.keys(@by_status)

  @status_for @by_status
              |> Enum.flat_map(fn {status, states} -> Enum.map(states, &{&1, status}) end)
              |> Map.new()

  @doc "Every legal `state` value."
  @spec all() :: [String.t()]
  def all, do: @states

  @doc "Every legal `status` value. Mirrors `JobRecord`'s own list."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The `status` a given `state` must be paired with."
  @spec status_for(String.t()) :: String.t() | nil
  def status_for(state), do: Map.get(@status_for, state)

  @doc "The `state` values legal for a given `status`."
  @spec states_for(String.t()) :: [String.t()]
  def states_for(status), do: Map.get(@by_status, status, [])

  @doc "Whether this pair may appear on the same row."
  @spec consistent?(String.t(), String.t()) :: boolean()
  def consistent?(status, state), do: status_for(state) == status

  @doc "Whether the job has stopped moving."
  @spec terminal?(String.t()) :: boolean()
  def terminal?(state), do: status_for(state) in ["done", "failed", "cancelled"]

  @doc """
  The state a freshly requeued or newly submitted job sits in.
  """
  @spec initial() :: String.t()
  def initial, do: "queued"

  @doc """
  Collapse onto the five statuses MCP defines.

  Note `failed` maps to `"completed"`, not `"failed"`: the protocol reserves `failed` for a
  JSON-RPC execution error and says it must not represent a tool result that merely completed
  unsuccessfully. A job that exhausted its attempts against a provider returning 429 produced a
  perfectly well-formed tool result saying so, and the caller renders it as an errored result —
  `Coordinator.Mcp.TaskView` pairs this with `isError: true`.
  """
  @spec mcp_status(String.t()) :: String.t()
  def mcp_status(state) do
    case status_for(state) do
      "done" -> "completed"
      "failed" -> "completed"
      "cancelled" -> "cancelled"
      # The one status that is not simply "the job is busy": the caller has to act before it
      # can continue, and a client that treats it as `working` waits forever.
      "awaiting_input" -> "input_required"
      _ -> "working"
    end
  end
end
