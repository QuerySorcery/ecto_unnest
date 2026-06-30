defmodule EctoUnnest.RequireAllFieldsConfigTest do
  # async: false — mutates the global `:ecto_unnest, :require_all_fields` app env.
  use ExUnit.Case, async: false

  alias EctoUnnest.Test.Event

  setup do
    on_exit(fn -> Application.delete_env(:ecto_unnest, :require_all_fields) end)
  end

  test "reads :require_all_fields from application config when no opt is given" do
    Application.put_env(:ecto_unnest, :require_all_fields, true)

    assert_raise ArgumentError, ~r/are not provided/, fn ->
      EctoUnnest.to_sql(Event, %{user_id: [1], type: ["a"]})
    end
  end

  test "an explicit opt overrides the config value" do
    Application.put_env(:ecto_unnest, :require_all_fields, true)

    # config says true, but the call opts out -> no error despite missing fields
    {sql, _} = EctoUnnest.to_sql(Event, %{user_id: [1], type: ["a"]}, require_all_fields: false)
    assert sql =~ ~s|INSERT INTO "events"|
  end
end
