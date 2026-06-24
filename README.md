# EctoUnnest

Bulk insert for Ecto via `unnest(...)` — **constant SQL text, independent of the
row count**, friendly to PgBouncer (transaction mode) and the prepared-statement
cache.

## Problem

`Ecto.Repo.insert_all/3` builds:

```sql
INSERT INTO events (a, b) VALUES ($1, $2), ($3, $4), ...   -- N*K parameters
```

Every batch size is a different SQL text → a different prepared statement.
PgBouncer in `transaction` mode can't cache that sensibly, and Postgres caps
parameters at ~65535.

## Solution

```sql
INSERT INTO "events" ("type","user_id")
(SELECT f0."type", f0."user_id"
 FROM (SELECT * FROM unnest($1::text[], $2::bigint[]) AS u("type","user_id")) AS f0)
```

Always K parameters (one array per column) → the **statement is identical for 1
and 10,000 rows**.

The query is assembled from Ecto building blocks (`fragment`/`dynamic`) and handed
to `Ecto.Repo.insert_all/3`, which renders `ON CONFLICT`/`RETURNING`/`prefix` and
loads structs natively. Because the text is constant per shape, Postgres reuses a
single prepared statement (Ecto caches it under `ecto_insert_all_<table>`).

## Usage

Two disjoint maps:

```elixir
EctoUnnest.insert_all(Repo, Event,
  # columns map: each value is a list -> goes into unnest
  %{user_id: [1, 2, 3], type: ["click", "view", "click"]},
  # :placeholders: constants broadcast onto every row
  placeholders: %{inserted_at: ~U[2026-06-17 10:00:00Z]},
  returning: true
)
# => {3, [%Event{...}, %Event{...}, %Event{...}]}
```

`EctoUnnest.to_sql/3` returns `{sql, params}` without executing — for debugging.
It is pure (no database connection) and renders the exact statement
`Repo.insert_all/3` would run.

## Options (same as `Ecto.Repo.insert_all/3`)

| option | meaning |
|---|---|
| `:placeholders` | `%{col => value}` of constant columns (default `%{}`) |
| `:returning` | `true \| false \| [field]` |
| `:prefix` | schema prefix (overrides `@schema_prefix`) |
| `:on_conflict` | `:raise \| :nothing \| :replace_all \| {:replace, fields} \| {:replace_all_except, fields} \| [set: kw, inc: kw]` |
| `:conflict_target` | `[col] \| {:unsafe_fragment, binary}` |
| `:types` | `%{col => pg_type}` override for inference (atom or string — see [Type overrides](#type-overrides)) |

## Type overrides and `:allowed_types`

A `:types` value is rendered into the SQL cast (`$n::type` / `::type[]`)
**verbatim**, so it must never come from user input. As a guard, the gate is
fail-closed:

- Ecto's **default PG types** (`bigint`, `float8`, `boolean`, `text`, `bytea`,
  `uuid`, `numeric`, `date`, `time`, `timestamp`, `timestamptz`, `jsonb`, `json`)
  are always accepted.
- **Anything else** — a domain (`kafka_topic_name`), an alias (`int4`), a modifier
  (`numeric(10,2)`), a quoted identifier — must be vouched for in config, or the
  call raises:

```elixir
config :ecto_unnest, :allowed_types, [:int4, "kafka_topic_name"]
```

Entries may be atoms or strings. Because binary sources (`"table"`) require
`:types`, any non-default type they cast to must be listed here.

## Reading: `unnest` as a virtual table

`EctoUnnest.table/3` exposes the same `unnest(...)` source as a composable
`%Ecto.Query{}` with a named binding (`:s` by default). Use it like any Ecto
source — `where`, `order_by`, `select`, `Repo.all/2`:

```elixir
q = EctoUnnest.table(Event, %{user_id: [1, 2, 3], type: ["a", "b", "c"]})

from([s: s] in q, where: s.user_id > 1, select: {s.user_id, s.type})
|> Repo.all()
# => [{2, "b"}, {3, "c"}]
```

### Bulk UPDATE from an in-memory CSV

Wrap the virtual table in `subquery/1` (which carries the parameters) and join it
into an `UPDATE`. Here we drive the update from a CSV like:

```csv
id,val
1,x
2,y
3,z
```

```elixir
csv = "id,val\n1,x\n2,y\n3,z\n"

# parse CSV into column arrays: %{id: [1, 2, 3], val: ["x", "y", "z"]}
[_header | rows] = csv |> String.trim() |> String.split("\n")

cols =
  rows
  |> Enum.map(&String.split(&1, ","))
  |> Enum.reduce(%{id: [], val: []}, fn [id, val], acc ->
    %{acc | id: [String.to_integer(id) | acc.id], val: [val | acc.val]}
  end)
  |> Map.update!(:id, &Enum.reverse/1)
  |> Map.update!(:val, &Enum.reverse/1)

# build the virtual table and join it into a single UPDATE statement
src =
  EctoUnnest.table(Event, %{user_id: cols.id, type: cols.val})
  |> then(&from([s: s] in &1, select: %{user_id: s.user_id, type: s.type}))

from(e in Event,
  join: s in subquery(src),
  on: e.user_id == s.user_id,
  update: [set: [type: s.type]]
)
|> Repo.update_all([])
# => {3, nil} — one statement, constant text regardless of CSV size
```

## UUIDv7 primary keys

`insert_all` (and therefore EctoUnnest) does **not** autogenerate primary keys, so
you supply the id list yourself. EctoUnnest is type-agnostic: a `UUIDv7` field is a
plain `Ecto.Type` whose `type/0` is `:uuid`, so it is inferred as `::uuid[]` and
each id is dumped through that type — no special integration needed.

Pair it with a bulk id generator such as [`uuuidv7`](https://hex.pm/packages/uuuidv7)
(`{:uuuidv7, "~> 0.3.0"}`):

```elixir
names = ["a", "b", "c"]

EctoUnnest.insert_all(Repo, Event,
  %{id: UUIDv7.generate_many(length(names)), name: names}
)
```

`UUIDv7.generate_many/1` produces monotonic ids in one shot, which keeps the insert
a single constant-text statement.

## Arrays

- A **constant** array value → insert it via `:placeholders` (goes in as a scalar
  `$n::int[]`, no unnest). Works.
- A **per-row** array column → unsupported (unnest flattens multi-dimensional
  arrays); the library raises a clear error.

## Status

Unit tests (`to_sql`, `table`) need no database. Integration tests (tagged
`@tag :integration`) require Postgres; run them with `INTEGRATION=1 mix test`.
