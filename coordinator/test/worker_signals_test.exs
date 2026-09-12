defmodule Coordinator.WorkerSignalsTest do
  @moduledoc """
  The scheduling signals the coordinator measures rather than accepts. Routing used to score
  workers on numbers they reported about themselves.
  """
  use ExUnit.Case, async: true

  alias Coordinator.WorkerSignals

  describe "observe_latency" do
    test "the first sample seeds the average instead of being eased into from zero" do
      # Easing from the 0.0 struct default would make every freshly connected worker look
      # like the fastest on the network for its first several jobs.
      assert WorkerSignals.observe_latency(0.0, 400) == 400.0
      assert WorkerSignals.observe_latency(nil, 400) == 400.0
    end

    test "later samples move the average without replacing it" do
      avg = WorkerSignals.observe_latency(100.0, 1000)

      assert avg > 100.0
      assert avg < 1000.0
    end

    test "a worker that genuinely slows down is followed within a few jobs" do
      avg = Enum.reduce(1..5, 100.0, fn _, acc -> WorkerSignals.observe_latency(acc, 2000) end)

      assert avg > 1500.0
    end

    test "an implausible sample is ignored rather than poisoning the average" do
      # A lease can outlive its job's deadline across a reconnect; that timestamp is not
      # evidence about throughput.
      assert WorkerSignals.observe_latency(250.0, 5_000_000) == 250.0
      assert WorkerSignals.observe_latency(250.0, -5) == 250.0
    end
  end

  describe "hourly request window" do
    test "counts completions inside the trailing hour and forgets older ones" do
      now = 10_000_000

      completions =
        [now - 3_500_000, now - 3_599_000, now - 7_200_000]
        |> WorkerSignals.record_completion(now)

      # The just-recorded one plus the two still inside the hour; the two-hour-old sample is
      # dropped on write, not merely uncounted, so the list cannot grow without bound.
      assert WorkerSignals.requests_in_window(completions, now) == 3
      assert length(completions) == 3
    end

    test "an hour later the window is empty again" do
      now = 10_000_000
      completions = WorkerSignals.record_completion([], now)

      assert WorkerSignals.requests_in_window(completions, now + 3_600_001) == 0
    end
  end

  describe "failure score" do
    test "a failure costs a point and successes pay it back" do
      failed = WorkerSignals.record_outcome(0.0, :failed)
      assert failed == 1.0

      recovering = WorkerSignals.record_outcome(failed, :ok)
      assert recovering < failed
      assert recovering > 0.0
    end

    test "a worker that keeps failing stays penalized" do
      score = Enum.reduce(1..5, 0.0, fn _, acc -> WorkerSignals.record_outcome(acc, :failed) end)
      assert score >= 5.0
    end

    test "rejections and timeouts count as failures" do
      assert WorkerSignals.record_outcome(0.0, :rejected) == 1.0
      assert WorkerSignals.record_outcome(0.0, :timeout) == 1.0
    end

    test "a result with no status is a failure — it did not demonstrate success" do
      assert WorkerSignals.outcome(%{"status" => "ok"}) == :ok
      assert WorkerSignals.outcome(%{"status" => "rejected"}) == :rejected
      assert WorkerSignals.outcome(%{"status" => "error"}) == :failed
      assert WorkerSignals.outcome(%{}) == :failed
      assert WorkerSignals.outcome(nil) == :failed
    end
  end
end
