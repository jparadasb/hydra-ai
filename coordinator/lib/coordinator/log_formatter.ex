defmodule Coordinator.LogFormatter do
  @moduledoc """
  One JSON object per log line, for production.

  Every log call in the coordinator attaches metadata — `job_id`, `worker_id`, `lease_id`,
  `peer_ip`, `attempts`. The default formatter renders that as a trailing string, so a
  collector has to parse fields back out of a sentence to filter on them. This emits them as
  fields.

  Kept deliberately small: no dependency, no configuration, and a failure to encode falls back
  to something loggable rather than raising inside the logger.
  """

  @doc """
  `Logger`'s formatter callback.

  Returns iodata ending in a newline. Anything that cannot be encoded is inspected rather than
  dropped: a log line that is hard to read still beats a logger that crashes.
  """
  def format(level, message, timestamp, metadata) do
    entry =
      metadata
      |> Map.new(fn {key, value} -> {key, encodable(value)} end)
      |> Map.merge(%{
        level: level,
        message: IO.iodata_to_binary(message),
        time: format_timestamp(timestamp)
      })

    [Jason.encode_to_iodata!(entry), ?\n]
  rescue
    # The logger is the last thing that should take a process down with it.
    error -> "could not format log entry: #{inspect(error)}\n"
  end

  # Pids, references, and charlists are routine in Logger metadata and are not JSON.
  defp encodable(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp encodable(nil), do: nil
  defp encodable(value) when is_atom(value), do: Atom.to_string(value)
  defp encodable(value) when is_list(value), do: Enum.map(value, &encodable/1)
  defp encodable(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encodable(value) when is_map(value), do: inspect(value)
  defp encodable(value), do: inspect(value)

  defp format_timestamp({date, {hour, minute, second, millisecond}}) do
    {year, month, day} = date

    :io_lib.format(
      "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~3..0BZ",
      [year, month, day, hour, minute, second, millisecond]
    )
    |> IO.iodata_to_binary()
  end

  defp format_timestamp(other), do: inspect(other)
end
