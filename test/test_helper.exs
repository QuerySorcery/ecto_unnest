integration? = System.get_env("INTEGRATION") in ["1", "true"]

if integration? do
  alias EctoUnnest.Test.Migration
  alias EctoUnnest.Test.Repo

  {:ok, _} = Application.ensure_all_started(:ecto_sql)
  {:ok, _} = Application.ensure_all_started(:postgrex)

  # Create the database (idempotently) and start the repo.
  _ = Ecto.Adapters.Postgres.storage_up(Repo.config())
  {:ok, _} = Repo.start_link()

  # Migrations (version 0; a re-run is skipped if already recorded).
  Ecto.Migrator.run(Repo, [{0, Migration}], :up, all: true, log: :info)

  Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
  ExUnit.start()
else
  ExUnit.start(exclude: [:integration])
end
