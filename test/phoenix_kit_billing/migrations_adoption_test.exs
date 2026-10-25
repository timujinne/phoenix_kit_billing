defmodule PhoenixKitBilling.MigrationsAdoptionTest do
  use PhoenixKitBilling.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitBilling.Migrations

  @moduledoc """
  V6 creates `phoenix_kit_currencies` and `phoenix_kit_orders` ahead of the
  V2/V3 statements that alter them, and carries core's seed rows — but only as
  part of creating a table. The first group is pure SQL-as-data; the second
  builds the chain in a scratch schema on the test database and looks at rows.
  """

  @schema "pkb_v6_seed_test"

  # V7's counter table is the one thing a rollback below V7 drops.
  defp v7_drop, do: ["DROP TABLE IF EXISTS public.phoenix_kit_billing_number_sequences"]

  # V8's trash columns and indexes go on the way down too.
  defp v8_drop do
    for table <- ~w(orders invoices),
        stmt <- [
          "DROP INDEX IF EXISTS public.phoenix_kit_#{table}_not_trashed_idx",
          "DROP INDEX IF EXISTS public.phoenix_kit_#{table}_trashed_idx",
          "ALTER TABLE public.phoenix_kit_#{table} DROP COLUMN IF EXISTS trashed_at",
          "ALTER TABLE public.phoenix_kit_#{table} DROP COLUMN IF EXISTS trashed_by_uuid"
        ],
        do: stmt
  end

  describe "the order of the statements" do
    test "the base tables come before the first statement that touches them" do
      statements = Migrations.up_statements("public")

      index = fn fun -> Enum.find_index(statements, fun) end

      create_currencies =
        index.(&(&1 =~ ~r/CREATE TABLE IF NOT EXISTS public\.phoenix_kit_currencies \(/))

      create_orders =
        index.(&(&1 =~ ~r/CREATE TABLE IF NOT EXISTS public\.phoenix_kit_orders \(/))

      v2 = index.(&(&1 =~ "UPDATE public.phoenix_kit_currencies SET is_default = false"))

      v3 =
        index.(
          &(&1 =~ "ALTER TABLE public.phoenix_kit_orders ADD COLUMN IF NOT EXISTS base_currency")
        )

      assert create_currencies < v2
      assert create_orders < v3
    end

    test "a target below 6 builds the chain as it was" do
      for target <- 1..5 do
        statements = Migrations.up_statements("public", target)
        refute Enum.any?(statements, &(&1 =~ "to_regclass")), "target #{target}"
      end
    end

    test "down from V6 only rewrites the marker" do
      assert [marker] = (Migrations.down_statements("public", 5) -- v7_drop()) -- v8_drop()
      assert marker =~ "pkb_schema:5"
    end
  end

  describe "seeds" do
    setup do
      Repo.query!("DROP SCHEMA IF EXISTS #{@schema} CASCADE")
      Repo.query!("CREATE SCHEMA #{@schema}")

      # The chain's FKs need a users table and a uuid function in its schema.
      Repo.query!("CREATE TABLE #{@schema}.phoenix_kit_users (uuid uuid PRIMARY KEY)")

      Repo.query!(
        "CREATE FUNCTION #{@schema}.uuid_generate_v7() RETURNS uuid LANGUAGE sql AS 'SELECT public.uuid_generate_v7()'"
      )

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.query!("DROP SCHEMA IF EXISTS #{@schema} CASCADE")
        end)
      end)

      :ok
    end

    defp build, do: Enum.each(Migrations.up_statements(@schema), &Repo.query!/1)

    defp codes(table),
      do: Repo.query!("SELECT code FROM #{@schema}.#{table} ORDER BY code").rows |> List.flatten()

    test "a database the chain builds gets core's seed rows, with one default currency" do
      build()

      assert codes("phoenix_kit_currencies") == ~w(EUR GBP USD)
      assert codes("phoenix_kit_payment_options") == ~w(bank_transfer cod paypal stripe)

      assert [[1, "EUR"]] =
               Repo.query!(
                 "SELECT count(*), max(code) FROM #{@schema}.phoenix_kit_currencies WHERE is_default"
               ).rows
    end

    test "a second run restores nothing a host deleted" do
      build()
      Repo.query!("DELETE FROM #{@schema}.phoenix_kit_currencies WHERE code = 'GBP'")
      Repo.query!("DELETE FROM #{@schema}.phoenix_kit_payment_options WHERE code = 'cod'")

      build()

      assert codes("phoenix_kit_currencies") == ~w(EUR USD)
      assert codes("phoenix_kit_payment_options") == ~w(bank_transfer paypal stripe)
    end
  end
end
