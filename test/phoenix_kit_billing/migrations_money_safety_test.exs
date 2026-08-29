defmodule PhoenixKitBilling.MigrationsMoneySafetyTest do
  use PhoenixKitBilling.DataCase, async: false

  alias Ecto.Migration.Runner
  alias PhoenixKitBilling.Migrations

  @moduledoc """
  The acceptance the money tables actually need, and that no static test
  can give: REAL rows in the adopted tables, a REAL `down/1` run as a
  migration, and the rows still there afterwards.

  `migrations_test.exs` proves what the chain BUILDS (no DROP/TRUNCATE/
  DELETE token anywhere, `down/1` emits marker bookkeeping only). That is
  a proof about text. This file proves what the chain DOES to a database
  that holds invoices, orders and transactions — the thing a reader of a
  green suite actually wants to know before rolling a billing release
  back.

  The last test is the mutation check: it runs the same survival harness
  against a deliberately destructive rollback and requires it to FAIL.
  Without that, a survival assertion that silently stopped asserting
  (wrong table name, empty row set) would stay green forever and prove
  nothing — the lesson this package already paid for once in B007.

  `async: false` — rows are seeded outside the usual fixtures and the
  migrator wants the shared sandbox connection.
  """

  @money_tables ~w(
    phoenix_kit_orders
    phoenix_kit_invoices
    phoenix_kit_transactions
    phoenix_kit_payment_provider_configs
  )

  defmodule RollbackToZero do
    @moduledoc false
    use Ecto.Migration

    def up, do: Migrations.down(prefix: "public", version: 0)
    def down, do: :ok
  end

  defmodule DestructiveRollback do
    @moduledoc false
    use Ecto.Migration

    # NOT what the package ships — the mutant the survival check must catch.
    def up do
      execute("DELETE FROM public.phoenix_kit_transactions")
      execute("DELETE FROM public.phoenix_kit_invoices")
    end

    def down, do: :ok
  end

  setup do
    seeded = seed_money_rows()
    {:ok, seeded: seeded}
  end

  test "a real down(version: 0) leaves every seeded money row alive", %{seeded: seeded} do
    before_counts = counts()

    run_migration(RollbackToZero)

    assert counts() == before_counts,
           "rolling this chain back changed row counts in money tables"

    for {table, uuid} <- seeded do
      assert row_exists?(table, uuid),
             "#{table}: the seeded row did not survive down(version: 0)"
    end
  end

  test "the rollback still does its one real job: the marker is cleared" do
    Repo.query!("COMMENT ON TABLE phoenix_kit_payment_provider_configs IS 'pkb_schema:2'")
    assert Migrations.migrated_version_runtime(prefix: "public") == 2

    run_migration(RollbackToZero)

    assert Migrations.migrated_version_runtime(prefix: "public") == 0
  end

  test "the survival check has teeth: a destructive rollback fails it", %{seeded: seeded} do
    before_counts = counts()

    run_migration(DestructiveRollback)

    # The same two assertions the real test makes. Both must fail here, or
    # the real test above is decoration.
    assert_raise ExUnit.AssertionError, fn ->
      assert counts() == before_counts
    end

    assert_raise ExUnit.AssertionError, fn ->
      for {table, uuid} <- seeded do
        assert row_exists?(table, uuid)
      end
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  # Runs the migration IN THIS PROCESS, through Ecto's own migration
  # runner, rather than `Ecto.Migrator.up/4`. The Migrator runs the
  # migration inside a `Task`, which then has to check out the sandbox
  # connection this test already owns — it never gets it, and every
  # assertion below dies in the checkout queue instead of testing the
  # rollback. The runner is what the Migrator itself calls once it has
  # dealt with locking and version bookkeeping; going straight to it keeps
  # the real migration context (so `execute/1` inside `down/1` is the real
  # `execute/1`) and drops only the parts this file is not about.
  defp run_migration(module) do
    Runner.run(
      Repo,
      [],
      :os.system_time(:microsecond),
      module,
      :forward,
      :up,
      :up,
      log: false,
      log_migrations_sql: false
    )
  end

  defp counts do
    Map.new(@money_tables, fn table ->
      %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{table}")
      {table, count}
    end)
  end

  defp row_exists?(table, uuid) do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM #{table} WHERE uuid = $1", [uuid])
    count == 1
  end

  defp seed_money_rows do
    # The struct carries the UUID as a string; a raw parameterised query
    # needs the 16-byte binary Postgres actually stores.
    user_uuid = fixture_user().uuid |> Ecto.UUID.dump!()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    tag = System.unique_integer([:positive])

    order =
      insert_returning_uuid(
        "INSERT INTO phoenix_kit_orders (order_number, total, user_uuid, inserted_at, updated_at)
         VALUES ($1, $2, $3, $4, $4) RETURNING uuid",
        ["B009-#{tag}", Decimal.new("42.00"), user_uuid, now]
      )

    invoice =
      insert_returning_uuid(
        "INSERT INTO phoenix_kit_invoices (invoice_number, total, user_uuid, order_uuid, inserted_at, updated_at)
         VALUES ($1, $2, $3, $4, $5, $5) RETURNING uuid",
        ["INV-B009-#{tag}", Decimal.new("42.00"), user_uuid, order, now]
      )

    transaction =
      insert_returning_uuid(
        "INSERT INTO phoenix_kit_transactions (transaction_number, amount, user_uuid, invoice_uuid, inserted_at, updated_at)
         VALUES ($1, $2, $3, $4, $5, $5) RETURNING uuid",
        ["TX-B009-#{tag}", Decimal.new("42.00"), user_uuid, invoice, now]
      )

    config =
      insert_returning_uuid(
        "INSERT INTO phoenix_kit_payment_provider_configs (provider, inserted_at, updated_at)
         VALUES ($1, $2, $2) RETURNING uuid",
        ["b009-#{tag}", now]
      )

    %{
      "phoenix_kit_orders" => order,
      "phoenix_kit_invoices" => invoice,
      "phoenix_kit_transactions" => transaction,
      "phoenix_kit_payment_provider_configs" => config
    }
  end

  defp insert_returning_uuid(sql, params) do
    %{rows: [[uuid]]} = Repo.query!(sql, params)
    uuid
  end
end
