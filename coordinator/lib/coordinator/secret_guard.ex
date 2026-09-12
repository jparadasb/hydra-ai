defmodule Coordinator.SecretGuard do
  @moduledoc """
  Defense in depth for the core rule: **provider tokens stay on the worker.**

  The wire contract (see `/proto`) has no token/secret field, and `Secret` is non-serializable
  on the worker — that is the real protection. This guard is the second line: it catches a
  credential that reached the coordinator anyway, before it lands in state, logs, or the
  database.

  ## Two boundaries, two answers

  Rejecting a whole payload is right in one place and wrong in the other, so the two are
  separate functions:

    * **Registration** (`verify/1`) — a join payload has no business carrying a credential.
      A match refuses the registration outright.

    * **Results and usage** (`redact/1`) — a worker's completion is the caller's answer. A
      match used to drop the entire result, which meant a model explaining how to use an HTTP
      API, or a tool call whose arguments carry an `authorization` header, produced a request
      that simply timed out at 504 with nothing to diagnose. The matched span is replaced
      instead, and the completion still reaches the caller.

  `redact/1` also keeps keys, replacing only their values. Deleting a key out of a tool call's
  arguments changes the model's output; replacing its value does not.

  ## What is *not* guarded

  The caller → worker direction is deliberately untouched. A prompt is the caller's own
  content: someone asking "why is my `Authorization: Bearer …` header rejected?" must get an
  answer, not a mangled prompt. How long that content is kept is bounded by
  `Coordinator.JobRetention` (see #15) rather than by redacting it on the way in.
  """

  require Logger

  @redaction "[REDACTED]"

  # Key words that mean "this value is a credential", matched anywhere in the key.
  @secret_words ~w(secret password passwd credential apikey)

  # Keys that contain a secret word but are not secrets. Token *counts* are the big one:
  # `max_tokens`, `input_tokens` and friends are on essentially every chat payload, and
  # `token_storage` is part of every worker registration.
  @safe_keys ~w(
    tokens token_count num_tokens max_tokens min_tokens
    input_tokens output_tokens total_tokens prompt_tokens completion_tokens
    reasoning_tokens cached_tokens max_output_tokens max_completion_tokens
    token_storage tokens_per_second
  )

  # Value shapes that are credentials wherever they appear. Prefix-and-length rather than a
  # bare prefix: `sk-` on its own matched ordinary prose.
  @secret_value_patterns [
    # OpenAI / Anthropic / Groq
    ~r/\bsk-ant-[A-Za-z0-9_-]{16,}/,
    ~r/\bsk-[A-Za-z0-9_-]{16,}/,
    ~r/\bgsk_[A-Za-z0-9_-]{16,}/,
    # Google
    ~r/\bAIza[A-Za-z0-9_-]{16,}/,
    # AWS access key ids
    ~r/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
    # GitHub (classic + fine-grained + app tokens)
    ~r/\bgh[pousr]_[A-Za-z0-9]{20,}/,
    ~r/\bgithub_pat_[A-Za-z0-9_]{20,}/,
    # Slack
    ~r/\bxox[baprs]-[A-Za-z0-9-]{10,}/,
    # Stripe
    ~r/\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}/,
    # JWTs — three base64url segments
    ~r/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/,
    # PEM private key blocks, header through footer
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/,
    # A bearer token long enough to be one. Shorter matches were mostly prose.
    ~r/\bBearer\s+[A-Za-z0-9._~+\/=-]{20,}/i
  ]

  # An unrecognized credential is still a long, dense, whitespace-free token. Bounded above so
  # a base64-encoded image or a document body is not mistaken for one, and applied only to a
  # value that is *entirely* such a token — never to a span inside prose.
  @opaque_secret_min_length 32
  @opaque_secret_max_length 200
  @opaque_secret_min_entropy 3.5
  # Credential alphabets are base64url/hex-ish. Excluding `.`, `:` and `/` is what keeps URLs,
  # file paths, dotted identifiers and email addresses out — all of which are otherwise long,
  # dense and high-entropy enough to match.
  @opaque_secret_charset ~r/^[A-Za-z0-9_\-+=]+$/

  @doc """
  Strict check for the registration boundary. `:ok`, or `{:error, reason}` so the join can be
  refused.
  """
  def verify(value) do
    cond do
      has_banned_key?(value) -> {:error, :secret_key_present}
      has_secret_value?(value) -> {:error, :secret_value_present}
      true -> :ok
    end
  end

  @doc """
  Redact secrets from a payload, preserving its shape.

  Returns `{clean, count}` where `count` is how many values were redacted — worth logging and
  worth alerting on, since a worker that leaks credentials is a bug wherever it came from.

  Values under a secret-shaped key are replaced wholesale; secret-shaped spans inside any other
  string are replaced in place. Keys are never removed.
  """
  def redact(value) do
    {clean, count} = do_redact(value, 0)

    if count > 0 do
      Logger.warning("SecretGuard redacted #{count} secret-shaped value(s) from a worker payload")
    end

    {clean, count}
  end

  @doc """
  Recursively strip banned keys and redact secret-shaped values. Used on the registration path,
  after `verify/1` has already passed — belt and suspenders on a payload we keep.

  Prefer `redact/1` anywhere the payload is somebody's data rather than a worker's self
  description: this one deletes keys.
  """
  def sanitize(value)

  def sanitize(map) when is_struct(map), do: map

  def sanitize(map) when is_map(map) do
    map
    |> Enum.reject(fn {k, _v} -> banned_key?(k) end)
    |> Enum.map(fn {k, v} -> {k, sanitize(v)} end)
    |> Map.new()
  end

  def sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)

  def sanitize(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> sanitize() |> List.to_tuple()

  def sanitize(str) when is_binary(str), do: redact_string(str)
  def sanitize(other), do: other

  # ---- redaction ------------------------------------------------------------------------------

  # Structs are data with a type, not payload maps: keep the type, redact the fields. A
  # DateTime has nothing to redact and comes back unchanged.
  defp do_redact(%module{} = struct, count) do
    {clean, count} = struct |> Map.from_struct() |> do_redact(count)
    {struct(module, clean), count}
  end

  defp do_redact(map, count) when is_map(map) do
    Enum.reduce(map, {%{}, count}, fn {k, v}, {acc, n} ->
      if banned_key?(k) and not empty_value?(v) do
        {Map.put(acc, k, @redaction), n + 1}
      else
        {clean, n} = do_redact(v, n)
        {Map.put(acc, k, clean), n}
      end
    end)
  end

  defp do_redact(list, count) when is_list(list) do
    {clean, count} =
      Enum.reduce(list, {[], count}, fn item, {acc, n} ->
        {clean, n} = do_redact(item, n)
        {[clean | acc], n}
      end)

    {Enum.reverse(clean), count}
  end

  defp do_redact(tuple, count) when is_tuple(tuple) do
    {clean, count} = tuple |> Tuple.to_list() |> do_redact(count)
    {List.to_tuple(clean), count}
  end

  defp do_redact(str, count) when is_binary(str) do
    cond do
      opaque_secret?(str) -> {@redaction, count + 1}
      true -> {redact_string(str), count + redaction_count(str)}
    end
  end

  defp do_redact(other, count), do: {other, count}

  defp redact_string(str) do
    Enum.reduce(@secret_value_patterns, str, fn re, acc ->
      Regex.replace(re, acc, @redaction)
    end)
  end

  defp redaction_count(str) do
    Enum.reduce(@secret_value_patterns, 0, fn re, n -> n + length(Regex.scan(re, str)) end)
  end

  defp empty_value?(v), do: v in [nil, "", [], %{}]

  # ---- key matching ---------------------------------------------------------------------------

  defp banned_key?(k) when is_atom(k), do: banned_key?(Atom.to_string(k))

  defp banned_key?(k) when is_binary(k) do
    normalized = k |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")

    cond do
      normalized in @safe_keys -> false
      Enum.any?(@secret_words, &String.contains?(normalized, &1)) -> true
      normalized in ~w(auth authorization bearer key) -> true
      String.contains?(normalized, "token") -> true
      # `api_key`, `apiKey`, `x-api-key`, `openai_api_key`, …
      String.contains?(normalized, "api") and String.contains?(normalized, "key") -> true
      # `private_key`, `access_key`, `client_key`, `signing_key`, …
      String.ends_with?(normalized, "_key") -> true
      true -> false
    end
  end

  defp banned_key?(_), do: false

  defp has_banned_key?(%_{} = struct), do: struct |> Map.from_struct() |> has_banned_key?()

  defp has_banned_key?(map) when is_map(map) do
    Enum.any?(map, fn {k, v} -> banned_key?(k) or has_banned_key?(v) end)
  end

  defp has_banned_key?(list) when is_list(list), do: Enum.any?(list, &has_banned_key?/1)

  defp has_banned_key?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> has_banned_key?()

  defp has_banned_key?(_), do: false

  # ---- value matching -------------------------------------------------------------------------

  defp has_secret_value?(%_{} = struct), do: struct |> Map.from_struct() |> has_secret_value?()

  defp has_secret_value?(map) when is_map(map),
    do: Enum.any?(map, fn {_k, v} -> has_secret_value?(v) end)

  defp has_secret_value?(list) when is_list(list), do: Enum.any?(list, &has_secret_value?/1)

  defp has_secret_value?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> has_secret_value?()

  defp has_secret_value?(str) when is_binary(str),
    do: Enum.any?(@secret_value_patterns, &Regex.match?(&1, str)) or opaque_secret?(str)

  defp has_secret_value?(_), do: false

  @doc """
  Does this string look like a credential whose format we do not recognize?

  Length-bounded, drawn from a credential alphabet, mixed-case-or-digits and high-entropy. The
  bounds matter in both directions: below them sit ordinary identifiers, above them sit base64
  blobs and document bodies, and neither should be redacted. The alphabet restriction is what
  keeps URLs and paths out — `https://api.example.com/v1/things` is otherwise long, dense and
  high-entropy enough to match.
  """
  def opaque_secret?(str) when is_binary(str) do
    length = String.length(str)

    length >= @opaque_secret_min_length and
      length <= @opaque_secret_max_length and
      Regex.match?(@opaque_secret_charset, str) and
      charset_classes(str) >= 2 and
      shannon_entropy(str) >= @opaque_secret_min_entropy
  end

  def opaque_secret?(_), do: false

  defp charset_classes(str) do
    [~r/[a-z]/, ~r/[A-Z]/, ~r/[0-9]/]
    |> Enum.count(&Regex.match?(&1, str))
  end

  # Shannon entropy in bits per character.
  defp shannon_entropy(str) do
    chars = String.graphemes(str)
    total = length(chars)

    chars
    |> Enum.frequencies()
    |> Enum.reduce(0.0, fn {_char, n}, acc ->
      p = n / total
      acc - p * :math.log2(p)
    end)
  end
end
