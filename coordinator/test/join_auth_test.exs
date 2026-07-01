defmodule Coordinator.JoinAuthTest do
  # async: false — mutates the shared :join_token application env.
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint Coordinator.Endpoint

  alias Coordinator.{JoinAuth, WorkerSocket}

  setup do
    on_exit(fn -> Application.delete_env(:coordinator, :join_token) end)
    :ok
  end

  describe "verify/1" do
    test "open when no token configured" do
      Application.delete_env(:coordinator, :join_token)
      refute JoinAuth.required?()
      assert :ok = JoinAuth.verify(%{})
      assert :ok = JoinAuth.verify(%{"token" => "anything"})
    end

    test "requires a matching token when configured" do
      Application.put_env(:coordinator, :join_token, "s3cret")
      assert JoinAuth.required?()
      assert :ok = JoinAuth.verify(%{"token" => "s3cret"})
      assert :error = JoinAuth.verify(%{"token" => "wrong"})
      assert :error = JoinAuth.verify(%{})
    end

    test "empty configured token is treated as open" do
      Application.put_env(:coordinator, :join_token, "")
      refute JoinAuth.required?()
      assert :ok = JoinAuth.verify(%{})
    end
  end

  describe "socket connect/3" do
    test "rejects a worker with no/wrong token when one is required" do
      Application.put_env(:coordinator, :join_token, "fleet-token")
      assert :error = connect(WorkerSocket, %{})
      assert :error = connect(WorkerSocket, %{"token" => "nope"})
    end

    test "accepts a worker presenting the right token" do
      Application.put_env(:coordinator, :join_token, "fleet-token")
      assert {:ok, _socket} = connect(WorkerSocket, %{"token" => "fleet-token"})
    end

    test "accepts any worker when no token is configured" do
      Application.delete_env(:coordinator, :join_token)
      assert {:ok, _socket} = connect(WorkerSocket, %{})
    end
  end
end
