defmodule Coordinator.RouterTest do
  use ExUnit.Case, async: true
  alias Coordinator.{Job, Router, Worker}

  @cap "text.extract_json"

  defp model(external?),
    do: %{
      name: if(external?, do: "gpt", else: "qwen"),
      capabilities: [@cap],
      context_length: 8000,
      uses_external_provider: external?
    }

  defp worker(id, opts) do
    %Worker{
      worker_id: id,
      execution_mode: Keyword.get(opts, :mode, :local_model),
      models: Keyword.get(opts, :models, [model(false)]),
      accepted_job_levels:
        Keyword.get(opts, :levels, [:public, :private, :sensitive, :local_only]),
      trust_level: Keyword.get(opts, :trust, "untrusted"),
      inflight: Keyword.get(opts, :inflight, 0),
      avg_latency_ms: Keyword.get(opts, :latency, 0.0),
      requests_last_hour: Keyword.get(opts, :rph, 0),
      recent_failures: Keyword.get(opts, :failures, 0.0),
      max_requests_per_hour: Keyword.get(opts, :max_rph),
      available: Keyword.get(opts, :available, true)
    }
  end

  defp job(privacy, allow_external \\ false) do
    %Job{
      job_id: "j",
      capability: @cap,
      privacy: privacy,
      allow_external_providers: allow_external
    }
  end

  test "public routes to local or external" do
    local = worker("local", models: [model(false)])
    ext = worker("ext", models: [model(true)])
    assert {:ok, _} = Router.route(job(:public), [ext])
    assert {:ok, %{worker_id: "local"}} = Router.route(job(:public), [local, ext])
  end

  test "requested model routes to a worker that serves it, over local preference" do
    qwen = worker("qwen-box", models: [model(false)])
    gpt = worker("gpt-box", models: [model(true)])
    j = %{job(:public, true) | model: "gpt"}

    # Without model preference, local (qwen-box) wins; requesting "gpt" flips it to gpt-box.
    assert {:ok, %{worker_id: "gpt-box"}} = Router.route(j, [qwen, gpt])
  end

  test "requested model rejects substitution when none serve it" do
    qwen = worker("qwen-box", models: [model(false)])
    j = %{job(:public, true) | model: "nonexistent-model"}
    assert {:error, :no_eligible_worker} = Router.route(j, [qwen])
  end

  test "local_only excludes external-only workers" do
    ext = worker("ext", models: [model(true)])
    assert {:error, :no_eligible_worker} = Router.route(job(:local_only), [ext])

    local = worker("local", models: [model(false)])
    assert {:ok, %{worker_id: "local"}} = Router.route(job(:local_only), [local, ext])
  end

  test "sensitive never routes to external by default" do
    ext = worker("ext", models: [model(true)])
    assert {:error, :no_eligible_worker} = Router.route(job(:sensitive), [ext])
  end

  test "private routes external only when the job permits it" do
    ext = worker("ext", models: [model(true)])
    assert {:error, :no_eligible_worker} = Router.route(job(:private, false), [ext])
    assert {:ok, %{worker_id: "ext"}} = Router.route(job(:private, true), [ext])
  end

  test "worker must accept the job's privacy level" do
    local = worker("local", models: [model(false)], levels: [:public])
    assert {:error, :no_eligible_worker} = Router.route(job(:private), [local])
  end

  test "prefers local (free) over external when both can serve" do
    local = worker("local", models: [model(false)], inflight: 1)
    ext = worker("ext", models: [model(true)], inflight: 0)
    # despite higher inflight, local wins because external carries a paid penalty
    assert {:ok, %{worker_id: "local"}} = Router.route(job(:public), [local, ext])
  end

  test "respects hourly capacity ceiling" do
    busy = worker("busy", models: [model(false)], rph: 5, max_rph: 5)
    assert {:error, :no_eligible_worker} = Router.route(job(:public), [busy])
  end

  test "the hourly ceiling counts the trailing hour, not instantaneous inflight" do
    # These were compared against each other despite being different units: five jobs running
    # right now is not five jobs in the last hour.
    concurrent = worker("concurrent", models: [model(false)], inflight: 5, rph: 1, max_rph: 5)
    assert {:ok, %{worker_id: "concurrent"}} = Router.route(job(:public), [concurrent])

    spent = worker("spent", models: [model(false)], inflight: 0, rph: 5, max_rph: 5)
    assert {:error, :no_eligible_worker} = Router.route(job(:public), [spent])
  end

  test "a worker that has been failing loses out to one that has not" do
    # Behavioural, and separate from the admin's trust grant: this says what a worker has
    # actually been doing.
    reliable = worker("reliable", models: [model(false)], failures: 0.0)
    flaky = worker("flaky", models: [model(false)], failures: 3.0)

    assert {:ok, %{worker_id: "reliable"}} = Router.route(job(:public), [flaky, reliable])
  end

  test "a failing trusted worker can still lose to a healthy untrusted one" do
    # Trust is a -20 bonus; a sustained failure record outweighs it. Otherwise a trusted
    # worker that has stopped working keeps being handed everything.
    trusted_but_broken =
      worker("trusted-broken", models: [model(false)], trust: "trusted", failures: 4.0)

    healthy = worker("healthy", models: [model(false)], trust: "untrusted")

    assert {:ok, %{worker_id: "healthy"}} =
             Router.route(job(:public), [trusted_but_broken, healthy])
  end

  test "unavailable workers are excluded" do
    down = worker("down", models: [model(false)], available: false)
    assert {:error, :no_eligible_worker} = Router.route(job(:public), [down])
  end
end
