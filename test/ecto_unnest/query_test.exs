defmodule EctoUnnest.QueryTest do
  use ExUnit.Case, async: true

  alias EctoUnnest.Test.Event
  alias EctoUnnest.Test.WithUuid

  describe "to_sql/3 — constant text, independent of N" do
    test "same SQL for 1 and for many rows" do
      {sql1, _} = EctoUnnest.to_sql(Event, %{user_id: [1], type: ["a"]})
      {sqlN, _} = EctoUnnest.to_sql(Event, %{user_id: [1, 2, 3], type: ["a", "b", "c"]})

      assert sql1 == sqlN
    end

    test "builds INSERT ... SELECT ... FROM unnest with casts and the u(...) alias" do
      {sql, params} = EctoUnnest.to_sql(Event, %{user_id: [1, 2], type: ["a", "b"]})

      assert sql ==
               ~s|INSERT INTO "events" ("type","user_id") | <>
                 ~s|(SELECT f0."type", f0."user_id" | <>
                 ~s|FROM (SELECT * FROM unnest($1::text[], $2::bigint[]) AS u("type", "user_id")) AS f0)|

      assert params == [["a", "b"], [1, 2]]
    end
  end

  describe "placeholders" do
    test "a scalar goes in as $n with a cast and is broadcast" do
      now = ~U[2026-06-17 10:00:00Z]

      {sql, params} =
        EctoUnnest.to_sql(Event, %{user_id: [1, 2], type: ["a", "b"]}, placeholders: %{inserted_at: now})

      assert sql =~ ~s|SELECT f0."type", f0."user_id", $1::timestamp|
      assert sql =~ ~s|FROM (SELECT * FROM unnest($2::text[], $3::bigint[])|
      assert params == [now, ["a", "b"], [1, 2]]
    end

    test "a list in placeholders lands in an array column (no unnest)" do
      {sql, params} =
        EctoUnnest.to_sql(Event, %{user_id: [1, 2]}, placeholders: %{tags: ["x", "y"]})

      # tags goes in as a scalar $1::varchar[] — one array value for all rows
      assert sql =~ ~s|$1::varchar[]|
      assert sql =~ ~s|FROM (SELECT * FROM unnest($2::bigint[])|
      assert params == [["x", "y"], [1, 2]]
    end

    test "a per-row array (in the columns map) is rejected" do
      assert_raise ArgumentError, ~r/array-typed and varies per row/, fn ->
        EctoUnnest.to_sql(Event, %{tags: [["a"], ["b"]]})
      end
    end
  end

  describe "validation" do
    test "a scalar value in the columns map -> error" do
      assert_raise ArgumentError, ~r/move it to :placeholders/, fn ->
        EctoUnnest.to_sql(Event, %{user_id: 1})
      end
    end

    test "the same key in columns and placeholders -> error" do
      assert_raise ArgumentError, ~r/in both the columns map/, fn ->
        EctoUnnest.to_sql(Event, %{user_id: [1]}, placeholders: %{user_id: 9})
      end
    end

    test "different list lengths -> error" do
      assert_raise ArgumentError, ~r/different lengths/, fn ->
        EctoUnnest.to_sql(Event, %{user_id: [1, 2], type: ["a"]})
      end
    end

    test "placeholders only -> a single row from a synthetic source, no unnest" do
      {sql, params} =
        EctoUnnest.to_sql(Event, %{}, placeholders: %{user_id: 1, type: "a"})

      refute sql =~ "unnest"
      assert sql =~ ~s|SELECT $1::varchar, $2::bigint FROM (SELECT 1) AS f0|
      assert params == ["a", 1]
    end
  end

  describe "returning / on_conflict" do
    test "returning: true expands to all fields" do
      {sql, _} = EctoUnnest.to_sql(Event, %{user_id: [1]}, returning: true)
      assert sql =~ ~s| RETURNING "inserted_at","payload","tags","score","type","user_id","id"|
    end

    test "on_conflict :nothing with conflict_target" do
      {sql, _} =
        EctoUnnest.to_sql(Event, %{user_id: [1]},
          on_conflict: :nothing,
          conflict_target: [:user_id]
        )

      assert sql =~ ~s|ON CONFLICT ("user_id") DO NOTHING|
    end

    test "on_conflict {:replace, fields}" do
      {sql, _} =
        EctoUnnest.to_sql(Event, %{user_id: [1], type: ["a"]},
          on_conflict: {:replace, [:type]},
          conflict_target: [:user_id]
        )

      assert sql =~ ~s|ON CONFLICT ("user_id") DO UPDATE SET "type" = EXCLUDED."type"|
    end

    test "on_conflict keyword [set:, inc:] appends params after arrays/scalars" do
      {sql, params} =
        EctoUnnest.to_sql(Event, %{user_id: [1], type: ["a"]},
          on_conflict: [set: [type: "x"], inc: [score: 1.0]],
          conflict_target: [:user_id]
        )

      # type ($1), user_id ($2) as arrays; set/inc appends $3, $4
      assert sql =~
               ~s|ON CONFLICT ("user_id") DO UPDATE SET "type" = $3, "score" = e0."score" + $4|

      assert params == [["a"], [1], "x", 1.0]
    end

    test "on_conflict keyword without :set/:inc -> error" do
      assert_raise ArgumentError, ~r/requires :set/, fn ->
        EctoUnnest.to_sql(Event, %{user_id: [1]}, on_conflict: [])
      end
    end
  end

  describe "types" do
    test "uuid schema -> name goes in as text[]" do
      {sql, _} = EctoUnnest.to_sql(WithUuid, %{name: ["a"]})
      assert sql =~ ~s|$1::text[]|
    end

    test "override via :types" do
      {sql, _} = EctoUnnest.to_sql(Event, %{user_id: [1]}, types: %{user_id: "int4"})
      assert sql =~ ~s|$1::int4[]|
    end
  end
end
