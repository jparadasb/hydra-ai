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

  describe "model_policy" do
    test "a preference orders the choice without refusing when it cannot be met" do
      # The point of the policy: an OpenAI client names a model and means it, but a delegating
      # agent usually wants "whatever can do this". Naming a model it cannot verify is connected
      # is how a submission gets refused for no good reason.
      job = policy_job(%{"prefer" => ["qwen"]})

      preferred = worker("w-preferred", [])
      other = worker("w-other", models: [%{model(false) | name: "something-else"}])

      assert {:ok, %{worker_id: "w-preferred"}} = Router.route(job, [other, preferred])
      # And when nothing serves the preference, the job still runs.
      assert {:ok, %{worker_id: "w-other"}} = Router.route(job, [other])
    end

    test "earlier preferences beat later ones" do
      job = policy_job(%{"prefer" => ["first-choice", "second-choice"]})

      first = worker("w-first", models: [%{model(false) | name: "first-choice"}])
      second = worker("w-second", models: [%{model(false) | name: "second-choice"}])

      assert {:ok, %{worker_id: "w-first"}} = Router.route(job, [second, first])
    end

    test "require_local is a hard filter, not a preference" do
      # It is a refusal to use an external provider in all but name, so it behaves like one.
      job = policy_job(%{"require_local" => true})

      local = worker("w-local", [])
      external = worker("w-external", mode: :external_provider, models: [model(true)])

      assert {:ok, %{worker_id: "w-local"}} = Router.route(job, [external, local])
      assert {:error, :no_eligible_worker} = Router.route(job, [external])
    end

    test "an exact model request still wins over a policy" do
      # Naming a model is a constraint; a policy is advice. A job that does both gets the model.
      job = %Job{
        job_id: "job-both",
        capability: @cap,
        privacy: :public,
        model: "exact",
        payload: %{"model_policy" => %{"prefer" => ["other"]}}
      }

      exact = worker("w-exact", models: [%{model(false) | name: "exact"}])
      other = worker("w-other", models: [%{model(false) | name: "other"}])

      assert {:ok, %{worker_id: "w-exact"}} = Router.route(job, [other, exact])
    end

    test "a job with no policy routes exactly as before" do
      job = %Job{job_id: "job-plain2", capability: @cap, privacy: :public, payload: %{}}
      assert {:ok, _} = Router.route(job, [worker("w-any", [])])
    end
  end

  defp policy_job(policy) do
    %Job{
      job_id: "job-policy",
      capability: @cap,
      privacy: :public,
      payload: %{"model_policy" => policy}
    }
  end

  test "a job that may ask for context only goes to a worker that knows to pause" do
    # An older worker would run the reserved tool call straight through and hand the caller a
    # tool call for a tool they never defined — a confusing result rather than a pause.
    job = %Job{
      job_id: "job-ctx",
      capability: @cap,
      privacy: :public,
      payload: %{"tools" => [Coordinator.Mcp.ContextRequest.tool()]}
    }

    old = worker("w-old", [])
    new = %{worker("w-new", []) | supports_input_requests: true}

    assert {:ok, %{worker_id: "w-new"}} = Router.route(job, [old, new])
    assert {:error, :no_eligible_worker} = Router.route(job, [old])
  end

  test "an ordinary job is unaffected by the context-request constraint" do
    job = %Job{job_id: "job-plain", capability: @cap, privacy: :public, payload: %{}}

    assert {:ok, _} = Router.route(job, [worker("w-old", [])])
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
