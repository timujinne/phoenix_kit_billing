defmodule PhoenixKitBilling.MigrationsNumberSequencesTest do
  @moduledoc """
  V7 creates `phoenix_kit_billing_number_sequences`, the counter behind order,
  invoice, receipt and transaction numbers. Built in a scratch schema on the test
  database, the same way the V6 seed tests do.
  """

  use PhoenixKitBilling.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitBilling.Migrations

  @schema "pkb_v7_seq_test"
  @table "phoenix_kit_billing_number_sequences"

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

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)

  defp table_exists? do
    Repo.query!("SELECT to_regclass('#{@schema}.#{@table}') IS NOT NULL").rows == [[true]]
  end

  test "up builds the table with its columns and a (scope, year) primary key" do
    run(Migrations.up_statements(@schema))

    assert table_exists?()

    assert [
             ["last_value", "bigint", "NO"],
             ["scope", "character varying", "NO"],
             ["updated_at", "timestamp with time zone", "NO"],
             ["year", "integer", "NO"]
           ] =
             Repo.query!(
               """
               SELECT column_name, data_type, is_nullable FROM information_schema.columns
               WHERE table_schema = $1 AND table_name = $2 ORDER BY column_name
               """,
               [@schema, @table]
             ).rows

    assert [["scope"], ["year"]] =
             Repo.query!("""
             SELECT a.attname FROM pg_index i
             JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
             WHERE i.indrelid = '#{@schema}.#{@table}'::regclass AND i.indisprimary
             ORDER BY a.attname
             """).rows
  end

  test "a second run neither fails nor touches the counter" do
    run(Migrations.up_statements(@schema))

    Repo.query!(
      "INSERT INTO #{@schema}.#{@table} (scope, year, last_value) VALUES ('order', 2026, 41)"
    )

    run(Migrations.up_statements(@schema))

    assert Repo.query!("SELECT last_value FROM #{@schema}.#{@table}").rows == [[41]]
  end

  test "updated_at defaults to now()" do
    run(Migrations.up_statements(@schema))

    Repo.query!(
      "INSERT INTO #{@schema}.#{@table} (scope, year, last_value) VALUES ('order', 2026, 1)"
    )

    assert Repo.query!("SELECT updated_at IS NOT NULL FROM #{@schema}.#{@table}").rows == [[true]]
  end

  test "down below 7 drops the table, down to 7 keeps it" do
    run(Migrations.up_statements(@schema))

    run(Migrations.down_statements(@schema, 7))
    assert table_exists?()

    run(Migrations.down_statements(@schema, 6))
    refute table_exists?()
  end
end
