defmodule Coordinator.DeviceAuth do
  @moduledoc """
  Ed25519 trust-on-first-use authentication for worker connections.

  A worker derives a stable `worker_id` from its machine and holds a locally-generated device
  keypair (private key never leaves the worker). On connect it presents, as query params:

    * `worker_id`, `pubkey` (base64), `ts` (unix seconds), `nonce`, and
    * `sig` (base64) — an Ed25519 signature over `"worker_id|ts|nonce"`.

  We verify the signature, reject stale timestamps (replay window), then pin the public key to
  the `worker_id` on first sight. Later connects must present the same key, or they are
  rejected (`:key_mismatch`); a revoked worker is rejected (`:revoked`).
  """

  import Ecto.Query, only: [from: 2]

  alias Coordinator.{Repo, WorkerKey}

  # Accepted clock skew / replay window for the signed timestamp.
  @window_seconds 120

  @doc "Verify connect params. Returns `{:ok, worker_id}` or `{:error, reason}`."
  def verify(params) when is_map(params) do
    with {:ok, f} <- extract(params),
         :ok <- check_freshness(f.ts),
         :ok <- check_signature(f),
         :ok <- tofu(f.worker_id, f.pubkey) do
      {:ok, f.worker_id}
    end
  end

  @doc "Does this params map carry a device-key challenge?"
  def present?(params) when is_map(params), do: Map.has_key?(params, "pubkey")

  @doc "Revoke a worker's key. Future connects with it are rejected."
  def revoke(worker_id) do
    from(k in WorkerKey, where: k.worker_id == ^worker_id)
    |> Repo.update_all(set: [status: "revoked", updated_at: DateTime.utc_now()])
    :ok
  end

  defp extract(params) do
    with worker_id when is_binary(worker_id) <- params["worker_id"],
         pubkey when is_binary(pubkey) <- params["pubkey"],
         nonce when is_binary(nonce) <- params["nonce"],
         sig when is_binary(sig) <- params["sig"],
         ts_raw when is_binary(ts_raw) <- params["ts"],
         {ts, ""} <- Integer.parse(ts_raw) do
      {:ok, %{worker_id: worker_id, pubkey: pubkey, nonce: nonce, sig: sig, ts: ts}}
    else
      _ -> {:error, :malformed}
    end
  end

  defp check_freshness(ts) do
    now = System.os_time(:second)
    if abs(now - ts) <= @window_seconds, do: :ok, else: {:error, :stale}
  end

  defp check_signature(f) do
    msg = "#{f.worker_id}|#{f.ts}|#{f.nonce}"

    with {:ok, pub} <- Base.decode64(f.pubkey),
         {:ok, sig} <- Base.decode64(f.sig),
         true <- byte_size(pub) == 32 and byte_size(sig) == 64,
         true <- :crypto.verify(:eddsa, :none, msg, sig, [pub, :ed25519]) do
      :ok
    else
      _ -> {:error, :bad_signature}
    end
  end

  defp tofu(worker_id, pubkey) do
    now = DateTime.utc_now()

    case Repo.get(WorkerKey, worker_id) do
      nil ->
        enroll(worker_id, pubkey, now)

      %WorkerKey{status: "revoked"} ->
        {:error, :revoked}

      %WorkerKey{public_key: ^pubkey} = key ->
        key |> WorkerKey.changeset(%{last_seen_at: now}) |> Repo.update()
        :ok

      %WorkerKey{} ->
        {:error, :key_mismatch}
    end
  end

  defp enroll(worker_id, pubkey, now) do
    %WorkerKey{}
    |> WorkerKey.changeset(%{
      worker_id: worker_id,
      public_key: pubkey,
      status: "trusted",
      first_seen_at: now,
      last_seen_at: now
    })
    |> Repo.insert()
    |> case do
      {:ok, _} ->
        :ok

      {:error, _} ->
        # Lost an enrollment race with a concurrent connect — re-read and compare.
        case Repo.get(WorkerKey, worker_id) do
          %WorkerKey{status: "revoked"} -> {:error, :revoked}
          %WorkerKey{public_key: ^pubkey} -> :ok
          _ -> {:error, :key_mismatch}
        end
    end
  end
end
