defmodule PhoenixKitBilling.MigrationsTrashTest do
  @moduledoc """
  V8 adds `trashed_at` / `trashed_by_uuid` and two partial indexes to the
  core-created `phoenix_kit_orders` and `phoenix_kit_invoices`. Built in a
  scratch schema on the test database, the same way the V7 tests do. The way
  down drops the columns and indexes and never a table.
  """

  use PhoenixKitBilling.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitBilling.Migrations

  @schema "pkb_v8_trash_test"

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

  defp columns(table) do
    Repo.query!(
      """
      SELECT column_name, data_type, is_nullable FROM information_schema.columns
      WHERE table_schema = $1 AND table_name = $2 AND column_name LIKE 'trashed%'
      ORDER BY column_name
      """,
      [@schema, table]
    ).rows
  end

  defp indexes(table) do
    Repo.query!(
      """
      SELECT indexname, indexdef FROM pg_indexes
      WHERE schemaname = $1 AND tablename = $2 AND indexname LIKE '%trashed%'
      ORDER BY indexname
      """,
      [@schema, table]
    ).rows
  end

  defp table_exists?(table) do
    Repo.query!("SELECT to_regclass('#{@schema}.#{table}') IS NOT NULL").rows == [[true]]
  end

  for table <- ~w(phoenix_kit_orders phoenix_kit_invoices) do
    test "up gives #{table} nullable trashed_at and trashed_by_uuid" do
      run(Migrations.up_statements(@schema))

      assert [
               ["trashed_at", "timestamp with time zone", "YES"],
               ["trashed_by_uuid", "uuid", "YES"]
             ] = columns(unquote(table))
    end

    test "up builds the partial indexes on #{table}" do
      run(Migrations.up_statements(@schema))

      assert [[not_trashed, not_trashed_def], [trashed, trashed_def]] = indexes(unquote(table))

      assert not_trashed == "#{unquote(table)}_not_trashed_idx"
      assert not_trashed_def =~ "(inserted_at)"
      assert not_trashed_def =~ "WHERE (trashed_at IS NULL)"

      assert trashed == "#{unquote(table)}_trashed_idx"
      assert trashed_def =~ "(trashed_at)"
      assert trashed_def =~ "WHERE (trashed_at IS NOT NULL)"
    end
  end

  test "a second run neither fails nor touches the trash state of a row" do
    run(Migrations.up_statements(@schema))

    Repo.query!("""
    INSERT INTO #{@schema}.phoenix_kit_orders (order_number, status, total, currency, inserted_at, updated_at, trashed_at)
    VALUES ('ORD-2026-0001', 'draft', 1, 'EUR', now(), now(), now())
    """)

    run(Migrations.up_statements(@schema))

    assert Repo.query!(
             "SELECT count(*) FROM #{@schema}.phoenix_kit_orders WHERE trashed_at IS NOT NULL"
           ).rows ==
             [[1]]
  end

  test "up from a database at V7 adds the columns and keeps the rows" do
    run(Migrations.up_statements(@schema, 7))
    assert columns("phoenix_kit_orders") == []

    Repo.query!("""
    INSERT INTO #{@schema}.phoenix_kit_orders (order_number, status, total, currency, inserted_at, updated_at)
    VALUES ('ORD-2026-0001', 'draft', 1, 'EUR', now(), now())
    """)

    run(Migrations.up_statements(@schema))

    assert length(columns("phoenix_kit_orders")) == 2

    assert Repo.query!(
             "SELECT count(*) FROM #{@schema}.phoenix_kit_orders WHERE trashed_at IS NULL"
           ).rows == [[1]]
  end

  test "down below 8 drops the columns and the indexes and keeps both tables and their rows" do
    run(Migrations.up_statements(@schema))

    Repo.query!("""
    INSERT INTO #{@schema}.phoenix_kit_orders (order_number, status, total, currency, inserted_at, updated_at, trashed_at)
    VALUES ('ORD-2026-0001', 'draft', 1, 'EUR', now(), now(), now())
    """)

    run(Migrations.down_statements(@schema, 8))
    assert length(columns("phoenix_kit_orders")) == 2

    run(Migrations.down_statements(@schema, 7))

    for table <- ~w(phoenix_kit_orders phoenix_kit_invoices) do
      assert table_exists?(table)
      assert columns(table) == []
      assert indexes(table) == []
    end

    assert Repo.query!("SELECT count(*) FROM #{@schema}.phoenix_kit_orders").rows == [[1]]

    # V7's counter is untouched by going down to 7.
    assert table_exists?("phoenix_kit_billing_number_sequences")
  end

  test "down and up again is a round trip" do
    run(Migrations.up_statements(@schema))
    run(Migrations.down_statements(@schema, 7))
    run(Migrations.up_statements(@schema))

    assert length(columns("phoenix_kit_invoices")) == 2
    assert length(indexes("phoenix_kit_invoices")) == 2
  end
end
