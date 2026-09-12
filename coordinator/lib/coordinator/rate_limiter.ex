defmodule Coordinator.RateLimiter do
  @moduledoc """
  Per-caller request-rate and concurrency ceilings for the HTTP front-door.

  Without these, one holder of a valid gateway key can saturate the whole network: N concurrent
  requests each pin a Bandit process, a PubSub subscription, and a durable job row for as long
  as the caller's `timeout_ms` allows.

  Two independent limits, both keyed by caller identity (the gateway key's id, or the peer IP
  when the door is open):

    * **rate** — requests started per fixed one-minute window (`:rate_limit_per_minute`)
    * **concurrency** — requests in flight at once (`:max_concurrent_per_key`)

  Setting either to `nil` or `0` disables that limit.

  Concurrency slots are tied to the requesting process: the limiter monitors it and releases
  its slot if it dies, so a caller that disconnects mid-stream (or a crashed request) can never
  leak a slot. Rate counters live in ETS and are read without going through the process.

  Scope is **node-local**. With more than one coordinator replica the effective ceiling is
  `limit x replicas`; a shared counter needs the shared datastore tracked in #17.
  """
  use GenServer

  @table __MODULE__.Table
  @window_ms 60_000
  # Windows older than this are dead weight; swept on the same cadence.
  @sweep_ms 120_000

  @default_rate_limit_per_minute 120
  @default_max_concurrent 8

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Count one request against `key`'s rate window.

  Returns `:ok`, or `{:error, :rate_limited, retry_after_seconds}` when the window is full —
  `retry_after_seconds` is how long until the window rolls, for the `retry-after` header.
  """
  def check_rate(key) do
    case rate_limit() do
      limit when is_integer(limit) and limit > 0 -> do_check_rate(key, limit)
      _ -> :ok
    end
  end

  @doc """
  Take one concurrency slot for `key`, held by the calling process.

  Returns `:ok` or `{:error, :too_many_concurrent}`. Release it with `release/1` — the slot is
  also released automatically if the caller dies.
  """
  def acquire(key) do
    case max_concurrent() do
      limit when is_integer(limit) and limit > 0 ->
        GenServer.call(__MODULE__, {:acquire, key, limit})

      _ ->
        :ok
    end
  end

  @doc "Give back a slot taken by `acquire/1`. Safe to call when no slot is held."
  def release(key) do
    case max_concurrent() do
      limit when is_integer(limit) and limit > 0 ->
        GenServer.cast(__MODULE__, {:release, key, self()})

      _ ->
        :ok
    end
  end

  @doc "Requests in flight for `key`. Exposed for tests and the admin console."
  def inflight(key) do
    case :ets.lookup(@table, {:inflight, key}) do
      [{_, count}] -> count
      [] -> 0
    end
  end

  @doc "Drop all counters. Test-only: limits are otherwise long-lived by design."
  def reset, do: GenServer.call(__MODULE__, :reset)

  # ---- server -------------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    # holders: caller pid -> {key, monitor ref}, so a dying caller's slot is returned.
    {:ok, %{holders: %{}}}
  end

  @impl true
  def handle_call({:acquire, key, limit}, {pid, _tag}, state) do
    if inflight(key) >= limit do
      {:reply, {:error, :too_many_concurrent}, state}
    else
      :ets.update_counter(@table, {:inflight, key}, {2, 1}, {{:inflight, key}, 0})
      ref = Process.monitor(pid)
      {:reply, :ok, put_in(state.holders[pid], {key, ref})}
    end
  end

  def handle_call(:reset, _from, state) do
    Enum.each(state.holders, fn {_pid, {_key, ref}} -> Process.demonitor(ref, [:flush]) end)
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | holders: %{}}}
  end

  @impl true
  def handle_cast({:release, key, pid}, state) do
    case Map.pop(state.holders, pid) do
      {nil, _} ->
        {:noreply, state}

      {{^key, ref}, holders} ->
        Process.demonitor(ref, [:flush])
        decrement(key)
        {:noreply, %{state | holders: holders}}

      # The process holds a slot for a different key; leave it alone.
      {_other, _} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Map.pop(state.holders, pid) do
      {nil, _} ->
        {:noreply, state}

      {{key, _ref}, holders} ->
        decrement(key)
        {:noreply, %{state | holders: holders}}
    end
  end

  def handle_info(:sweep, state) do
    cutoff = window_of(System.system_time(:millisecond) - @sweep_ms)
    :ets.select_delete(@table, [{{{:rate, :_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- internals ----------------------------------------------------------------------------

  defp do_check_rate(key, limit) do
    now = System.system_time(:millisecond)
    window = window_of(now)
    count = :ets.update_counter(@table, {:rate, key, window}, {2, 1}, {{:rate, key, window}, 0})

    if count > limit do
      retry_ms = (window + 1) * @window_ms - now
      {:error, :rate_limited, max(div(retry_ms, 1000), 1)}
    else
      :ok
    end
  end

  # Never let the counter go negative — a stray release would otherwise hand out free slots.
  defp decrement(key) do
    :ets.update_counter(@table, {:inflight, key}, {2, -1, 0, 0}, {{:inflight, key}, 0})
  end

  defp window_of(ms), do: div(ms, @window_ms)

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)

  defp rate_limit,
    do: Application.get_env(:coordinator, :rate_limit_per_minute, @default_rate_limit_per_minute)

  defp max_concurrent,
    do: Application.get_env(:coordinator, :max_concurrent_per_key, @default_max_concurrent)
end
