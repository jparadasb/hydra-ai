defmodule Coordinator.DelegationTest do
  @moduledoc """
  The decisions both front doors have to agree about, and the ones where they deliberately
  differ.
  """
  use ExUnit.Case, async: false

  alias Coordinator.Delegation

  setup do
    Application.delete_env(:coordinator, :on_client_disconnect)
    on_exit(fn -> Application.delete_env(:coordinator, :on_client_disconnect) end)
    :ok
  end

  describe "on_client_disconnect/1" do
    test "cancelling stays the default" do
      # A detached job nobody comes back for is the orphaned work the feature exists to avoid.
      assert Delegation.on_client_disconnect(nil) == :cancel
    end

    test "a caller can ask for their job to outlive the connection" do
      assert Delegation.on_client_disconnect("detach") == :detach
    end

    test "a deployment can change the default, and a request can still override it" do
      Application.put_env(:coordinator, :on_client_disconnect, :detach)

      assert Delegation.on_client_disconnect(nil) == :detach
      assert Delegation.on_client_disconnect("cancel") == :cancel
    end

    test "anything unrecognized falls back rather than guessing" do
      assert Delegation.on_client_disconnect("maybe") == :cancel
    end
  end

  describe "resolve_privacy/2" do
    test "defaults to local_only, unlike the OpenAI door" do
      # The HTTP door defaults to public because its callers predate privacy levels. This door
      # has no such history, and what arrives through it is delegated repository content.
      assert {:ok, %{level: "local_only", allow_external_providers: false}} =
               Delegation.resolve_privacy(nil)
    end

    test "a refusal to leave the machine outranks an explicit request to allow external" do
      for level <- ["sensitive", "local_only"] do
        assert {:ok, %{level: ^level, allow_external_providers: false}} =
                 Delegation.resolve_privacy(level, true)
      end
    end

    test "a wider level has to be asked for" do
      assert {:ok, %{level: "public", allow_external_providers: false}} =
               Delegation.resolve_privacy("public")

      assert {:ok, %{level: "public", allow_external_providers: true}} =
               Delegation.resolve_privacy("public", true)
    end

    test "an unknown level is refused rather than quietly narrowed" do
      assert {:error, {:bad_privacy, "sort-of-private"}} =
               Delegation.resolve_privacy("sort-of-private")
    end
  end

  describe "resolve_timeout/1" do
    test "a delegated job may run far longer than an HTTP one, but not forever" do
      assert Delegation.resolve_timeout(nil) == Delegation.default_timeout_ms()
      assert Delegation.resolve_timeout(5_000) == 5_000
      assert Delegation.resolve_timeout(999_999_999) == Delegation.max_timeout_ms()
      # For a worker that cannot renew its lease, this deadline pins lease_expires_at — an
      # unbounded one would strand a dead worker's job for as long as it asked for.
      assert Delegation.max_timeout_ms() <= 21_600_000
    end
  end
end
