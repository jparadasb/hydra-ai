defmodule Coordinator.LogFormatterTest do
  @moduledoc """
  Production log lines. Metadata is only useful if a collector can read it as fields rather
  than parsing it back out of a sentence.
  """
  use ExUnit.Case, async: true

  alias Coordinator.LogFormatter

  @timestamp {{2026, 9, 12}, {21, 30, 15, 123}}

  defp format(level, message, metadata) do
    level
    |> LogFormatter.format(message, @timestamp, metadata)
    |> IO.iodata_to_binary()
  end

  test "renders one JSON object per line with metadata as fields" do
    line = format(:info, "job leased", job_id: "job-1", worker_id: "w-1", attempts: 2)

    assert String.ends_with?(line, "\n")

    entry = Jason.decode!(line)
    assert entry["level"] == "info"
    assert entry["message"] == "job leased"
    assert entry["job_id"] == "job-1"
    assert entry["worker_id"] == "w-1"
    assert entry["attempts"] == 2
    assert entry["time"] == "2026-09-12T21:30:15.123Z"
  end

  test "metadata that is not JSON is inspected rather than dropped or raised on" do
    # Pids and references are routine in Logger metadata.
    line = format(:error, "worker channel died", pid: self(), ref: make_ref())

    entry = Jason.decode!(line)
    assert entry["pid"] =~ "#PID<"
    assert entry["ref"] =~ "#Reference<"
  end

  test "a value that cannot be encoded at all still produces a loggable line" do
    # The logger is the last thing that should take a process down with it.
    line = format(:info, "odd metadata", weird: {:a, fn -> :b end})

    assert is_binary(line)
    assert String.ends_with?(line, "\n")
  end

  test "chardata messages are rendered as strings" do
    line = format(:warning, ["job ", "failed"], job_id: "job-2")
    assert Jason.decode!(line)["message"] == "job failed"
  end
end
