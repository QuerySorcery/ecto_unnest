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
    * the **`SELECT`** is assembled with `dynamic/2` via `from(b in base, select: ^sel)` —
      `field(s, ^col)` for `unnest` columns, `type(^val, type)` for placeholders.

  Execution and all of `ON CONFLICT`/`RETURNING`/`prefix`/struct loading are
  delegated to `Ecto.Repo.insert_all/3`. `to_sql/1` renders the same plan into the
  full `INSERT` text with no database connection, via
  `Ecto.Adapters.Postgres.Connection`.
  """

  import Ecto.Query

  alias Ecto.Query.Planner

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
    {arrays, scalars} = split(plan)

    base = virtual(arrays, :s)

    sel =
      Map.merge(
        Map.new(arrays, fn c -> {c.name, dynamic([s: s], field(s, ^c.name))} end),
        Map.new(scalars, fn c -> {c.name, dynamic([s: s], type(^plan.placeholders[c.name], ^c.ecto_type))} end)
      )

    from(b in base, select: ^sel)
  end

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

    parts =
      [raw: "(SELECT * FROM unnest("] ++
        (arrays
         |> Enum.with_index()
         |> Enum.flat_map(fn {c, i} ->
           tail =
             if i == length(arrays) - 1,
               do: "::#{c.pg_type}[]) AS u(#{aliases}))",
               else: "::#{c.pg_type}[], "

           [expr: {:^, [], [i]}, raw: tail]
         end))

    {:fragment, [], parts}
  end

  defp from_params(arrays),
    do: Enum.map(arrays, fn c -> {Map.fetch!(c, :values), {:array, Map.fetch!(c, :dump_type)}} end)

  # ── INSERT header from the planned SELECT ──────────────────────────────
  # The SELECT is a map -> columns in the map's argument order (consistent with
  # the projection).
  defp header(%Ecto.Query{select: %Ecto.Query.SelectExpr{expr: {:%{}, _, args}}}),
    do: Enum.map(args, fn {field, _} -> field end)

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
    update_query = Ecto.Query.from(from, update: ^kw)

    {planned, params, _} = Planner.plan(%{update_query | prefix: p.prefix}, :update_all, @adapter)
    {cast_params, dump_params} = Enum.unzip(params)
    {normalized, _} = Planner.normalize(planned, :update_all, @adapter, counter.())

    {{normalized, dump_params, target(p)}, cast_params}
  end

  defp on_conflict(%{on_conflict: other}, _counter) do
    raise ArgumentError,
          ":on_conflict #{inspect(other)} not supported — use " <>
            ":raise | :nothing | :replace_all | {:replace, fields} | " <>
            "{:replace_all_except, fields} | [set: kw, inc: kw]"
  end

  defp target(%{conflict_target: {:unsafe_fragment, _} = frag}), do: frag
  defp target(%{conflict_target: cols}), do: List.wrap(cols)

  defp all_sources(%{columns: columns}), do: Enum.map(columns, & &1.name)

  defp split(plan), do: Enum.split_with(plan.columns, &(&1.kind == :array))
end
