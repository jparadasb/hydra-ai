defmodule Coordinator.BootCheckTest do
  @moduledoc """
  Startup invariants. Both of these guard configurations that otherwise fail silently or
  somewhere far from the mistake.
  """
  use ExUnit.Case, async: true

  alias Coordinator.BootCheck

  @sqlite Ecto.Adapters.SQLite3
  @postgres Ecto.Adapters.Postgres

  @topology [
    hydra: [strategy: Cluster.Strategy.Kubernetes.DNS, config: [service: "coordinator-headless"]]
  ]

  describe "adapter agreement" do
    test "a DB_ADAPTER that disagrees with the compiled adapter is a named error" do
      assert {:error, message} = BootCheck.verify("postgres", @sqlite, [])

      assert message =~ "DB_ADAPTER mismatch"
      assert message =~ "Ecto.Adapters.Postgres"
      assert message =~ "Ecto.Adapters.SQLite3"
      # Says what to do about it, not just that something is wrong.
      assert message =~ "Rebuild the release"
    end

    test "either spelling of each adapter agrees with its module" do
      assert BootCheck.verify("postgres", @postgres, []) == :ok
      assert BootCheck.verify("postgresql", @postgres, []) == :ok
      assert BootCheck.verify("sqlite3", @sqlite, []) == :ok
      assert BootCheck.verify("sqlite", @sqlite, []) == :ok
    end

    test "no DB_ADAPTER means nothing to disagree with (dev and test)" do
      assert BootCheck.verify(nil, @sqlite, []) == :ok
      assert BootCheck.verify(nil, @postgres, []) == :ok
    end
  end

  describe "clustering" do
    test "clustering on SQLite refuses to start" do
      assert {:error, message} = BootCheck.verify("sqlite3", @sqlite, @topology)

      assert message =~ "Refusing to start"
      assert message =~ "SQLite"
      # Names both ways out.
      assert message =~ "single replica"
      assert message =~ "DB_ADAPTER=postgres"
    end

    test "clustering on Postgres is fine" do
      assert BootCheck.verify("postgres", @postgres, @topology) == :ok
    end

    test "SQLite with no topology is fine — that is the single-node deployment" do
      assert BootCheck.verify("sqlite3", @sqlite, []) == :ok
      assert BootCheck.verify("sqlite3", @sqlite, nil) == :ok
    end

    test "an adapter mismatch is reported before the clustering check" do
      # Both are wrong here; the mismatch is the one to fix first, since it changes which
      # database is even in play.
      assert {:error, message} = BootCheck.verify("postgres", @sqlite, @topology)
      assert message =~ "DB_ADAPTER mismatch"
    end
  end

  test "verify!/0 passes against the running configuration" do
    # The suite's own config is the single-node SQLite case.
    assert BootCheck.verify!() == :ok
  end
end
