defmodule EctoUnnest.Test.Repo do
  @moduledoc false
  use Ecto.Repo, otp_app: :ecto_unnest, adapter: Ecto.Adapters.Postgres
end

defmodule EctoUnnest.Test.Migration do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:events) do
      add(:user_id, :integer)
      add(:type, :string)
      add(:score, :float)
      add(:tags, {:array, :string})
      add(:payload, :map)
      add(:inserted_at, :utc_datetime)
    end

    create(unique_index(:events, [:user_id]))

    create table(:with_uuid, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string)
    end

    create table(:docs) do
      add(:summary, :jsonb)
      add(:meta, :jsonb)
      add(:status, :integer)
      add(:created_at, :utc_datetime)
    end

    # A binary-source table whose physical column order differs from any sane
    # map-key order — used to prove name-ordered alignment on execution (Gap 3).
    create table(:scrambled, primary_key: false) do
      add(:m_col, :text, null: false)
      add(:id, :bigint, null: false)
      add(:a_col, :text, null: false)
      add(:z_col, :text, null: false)
      add(:ph_col, :text, null: false)
    end

    # A custom PG domain, for placeholder casts to an app-defined type.
    execute(
      "CREATE DOMAIN kafka_topic_name AS text CHECK (VALUE ~ '^[a-zA-Z0-9._-]+$')",
      "DROP DOMAIN kafka_topic_name"
    )

    create table(:topics, primary_key: false) do
      add(:id, :bigint, null: false)
      add(:topic, :kafka_topic_name, null: false)
    end
  end
end
