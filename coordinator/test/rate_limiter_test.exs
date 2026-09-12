defmodule Coordinator.RateLimiterTest do
  @moduledoc "Per-caller rate window and concurrency slots, independent of the HTTP front-door."
  # async: false — the limiter is a singleton with process-global counters.
  use ExUnit.Case, async: false

  alias Coordinator.RateLimiter

  setup do
    RateLimiter.reset()

    on_exit(fn ->
      Application.put_env(:coordinator, :rate_limit_per_minute, 0)
      Application.put_env(:coordinator, :max_concurrent_per_key, 0)
      RateLimiter.reset()
    end)

    :ok
  end

  test "a limit of zero disables the check" do
    Application.put_env(:coordinator, :rate_limit_per_minute, 0)
    Application.put_env(:coordinator, :max_concurrent_per_key, 0)

    for _ <- 1..50, do: assert(RateLimiter.check_rate({:token, "off"}) == :ok)
    for _ <- 1..50, do: assert(RateLimiter.acquire({:token, "off"}) == :ok)
  end

  test "requests beyond the window limit are refused with a retry hint" do
    Application.put_env(:coordinator, :rate_limit_per_minute, 3)
    key = {:token, "rate-#{System.unique_integer([:positive])}"}

    assert RateLimiter.check_rate(key) == :ok
    assert RateLimiter.check_rate(key) == :ok
    assert RateLimiter.check_rate(key) == :ok

    assert {:error, :rate_limited, retry_after} = RateLimiter.check_rate(key)
    assert retry_after > 0 and retry_after <= 60
  end

  test "one caller's rate window does not spend another's" do
    Application.put_env(:coordinator, :rate_limit_per_minute, 1)

    assert RateLimiter.check_rate({:token, "a"}) == :ok
    assert {:error, :rate_limited, _} = RateLimiter.check_rate({:token, "a"})
    assert RateLimiter.check_rate({:token, "b"}) == :ok
  end

  test "slots are handed back on release" do
    Application.put_env(:coordinator, :max_concurrent_per_key, 1)
    key = {:token, "slots"}

    assert RateLimiter.acquire(key) == :ok
    assert RateLimiter.inflight(key) == 1

    task = Task.async(fn -> RateLimiter.acquire(key) end)
    assert Task.await(task) == {:error, :too_many_concurrent}

    RateLimiter.release(key)
    # release/1 is a cast; inflight/1 reflects it once the limiter has processed it.
    assert RateLimiter.inflight(key) == 0 or wait_until(fn -> RateLimiter.inflight(key) == 0 end)
    assert RateLimiter.acquire(key) == :ok
  end

  test "a holder that dies without releasing gives its slot back" do
    Application.put_env(:coordinator, :max_concurrent_per_key, 1)
    key = {:token, "dead-holder"}

    {:ok, pid} =
      Task.start(fn ->
        RateLimiter.acquire(key)
        Process.sleep(:infinity)
      end)

    assert wait_until(fn -> RateLimiter.inflight(key) == 1 end)

    Process.exit(pid, :kill)

    assert wait_until(fn -> RateLimiter.inflight(key) == 0 end)
    assert RateLimiter.acquire(key) == :ok
  end

  test "a release from a process holding no slot cannot create one" do
    Application.put_env(:coordinator, :max_concurrent_per_key, 1)
    key = {:token, "phantom-release"}

    RateLimiter.release(key)
    RateLimiter.release(key)

    assert RateLimiter.acquire(key) == :ok
    assert wait_until(fn -> RateLimiter.inflight(key) == 1 end)
    task = Task.async(fn -> RateLimiter.acquire(key) end)
    assert Task.await(task) == {:error, :too_many_concurrent}
  end

  defp wait_until(fun, tries \\ 100)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      wait_until(fun, tries - 1)
    end
  end
end
