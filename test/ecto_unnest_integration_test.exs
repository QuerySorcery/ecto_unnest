defmodule EctoUnnest.IntegrationTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias EctoUnnest.Test.Doc
  alias EctoUnnest.Test.Event
  alias EctoUnnest.Test.Repo

  @moduletag :integration

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  describe "insert_all via unnest on a live database" do
    test "inserts many rows and loads RETURNING into structs" do
      now = ~U[2026-06-17 10:00:00Z]

      {n, rows} =
        EctoUnnest.insert_all(
          Repo,
          Event,
          %{user_id: [1, 2, 3], type: ["click", "view", "click"]},
          placeholders: %{inserted_at: now, score: 1.5},
          returning: true
        )

      assert n == 3
      assert length(rows) == 3
      assert Enum.all?(rows, &match?(%Event{}, &1))
      assert rows |> Enum.map(& &1.user_id) |> Enum.sort() == [1, 2, 3]
      assert Enum.all?(rows, &(&1.score == 1.5))
      assert Enum.all?(rows, &(&1.inserted_at == now))
      assert Enum.all?(rows, &is_integer(&1.id))
    end

    test "Postgrex encodes arrays correctly under ::bigint[]/::text[] casts" do
      {3, _} =
        EctoUnnest.insert_all(Repo, Event, %{
          user_id: [10, 20, 30],
          type: ["a", "b", "c"]
        })

      assert Repo.aggregate(Event, :count) == 3

      loaded =
        Event
        |> Repo.all()
        |> Enum.sort_by(& &1.user_id)

      assert Enum.map(loaded, & &1.user_id) == [10, 20, 30]
      assert Enum.map(loaded, & &1.type) == ["a", "b", "c"]
    end

    test "a list in :placeholders lands in an array column (broadcast, no unnest)" do
      {2, [a, b]} =
        EctoUnnest.insert_all(
          Repo,
          Event,
          %{user_id: [1, 2]},
          placeholders: %{tags: ["x", "y"], payload: %{"k" => "v"}},
          returning: [:user_id, :tags, :payload]
        )

      assert a.tags == ["x", "y"]
      assert b.tags == ["x", "y"]
      assert a.payload == %{"k" => "v"}
    end

    test "placeholders only -> a single row (N=1, no FROM)" do
      {1, [row]} =
        EctoUnnest.insert_all(Repo, Event, %{},
          placeholders: %{user_id: 99, type: "solo"},
          returning: true
        )

      assert row.user_id == 99
      assert row.type == "solo"
    end
  end

  describe "on_conflict" do
    test ":nothing skips the conflict (unique on user_id)" do
      {1, _} = EctoUnnest.insert_all(Repo, Event, %{user_id: [1], type: ["first"]})

      {n, _} =
        EctoUnnest.insert_all(
          Repo,
          Event,
          %{user_id: [1, 2], type: ["duplicate", "new"]},
          on_conflict: :nothing,
          conflict_target: [:user_id]
        )

      assert n == 1
      assert Repo.aggregate(Event, :count) == 2
    end

    test "{:replace, [:type]} updates the existing row" do
      {1, _} = EctoUnnest.insert_all(Repo, Event, %{user_id: [1], type: ["old"]})

      {_, _} =
        EctoUnnest.insert_all(
          Repo,
          Event,
          %{user_id: [1], type: ["new"]},
          on_conflict: {:replace, [:type]},
          conflict_target: [:user_id]
        )

      assert Repo.aggregate(Event, :count) == 1
      assert Repo.get_by(Event, user_id: 1).type == "new"
    end

    test "keyword [set:, inc:] sets and increments" do
      {1, _} =
        EctoUnnest.insert_all(Repo, Event, %{user_id: [1], type: ["old"]}, placeholders: %{score: 10.0})

      {_, _} =
        EctoUnnest.insert_all(
          Repo,
          Event,
          %{user_id: [1], type: ["ignored"]},
          on_conflict: [set: [type: "new"], inc: [score: 5.0]],
          conflict_target: [:user_id]
        )

      row = Repo.get_by(Event, user_id: 1)
      assert row.type == "new"
      assert row.score == 15.0
    end
  end

  describe "table/3 — unnest as a virtual table" do
    test "SELECT/where/order_by reads from the virtual table" do
      q = EctoUnnest.table(Event, %{user_id: [1, 2, 3], type: ["a", "b", "c"]})

      rows = Repo.all(from([s: s] in q, where: s.user_id > 1, order_by: s.user_id, select: {s.user_id, s.type}))

      assert rows == [{2, "b"}, {3, "c"}]
    end

    test "bulk UPDATE by joining a subquery of the virtual table" do
      {2, _} = EctoUnnest.insert_all(Repo, Event, %{user_id: [1, 2], type: ["old", "old"]})

      q = EctoUnnest.table(Event, %{user_id: [1, 2], type: ["x", "y"]})
      src = from([s: s] in q, select: %{user_id: s.user_id, type: s.type})

      {n, _} =
        Repo.update_all(
          from(e in Event, join: s in subquery(src), on: e.user_id == s.user_id, update: [set: [type: s.type]]),
          []
        )

      assert n == 2
      assert Repo.get_by(Event, user_id: 1).type == "x"
      assert Repo.get_by(Event, user_id: 2).type == "y"
    end
  end

  describe "UUIDv7 primary keys (bulk)" do
    alias EctoUnnest.Test.WithUuidV7

    test "ids from UUIDv7.generate_many/1 are inferred as ::uuid[] and dumped" do
      ids = UUIDv7.generate_many(3)

      {sql, _} = EctoUnnest.to_sql(WithUuidV7, %{id: ids, name: ["a", "b", "c"]})
      assert sql =~ ~s|unnest($1::uuid[], $2::text[])|

      # insert_all does not autogenerate keys, so we supply the id list ourselves.
      {3, rows} =
        EctoUnnest.insert_all(Repo, WithUuidV7, %{id: ids, name: ["a", "b", "c"]}, returning: [:id, :name])

      assert Enum.sort(Enum.map(rows, & &1.id)) == Enum.sort(ids)
    end
  end

  describe "Gap 1 — per-row JSON columns (execution)" do
    test "schema {:array, :map} round-trips; id and other columns stay aligned" do
      ts = ~U[2026-06-17 10:00:00Z]

      {2, [a, b]} =
        EctoUnnest.insert_all(
          Repo,
          Doc,
          %{id: [101, 102], summary: [[%{"a" => 1}], [%{"b" => 2}, %{"c" => 3}]]},
          placeholders: %{created_at: ts},
          returning: [:id, :summary, :created_at]
        )

      [a, b] = Enum.sort_by([a, b], & &1.id)
      assert a.id == 101
      assert a.summary == [%{"a" => 1}]
      assert a.created_at == ts
      assert b.id == 102
      assert b.summary == [%{"b" => 2}, %{"c" => 3}]
    end

    test "binary source with types: jsonb stores a list-valued jsonb, id not nulled" do
      EctoUnnest.insert_all(
        Repo,
        "docs",
        %{id: [201, 202], summary: [[%{"x" => 1}], [%{"y" => 2}]]},
        types: %{id: :bigint, summary: :jsonb}
      )

      rows =
        Doc
        |> Repo.all()
        |> Enum.filter(&(&1.id in [201, 202]))
        |> Enum.sort_by(& &1.id)

      assert Enum.map(rows, & &1.id) == [201, 202]
      assert Enum.map(rows, & &1.summary) == [[%{"x" => 1}], [%{"y" => 2}]]
    end

    test "plain :map per-row column round-trips" do
      {1, [doc]} =
        EctoUnnest.insert_all(Repo, Doc, %{id: [301], meta: [%{"k" => "v"}]}, returning: [:id, :meta])

      assert doc.meta == %{"k" => "v"}
    end
  end

  describe "Gap 2 — placeholder types (execution)" do
    test "integer-backed Ecto.Enum placeholder inserts its mapped value (no :types)" do
      {1, [doc]} =
        EctoUnnest.insert_all(Repo, Doc, %{id: [401]},
          placeholders: %{status: :published},
          returning: [:id, :status]
        )

      assert doc.status == :published
      assert Repo.query!("SELECT status FROM docs WHERE id = 401").rows == [[1]]
    end

    test "binary-source datetime placeholder casts via :types" do
      ts = ~U[2026-06-17 10:00:00Z]

      EctoUnnest.insert_all(Repo, "docs", %{id: [501]},
        types: %{id: :bigint, created_at: :timestamptz},
        placeholders: %{created_at: ts}
      )

      assert Repo.get(Doc, 501).created_at == ts
    end

    test "custom PG domain placeholder cast (kafka_topic_name)" do
      EctoUnnest.insert_all(Repo, "topics", %{id: [1, 2]},
        types: %{id: :bigint, topic: :kafka_topic_name},
        placeholders: %{topic: "orders.created"}
      )

      assert Repo.query!("SELECT id, topic FROM topics ORDER BY id").rows ==
               [[1, "orders.created"], [2, "orders.created"]]
    end
  end

  describe "Gap 3 — binary-source column alignment (execution)" do
    test "values land in their named column even when map order ≠ physical order" do
      # physical order: m_col, id, a_col, z_col, ph_col
      EctoUnnest.insert_all(
        Repo,
        "scrambled",
        %{m_col: ["m1", "m2"], id: [1, 2], a_col: ["a1", "a2"], z_col: ["z1", "z2"]},
        types: %{m_col: :text, id: :bigint, a_col: :text, z_col: :text, ph_col: :text},
        placeholders: %{ph_col: "PH"}
      )

      rows = Repo.query!("SELECT m_col, id, a_col, z_col, ph_col FROM scrambled ORDER BY id").rows

      assert rows == [
               ["m1", 1, "a1", "z1", "PH"],
               ["m2", 2, "a2", "z2", "PH"]
             ]
    end
  end

  describe "Gap 4 — ON CONFLICT DO UPDATE ... WHERE (execution)" do
    test "a conditional upsert updates only rows matching the predicate" do
      {1, _} = EctoUnnest.insert_all(Repo, Event, %{user_id: [1], type: ["orig"]})

      # predicate matches -> update applies
      matching = from(e in Event, update: [set: [type: "revived"]], where: e.type == "orig")

      {_, _} =
        EctoUnnest.insert_all(Repo, Event, %{user_id: [1], type: ["x"]},
          on_conflict: matching,
          conflict_target: [:user_id]
        )

      assert Repo.get_by(Event, user_id: 1).type == "revived"

      # predicate does not match -> row left as-is
      non_matching = from(e in Event, update: [set: [type: "nope"]], where: e.type == "absent")

      {_, _} =
        EctoUnnest.insert_all(Repo, Event, %{user_id: [1], type: ["x"]},
          on_conflict: non_matching,
          conflict_target: [:user_id]
        )

      assert Repo.get_by(Event, user_id: 1).type == "revived"
    end
  end

  describe "statement stability" do
    test "the same prepared statement for different N" do
      # Force a prepared statement and assert the text is identical for 1 and 50 rows.
      {sql1, _} = EctoUnnest.to_sql(Event, %{user_id: [1], type: ["a"]})

      {sql50, _} =
        EctoUnnest.to_sql(Event, %{user_id: Enum.to_list(1..50), type: List.duplicate("a", 50)})

      assert sql1 == sql50

      # And that both actually run through the same statement text.
      assert {1, nil} = EctoUnnest.insert_all(Repo, Event, %{user_id: [1], type: ["a"]})

      assert {50, nil} =
               EctoUnnest.insert_all(Repo, Event, %{
                 user_id: Enum.to_list(100..149),
                 type: List.duplicate("a", 50)
               })
    end

    test "distinct unnest shapes get distinct prepared-statement names" do
      now = ~U[2026-06-17 10:00:00Z]

      # Arity 2 and arity 3 into the same table: different SQL, so they must not
      # share a prepared-statement cache slot (Ecto's table-only default would).
      EctoUnnest.insert_all(Repo, Event, %{user_id: [1], type: ["a"]}, placeholders: %{inserted_at: now})

      EctoUnnest.insert_all(Repo, Event, %{user_id: [2], type: ["b"], score: [9.9]}, placeholders: %{inserted_at: now})

      names =
        Repo.query!("SELECT name FROM pg_prepared_statements WHERE name LIKE 'ecto_unnest_all_events_%'").rows
        |> List.flatten()
        |> Enum.sort()

      assert names == ["ecto_unnest_all_events_2", "ecto_unnest_all_events_3"]
    end

    test "an explicit :cache_statement overrides the default name" do
      EctoUnnest.insert_all(Repo, Event, %{user_id: [1], type: ["a"]},
        placeholders: %{inserted_at: ~U[2026-06-17 10:00:00Z]},
        cache_statement: "my_custom_stmt"
      )

      %{rows: rows} =
        Repo.query!("SELECT 1 FROM pg_prepared_statements WHERE name = 'my_custom_stmt'")

      assert rows == [[1]]
    end
  end
end
