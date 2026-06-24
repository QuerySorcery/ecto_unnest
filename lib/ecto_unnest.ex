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
    * `:on_conflict` — `:raise | :nothing | :replace_all | {:replace, fields} |
      {:replace_all_except, fields} | [set: kw, inc: kw] | Ecto.Query.t()`. A full
      query enables a conditional `DO UPDATE ... WHERE ...` (see "Conflicts" below)
    * `:conflict_target` — `[col] | {:unsafe_fragment, binary}`
    * `:types` — `%{col => pg_type}` override for type inference, where `pg_type` is
      an atom (recommended — assumed app-controlled, so rendered straight into the
      SQL cast) or a string. For a placeholder it becomes a raw `::pg_type` cast, so
      it can name a custom PG type (e.g. a domain `:kafka_topic_name`). The value is
      rendered into SQL verbatim, so it is fail-closed: Ecto's default PG types
      (`bigint`, `text`, `jsonb`, `timestamptz`, …) are always accepted, but any
      other spelling (a domain, an alias like `int4`, a modifier like `numeric(10,2)`)
      must be vouched for in config, or it raises:

          config :ecto_unnest, :allowed_types, [:int4, "kafka_topic_name"]
    * `:json` — `[col]` columns to force into JSON mode (see "JSON columns" below)

  ## JSON columns

  A per-row value destined for a `jsonb` column (Ecto type `:map`, `{:map, _}` or
  `{:array, :map}`) cannot ride in `unnest` as a `::jsonb[]` array — `unnest`
  flattens multi-dimensional arrays and Postgrex would double-encode. Such columns
  are shipped instead as a 1-D `text[]` of pre-encoded JSON with a `::jsonb` cast in
  the projection. Schema sources detect this automatically from the Ecto type; on
  binary sources use `types: %{col: :jsonb}` or `json: [:col]`. Raw terms are JSON
  encoded with the configured `:postgrex` `:json_library`; already-encoded strings
  pass through untouched.

      EctoUnnest.insert_all(Repo, Doc,
        %{id: [id1, id2], summary: [[%{"a" => 1}], [%{"b" => 2}]]},
        placeholders: %{created_at: ts})

  ## Conflicts

  Besides the keyword form, `:on_conflict` accepts a full `Ecto.Query` (as
  `Ecto.Repo.insert_all/3` does) for a conditional update:

      from(s in Setting, update: [set: [deleted_at: nil]], where: not is_nil(s.deleted_at))

  ## Reading: virtual table

  `table/3` exposes the same `unnest(...)` source as a composable `%Ecto.Query{}`,
  so you can `SELECT` from it or join it into an `UPDATE`. See `table/3`.

  ## Limitations

    * non-JSON array-typed columns (`{:array, _}` other than `{:array, :map}`) that
      vary per row are unsupported (`unnest` flattens multi-dimensional arrays) — we
      raise a clear error. JSON arrays (`{:array, :map}`) are supported via JSON mode
      (see "JSON columns"),
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
    json_opt = MapSet.new(opts[:json] || [])

    array_cols = for k <- Map.keys(columns), do: {k, :array}
    scalar_cols = for k <- Map.keys(placeholders), do: {k, :scalar}

    (array_cols ++ scalar_cols)
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map(fn {name, kind} ->
      override = normalize_type(name, overrides[name])
      ecto_type = EctoUnnest.Types.ecto_type!(schema, name, override)
      classify_column!(schema, name, kind, ecto_type, override, columns, MapSet.member?(json_opt, name))
    end)
  end

  # An `:array` (per-row) column whose value is itself JSON (jsonb/`{:array,:map}`).
  # `unnest` flattens multi-dimensional arrays, so the only shape Postgres accepts
  # is a 1-D `text[]` of pre-encoded JSON with a `::jsonb` cast in the projection.
  defp classify_column!(schema, name, :array, ecto_type, override, columns, json?) do
    base = %{name: name, kind: :array, ecto_type: ecto_type}

    if json?(ecto_type, override, json?) do
      Map.merge(base, %{
        json: true,
        pg_type: "text",
        values: Enum.map(columns[name], &encode_json/1),
        dump_type: :string
      })
    else
      pg_type = resolve_pg_type!(name, ecto_type, override, :array)
      # Schema -> dump arrays through the real Ecto type (UUID, Enum, datetime).
      # Binary source -> the Ecto type is a `:string` stand-in, so pass values
      # through untouched (`:any`) and let the `::pg_type[]` cast do the encoding.
      dump_type = if is_binary(schema), do: :any, else: ecto_type
      Map.merge(base, %{pg_type: pg_type, values: columns[name], dump_type: dump_type})
    end
  end

  # Placeholders never go through `unnest`, so they need no `::pg_type[]` param
  # cast — the value is a scalar parameter cast in the projection. `:types`, when
  # given, becomes a raw `::type` cast on that parameter (supports custom PG types
  # such as a domain `kafka_topic_name`, and non-string types on binary sources);
  # otherwise the Ecto type drives the cast (so `Ecto.Enum`/date/uuid just work).
  defp classify_column!(_schema, name, :scalar, ecto_type, override, _columns, _json?) do
    cast = if override, do: {:raw, override}, else: {:ecto, ecto_type}
    %{name: name, kind: :scalar, ecto_type: ecto_type, cast: cast}
  end

  defp json?(_ecto_type, _override, true), do: true
  defp json?(_ecto_type, override, _json?) when override in ["jsonb", "json"], do: true
  defp json?(ecto_type, nil, _json?), do: EctoUnnest.Types.jsonb?(ecto_type)
  defp json?(_ecto_type, _override, _json?), do: false

  # `:types` may be an atom (recommended — app-controlled, so it is safe to render
  # straight into the SQL cast) or a string. Normalize to a string for rendering.
  defp normalize_type(_name, nil), do: nil
  defp normalize_type(name, t) when is_atom(t), do: validate_type!(name, Atom.to_string(t))
  defp normalize_type(name, t) when is_binary(t), do: validate_type!(name, t)

  # The override is rendered straight into the SQL cast (`$n::type` / `::type[]`),
  # so as a defence-in-depth guard against injection we accept only a well-formed
  # PostgreSQL type spelling, not just a safe character set: a (possibly
  # multi-word, schema-qualified) base name, an optional `(...)` modifier whose
  # parens must close, and zero or more `[]`/`[n]` array suffixes whose brackets
  # must close. Covers `kafka_topic_name`, `bigint[]`, `numeric(10,2)`,
  # `timestamp with time zone`, `public.mytype`. A stray `int4)` or `bigint[`,
  # or any other char (`;`, quotes, `-`, `\`, …), is rejected.
  # A `:types` override is rendered into SQL verbatim, so it is fail-closed: a
  # spelling is allowed only if it is one of Ecto's default PG types or the app has
  # vouched for it via `config :ecto_unnest, :allowed_types`. Anything else raises.
  defp validate_type!(name, type) do
    if type in allowed_types() do
      type
    else
      raise ArgumentError,
            ":types value #{inspect(type)} for column #{inspect(name)} is not allowed — it is not a " <>
              "default Ecto type; add it to `config :ecto_unnest, :allowed_types, [...]`"
    end
  end

  # Default PG types (always allowed) plus the configured custom ones. Config
  # entries may be atoms or strings; normalized to strings to match the cast.
  defp allowed_types do
    configured =
      case Application.get_env(:ecto_unnest, :allowed_types) do
        nil -> []
        list -> Enum.map(list, &to_string/1)
      end

    EctoUnnest.Types.default_pg_types() ++ configured
  end

  defp encode_json(nil), do: nil
  defp encode_json(v) when is_binary(v), do: v
  defp encode_json(v), do: json_library().encode!(v)

  defp json_library, do: Application.get_env(:postgrex, :json_library, JSON)

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
