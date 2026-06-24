defmodule EctoUnnest.AllowedTypesTest do
  # async: false — mutates the global `:ecto_unnest, :allowed_types` app env.
  use ExUnit.Case, async: false

  setup do
    original = Application.get_env(:ecto_unnest, :allowed_types)

    on_exit(fn ->
      if original,
        do: Application.put_env(:ecto_unnest, :allowed_types, original),
        else: Application.delete_env(:ecto_unnest, :allowed_types)
    end)
  end

  test "default Ecto types are allowed even with no allow-list configured" do
    Application.delete_env(:ecto_unnest, :allowed_types)

    {sql, _} = EctoUnnest.to_sql("t", %{id: [1]}, types: %{id: :timestamptz})
    assert sql =~ ~s|$1::timestamptz[]|
  end

  test "a non-default type requires the allow-list" do
    Application.delete_env(:ecto_unnest, :allowed_types)

    assert_raise ArgumentError, ~r/is not allowed/, fn ->
      EctoUnnest.to_sql("t", %{id: [1]}, types: %{id: :kafka_topic_name})
    end
  end

  test "a configured custom type is permitted (atoms or strings)" do
    Application.put_env(:ecto_unnest, :allowed_types, [:kafka_topic_name])

    {sql, _} =
      EctoUnnest.to_sql("topics", %{id: [1]},
        types: %{id: :bigint, topic: :kafka_topic_name},
        placeholders: %{topic: "my.topic"}
      )

    assert sql =~ ~s|$1::kafka_topic_name|
    assert sql =~ ~s|$2::bigint[]|
  end

  test "a custom type still outside the configured list is rejected" do
    Application.put_env(:ecto_unnest, :allowed_types, [:kafka_topic_name])

    assert_raise ArgumentError, ~r/is not allowed/, fn ->
      EctoUnnest.to_sql("t", %{id: [1]}, types: %{id: :geometry})
    end
  end

  test "the allow-list can permit exotic spellings (e.g. a quoted identifier)" do
    Application.put_env(:ecto_unnest, :allowed_types, [~s|"My Type"|])

    {sql, _} =
      EctoUnnest.to_sql("t", %{id: [1]}, types: %{id: :bigint, c: ~s|"My Type"|}, placeholders: %{c: "x"})

    assert sql =~ ~s|$1::"My Type"|
  end
end
