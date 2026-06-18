defmodule EctoUnnest.Test.Event do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "events" do
    field(:user_id, :integer)
    field(:type, :string)
    field(:score, :float)
    field(:tags, {:array, :string})
    field(:payload, :map)
    field(:inserted_at, :utc_datetime)
  end
end

defmodule EctoUnnest.Test.WithUuid do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "with_uuid" do
    field(:name, :string)
  end
end

defmodule EctoUnnest.Test.WithUuidV7 do
  @moduledoc false
  use Ecto.Schema

  # UUIDv7 is a custom Ecto.Type whose `type/0` is `:uuid`, so it stores in the
  # same `with_uuid` table. EctoUnnest infers `::uuid[]` and dumps through it.
  @primary_key {:id, UUIDv7, autogenerate: true}
  schema "with_uuid" do
    field(:name, :string)
  end
end
