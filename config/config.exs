import Config

alias EctoUnnest.Test.Repo

config :ecto_unnest, Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: System.get_env("PGDATABASE", "ecto_unnest_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :ecto_unnest, ecto_repos: [Repo]

# Use Elixir's built-in JSON module (1.18+) instead of Jason.
config :postgrex, :json_library, JSON
