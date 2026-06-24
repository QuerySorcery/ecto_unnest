defmodule EctoUnnest.QueryTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias EctoUnnest.Test.Doc
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

    test "override via :types (string)" do
      {sql, _} = EctoUnnest.to_sql(Event, %{user_id: [1]}, types: %{user_id: "int4"})
      assert sql =~ ~s|$1::int4[]|
    end

    test "override via :types (atom — app-controlled)" do
      {sql, _} = EctoUnnest.to_sql(Event, %{user_id: [1]}, types: %{user_id: :int4})
      assert sql =~ ~s|$1::int4[]|
    end

    test "a default Ecto type is allowed with no extra config" do
      {sql, _} = EctoUnnest.to_sql("t", %{c: [1]}, types: %{c: :bigint})
      assert sql =~ ~s|$1::bigint[]|
    end

    test ":types not allowed (not default, not configured) raises" do
      for bad <- ["int4); DROP TABLE t; --", "geometry", "citext"] do
        assert_raise ArgumentError, ~r/is not allowed/, fn ->
          EctoUnnest.to_sql("t", %{id: [1]}, types: %{id: bad})
        end
      end
    end
  end

  describe "Gap 1 — per-row JSON columns" do
    test "schema {:array, :map} ships as text[] and projects ::jsonb" do
      {sql, params} = EctoUnnest.to_sql(Doc, %{id: [1, 2], summary: [[%{"a" => 1}], [%{"b" => 2}]]})

      assert sql ==
               ~s|INSERT INTO "docs" ("id","summary") | <>
                 ~s|(SELECT f0."id", f0."summary"::jsonb | <>
                 ~s|FROM (SELECT * FROM unnest($1::bigint[], $2::text[]) AS u("id", "summary")) AS f0)|

      # summary went in pre-encoded as a 1-D text[] (no multi-dimensional array)
      assert params == [[1, 2], [~s|[{"a":1}]|, ~s|[{"b":2}]|]]
    end

    test "schema plain :map per-row column also routes through JSON mode" do
      {sql, params} = EctoUnnest.to_sql(Doc, %{id: [1], meta: [%{"k" => "v"}]})
      assert sql =~ ~s|f0."meta"::jsonb|
      assert sql =~ ~s|unnest($1::bigint[], $2::text[])|
      assert params == [[1], [~s|{"k":"v"}|]]
    end

    test "binary source with types: jsonb ships text[] + ::jsonb projection" do
      {sql, params} =
        EctoUnnest.to_sql("docs", %{id: [1], summary: [[%{"a" => 1}]]}, types: %{id: :bigint, summary: :jsonb})

      assert sql =~ ~s|f0."summary"::jsonb|
      assert sql =~ ~s|unnest($1::bigint[], $2::text[])|
      assert params == [[1], [~s|[{"a":1}]|]]
    end

    test "explicit json: option opts a column into JSON mode" do
      {sql, params} =
        EctoUnnest.to_sql("docs", %{id: [1], summary: [%{"x" => 9}]},
          types: %{id: :bigint, summary: :text},
          json: [:summary]
        )

      assert sql =~ ~s|f0."summary"::jsonb|
      assert params == [[1], [~s|{"x":9}|]]
    end

    test "pre-encoded JSON strings are passed through untouched" do
      {_sql, params} =
        EctoUnnest.to_sql("docs", %{id: [1], summary: [~s|[{"a":1}]|]}, types: %{id: :bigint, summary: :jsonb})

      assert params == [[1], [~s|[{"a":1}]|]]
    end
  end

  describe "Gap 2 — placeholder types" do
    test "integer-backed Ecto.Enum placeholder works with no :types (schema source)" do
      {sql, params} = EctoUnnest.to_sql(Doc, %{id: [1]}, placeholders: %{status: :published})

      assert sql =~ ~s|SELECT f0."id", $1::bigint|
      # :published dumps to its integer mapping (1) via the Ecto.Enum type
      assert params == [1, [1]]
    end

    test "binary-source non-string placeholder casts via :types" do
      now = ~U[2026-06-17 10:00:00Z]

      {sql, params} =
        EctoUnnest.to_sql("docs", %{id: [1]},
          types: %{id: :bigint, created_at: :timestamptz},
          placeholders: %{created_at: now}
        )

      assert sql =~ ~s|SELECT f0."id", $1::timestamptz|
      assert params == [now, [1]]
    end

    test "custom PG type placeholder cast (atom :types) renders raw" do
      {sql, _} =
        EctoUnnest.to_sql("topics", %{id: [1]},
          types: %{id: :bigint, topic: :kafka_topic_name},
          placeholders: %{topic: "my.topic"}
        )

      assert sql =~ ~s|SELECT f0."id", $1::kafka_topic_name|
    end
  end

  describe "Gap 4 — ON CONFLICT DO UPDATE ... WHERE" do
    test "a full Ecto query threads its WHERE into the DO UPDATE" do
      upd = from(e in Event, update: [set: [type: "revived"]], where: not is_nil(e.type))

      {sql, _} =
        EctoUnnest.to_sql(Event, %{user_id: [1], type: ["x"]},
          on_conflict: upd,
          conflict_target: [:user_id]
        )

      assert sql =~ ~s|ON CONFLICT ("user_id") DO UPDATE SET "type" = 'revived' WHERE (NOT (e0."type" IS NULL))|
    end
  end
end
