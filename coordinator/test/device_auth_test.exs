defmodule Coordinator.DeviceAuthTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint Coordinator.Endpoint

  alias Coordinator.{DeviceAuth, Repo, WorkerKey, WorkerSocket}

  setup do
    Repo.delete_all(WorkerKey)
    on_exit(fn -> Application.delete_env(:coordinator, :require_device_auth) end)
    :ok
  end

  # Build a fresh Ed25519 keypair as `{pub_b64, priv}`.
  defp keypair do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {Base.encode64(pub), priv}
  end

  # Build signed connect params for `worker_id` with the given private key (and optional
  # overrides for ts/pubkey to exercise failure paths).
  defp params(worker_id, pub_b64, priv, opts \\ []) do
    ts = Keyword.get(opts, :ts, System.os_time(:second))
    nonce = Base.encode64(:crypto.strong_rand_bytes(12))
    msg = "#{worker_id}|#{ts}|#{nonce}"
    sig = :crypto.sign(:eddsa, :none, msg, [priv, :ed25519])

    %{
      "worker_id" => worker_id,
      "pubkey" => Keyword.get(opts, :pubkey, pub_b64),
      "ts" => Integer.to_string(ts),
      "nonce" => nonce,
      "sig" => Base.encode64(sig)
    }
  end

  describe "verify/1" do
    test "first connect enrolls the key (TOFU); same key reconnects" do
      {pub, priv} = keypair()
      assert {:ok, "worker-abc"} = DeviceAuth.verify(params("worker-abc", pub, priv))
      assert %WorkerKey{public_key: ^pub, status: "trusted"} = Repo.get(WorkerKey, "worker-abc")
      # Reconnect with the same key.
      assert {:ok, "worker-abc"} = DeviceAuth.verify(params("worker-abc", pub, priv))
    end

    test "a different key for an enrolled worker_id is rejected" do
      {pub1, priv1} = keypair()
      {pub2, priv2} = keypair()
      assert {:ok, _} = DeviceAuth.verify(params("worker-x", pub1, priv1))
      assert {:error, :key_mismatch} = DeviceAuth.verify(params("worker-x", pub2, priv2))
    end

    test "a revoked worker is rejected" do
      {pub, priv} = keypair()
      assert {:ok, _} = DeviceAuth.verify(params("worker-r", pub, priv))
      :ok = DeviceAuth.revoke("worker-r")
      assert {:error, :revoked} = DeviceAuth.verify(params("worker-r", pub, priv))
    end

    test "a stale timestamp is rejected" do
      {pub, priv} = keypair()
      old = System.os_time(:second) - 1_000
      assert {:error, :stale} = DeviceAuth.verify(params("worker-s", pub, priv, ts: old))
    end

    test "a tampered signature is rejected" do
      {pub, priv} = keypair()
      {other_pub, _} = keypair()
      # Sign with priv but claim other_pub -> signature won't verify.
      assert {:error, :bad_signature} =
               DeviceAuth.verify(params("worker-t", pub, priv, pubkey: other_pub))
    end

    test "missing fields are rejected as malformed" do
      assert {:error, :malformed} = DeviceAuth.verify(%{"pubkey" => "x"})
    end
  end

  describe "socket connect/3" do
    test "accepts a valid device challenge and binds the worker_id" do
      {pub, priv} = keypair()
      assert {:ok, socket} = connect(WorkerSocket, params("worker-d", pub, priv))
      assert socket.assigns.auth_worker_id == "worker-d"
    end

    test "rejects an invalid device challenge" do
      {pub, priv} = keypair()
      bad = params("worker-d", pub, priv, ts: System.os_time(:second) - 9_999)
      assert :error = connect(WorkerSocket, bad)
    end

    test "require_device_auth rejects a worker with no device key" do
      Application.put_env(:coordinator, :require_device_auth, true)
      assert :error = connect(WorkerSocket, %{})
    end
  end
end
