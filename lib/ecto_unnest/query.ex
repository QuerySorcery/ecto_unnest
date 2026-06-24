defmodule EctoUnnest.Query do
  @moduledoc """
  Builds the `INSERT ... SELECT ... FROM unnest(...)` query from Ecto building blocks.

  Instead of assembling the whole SQL string by hand, we build an `%Ecto.Query{}`:

    * the **`FROM` source** is the fragment `unnest($1::t[], ...) AS u(col, ...)`.
      Column names and casts are dynamic (they depend on the column set), and
      `fragment/1` as a macro requires a string literal — so `from.source` is
      built as an `%Ecto.Query.FromExpr{}` struct with properly alternating
      `raw`/`expr` parts (otherwise Ecto's `Inspect` blows up). The binding is
      named `:s`,
    * the **`SELECT`** is assembled as a `%Ecto.Query.SelectExpr{}` struct (the same
      shape Ecto compiles from `select: ^map`): `field(s, col)` for `unnest` columns,
      `type(^val, type)` for placeholders, and `fragment` casts for JSON columns
      (`f0."col"::jsonb`) and custom-typed placeholders (`$n::type`) — those need a
      runtime cast string a `dynamic/2` `fragment/1` (literal-only) cannot express.

  Execution and all of `ON CONFLICT`/`RETURNING`/`prefix`/struct loading are
  delegated to `Ecto.Repo.insert_all/3`. `to_sql/1` renders the same plan into the
  full `INSERT` text with no database connection, via
  `Ecto.Adapters.Postgres.Connection`.
  """

  alias Ecto.Query.Planner
  alias Ecto.Query.SelectExpr

  require Ecto.Query

  @adapter Ecto.Adapters.Postgres
  @conn Ecto.Adapters.Postgres.Connection

  @doc """
  Returns an `%Ecto.Query{}` with just `FROM unnest(...) AS u(...)` and a named
  binding `as` — a virtual table for free composition (`where`, `select`, `join`,
  `Repo.all`, `subquery/1`).
  """
  def virtual(arrays, as) when is_atom(as) do
    %Ecto.Query{
      from: %Ecto.Query.FromExpr{source: source(arrays), params: from_params(arrays), as: as},
      aliases: %{as => 0}
    }
  end

  @doc "Builds the `%Ecto.Query{}` used as the source for `Repo.insert_all/3`."
  def build(plan) do
    {arrays, _scalars} = split(plan)
    base = virtual(arrays, :s)

    # Column order matches the map Ecto would build from `select: ^map` (keyed by
    # name) so the INSERT header and projection stay byte-for-byte stable. JSON and
    # custom-typed placeholders need a runtime cast string in the SELECT, which a
    # `dynamic/2` `fragment/1` (literal-only) cannot express — so the `SelectExpr`
    # is assembled by hand, the same struct Ecto would produce from the macro.
    ordered = plan.columns |> Map.new(&{&1.name, &1}) |> Map.to_list() |> Enum.map(&elem(&1, 1))

    {args, params, _i} =
      Enum.reduce(ordered, {[], [], 0}, fn c, {args, params, i} ->
        {expr, new_params, next} = select_entry(c, plan, i)
        {args ++ [{c.name, expr}], params ++ new_params, next}
      end)

    select = %SelectExpr{
      expr: {:%{}, [], args},
      params: params,
      take: %{},
      subqueries: [],
      aliases: %{},
      line: __ENV__.line,
      file: __ENV__.file
    }

    %{base | select: select}
  end

  # A per-row JSON column: `f0."col"::jsonb` over a 1-D `text[]` of pre-encoded JSON.
  defp select_entry(%{kind: :array, json: true, name: name}, _plan, i),
    do: {{:fragment, [], [raw: "", expr: field_expr(name), raw: "::jsonb"]}, [], i}

  # A plain `unnest` column: `f0."col"`.
  defp select_entry(%{kind: :array, name: name}, _plan, i), do: {field_expr(name), [], i}

  # A placeholder with a `:types` override: a raw `$n::type` cast on the parameter.
  # The type is app-controlled (an atom/string from the caller), so it is rendered
  # straight into the SQL — supporting custom PG types and binary-source casts.
  defp select_entry(%{kind: :scalar, cast: {:raw, type}, name: name}, plan, i),
    do: {{:fragment, [], [raw: "", expr: {:^, [], [i]}, raw: "::#{type}"]}, [{plan.placeholders[name], :any}], i + 1}

  # A placeholder cast through its Ecto type: `type(^val, ecto_type)` (handles
  # `Ecto.Enum`, dates, uuids on schema sources with no `:types` entry).
  defp select_entry(%{kind: :scalar, cast: {:ecto, type}, name: name}, plan, i),
    do: {{:type, [], [{:^, [], [i]}, type]}, [{plan.placeholders[name], type}], i + 1}

  defp field_expr(name), do: {{:., [], [{:&, [], [0]}, name]}, [], []}

  @doc """
  `{sql, params}` of the full `INSERT` — without executing, purely.

  Uses the same building blocks as `Repo.insert_all/3`: it plans the query
  (`plan_query`), reconstructs the planned `on_conflict`, and assembles the text
  via the Postgres adapter's `Connection` module.
  """
  def to_sql(plan) do
    query = build(plan)
    {query, _cast_params, dump_params} = Ecto.Adapter.Queryable.plan_query(:insert_all, @adapter, query)

    header = header(query)
    {on_conflict, conflict_params} = on_conflict(plan, fn -> length(dump_params) end)

    # Ecto builds the RETURNING source list by prepending (fields_to_sources/2),
    # so it comes out reversed — we mirror that for byte-for-byte parity.
    sql =
      plan.prefix
      |> @conn.insert(plan.table, header, query, on_conflict, Enum.reverse(plan.returning), [])
      |> IO.iodata_to_binary()

    {sql, dump_params ++ conflict_params}
  end

  # ── FROM source (unnest fragment) ──────────────────────────────────────

  # No array columns -> a single synthetic row (placeholders only, N=1).
  defp source([]), do: {:fragment, [], [raw: "(SELECT 1)"]}

  defp source(arrays) do
    aliases = Enum.map_join(arrays, ", ", &~s|"#{&1.name}"|)
    len = length(arrays)

    parts =
      [raw: "(SELECT * FROM unnest("] ++
        (arrays
         |> Enum.with_index()
         |> Enum.flat_map(fn {c, i} ->
           type = "::#{c.pg_type}[]"
           tail = if i == len - 1, do: ") AS u(#{aliases}))", else: ", "

           [expr: {:^, [], [i]}, raw: [type, tail]]
         end))

    {:fragment, [], parts}
  end

  defp from_params(arrays),
    do: Enum.map(arrays, fn c -> {Map.fetch!(c, :values), {:array, Map.fetch!(c, :dump_type)}} end)

  # ── INSERT header from the planned SELECT ──────────────────────────────
  # The SELECT is a map -> columns in the map's argument order (consistent with
  # the projection).
  defp header(%Ecto.Query{select: %SelectExpr{expr: {:%{}, _, args}}}), do: Enum.map(args, fn {field, _} -> field end)

  # ── ON CONFLICT (rebuild the planned form for Connection.insert) ────────

  defp on_conflict(%{on_conflict: :raise}, _counter), do: {{:raise, [], []}, []}

  defp on_conflict(%{on_conflict: :nothing} = p, _counter), do: {{:nothing, [], target(p)}, []}

  defp on_conflict(%{on_conflict: :replace_all} = p, _counter),
    do: {{all_sources(p) -- List.wrap(p.conflict_target), [], target(p)}, []}

  defp on_conflict(%{on_conflict: {:replace, fields}} = p, _counter) when is_list(fields),
    do: {{fields, [], target(p)}, []}

  defp on_conflict(%{on_conflict: {:replace_all_except, except}} = p, _counter),
    do: {{(all_sources(p) -- List.wrap(p.conflict_target)) -- except, [], target(p)}, []}

  defp on_conflict(%{on_conflict: kw} = p, counter) when is_list(kw) do
    if Keyword.get(kw, :set, []) == [] and Keyword.get(kw, :inc, []) == [] do
      raise ArgumentError, ":on_conflict as a keyword requires :set and/or :inc"
    end

    from = if is_atom(p.schema), do: {p.table, p.schema}, else: p.table
    plan_update(Ecto.Query.from(from, update: ^kw), p, counter)
  end

  # A full Ecto query as `:on_conflict` — a conditional `DO UPDATE ... WHERE ...`
  # (`Ecto.Repo.insert_all/3` accepts the same). Planned as `:update_all`, exactly
  # like the keyword form, so the `WHERE`/`ORDER BY` ride along into the rendered
  # `ON CONFLICT` clause.
  defp on_conflict(%{on_conflict: %Ecto.Query{} = query} = p, counter), do: plan_update(query, p, counter)

  defp on_conflict(%{on_conflict: other}, _counter) do
    raise ArgumentError,
          ":on_conflict #{inspect(other)} not supported — use " <>
            ":raise | :nothing | :replace_all | {:replace, fields} | " <>
            "{:replace_all_except, fields} | [set: kw, inc: kw] | %Ecto.Query{}"
  end

  defp plan_update(update_query, p, counter) do
    {planned, params, _} = Planner.plan(%{update_query | prefix: p.prefix}, :update_all, @adapter)
    {cast_params, dump_params} = Enum.unzip(params)
    {normalized, _} = Planner.normalize(planned, :update_all, @adapter, counter.())

    {{normalized, dump_params, target(p)}, cast_params}
  end

  defp target(%{conflict_target: {:unsafe_fragment, _} = frag}), do: frag
  defp target(%{conflict_target: cols}), do: List.wrap(cols)

  defp all_sources(%{columns: columns}), do: Enum.map(columns, & &1.name)

  defp split(plan), do: Enum.split_with(plan.columns, &(&1.kind == :array))
end
