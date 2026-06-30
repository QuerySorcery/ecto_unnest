defmodule EctoUnnest.CacheStatementTest do
  use ExUnit.Case, async: true

  alias EctoUnnest.Test.Event

  # A stub repo that just captures the opts EctoUnnest.insert_all/4 forwards, so we
  # can assert the :cache_statement without a database connection.
  defmodule CaptureRepo do
    def insert_all(_schema, _query, opts) do
      send(self(), {:insert_all_opts, opts})
      {0, nil}
    end
  end

  defp cache_statement(columns, opts \\ []) do
    EctoUnnest.insert_all(CaptureRepo, Event, columns, opts)
    assert_received {:insert_all_opts, opts}
    Keyword.fetch!(opts, :cache_statement)
  end

  test "default name appends the unnest arity (the number of array columns)" do
    assert cache_statement(%{user_id: [1], type: ["a"]}) == "ecto_unnest_all_events_2"

    assert cache_statement(%{user_id: [1], type: ["a"], score: [1.0]}) ==
             "ecto_unnest_all_events_3"
  end

  test "arity counts only array columns, not placeholders" do
    name =
      cache_statement(%{user_id: [1]},
        placeholders: %{type: "a", inserted_at: ~U[2026-06-17 10:00:00Z]}
      )

    assert name == "ecto_unnest_all_events_1"
  end

  test "row count does not change the name (SQL is constant across it)" do
    one = cache_statement(%{user_id: [1], type: ["a"]})
    many = cache_statement(%{user_id: [1, 2, 3], type: ["a", "b", "c"]})
    assert one == many
  end

  test "an explicit :cache_statement is used verbatim" do
    assert cache_statement(%{user_id: [1], type: ["a"]}, cache_statement: "my_custom_name") ==
             "my_custom_name"
  end

  test "cache_statement: nil falls back to Ecto's default" do
    assert cache_statement(%{user_id: [1], type: ["a"]}, cache_statement: nil) == nil
  end
end
