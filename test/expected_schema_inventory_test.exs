defmodule PhoenixKitBilling.ExpectedSchemaInventoryTest do
  use ExUnit.Case, async: true

  alias PhoenixKitBilling.ExpectedSchema
  alias PhoenixKitBilling.Migrations

  test "the manifest covers every table created by the current migration chain" do
    created_tables =
      Migrations.up_statements("public")
      |> Enum.flat_map(fn statement ->
        Regex.scan(~r/CREATE TABLE IF NOT EXISTS public\.(\w+)/, statement,
          capture: :all_but_first
        )
      end)
      |> List.flatten()
      |> MapSet.new()

    manifest_tables =
      for %{class: :table, check: {:catalog, %{name: name}}} <- ExpectedSchema.objects("public"),
          into: MapSet.new(),
          do: name

    assert MapSet.size(created_tables) > 0
    assert manifest_tables == created_tables
  end
end
