defmodule Coordinator.Repo.Migrations.AdminControlledTrust do
  use Ecto.Migration

  def change do
    # Trust was taken from the worker's own registration payload and was worth a -20 routing
    # bonus, so a worker could declare itself trusted and win essentially every routing
    # decision. It moves here, next to the privacy grant: admin-controlled, default untrusted.
    alter table(:worker_keys) do
      add :trust_level, :string, null: false, default: "untrusted"
    end
  end
end
