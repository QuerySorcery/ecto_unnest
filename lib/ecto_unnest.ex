defmodule EctoUnnest do
  @moduledoc """
  Bulk insert for Ecto via `unnest(...)`.

  A plain `Ecto.Repo.insert_all/3` builds `VALUES ($1,$2),($3,$4),...`, so the SQL
  text grows with the number of rows — every batch size is a different prepared
  statement. PgBouncer (transaction mode) dislikes that, and Postgres caps
  parameters at ~65535.

  This library generates **constant SQL text, independent of the row count**:

      INSERT INTO "events" ("type","user_id")
      (SELECT f0."type", f0."user_id"
       FROM (SELECT * FROM unnest($1::text[], $2::bigint[]) AS u("type","user_id")) AS f0)

  Whether you insert 1 or 10,000 rows, the statement is identical. The query is
  assembled from Ecto building blocks (`fragment`/`dynamic`) and handed to
  `Ecto.Repo.insert_all/3`, which renders `ON CONFLICT`/`RETURNING`/`prefix` and
  loads structs natively.

  ## API

  Two disjoint maps:

    * a columns map `%{col => list}` — each column goes into `unnest` as an array,
    * `:placeholders` `%{col => value}` — constants broadcast onto every row.

  ```elixir
  EctoUnnest.insert_all(Repo, Event,
    %{user_id: [1, 2, 3], type: ["click", "view", "click"]},
    placeholders: %{inserted_at: ~U[2026-06-17 10:00:00Z]},
    returning: true
  )
  ```

  ## Options (same as `Ecto.Repo.insert_all/3`)

    * `:placeholders` — `%{col => value}` of constant columns (default `%{}`)
    * `:returning` — `true | false | [field]` (default `false`)
    * `:prefix` — schema prefix (overrides `@schema_prefix`)
    * `:on_conflict` — `:raise | :nothing | :replace_all | {:replace, fields} | {:replace_all_except, fields} | [set: kw, inc: kw]`
    * `:conflict_target` — `[col] | {:unsafe_fragment, binary}`
    * `:types` — `%{col => "pg_type"}` override for type inference

  ## Reading: virtual table

  `table/3` exposes the same `unnest(...)` source as a composable `%Ecto.Query{}`,
  so you can `SELECT` from it or join it into an `UPDATE`. See `table/3`.

  ## Limitations

    * array-typed columns (`{:array, _}`) that vary per row are unsupported
      (`unnest` flattens multi-dimensional arrays) — we raise a clear error,
    * binary sources (`"table"`) require `:types`, and `:returning` as a field list
      (no `__schema__`).
  """

  alias EctoUnnest.Query

  @type source :: module() | binary()
  @type columns :: %{atom() => list()}

  @spec insert_all(Ecto.Repo.t(), source(), columns(), keyword()) ::
          {non_neg_integer(), [struct()] | nil}
  def insert_all(repo, schema, columns, opts \\ []) when is_map(columns) and is_list(opts) do
    placeholders = Map.new(opts[:placeholders] || %{})
    plan = build_plan!(schema, columns, placeholders, opts)

    repo.insert_all(schema, Query.build(plan),
      on_conflict: plan.on_conflict,
      conflict_target: conflict_target_opt(plan.conflict_target),
      returning: returning_opt(plan.returning),
      prefix: plan.prefix
    )
  end

  @doc """
  Returns `{sql, params}` without executing the query.

  Useful for debugging and for tests with no database connection — the whole plan
  build (type inference) is pure, and the text itself is rendered by the Postgres
  adapter's `Connection` module (the same building blocks `Repo.insert_all/3` uses).
  """
  @spec to_sql(source(), columns(), keyword()) :: {String.t(), [term()]}
  def to_sql(schema, columns, opts \\ []) when is_map(columns) and is_list(opts) do
    placeholders = Map.new(opts[:placeholders] || %{})
    plan = build_plan!(schema, columns, placeholders, opts)
    Query.to_sql(plan)
  end

  @doc """
  A virtual table built from `unnest(...)` as a composable `%Ecto.Query{}`.

  Each column `%{col => list}` becomes an `unnest` column. The result can be used
  like any Ecto source — `where`, `order_by`, `select`, `Repo.all/2`, and through
  `subquery/1` also in a `join` for `update_all`/`delete_all`.

  Types come from the schema (like `insert_all/4`) or from `:types` for sources
  without a schema. The binding is named `:s` by default (`:as` option).

      q = EctoUnnest.table(Event, %{user_id: [1, 2, 3], type: ["a", "b", "c"]})

      from([s: s] in q, where: s.user_id > 1, select: {s.user_id, s.type})
      |> Repo.all()

  For a join, wrap it in `subquery/1` (which carries the parameters) and give it a
  `select`:

      src = from([s: s] in q, select: %{user_id: s.user_id, type: s.type})

      from(e in Event, join: s in subquery(src), on: e.user_id == s.user_id,
        update: [set: [type: s.type]])
      |> Repo.update_all([])
  """
  @spec table(source(), columns(), keyword()) :: Ecto.Query.t()
  def table(schema, columns, opts \\ []) when is_map(columns) and is_list(opts) do
    validate_lists!(columns)
    _ = row_count!(columns)
    arrays = classify_columns!(schema, columns, %{}, opts)
    Query.virtual(arrays, opts[:as] || :s)
  end

  # `Repo.insert_all/3` wants a field list in :returning (or no key at all).
  defp returning_opt([]), do: false
  defp returning_opt(fields), do: fields

  # Empty conflict target -> don't pass it (Ecto requires a non-empty one).
  defp conflict_target_opt([]), do: []
  defp conflict_target_opt(target), do: target

  # ── Plan: all validation and classification in one place ──────────────

  defp build_plan!(schema, columns, placeholders, opts) do
    validate_disjoint!(columns, placeholders)
    validate_lists!(columns)

    n = row_count!(columns)
    cols = classify_columns!(schema, columns, placeholders, opts)

    %{
      schema: schema,
      table: table_name(schema),
      prefix: opts[:prefix] || schema_prefix(schema),
      columns: cols,
      n: n,
      values: columns,
      placeholders: placeholders,
      returning: normalize_returning(opts[:returning] || false, schema),
      on_conflict: opts[:on_conflict] || :raise,
      conflict_target: opts[:conflict_target] || []
    }
  end

  defp validate_disjoint!(columns, placeholders) do
    (%MapSet{} = ms) = MapSet.intersection(MapSet.new(Map.keys(columns)), MapSet.new(Map.keys(placeholders)))

    if MapSet.size(ms) > 0 do
      raise ArgumentError,
            "columns #{inspect(MapSet.to_list(ms))} are in both the columns map and :placeholders"
    end
  end

  defp validate_lists!(columns) do
    for {name, value} <- columns, not is_list(value) do
      raise ArgumentError,
            "column #{inspect(name)} has a scalar value — move it to :placeholders " <>
              "or wrap it in a list"
    end

    :ok
  end

  # N = length of the column lists; all lists must be equal.
  # Empty columns map -> N = 1 (insert a single row of placeholders only).
  defp row_count!(columns) do
    case columns |> Map.values() |> Enum.map(&length/1) |> Enum.uniq() do
      [] -> 1
      [n] -> n
      lens -> raise ArgumentError, "column lists have different lengths: #{inspect(lens)}"
    end
  end

  # Deterministic column order (sorted by name) -> stable SQL.
  defp classify_columns!(schema, columns, placeholders, opts) do
    overrides = Map.new(opts[:types] || %{})

    array_cols = for k <- Map.keys(columns), do: {k, :array}
    scalar_cols = for k <- Map.keys(placeholders), do: {k, :scalar}

    (array_cols ++ scalar_cols)
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map(fn {name, kind} ->
      ecto_type = EctoUnnest.Types.ecto_type!(schema, name, overrides[name])
      pg_type = resolve_pg_type!(name, ecto_type, overrides[name], kind)
      base = %{name: name, kind: kind, pg_type: pg_type, ecto_type: ecto_type}

      if kind == :array do
        # Schema -> dump arrays through the real Ecto type (UUID, Enum, datetime).
        # Binary source -> the Ecto type is a `:string` stand-in, so pass values
        # through untouched (`:any`) and let the `::pg_type[]` cast do the encoding.
        dump_type = if is_binary(schema), do: :any, else: ecto_type
        Map.merge(base, %{values: columns[name], dump_type: dump_type})
      else
        base
      end
    end)
  end

  defp resolve_pg_type!(name, ecto_type, override, kind) do
    case EctoUnnest.Types.resolve_pg_type(ecto_type, override, kind) do
      {:ok, pg_type} ->
        pg_type

      {:error, :array_unsupported} ->
        raise ArgumentError,
              "column #{inspect(name)} is array-typed and varies per row — " <>
                "unnest flattens multi-dimensional arrays. If the value is constant, " <>
                "move it to :placeholders (then it goes as a scalar parameter)."
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp table_name(schema) when is_atom(schema), do: schema.__schema__(:source)
  defp table_name(source) when is_binary(source), do: source

  defp schema_prefix(schema) when is_atom(schema), do: schema.__schema__(:prefix)
  defp schema_prefix(_), do: nil

  defp normalize_returning(false, _schema), do: []
  defp normalize_returning(true, schema) when is_atom(schema), do: schema.__schema__(:fields)

  defp normalize_returning(true, source) when is_binary(source),
    do: raise(ArgumentError, "for source #{inspect(source)} pass :returning as a field list")

  defp normalize_returning(list, _schema) when is_list(list), do: list
end
