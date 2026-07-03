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

  test "requested model falls back to any capable worker when none serve it" do
    qwen = worker("qwen-box", models: [model(false)])
    j = %{job(:public, true) | model: "nonexistent-model"}
    # No worker serves it -> best-effort route to a capable worker rather than failing.
    assert {:ok, %{worker_id: "qwen-box"}} = Router.route(j, [qwen])
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
    busy = worker("busy", models: [model(false)], inflight: 5, max_rph: 5)
    assert {:error, :no_eligible_worker} = Router.route(job(:public), [busy])
  end

  test "unavailable workers are excluded" do
    down = worker("down", models: [model(false)], available: false)
    assert {:error, :no_eligible_worker} = Router.route(job(:public), [down])
  end
end
