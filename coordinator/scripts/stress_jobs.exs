# Job-intake stress load for the coordinator.
#
# The coordinator has NO HTTP job API — jobs are created by calling `Coordinator.submit_job/1`,
# which persists the job (Repo) and enqueues its lease assignment (Oban -> Router -> WS
# broadcast). This module floods that real path from inside the running node, so it exercises
# Postgres inserts, Oban, and the routing decision end-to-end.
#
# Run it in the LIVE node (single Oban processing path) via `bin/coordinator rpc` — see
# scripts/stress_jobs.sh. It defines `StressJobs`; the wrapper appends the `StressJobs.run(...)`
# call with interpolated options (env can't cross into an rpc'd node, so options are passed in).
#
# Options (keyword list):
#   total:          total jobs to submit            (default 1000)
#   conc:           concurrent producer tasks       (default 50)
#   capability:     job capability string           (default "chat")
#   privacy:        public|private|sensitive|local_only (default "public")
#   allow_external: allow external providers        (default true)
#   wait_ms:        if > 0, poll each job up to this long for it to leave `pending`,
#                   measuring time-to-lease (needs a connected, eligible worker) (default 0)
defmodule StressJobs do
  def run(opts \\ []) do
    total = Keyword.get(opts, :total, 1000)
    conc = Keyword.get(opts, :conc, 50)
    capability = Keyword.get(opts, :capability, "chat")
    privacy = Keyword.get(opts, :privacy, "public")
    allow_external = Keyword.get(opts, :allow_external, true)
    wait_ms = Keyword.get(opts, :wait_ms, 0)

    IO.puts("job-intake stress: total=#{total} conc=#{conc} capability=#{capability} " <>
              "privacy=#{privacy} allow_external=#{allow_external} wait_ms=#{wait_ms}")

    per = div(total, conc)
    actual = per * conc
    if actual != total, do: IO.puts("(rounding to #{actual} = #{per} x #{conc})")

    started = System.monotonic_time()

    results =
      1..conc
      |> Task.async_stream(
        fn shard ->
          Enum.map(1..per, fn i -> one(shard, i, capability, privacy, allow_external) end)
        end,
        max_concurrency: conc,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.flat_map(fn {:ok, list} -> list end)

    wall_us = System.monotonic_time() - started |> to_us()

    {oks, errs} = Enum.split_with(results, fn {st, _, _} -> st == :ok end)
    submit_lat = oks |> Enum.map(fn {_, us, _} -> us end) |> Enum.sort()

    IO.puts("\nsubmit results:")
    IO.puts("  ok     #{length(oks)}")
    IO.puts("  failed #{length(errs)}")
    print_errs(errs)

    IO.puts("\nthroughput:")
    IO.puts("  wall time      #{fmt_ms(wall_us)} ms")
    IO.puts("  submits/sec    #{ratef(length(results), wall_us)}")

    IO.puts("\nsubmit latency (Repo insert + Oban enqueue):")
    print_pcts(submit_lat)

    if wait_ms > 0, do: measure_lease(oks, wait_ms)
    :ok
  end

  # One job submission, timed. Returns {:ok|:error, micros, id_or_reason}.
  defp one(shard, i, capability, privacy, allow_external) do
    attrs = %{
      capability: capability,
      privacy: privacy,
      allow_external_providers: allow_external,
      payload: %{
        "messages" => [%{"role" => "user", "content" => "stress #{shard}.#{i}"}],
        "max_tokens" => 16
      }
    }

    t0 = System.monotonic_time()

    case Coordinator.submit_job(attrs) do
      {:ok, rec} -> {:ok, to_us(System.monotonic_time() - t0), rec.id}
      {:error, reason} -> {:error, to_us(System.monotonic_time() - t0), inspect(reason)}
    end
  end

  # Poll the submitted jobs until they leave `pending`, measuring time-to-lease. This only moves
  # if an eligible worker is connected; otherwise jobs stay pending (Router finds no worker) and
  # this reports them as "still pending" — which is itself a useful signal under load.
  defp measure_lease(oks, wait_ms) do
    ids = Enum.map(oks, fn {_, _, id} -> id end)
    deadline = System.monotonic_time() + System.convert_time_unit(wait_ms, :millisecond, :native)
    t0 = System.monotonic_time()

    lease_lat =
      ids
      |> Enum.map(fn id -> poll_left_pending(id, deadline, t0) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    pending = length(ids) - length(lease_lat)
    IO.puts("\nlease outcome (within #{wait_ms} ms):")
    IO.puts("  left pending   #{length(lease_lat)}")
    IO.puts("  still pending  #{pending}  (no eligible worker, or backpressure)")
    if lease_lat != [] do
      IO.puts("\ntime-to-lease (submit -> routed to a worker):")
      print_pcts(lease_lat)
    end
  end

  defp poll_left_pending(id, deadline, t0) do
    case Coordinator.Jobs.get(id) do
      %{status: "pending"} ->
        if System.monotonic_time() >= deadline do
          nil
        else
          Process.sleep(20)
          poll_left_pending(id, deadline, t0)
        end

      %{} ->
        to_us(System.monotonic_time() - t0)

      nil ->
        nil
    end
  end

  # ---- reporting helpers ----
  defp print_pcts([]), do: IO.puts("  (none)")

  defp print_pcts(sorted) do
    IO.puts("  avg  #{fmt_ms(avg(sorted))} ms")
    IO.puts("  p50  #{fmt_ms(pct(sorted, 50))} ms")
    IO.puts("  p95  #{fmt_ms(pct(sorted, 95))} ms")
    IO.puts("  p99  #{fmt_ms(pct(sorted, 99))} ms")
    IO.puts("  max  #{fmt_ms(List.last(sorted))} ms")
  end

  defp print_errs([]), do: :ok

  defp print_errs(errs) do
    errs
    |> Enum.map(fn {_, _, reason} -> reason end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, n} -> -n end)
    |> Enum.take(5)
    |> Enum.each(fn {reason, n} -> IO.puts("    #{n}x #{reason}") end)
  end

  defp pct(sorted, q) do
    n = length(sorted)
    idx = max(0, min(n - 1, round(q / 100 * n) - 1))
    Enum.at(sorted, idx)
  end

  defp avg([]), do: 0
  defp avg(xs), do: div(Enum.sum(xs), length(xs))
  defp to_us(native), do: System.convert_time_unit(native, :native, :microsecond)
  defp fmt_ms(us), do: :erlang.float_to_binary(us / 1000, decimals: 2)

  defp ratef(_n, 0), do: "inf"
  defp ratef(n, us), do: :erlang.float_to_binary(n / (us / 1_000_000), decimals: 1)
end
