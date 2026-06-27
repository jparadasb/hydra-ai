defmodule Coordinator.SecretGuard do
  @moduledoc """
  Defense in depth for the core rule: **provider tokens stay on the worker.**

  The wire contract (see `/proto`) has no token/secret field. This guard additionally
  strips — and can reject — any inbound payload that nonetheless carries a secret-shaped
  key or value, so a buggy/malicious worker cannot push a credential into coordinator
  state, logs, or the database.
  """

  # Keys that must never appear on an inbound payload.
  @banned_keys ~w(token api_key apikey secret authorization auth password
                  x-api-key x_api_key bearer credential credentials private_key)

  # Value patterns that look like provider secrets.
  @secret_value_patterns [
    ~r/\bsk-[A-Za-z0-9_-]{8,}/,
    ~r/\bsk-ant-[A-Za-z0-9_-]{8,}/,
    ~r/\bAIza[A-Za-z0-9_-]{8,}/,
    ~r/\bgsk_[A-Za-z0-9_-]{8,}/,
    ~r/\bBearer\s+[A-Za-z0-9._-]{8,}/i
  ]

  @doc """
  Recursively strip banned keys and redact secret-shaped string values from a decoded
  payload (maps/lists/scalars). Returns the cleaned payload. Safe to store/log.
  """
  def sanitize(value)

  def sanitize(map) when is_map(map) do
    map
    |> Enum.reject(fn {k, _v} -> banned_key?(k) end)
    |> Enum.map(fn {k, v} -> {k, sanitize(v)} end)
    |> Map.new()
  end

  def sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)

  def sanitize(str) when is_binary(str) do
    Enum.reduce(@secret_value_patterns, str, fn re, acc ->
      Regex.replace(re, acc, "[REDACTED]")
    end)
  end

  def sanitize(other), do: other

  @doc """
  Strict check used at the channel boundary. Returns `:ok` if the payload is free of
  secret-shaped keys/values, or `{:error, reason}` so the join/push can be refused.
  """
  def verify(value) do
    cond do
      has_banned_key?(value) -> {:error, :secret_key_present}
      has_secret_value?(value) -> {:error, :secret_value_present}
      true -> :ok
    end
  end

  defp banned_key?(k) when is_atom(k), do: banned_key?(Atom.to_string(k))
  defp banned_key?(k) when is_binary(k), do: String.downcase(k) in @banned_keys

  defp has_banned_key?(map) when is_map(map) do
    Enum.any?(map, fn {k, v} -> banned_key?(k) or has_banned_key?(v) end)
  end

  defp has_banned_key?(list) when is_list(list), do: Enum.any?(list, &has_banned_key?/1)
  defp has_banned_key?(_), do: false

  defp has_secret_value?(map) when is_map(map),
    do: Enum.any?(map, fn {_k, v} -> has_secret_value?(v) end)

  defp has_secret_value?(list) when is_list(list), do: Enum.any?(list, &has_secret_value?/1)

  defp has_secret_value?(str) when is_binary(str),
    do: Enum.any?(@secret_value_patterns, &Regex.match?(&1, str))

  defp has_secret_value?(_), do: false
end
