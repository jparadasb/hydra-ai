defmodule Coordinator.McpToolsTest do
  @moduledoc """
  The four verbs, driven directly rather than over HTTP — the transport has its own tests, and
  what matters here is what a delegating agent is actually told.
  """
  use ExUnit.Case, async: false

  alias Coordinator.Jobs
  alias Coordinator.Jobs.JobRecord
  alias Coordinator.Mcp.Tools

  @caller %{token_id: "tok-a", key: {:token, "tok-a"}}
  @other %{token_id: "tok-b", key: {:token, "tok-b"}}

  setup do
    Coordinator.Repo.delete_all(JobRecord)
    Coordinator.Repo.delete_all(Oban.Job)
    Application.delete_env(:coordinator, :mcp_max_open_jobs_per_key)

    on_exit(fn -> Application.delete_env(:coordinator, :mcp_max_open_jobs_per_key) end)
    :ok
  end

  defp call(name, args, caller \\ @caller) do
    {:ok, result} = Tools.call(name, args, %{caller: caller})
    result
  end

  defp submit(args \\ %{}, caller \\ @caller) do
    call("hydra_submit_job", Map.merge(%{"prompt" => "do the thing"}, args), caller)
  end

  describe "hydra_submit_job" do
    test "returns an id immediately and tells the agent how to follow it" do
      result = submit()

      refute result["isError"]

      assert %{"job_id" => id, "created" => true, "poll_after_ms" => poll} =
               result["structuredContent"]

      assert is_binary(id)
      assert is_integer(poll)
      # The text is what a model reads; it has to point at the next step.
      assert hd(result["content"])["text"] =~ "hydra_get_job"

      assert Jobs.get(id).status == "pending"
    end

    test "defaults to local_only, which the HTTP door does not" do
      # Delegated work is repository content from an agent that did not necessarily think about
      # where it would run. The HTTP door defaults to public only because its callers predate
      # privacy levels.
      job = Jobs.get(submit()["structuredContent"]["job_id"])

      assert job.privacy == "local_only"
      refute job.allow_external_providers
    end

    test "a refusal to leave the machine is not negotiable by another argument" do
      job =
        submit(%{"privacy" => "sensitive", "allow_external_providers" => true})
        |> get_in(["structuredContent", "job_id"])
        |> Jobs.get()

      assert job.privacy == "sensitive"
      refute job.allow_external_providers
    end

    test "a wider level has to be asked for explicitly" do
      job =
        submit(%{"privacy" => "public", "allow_external_providers" => true})
        |> get_in(["structuredContent", "job_id"])
        |> Jobs.get()

      assert job.privacy == "public"
      assert job.allow_external_providers
    end

    test "prompt, system and context become ordinary chat turns" do
      # `context` is not a payload field: no worker knows what one is, and inventing one would
      # mean a job only new workers could run.
      job =
        submit(%{"system" => "be terse", "context" => %{"file" => "lib/a.ex"}})
        |> get_in(["structuredContent", "job_id"])
        |> Jobs.get()

      roles = Enum.map(job.payload["messages"], & &1["role"])
      assert roles == ["system", "user", "user"]
      assert Enum.any?(job.payload["messages"], &(&1["content"] =~ "lib/a.ex"))
    end

    test "a bad privacy level is a tool error, not a protocol error" do
      # The call succeeded and has bad news. Models handle that well and JSON-RPC errors badly.
      result = submit(%{"privacy" => "kind-of-private"})

      assert result["isError"]
      assert hd(result["content"])["text"] =~ "local_only"
    end

    test "an empty submission says what is missing" do
      result = call("hydra_submit_job", %{})

      assert result["isError"]
      assert hd(result["content"])["text"] =~ "prompt"
    end

    test "the same idempotency key returns the first job rather than buying a second run" do
      first = submit(%{"idempotency_key" => "k1"})
      second = submit(%{"idempotency_key" => "k1"})

      assert first["structuredContent"]["job_id"] == second["structuredContent"]["job_id"]
      assert first["structuredContent"]["created"]
      refute second["structuredContent"]["created"]
    end

    test "a caller cannot queue unbounded work" do
      Application.put_env(:coordinator, :mcp_max_open_jobs_per_key, 2)

      submit()
      submit()
      refused = submit()

      assert refused["isError"]
      assert hd(refused["content"])["text"] =~ "per-key limit"
      # Another caller is unaffected: the ceiling is per key, not global.
      refute submit(%{}, @other)["isError"]
    end
  end

  describe "hydra_get_job" do
    test "reports the state, the worker and what it has generated" do
      id = submit()["structuredContent"]["job_id"]
      {:ok, _} = Jobs.mark_leased(Jobs.get(id), "m40-01", "lease-1")

      :ok =
        Jobs.record_progress(id, %{
          "lease_id" => "lease-1",
          "seq" => 0,
          "phase" => "generating",
          "output_tokens" => 300,
          "model" => "qwen3-coder-30b"
        })

      result = call("hydra_get_job", %{"job_id" => id})
      hydra = result["structuredContent"]["hydra"]

      assert result["structuredContent"]["status"] == "working"
      assert result["structuredContent"]["state"] == "generating"
      assert hydra["worker"] == "m40-01"
      assert hydra["model"] == "qwen3-coder-30b"
      assert hydra["tokens"]["generated"] == 300
      # The single line a model reads without parsing metadata.
      assert hd(result["content"])["text"] =~ "300 tokens"
    end

    test "another caller's job is reported exactly as one that never existed" do
      id = submit()["structuredContent"]["job_id"]

      mine = call("hydra_get_job", %{"job_id" => id})
      theirs = call("hydra_get_job", %{"job_id" => id}, @other)
      absent = call("hydra_get_job", %{"job_id" => "job-nope"}, @other)

      refute mine["isError"]
      assert theirs["isError"]
      assert absent["isError"]

      # The two refusals differ only in the id they echo back, so an agent holding a real id it
      # does not own learns nothing that an agent guessing one does not.
      assert hd(theirs["content"])["text"] == "No job #{inspect(id)} belongs to you."
      assert hd(absent["content"])["text"] == ~s(No job "job-nope" belongs to you.)
      assert theirs["structuredContent"] == absent["structuredContent"]
    end
  end

  describe "hydra_cancel_job" do
    test "says whether it stopped something, and keeps what the job had done" do
      id = submit()["structuredContent"]["job_id"]
      {:ok, _} = Jobs.mark_leased(Jobs.get(id), "m40-01", "lease-1")

      :ok =
        Jobs.record_progress(id, %{
          "lease_id" => "lease-1",
          "seq" => 0,
          "phase" => "generating",
          "output_tokens" => 88
        })

      cancelled = call("hydra_cancel_job", %{"job_id" => id})

      assert cancelled["structuredContent"]["cancelled"]
      assert cancelled["structuredContent"]["hydra"]["tokens"]["generated"] == 88

      # Repeating it is a success that changed nothing — an agent retrying after a dropped
      # connection must not be told its cancel failed.
      again = call("hydra_cancel_job", %{"job_id" => id})
      refute again["isError"]
      refute again["structuredContent"]["cancelled"]
      assert again["structuredContent"]["already_terminal"]
    end

    test "a caller cannot cancel someone else's work" do
      id = submit()["structuredContent"]["job_id"]

      assert call("hydra_cancel_job", %{"job_id" => id}, @other)["isError"]
      assert Jobs.get(id).status == "pending"
    end
  end

  describe "hydra_get_result" do
    test "a running job says so rather than pretending to have an answer" do
      id = submit()["structuredContent"]["job_id"]
      result = call("hydra_get_result", %{"job_id" => id})

      refute result["isError"]
      assert result["structuredContent"]["status"] == "working"
      assert is_nil(result["structuredContent"]["text"])
    end

    test "a finished job returns its text, artifacts and usage" do
      id = submit()["structuredContent"]["job_id"]
      {:ok, leased} = Jobs.mark_leased(Jobs.get(id), "m40-01", "lease-1")

      {:ok, _} =
        Jobs.complete(leased.id, %{
          "job_id" => leased.id,
          "lease_id" => "lease-1",
          "status" => "ok",
          "output" => %{
            "content" => "implementation complete",
            "artifacts" => [%{"type" => "patch", "name" => "impl.diff"}]
          },
          "usage" => %{"input_tokens" => 800, "output_tokens" => 200}
        })

      result = call("hydra_get_result", %{"job_id" => id})

      refute result["isError"]
      assert result["structuredContent"]["text"] == "implementation complete"
      assert [%{"name" => "impl.diff"}] = result["structuredContent"]["artifacts"]
      assert result["structuredContent"]["usage"]["total_tokens"] == 1000
    end

    test "a job that failed is an errored result, not a missing one" do
      id = submit()["structuredContent"]["job_id"]
      {:ok, leased} = Jobs.mark_leased(Jobs.get(id), "m40-01", "lease-1")

      for _ <- 1..6 do
        Jobs.complete(leased.id, %{
          "job_id" => leased.id,
          "status" => "error",
          "reason" => "provider_error"
        })
      end

      result = call("hydra_get_result", %{"job_id" => id})

      assert result["isError"]
      assert result["structuredContent"]["failure_reason"] == "provider_error"
      # MCP reserves `failed` for protocol failures; a job that gave up is a completed call
      # carrying bad news.
      assert result["structuredContent"]["status"] == "completed"
    end

    test "a job whose text has expired is reported as redacted, not as missing" do
      id = submit()["structuredContent"]["job_id"]
      {:ok, leased} = Jobs.mark_leased(Jobs.get(id), "m40-01", "lease-1")

      {:ok, _} =
        Jobs.complete(leased.id, %{
          "job_id" => leased.id,
          "lease_id" => "lease-1",
          "status" => "ok",
          "output" => %{"content" => "gone by now"}
        })

      Application.put_env(:coordinator, :job_redact_after_hours, 1)
      on_exit(fn -> Application.delete_env(:coordinator, :job_redact_after_hours) end)

      import Ecto.Query

      Coordinator.Repo.update_all(
        from(j in JobRecord, where: j.id == ^id),
        set: [updated_at: DateTime.add(DateTime.utc_now(), -3, :hour)]
      )

      assert 1 = Coordinator.JobRetention.redact_expired()

      result = call("hydra_get_result", %{"job_id" => id})

      assert result["structuredContent"]["redacted"]
      assert hd(result["content"])["text"] =~ "retention window"
    end
  end

  describe "asking the caller for context" do
    defp park(job_id) do
      {:ok, _} = Jobs.mark_leased(Jobs.get(job_id), "m40-01", "lease-1")

      {:ok, _} =
        Jobs.park_for_input(job_id, %{
          "lease_id" => "lease-1",
          "request_id" => "ir-1",
          "requests" => [
            %{
              "tool_call_id" => "call_1",
              "arguments" => %{
                "kind" => "file",
                "path" => "src/foo.ex",
                "reason" => "need the record definition"
              }
            }
          ],
          "assistant_message" => %{"role" => "assistant", "tool_calls" => [%{"id" => "call_1"}]}
        })

      :ok
    end

    test "the reserved tool is only offered when the caller opts in" do
      plain = Jobs.get(submit()["structuredContent"]["job_id"])
      refute Coordinator.Mcp.ContextRequest.present?(plain.payload)

      opted = Jobs.get(submit(%{"allow_context_requests" => true})["structuredContent"]["job_id"])
      assert Coordinator.Mcp.ContextRequest.present?(opted.payload)
    end

    test "the reserved name cannot be shadowed by a caller's own tool" do
      # Not reachable through hydra_submit_job today — its schema has no `tools` field — so this
      # guards the injection point directly. Shadowing would mean the caller's tool never being
      # called and the job pausing when they expected an answer.
      assert {:error, :reserved_tool_name} =
               Coordinator.Mcp.ContextRequest.inject(%{
                 "tools" => [Coordinator.Mcp.ContextRequest.tool()]
               })

      assert {:ok, payload} = Coordinator.Mcp.ContextRequest.inject(%{"messages" => []})
      assert Coordinator.Mcp.ContextRequest.present?(payload)
    end

    test "hydra_get_job surfaces the question where the agent is already looking" do
      id = submit(%{"allow_context_requests" => true})["structuredContent"]["job_id"]
      :ok = park(id)

      result = call("hydra_get_job", %{"job_id" => id})

      assert result["structuredContent"]["status"] == "input_required"
      request = result["structuredContent"]["input_request"]
      assert request["request_id"] == "ir-1"
      assert %{"call_1" => question} = request["requests"]
      assert question["what"] == "src/foo.ex"
      assert question["prompt"] =~ "record definition"
      # The one line a model reads without parsing metadata.
      assert hd(result["content"])["text"] =~ "src/foo.ex"
    end

    test "answering resumes the same job under the same id" do
      id = submit(%{"allow_context_requests" => true})["structuredContent"]["job_id"]
      :ok = park(id)

      answered =
        call("hydra_provide_input", %{
          "job_id" => id,
          "request_id" => "ir-1",
          "responses" => %{"call_1" => "defmodule Foo do end"}
        })

      refute answered["isError"]
      assert answered["structuredContent"]["job_id"] == id
      assert answered["structuredContent"]["state"] == "queued"

      resumed = Jobs.get(id)
      assert List.last(resumed.payload["messages"])["content"] =~ "defmodule Foo"
    end

    test "answering the wrong question is refused with something actionable" do
      id = submit(%{"allow_context_requests" => true})["structuredContent"]["job_id"]
      :ok = park(id)

      result =
        call("hydra_provide_input", %{
          "job_id" => id,
          "request_id" => "ir-stale",
          "responses" => %{"call_1" => "x"}
        })

      assert result["isError"]
      assert hd(result["content"])["text"] =~ "hydra_get_job"
    end

    test "another caller cannot answer a question that was not asked of them" do
      id = submit(%{"allow_context_requests" => true})["structuredContent"]["job_id"]
      :ok = park(id)

      result =
        call(
          "hydra_provide_input",
          %{"job_id" => id, "request_id" => "ir-1", "responses" => %{"call_1" => "x"}},
          @other
        )

      assert result["isError"]
      assert Jobs.get(id).status == "awaiting_input"
    end
  end

  test "an unknown tool is a protocol error, because no tool ran" do
    assert {:error, {:unknown_tool, "hydra_do_something_else"}} =
             Tools.call("hydra_do_something_else", %{}, %{caller: @caller})
  end
end
