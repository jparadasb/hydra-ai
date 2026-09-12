defmodule Coordinator.BootCheck do
  @moduledoc """
  Configuration invariants that must hold before the coordinator accepts anything.

  Two of them exist because the failure they prevent is silent:

    * **Adapter agreement.** `Coordinator.Repo`'s Ecto adapter is chosen at *compile* time from
      `DB_ADAPTER`, while connection settings come from `DB_ADAPTER` again at *boot*. A release
      built for SQLite and booted with `DB_ADAPTER=postgres` gets Postgres connection options
      handed to the SQLite adapter, and fails somewhere downstream of the actual mistake.

    * **SQLite is single-node.** The coordinator supports multi-replica clustering: libcluster
      joins the BEAM nodes so Presence and PubSub span replicas. With a SQLite file per pod,
      each replica also gets its own database and its own Oban queue — a job enqueued on pod A
      is invisible to pod B — while the unified Presence view makes it look like one system.
      Clustering with SQLite is refused rather than silently diverging.

  Checked at startup (`Coordinator.Application`) so a misconfigured deploy crash-loops with a
  named error instead of half-working.
  """

  @doc """
  Run every invariant, raising on the first violation. Reads the running configuration.
  """
  def verify! do
    case verify(
           Application.get_env(:coordinator, :db_adapter),
           Coordinator.Repo.adapter(),
           Application.get_env(:coordinator, :cluster_topologies, [])
         ) do
      :ok -> :ok
      {:error, message} -> raise message
    end
  end

  @doc """
  Pure form of `verify!/0`.

  `requested` is the adapter named by the environment (`nil` in dev/test, where the compiled
  adapter is the only opinion). `compiled` is what `Coordinator.Repo` was built against.
  `topologies` is the libcluster configuration.
  """
  def verify(requested, compiled, topologies) do
    with :ok <- check_adapter(requested, compiled) do
      check_clustering(compiled, topologies)
    end
  end

  # Dev and test do not set DB_ADAPTER; there is nothing to disagree with.
  defp check_adapter(nil, _compiled), do: :ok

  defp check_adapter(requested, compiled) do
    if module_for(requested) == compiled do
      :ok
    else
      {:error,
       """
       DB_ADAPTER mismatch.

           DB_ADAPTER says:        #{inspect(requested)} (#{inspect(module_for(requested))})
           this release was built: #{inspect(compiled)}

       Coordinator.Repo's adapter is compiled in, so DB_ADAPTER at boot cannot change it — it
       can only disagree with it. Rebuild the release with the same DB_ADAPTER you intend to
       run, or set DB_ADAPTER to match this build.
       """}
    end
  end

  defp check_clustering(_compiled, topologies) when topologies in [nil, []], do: :ok

  defp check_clustering(Ecto.Adapters.SQLite3, _topologies) do
    {:error,
     """
     Refusing to start: clustering is configured while the database is SQLite.

     HYDRA_CLUSTER_SERVICE joins the BEAM nodes, so Presence and PubSub span replicas — but a
     SQLite database is a file local to one pod. Each replica would get its own jobs table and
     its own Oban queue while the dashboard showed a single unified system.

     Either run a single replica with no HYDRA_CLUSTER_SERVICE, or move to Postgres
     (DB_ADAPTER=postgres, rebuilt release, DATABASE_URL).
     """}
  end

  defp check_clustering(_compiled, _topologies), do: :ok

  defp module_for(adapter) when adapter in ["postgres", "postgresql", :postgres],
    do: Ecto.Adapters.Postgres

  defp module_for(adapter) when adapter in ["sqlite", "sqlite3", :sqlite3],
    do: Ecto.Adapters.SQLite3

  defp module_for(other), do: other
end
