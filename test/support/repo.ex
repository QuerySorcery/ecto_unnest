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
  end
end
