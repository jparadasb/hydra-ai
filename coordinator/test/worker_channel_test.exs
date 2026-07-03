defmodule Coordinator.WorkerChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint Coordinator.Endpoint

  alias Coordinator.{WorkerChannel, WorkerRegistry, WorkerSocket}
  import Coordinator.WorkerTestHelper

  # Channels are linked to the test process; each joined worker is untracked from Presence when
  # its channel shuts down at the end of the test, so no manual cleanup is needed.

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
end
