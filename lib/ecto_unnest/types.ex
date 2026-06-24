defmodule EctoUnnest.Types do
  @moduledoc """
  Ecto type inference from the schema and mapping to a PostgreSQL type.

  The type is read from `schema.__schema__(:type, field)` and mapped to the PG
  type used in `::type[]` casts. The `:types` option (override) takes precedence
  and is the only path for binary sources (`"table"`), which have no schema.
  """

  @doc """
  Returns the Ecto type for a field. For a binary source it requires an `override`
  from `:types`, but even then returns only a type stand-in — the real PG type
  comes from the override.
  """
  def ecto_type!(schema, field, _override) when is_atom(schema) do
    schema.__schema__(:type, field) ||
      raise ArgumentError, "field #{inspect(field)} does not exist in #{inspect(schema)}"
  end

  def ecto_type!(source, field, override) when is_binary(source) do
    if override do
      # For a raw source we have no Ecto type; use :string as a neutral stand-in
      # (Postgrex receives the cast from the override anyway).
      :string
    else
      raise ArgumentError,
            "for source #{inspect(source)} pass the type of field #{inspect(field)} via :types"
    end
  end

  @doc """
  True when an Ecto type is stored as `jsonb` (a per-row value that must go in as
  pre-encoded JSON text with a `::jsonb` cast in the projection — see `EctoUnnest`'s
  JSON mode). Covers `:map`, `{:map, _}`, `{:array, :map}`, `{:array, {:map, _}}`
  and parameterized types whose primitive is one of those.
  """
  def jsonb?(:map), do: true
  def jsonb?({:map, _}), do: true
  def jsonb?({:array, :map}), do: true
  def jsonb?({:array, {:map, _}}), do: true
  def jsonb?({:parameterized, _, _} = t), do: jsonb?(primitive(t))
  def jsonb?(_), do: false

  # The canonical PG type names `map_pg/1` emits — the set of types Ecto's own
  # type inference produces, always allowed for a `:types` override without needing
  # `config :ecto_unnest, :allowed_types`. Keep in sync with `map_pg/1`.
  @default_pg_types ~w(bigint float8 boolean text bytea uuid numeric date time timestamp timestamptz jsonb json)

  @doc "PG type names always allowed for a `:types` override (see `EctoUnnest`'s `:allowed_types`)."
  def default_pg_types, do: @default_pg_types

  @doc """
  `{:ok, "pg_type"}` or `{:error, :array_unsupported}`.

  `override` (from `:types`) takes precedence. `kind` decides about arrays:

    * `:array` (an `unnest` column) + array type -> `{:error, :array_unsupported}`
      (unnest would flatten a multi-dimensional array),
    * `:scalar` (a placeholder) + array type -> OK, e.g. `"bigint[]"` — it is an
      ordinary scalar parameter, so a constant array value lands in the column fine.
  """
  def resolve_pg_type(ecto_type, override, kind \\ :array)

  def resolve_pg_type(_ecto_type, override, _kind) when is_binary(override), do: {:ok, override}

  def resolve_pg_type({:array, inner}, nil, :scalar), do: {:ok, map_pg(primitive(inner)) <> "[]"}

  def resolve_pg_type({:array, _inner}, nil, :array), do: {:error, :array_unsupported}

  def resolve_pg_type({:parameterized, _, _} = t, nil, kind) do
    case primitive(t) do
      {:array, _} = arr -> resolve_pg_type(arr, nil, kind)
      prim -> {:ok, map_pg(prim)}
    end
  end

  def resolve_pg_type(ecto_type, nil, _kind), do: {:ok, map_pg(primitive(ecto_type))}

  # Custom Ecto.Type -> primitive (Ecto.Enum, Ecto.UUID, custom types).
  defp primitive({:parameterized, mod, params}), do: mod.type(params)

  defp primitive(type) when is_atom(type) do
    if Code.ensure_loaded?(type) and function_exported?(type, :type, 0),
      do: type.type(),
      else: type
  end

  defp primitive(type), do: type

  # The cast must match the representation Postgrex sends for the dumped value.
  defp map_pg(:id), do: "bigint"
  defp map_pg(:integer), do: "bigint"
  defp map_pg(:float), do: "float8"
  defp map_pg(:boolean), do: "boolean"
  defp map_pg(:string), do: "text"
  defp map_pg(:binary), do: "bytea"
  defp map_pg(:binary_id), do: "uuid"
  defp map_pg(:decimal), do: "numeric"
  defp map_pg(:date), do: "date"
  defp map_pg(:time), do: "time"
  defp map_pg(:time_usec), do: "time"
  defp map_pg(:naive_datetime), do: "timestamp"
  defp map_pg(:naive_datetime_usec), do: "timestamp"
  defp map_pg(:utc_datetime), do: "timestamptz"
  defp map_pg(:utc_datetime_usec), do: "timestamptz"
  defp map_pg(:map), do: "jsonb"
  defp map_pg({:map, _}), do: "jsonb"
  defp map_pg(:uuid), do: "uuid"

  defp map_pg(other), do: raise(ArgumentError, "unknown type #{inspect(other)} — pass it via :types")
end
