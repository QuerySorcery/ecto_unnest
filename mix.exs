defmodule EctoUnnest.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/QuerySorcery/ecto_unnest"

  def project do
    [
      app: :ecto_unnest,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto, "~> 3.10"},
      {:ecto_sql, "~> 3.10"},
      {:styler, "~> 1.0", only: :dev, runtime: false},
      {:postgrex, "~> 0.17", optional: true},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:uuuidv7, "~> 0.3.0", only: :test}
    ]
  end

  defp description do
    "Bulk insert dla Ecto przez unnest(...) — staly tekst SQL niezalezny od liczby " <>
      "wierszy, przyjazny dla PgBouncera (transaction mode) i prepared statement cache."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["Daniel Kukula"]
    ]
  end

  defp docs do
    [main: "EctoUnnest", source_ref: "v#{@version}", source_url: @source_url]
  end
end
