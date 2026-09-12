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
      "capability" => "text.extract_json",
      "privacy" => "public",
      "allow_external_providers" => true,
      "payload" => %{"messages" => []}
    }

    WorkerChannel.lease("w-chan", job)
    assert_push("job", %{"job_id" => "j1"})

    WorkerChannel.cancel("w-chan", "j1")
    assert_push("cancel", %{"job_id" => "j1"})
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

  test "result message is accepted only when secret-free" do
    {:ok, _reply, socket} = join_worker("w-res", registration("w-res"))

    ref = push(socket, "result", %{"job_id" => "j1", "status" => "ok", "output" => %{}})
    assert_reply(ref, :ok)

    ref2 = push(socket, "result", %{"job_id" => "j1", "authorization" => "Bearer abcdefgh"})
    assert_reply(ref2, :error, %{reason: "secret_key_present"})
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
end
