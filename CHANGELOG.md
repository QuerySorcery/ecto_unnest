# Changelog

## Unreleased

### Added

- **Per-row JSON columns (`jsonb` / `{:array, :map}`).** A column whose per-row
  value is itself JSON is now shipped as a 1-D `text[]` of pre-encoded JSON with a
  `::jsonb` cast in the `SELECT` projection (instead of a `::jsonb[]` param, which
  `unnest` flattened and Postgrex double-encoded). Schema sources auto-detect
  `:map` / `{:map, _}` / `{:array, :map}`; binary sources opt in with
  `types: %{col: :jsonb}` or the new `:json` option. Raw terms are encoded with the
  configured `:postgrex` `:json_library`; already-encoded strings pass through.
- **Full `Ecto.Query` as `:on_conflict`.** Enables a conditional
  `ON CONFLICT ... DO UPDATE SET ... WHERE <predicate>` (and `ORDER BY`), matching
  `Ecto.Repo.insert_all/3`.
- **`:types` accepts atoms** (recommended — assumed app-controlled, so rendered
  straight into the SQL cast). Strings still work.

### Fixed

- **Placeholders no longer require a `pg_type`.** `resolve_pg_type!` is skipped for
  placeholder (`:scalar`) columns, since their cast comes from `type(^value, type)`
  in the projection, not the `unnest` param. Integer-backed `Ecto.Enum`, date and
  uuid placeholders now work on schema sources with no `:types` entry.
- **Binary-source non-string placeholders** can be cast via `:types` (e.g.
  `types: %{created_at: :timestamptz}`), including custom PG types such as a domain
  `:kafka_topic_name`, rendered as a raw `::type` cast on the parameter.

### Notes

- Binary-source column alignment was confirmed correct on execution: both the
  executed `Repo.insert_all/3` and `to_sql/3` derive the `INSERT` column list from
  the same name-ordered `SELECT`, and the projection references `unnest` columns by
  name — so values land in their named column regardless of physical column order.
  A regression test guards this.
