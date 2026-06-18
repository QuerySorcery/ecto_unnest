defmodule EctoUnnest.IntegrationTest do
  use ExUnit.Case, async: false

  import Ecto.Query

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
  end
end
