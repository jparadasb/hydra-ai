defmodule Coordinator.WorkerChannelTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Coordinator.Repo
  import Phoenix.ChannelTest

  @endpoint Coordinator.Endpoint

  alias Coordinator.{Jobs, LeaseWorker, WorkerChannel, WorkerRegistry, WorkerSocket}
  alias Coordinator.Jobs.JobRecord
  import Coordinator.WorkerTestHelper

  # Channels are linked to the test process; each joined worker is untracked from Presence when
  # its channel shuts down at the end of the test, so no manual cleanup is needed.

  setup do
    Coordinator.Repo.delete_all(JobRecord)
    Coordinator.Repo.delete_all(Oban.Job)
    :ok
  end

  defp registration(id) do
    %{
      "worker_id" => id,
      "execution_mode" => "external_provider",
      "provider" => %{"name" => "openai", "api_type" => "openai_compatible"},
      "models" => [
        %{
          "name" => "gpt-4.1-mini",
          "capabilities" => ["text.extract_json"],
          "uses_external_provider" => true
        }
      ],
      "privacy" => %{"accepted_job_levels" => ["public", "private"]}
    }
  end

  test "the worker socket binds the peer address so abuse can be traced to a host" do
    {:ok, socket} =
      connect(WorkerSocket, %{}, connect_info: %{peer_data: %{address: {203, 0, 113, 7}}})

    assert socket.assigns.peer_ip == "203.0.113.7"

    # Behind an ingress the TCP peer is the proxy, so the forwarded client wins.
    {:ok, proxied} =
      connect(WorkerSocket, %{},
        connect_info: %{
          peer_data: %{address: {10, 0, 0, 1}},
          x_headers: [{"x-forwarded-for", "198.51.100.4, 10.0.0.1"}]
        }
      )

    assert proxied.assigns.peer_ip == "198.51.100.4"
  end

  defp join_worker(id, payload) do
    {:ok, socket} = connect(WorkerSocket, %{})
    subscribe_and_join(socket, WorkerChannel, "worker:#{id}", payload)
  end

  test "clean worker joins, registers, and receives a leased job" do
    assert {:ok, %{registered: "w-chan"}, _socket} =
             join_worker("w-chan", registration("w-chan"))

    wait_present("w-chan")
    assert Enum.any?(WorkerRegistry.list(), &(&1.worker_id == "w-chan"))

    job = %{
      "job_id" => "j1",
      "lease_id" => "lease-j1",
      "capability" => "text.extract_json",
      "privacy" => "public",
      "allow_external_providers" => true,
      "payload" => %{"messages" => []}
    }

    WorkerChannel.lease("w-chan", job)
    assert_push("job", %{"job_id" => "j1"})
    wait_inflight("w-chan", 1)

    WorkerChannel.cancel("w-chan", "j1", "lease-j1")
    assert_push("cancel", %{"job_id" => "j1", "lease_id" => "lease-j1"})
    wait_inflight("w-chan", 0)
  end

  test "join is refused when registration carries a token; nothing is registered" do
    dirty = Map.put(registration("w-bad"), "token", "sk-should-not-be-here-123")
    assert {:error, %{reason: "secret_key_present"}} = join_worker("w-bad", dirty)
    refute Enum.any?(WorkerRegistry.list(), &(&1.worker_id == "w-bad"))
  end

  test "join is refused when topic and worker_id disagree" do
    assert {:error, %{reason: "worker_id_mismatch"}} =
             join_worker("w-topic", registration("w-different"))
  end

  test "a result carrying a secret is accepted with the secret redacted, not refused" do
    # It used to be refused, which meant the caller waited out their timeout and got a 504
    # with nothing to explain it — for a completion that may have been perfectly good.
    {:ok, _reply, socket} = join_worker("w-res", registration("w-res"))

    ref = push(socket, "result", %{"job_id" => "j1", "status" => "ok", "output" => %{}})
    assert_reply(ref, :ok)

    Phoenix.PubSub.subscribe(Coordinator.PubSub, Jobs.result_topic("j-redact"))

    ref2 =
      push(socket, "result", %{
        "job_id" => "j-redact",
        "status" => "ok",
        "authorization" => "Bearer abcdefghijklmnopqrstuvwxyz",
        "output" => %{"content" => "the answer"}
      })

    assert_reply(ref2, :ok)

    assert_receive {:job_result, result}
    assert result["authorization"] == "[REDACTED]"
    assert result["output"]["content"] == "the answer"
  end

  test "racing cancellation and result decrement inflight only once" do
    reg = Map.put(registration("w-race"), "supports_cancel_ack", true)
    {:ok, _reply, socket} = join_worker("w-race", reg)
    wait_present("w-race")

    WorkerChannel.lease("w-race", %{"job_id" => "j-race", "lease_id" => "lease-race"})
    assert_push("job", %{"job_id" => "j-race"})
    wait_inflight("w-race", 1)

    WorkerChannel.cancel("w-race", "j-race", "lease-race")
    assert_push("cancel", %{"job_id" => "j-race", "lease_id" => "lease-race"})
    wait_inflight("w-race", 1)

    stale_ref = push(socket, "cancelled", %{"job_id" => "j-race", "lease_id" => "stale"})
    assert_reply(stale_ref, :ok)
    wait_inflight("w-race", 1)

    cancel_ref =
      push(socket, "cancelled", %{"job_id" => "j-race", "lease_id" => "lease-race"})

    assert_reply(cancel_ref, :ok)
    wait_inflight("w-race", 0)

    ref = push(socket, "result", %{"job_id" => "j-race", "status" => "ok", "output" => %{}})
    assert_reply(ref, :ok)
    wait_inflight("w-race", 0)
  end

  test "re-lease tracks both generations until each one finishes" do
    reg = Map.put(registration("w-generations"), "supports_cancel_ack", true)
    {:ok, _reply, socket} = join_worker("w-generations", reg)
    wait_present("w-generations")

    WorkerChannel.lease("w-generations", %{"job_id" => "j-gen", "lease_id" => "lease-1"})
    assert_push("job", _)
    WorkerChannel.lease("w-generations", %{"job_id" => "j-gen", "lease_id" => "lease-2"})
    assert_push("job", _)
    wait_inflight("w-generations", 2)

    WorkerChannel.cancel("w-generations", "j-gen", "lease-1")
    assert_push("cancel", _)
    ack = push(socket, "cancelled", %{"job_id" => "j-gen", "lease_id" => "lease-1"})
    assert_reply(ack, :ok)
    wait_inflight("w-generations", 1)

    result =
      push(socket, "result", %{
        "job_id" => "j-gen",
        "lease_id" => "lease-2",
        "status" => "ok",
        "output" => %{}
      })

    assert_reply(result, :ok)
    wait_inflight("w-generations", 0)
  end

  test "malformed cancellation acknowledgement is rejected without closing channel" do
    {:ok, _reply, socket} = join_worker("w-malformed", registration("w-malformed"))
    ref = push(socket, "cancelled", %{})
    assert_reply(ref, :error, %{reason: "invalid_cancellation_ack"})
    assert Process.alive?(socket.channel_pid)
  end

  test "a result releases channel bookkeeping even when it carries a secret" do
    {:ok, _reply, socket} = join_worker("w-rejected", registration("w-rejected"))
    wait_present("w-rejected")
    WorkerChannel.lease("w-rejected", %{"job_id" => "j-rejected", "lease_id" => "l-rejected"})
    assert_push("job", _)
    wait_inflight("w-rejected", 1)

    ref =
      push(socket, "result", %{
        "job_id" => "j-rejected",
        "status" => "ok",
        "authorization" => "Bearer abcdefghijklmnopqrstuvwxyz"
      })

    assert_reply(ref, :ok)
    wait_inflight("w-rejected", 0)
  end

  test "closing an overlapping stale channel does not reclaim live reconnect leases" do
    {:ok, _reply, stale} = join_worker("w-overlap", registration("w-overlap"))
    {:ok, _reply, _live} = join_worker("w-overlap", registration("w-overlap"))
    wait_present("w-overlap")

    {:ok, rec} =
      Jobs.enqueue(%{
        capability: "text.extract_json",
        privacy: "public",
        allow_external_providers: true,
        payload: %{"messages" => []}
      })

    assert :ok = perform_job(LeaseWorker, %{job_id: rec.id})
    Process.unlink(stale.channel_pid)
    close(stale)
    assert Jobs.get(rec.id).status == "leased"
  end

  test "closing a worker channel requeues its in-flight jobs" do
    {:ok, _reply, socket} = join_worker("w-dies", registration("w-dies"))
    wait_present("w-dies")

    {:ok, rec} =
      Jobs.enqueue(%{
        capability: "text.extract_json",
        privacy: "public",
        allow_external_providers: true,
        payload: %{"messages" => []}
      })

    assert :ok = perform_job(LeaseWorker, %{job_id: rec.id})
    assert Jobs.get(rec.id).status == "leased"

    Process.unlink(socket.channel_pid)
    close(socket)

    reclaimed = Jobs.get(rec.id)
    assert reclaimed.status == "pending"
    assert reclaimed.worker_id == nil
    assert reclaimed.lease_id == nil
    assert_enqueued(worker: LeaseWorker, args: %{job_id: rec.id})
  end

  defp wait_inflight(worker_id, expected, tries \\ 50)
  defp wait_inflight(_worker_id, _expected, 0), do: flunk("worker inflight did not converge")

  defp wait_inflight(worker_id, expected, tries) do
    case Enum.find(WorkerRegistry.list(), &(&1.worker_id == worker_id)) do
      %{inflight: ^expected} ->
        :ok

      _ ->
        Process.sleep(10)
        wait_inflight(worker_id, expected, tries - 1)
    end
  end
end
