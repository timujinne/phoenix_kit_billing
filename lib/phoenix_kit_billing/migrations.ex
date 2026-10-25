defmodule PhoenixKitBilling.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_billing` — the
  decentralized-migrations protocol that core's `mix phoenix_kit.update`
  discovers via `migration_module/0`: `current_version/0` +
  `migrated_version_runtime/1` + idempotent `up/1` + version-aware
  `down/1`. `phoenix_kit_legal` (over `phoenix_kit_consent_logs`) is the
  closest sibling example of this exact situation — a core-created table
  whose future shape a module chain adopts.

  ## Ownership situation — read before touching

  `phoenix_kit_payment_provider_configs` is one of core's V135 baseline
  tables. Nothing in this package's `lib/` reads or writes it today — it
  is currently orphaned application-code-wise, though core still creates
  it (and can still roll it back on its own baseline `down`). Payment
  provider credentials this package actually reads and writes today live
  in `phoenix_kit_settings`, via `PhoenixKitBilling.Providers` — this
  version changes NONE of that.

  V1 is purely an ADOPTION step:

    * on existing installs the table is already there (core V135), the
      `CREATE TABLE IF NOT EXISTS` finds it, and the only new object is
      the `pkb_schema:1` marker — from then on this chain owns the
      table's future shape;
    * on a hypothetical future install whose core baseline no longer
      creates the table, the same statements create it — shape-identical
      to core's V135, with core's exact index and constraint names.

  Because V1 changes no shape, core's `ExpectedSchema` manifest (which
  still audits the V135 shape of this table) stays accurate and NO core
  release is required for this version.

  ## What `down/1` is NOT

  `down/1` unstamps the version marker; it NEVER drops
  `phoenix_kit_payment_provider_configs`. The table is core-created, and
  rolling back this module's chain must not destroy it — only core's own
  baseline rollback does that. The same invariant holds for V2 below —
  `down/1` never drops a core-created table, even one whose shape this
  chain now owns.

  The migrated version is tracked as a `pkb_schema:<N>` COMMENT on
  `phoenix_kit_payment_provider_configs` (the marker convention from the
  projects/legal chains, namespaced). A marker-less table reads as
  version 0 — the core-baseline shape before this chain existed.

  ## V2 — `phoenix_kit_currencies` gets a shape

  `phoenix_kit_currencies` is likewise a core-created table (V31
  baseline), and likewise untouched by V1 above (an unrelated table). V2
  is this chain's first shape-CHANGING step, entirely on
  `phoenix_kit_currencies`:

    * a partial unique index `phoenix_kit_currencies_default_uidx` on
      `(is_default) WHERE is_default` — today uniqueness of the default
      currency is held only by the transaction in
      `set_default_currency/1`, not by the database: two
      `is_default = true` rows raise `Ecto.MultipleResultsError` out of
      `get_default_currency/0` (`Ecto.Repo.one/2`). This index is also a
      prerequisite for a `LIMIT`-less `WHERE is_default` backfill a future
      chain runs against this table, so it must exist before that
      backfill runs, not merely by the time it finishes.
      A host can already BE in the two-default state the index forbids, so
      V2 demotes every default but one (lowest `sort_order`, then oldest)
      immediately before creating the index — otherwise `CREATE UNIQUE
      INDEX` aborts the whole chain on exactly those databases. That
      `UPDATE` is the one row-level write this chain makes to a
      core-created table, and it only repairs a state no reader can
      handle: `get_default_currency/0` raises on it today.
    * `rounding_rule character varying(16) NOT NULL DEFAULT 'exact'` and
      `rate_updated_at timestamp with time zone` — both additions with no
      reader anywhere in this version; the default reproduces today's
      rounding behavior exactly, so nothing observable changes for any
      host that migrates to V2.

  Both ride in the same chain version because this chain moves one
  version per module per release, not one version per column. `down/1`
  to below V2 drops the index and both columns — never the table.

  ## V3 — `phoenix_kit_orders` gets its frozen-currency columns

  `phoenix_kit_orders` is another core-created table this chain does not
  otherwise own. `PhoenixKitBilling.Order` (§4.5/§9.1 of the per-domain-
  currency spec) declares `base_currency`, `exchange_rate` and
  `base_total` — the shop's base currency and the rate an order was
  actually priced at, frozen at creation — but the core release that was
  originally meant to add these columns (an unreleased "V186", adding the
  identical three columns with the identical types) had not shipped to
  Hex when the schema change did. Any host resolving the currently
  published core got an `Order` struct whose SELECT lists columns the
  database does not have, and `Ecto.Repo.all/2`/`get/2`/`one/2` on
  `Order` — hit by `list_orders/1`, `get_order/1`, the user dashboard's
  orders LiveView, `delete_order/1` — all raised
  `Postgrex.Error (undefined_column)` instead of returning data.

  V3 closes that gap the same way V2 closed one on `phoenix_kit_currencies`:
  this chain adds the columns itself rather than waiting on a core
  release. The three `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` statements
  use the exact names and types core's own eventual migration does, so
  the day that core release ships, its `ADD COLUMN IF NOT EXISTS` finds
  the columns already here and no-ops — and its backfill (deriving
  `base_currency`/`exchange_rate`/`base_total` for pre-existing rows from
  `phoenix_kit_currencies`) still runs and still does useful work,
  because V3 deliberately adds the columns nullable with NO backfill of
  its own: inventing a derivation here would duplicate — and risk
  disagreeing with — logic that belongs to whichever release actually
  owns getting it right. Every reader of these three fields already
  treats `nil` as "unknown", per `Order`'s own moduledoc, so an
  unbackfilled column breaks nothing between V3 and that release.

  `down/1` to below V3 drops the three columns — never the table, same
  invariant as V1/V2.

  ## V4 — adoption of the remaining ten core-baseline tables

  Every other `phoenix_kit_billing` table is, like V1's and V2/V3's
  target tables, a core baseline table: core's V135 created them, and
  later core versions have amended some (V162 added
  `payment_option_uuid`, its FK and its index to `phoenix_kit_orders`;
  V164 renamed the `subscription_types` slug index). V4 ADOPTS that
  shape, table by table, for the ten this chain did not already reach:
  billing profiles, currencies, invoices, orders, transactions, payment
  methods, subscriptions, webhook events, payment options, subscription
  types.

  Same Phase-0 contract as V1: every statement reproduces core's shape
  for the table under core's exact object names, so an install where
  core already created these tables sees a pure no-op and the only new
  object is the version marker. On a future install whose core baseline
  no longer creates them, the same statements create them.

  For `phoenix_kit_currencies` and `phoenix_kit_orders` specifically, V4's
  `CREATE TABLE` intentionally reproduces the base V135 shape ONLY — it
  does not repeat `rounding_rule`/`rate_updated_at` (owned by V2 above)
  or `base_currency`/`exchange_rate`/`base_total` (owned by V3 above).
  Those columns are this chain's own later versions' property; restating
  them here would either duplicate V2/V3's `ADD COLUMN IF NOT EXISTS` (at
  best redundant) or drift from their exact DDL (at worst wrong).

  Statement order is load-bearing: tables, then primary keys and unique
  constraints, then indexes, then foreign keys last — by which point
  every referenced table and referenced key exists, whatever order the
  tables themselves were created in.

  **A known, undocumented-by-fix ordering gap:** on a real install, core's
  baseline always creates `phoenix_kit_currencies`/`phoenix_kit_orders`
  before this chain runs, so V2's and V3's `ALTER TABLE` statements
  always find their table — this is the situation every real host is in
  today. But this chain's own stated hypothetical for V1-V3 — "a future
  core baseline that no longer creates these tables" — has a gap for
  these two tables specifically: `up_statements/2` runs `v1 ++ v2 ++ v3
  ++ v4` in that order, so on such a hypothetical fresh install, V2's
  `ALTER TABLE phoenix_kit_currencies` and V3's `ALTER TABLE
  phoenix_kit_orders` would run BEFORE V4's `CREATE TABLE` for those same
  tables — and fail. This gap already exists for V2 and V3 today (both
  already assume the table pre-exists, independently of V4); V4 does not
  introduce it, it only inherits it for two of its ten tables. Fixing it
  would mean reordering V1-V3, which are published and frozen — left as
  a known limitation rather than silently ignored. **Closed by V6 below**,
  which emits the base shape of those two tables ahead of V2 without touching
  the published versions.

  `down/1` to below V4 never drops any of the ten tables — same
  invariant as V1/V2/V3, and, like V1, V4 changes no shape of its own
  (it only creates what core's baseline already creates), so there is
  nothing for `down/1` to undo beyond the marker.

  ## V6 — the tables V2 and V3 alter, created before them

  The "known ordering gap" in V4's section above is closed here. V2 and V3
  alter `phoenix_kit_currencies` and `phoenix_kit_orders`, but V4 creates them,
  so on a database without core's copy V2's `UPDATE` failed on a missing table
  and nothing was adopted. V6 emits the base `CREATE TABLE IF NOT EXISTS` of
  those two tables (the same text V4 uses — shared, not copied) **between V1
  and V2**, ahead of the first statement that touches them. The version is
  still the next number; shipped versions' own statements are not edited, and
  a target below 6 builds the chain as it was. On every existing install the
  tables are there and V6 does nothing.

  Core's V135 also seeds rows into `phoenix_kit_currencies` (EUR default, GBP,
  USD) and `phoenix_kit_payment_options` (bank_transfer, cod, paypal, stripe).
  V6 carries them, but only as part of creating the table (one `DO` block each,
  guarded by `to_regclass`), so they appear on a database this chain builds and
  never over a host's own rows. Re-running them with `ON CONFLICT DO NOTHING`
  would restore currencies or options an operator deleted, and the seeded EUR
  default would collide with `phoenix_kit_currencies_default_uidx` on a host
  whose default is another currency. `phoenix_kit_payment_options` is created in
  the same block (V4 then finds it).

  `down/1` below V6 only moves the marker and never drops a table.

  ## V5 — a payer need not have an account

  `phoenix_kit_invoices.user_uuid` and `phoenix_kit_transactions.user_uuid`
  drop `NOT NULL`. An invoice's payer is now EITHER a user OR a billing
  email in `billing_details` — enforced by the
  `phoenix_kit_invoices_payer_check` CHECK as well as the changeset — so a
  module can take money from someone who never registered (a guest paying
  for a booking) without inventing an account for them. Existing rows all
  have a user; nothing is rewritten.

  Transactions follow: a provider-confirmed payment on a guest invoice has
  no admin actor and no invoice user, and with `NOT NULL` its insert failed
  — the card charged, the invoice left unpaid.

  Core's `ExpectedSchema` still records both columns as `NOT NULL`, but
  its differ deliberately does not compare `not_null` for a `NOT NULL`
  column with no default (its own repair can never re-create one), so
  `mix phoenix_kit.repair` reports nothing here.

  `down/1` to below V5 **refuses** while guest invoices or transactions
  exist: re-adding `NOT NULL` would fail anyway, and the only way to make
  it succeed would be to delete or re-attribute money records, which a
  rollback must never do silently.

  ## V7 — a counter for order, invoice, receipt and transaction numbers

  Numbers used to be `count(rows of the year) + 1`. Delete any row of the year
  but the last and the count falls behind a number already taken: the insert
  fails on the unique index, and keeps failing, because the count no longer
  grows. Two concurrent creates read the same count and collide the same way.

  V7 creates `phoenix_kit_billing_number_sequences` — `(scope, year)` primary
  key, `last_value`, `updated_at` — the counter the numbers now come from
  (`scope` is `order`, `invoice`, `receipt` or `transaction`). The code takes a
  number with a row-locking `UPDATE` inside the transaction that inserts the
  row using it, so creates queue up, a rolled-back insert gives its number
  back, and deleting a row never frees one. A scope with no row yet for the
  year is seeded from the rows already there (the larger of their count and
  their highest number), so an existing install continues where it was.

  Numbers taken outside the counter are met in two ways. A number the caller
  types, or changes a row to, that has this year's shape with the configured
  prefix (`PREFIX-YYYY-NNNN`) lifts the counter to at least NNNN without using
  a value. A generated number that a row already has (a node that still counts
  rows, or a number typed in another shape) is skipped: the insert runs in a
  savepoint, and on a unique-index conflict on that number the counter is
  first lifted to the highest number of the year with the configured prefix
  (so a long run is stepped over at once), then the next number is tried, up
  to 20 times, each skipped number staying used up. If all 20 are taken the
  create returns `{:error, changeset}` with an error on the number field and
  the counter left past them. Only numbers zero-padded to four digits or more
  (`ORD-2026-0007`, as the counter writes them) count. Receipts have no unique
  index, so nothing is skipped there.

  **Run V7 before the code that uses it.** Without the table every create
  raises `undefined_table`. Old nodes that still number by `count + 1` can keep
  running next to new ones for a while - the skip above steps over the numbers
  they take - but finish the rollout quickly: an old node can also meet a
  number the counter issued, and its create then fails on the unique index.

  Unlike every table above, this one is created by this chain, not by core, so
  `down/1` below V7 drops it. A later `up/1` then reseeds from the rows that
  survive, so the numbers of deleted top rows can come back.

  Locks. A create holds its counter row until its transaction ends. Take them
  in this order, everywhere: order counter, invoice counter, invoice row,
  transaction counter, receipt counter, order row (`FOR NO KEY UPDATE`). (An
  `update_invoice` that changes a number locks the invoice row first, then
  lifts the counters - no other path waits on that row while holding a counter
  it needs.) A host
  that wraps several creates in one transaction must keep that order, or two of
  them can deadlock (Postgres aborts one). The subscription renewal worker
  creates its invoice inside the transaction that also charges the payment
  method, so it holds the invoice counter across the provider call: other
  invoice creates wait for the charge to finish.
  """

  use Ecto.Migration

  @current_version 7
  @marker_prefix "pkb_schema:"
  @version_table "phoenix_kit_payment_provider_configs"

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The table carrying the `pkb_schema:<N>` marker (auditor contract)."
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc """
  The chain version currently applied in the database, read OUTSIDE a
  migration (the protocol shape core's update task calls — `opts` with
  `:prefix`): the `pkb_schema:<N>` marker when present; a marker-less or
  foreign-comment table reads as `0` (core-baseline shape — V1 is purely
  adoptive, there is no pre-chain content to defend).
  """
  def migrated_version_runtime(opts \\ []) do
    prefix = validated_prefix(opts)

    # classoid anchors the description join to pg_class (the projects/
    # legal chains' convention).
    query = """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = '#{@version_table}' AND c.relkind = 'r'
    """

    case PhoenixKit.RepoHelper.repo().query(query, [prefix]) do
      {:ok, %{rows: [[@marker_prefix <> n]]}} -> parse_version(n)
      _ -> 0
    end
  rescue
    # An invalid prefix must surface as the validation error, not be
    # swallowed into 0 ("not installed") — that misleads the operator AND
    # lets the unvalidated string reach interpolated SQL in callers'
    # fallback paths.
    e in ArgumentError ->
      reraise e, __STACKTRACE__

    _ ->
      0
  end

  @doc "Applies every chain version up to `target` (`:version` in `opts`, default `current_version/0`); idempotent."
  def up(opts \\ []) do
    prefix = validated_prefix(opts)
    target = target_version(opts, @current_version)

    prefix
    |> up_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc "Rolls back to `target` (`:version` in `opts`). Never drops a core-created table — see the moduledoc."
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    target = target_version(opts, 0)

    prefix
    |> down_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. The
  ownership test parses these statements to prove that the object names
  are core's V135 names, that the CREATE TABLE stays shape-identical to
  core's `ExpectedSchema` manifest, and that nothing here can drop the
  table.

  `target` selects how much of the chain to emit (default
  `current_version/0`): `0` applies nothing (not an operation — clearing
  the marker is `down/1`'s job); `1` is the pure V135-adoption step on
  `phoenix_kit_payment_provider_configs`; `2` additionally shapes
  `phoenix_kit_currencies` (partial unique default-currency index,
  `rounding_rule`, `rate_updated_at`); `3` additionally adds
  `phoenix_kit_orders`' frozen-currency columns; `4` additionally adopts
  the remaining ten core-baseline tables (see the moduledoc); `7`
  additionally creates the number sequences table.
  """
  @spec up_statements(String.t(), non_neg_integer()) :: [String.t()]
  def up_statements(prefix \\ "public", target \\ @current_version)

  def up_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    if target == 0 do
      # "Apply up to version 0" is not an operation: there is nothing to
      # apply, and stamping `pkb_schema:0` would be the only statement in
      # this function that assumes the marker-carrying table already
      # exists. Clearing the marker is `down/1`'s job.
      []
    else
      v1 = [
        """
        CREATE TABLE IF NOT EXISTS #{p}#{@version_table} (
          "provider" character varying(20) NOT NULL,
          "enabled" boolean DEFAULT false NOT NULL,
          "mode" character varying(10) DEFAULT 'test'::character varying NOT NULL,
          "api_key" text,
          "api_secret" text,
          "webhook_secret" text,
          "webhook_url" character varying(255),
          "last_verified_at" timestamp with time zone,
          "verification_status" character varying(20) DEFAULT 'pending'::character varying,
          "verification_error" text,
          "config" jsonb DEFAULT '{}'::jsonb NOT NULL,
          "inserted_at" timestamp with time zone NOT NULL,
          "updated_at" timestamp with time zone NOT NULL,
          "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL
        )
        """,
        """
        DO $$
        BEGIN
          IF NOT EXISTS (
            SELECT 1
            FROM pg_constraint c
            JOIN pg_class t ON t.oid = c.conrelid
            JOIN pg_namespace n ON n.oid = t.relnamespace
            WHERE c.conname = '#{@version_table}_pkey'
              AND t.relname = '#{@version_table}'
              AND n.nspname = '#{prefix}'
          ) THEN
            ALTER TABLE #{p}#{@version_table} ADD CONSTRAINT #{@version_table}_pkey PRIMARY KEY (uuid);
          END IF;
        END
        $$
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS #{@version_table}_provider_uidx ON #{p}#{@version_table} USING btree (provider)",
        "CREATE UNIQUE INDEX IF NOT EXISTS #{@version_table}_uuid_idx ON #{p}#{@version_table} USING btree (uuid)"
      ]

      # V6: the tables V2 and V3 alter, created before them (see the moduledoc).
      v6 = if target >= 6, do: v6_statements(p), else: []

      v2 =
        if target >= 2 do
          [
            # The index below is created on a table that is ALREADY allowed
            # to hold two `is_default` rows — that is the very defect V2
            # exists to close, and `create_currency/1` / `update_currency/2`
            # can still produce it today. `CREATE UNIQUE INDEX` on such a
            # table aborts with a unique violation, so the migration would
            # fail on precisely the databases that need it. Demote every
            # default but one (lowest `sort_order`, then oldest) first. A
            # table with zero or one default row is untouched: the subselect
            # is NULL and `uuid <> NULL` matches nothing.
            """
            UPDATE #{p}phoenix_kit_currencies SET is_default = false
            WHERE is_default
              AND uuid <> (
                SELECT uuid FROM #{p}phoenix_kit_currencies
                WHERE is_default
                ORDER BY sort_order, inserted_at, uuid
                LIMIT 1
              )
            """,
            # §9.1/§3.2 of the currency design spec: the index must exist
            # before the core backfill that assumes a single `is_default`
            # row runs — billing (this chain) migrates before core in the
            # documented release order.
            "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_currencies_default_uidx ON #{p}phoenix_kit_currencies USING btree (is_default) WHERE is_default",
            "ALTER TABLE #{p}phoenix_kit_currencies ADD COLUMN IF NOT EXISTS rounding_rule character varying(16) DEFAULT 'exact' NOT NULL",
            "ALTER TABLE #{p}phoenix_kit_currencies ADD COLUMN IF NOT EXISTS rate_updated_at timestamp with time zone"
          ]
        else
          []
        end

      v3 =
        if target >= 3 do
          [
            "ALTER TABLE #{p}phoenix_kit_orders ADD COLUMN IF NOT EXISTS base_currency character varying(3)",
            "ALTER TABLE #{p}phoenix_kit_orders ADD COLUMN IF NOT EXISTS exchange_rate numeric(15,6)",
            "ALTER TABLE #{p}phoenix_kit_orders ADD COLUMN IF NOT EXISTS base_total numeric(15,2)"
          ]
        else
          []
        end

      v4 = if target >= 4, do: v4_statements(prefix, p), else: []

      v5 = if target >= 5, do: v5_statements(prefix, p), else: []

      v7 = if target >= 7, do: v7_statements(p), else: []

      v1 ++
        v6 ++
        v2 ++
        v3 ++
        v4 ++
        v5 ++ v7 ++ ["COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"]
    end
  end

  # V6 — the base shape of the tables V2 and V3 alter, emitted between V1 and
  # V2 (see the moduledoc). Each statement is a no-op wherever core created the
  # table. Core's V135 also seeds rows into two of them; the seed is part of
  # creating the table here, in the same `DO` block, so it runs only when this
  # chain creates the table — never over a host's own currencies or payment
  # options, which it would otherwise restore after they were deleted (or
  # collide with, as a second default currency).
  defp v6_statements(p) do
    [
      """
      DO $$
      BEGIN
        IF to_regclass('#{p}phoenix_kit_currencies') IS NULL THEN
          #{currencies_table(p)};
          INSERT INTO #{p}phoenix_kit_currencies ("code", "decimal_places", "enabled", "exchange_rate", "is_default", "name", "sort_order", "symbol", "inserted_at", "updated_at")
          VALUES ('EUR', 2, TRUE, '1.000000', TRUE, 'Euro', 1, '€', NOW(), NOW()),
                 ('GBP', 2, TRUE, '0.850000', FALSE, 'British Pound', 3, '£', NOW(), NOW()),
                 ('USD', 2, TRUE, '1.100000', FALSE, 'US Dollar', 2, '$', NOW(), NOW());
        END IF;
      END
      $$
      """,
      orders_table(p),
      """
      DO $$
      BEGIN
        IF to_regclass('#{p}phoenix_kit_payment_options') IS NULL THEN
          #{payment_options_table(p)};
          INSERT INTO #{p}phoenix_kit_payment_options ("code", "active", "description", "icon", "instructions", "name", "position", "provider", "requires_billing_profile", "settings", "type")
          VALUES ('bank_transfer', FALSE, 'Pay via bank transfer', 'hero-building-library', 'You will receive invoice with bank details after order confirmation.', 'Bank Transfer', 2, NULL, TRUE, '{}'::jsonb, 'offline'),
                 ('cod', TRUE, 'Pay when you receive your order', 'hero-banknotes', 'Payment will be collected upon delivery. Please have the exact amount ready.', 'Cash on Delivery', 1, NULL, TRUE, '{}'::jsonb, 'offline'),
                 ('paypal', FALSE, 'Pay securely with your PayPal account', 'hero-credit-card', NULL, 'PayPal', 4, 'paypal', FALSE, '{}'::jsonb, 'online'),
                 ('stripe', FALSE, 'Secure payment with credit or debit card', 'hero-credit-card', NULL, 'Pay with Card', 3, 'stripe', FALSE, '{}'::jsonb, 'online');
        END IF;
      END
      $$
      """
    ]
  end

  # V7 — the counter behind order, invoice, receipt and transaction numbers (see the
  # moduledoc). A table of this chain's own, so `IF NOT EXISTS` is all the
  # idempotence it needs.
  defp v7_statements(p) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_billing_number_sequences (
        scope character varying(32) NOT NULL,
        year integer NOT NULL,
        last_value bigint NOT NULL,
        updated_at timestamp with time zone DEFAULT now() NOT NULL,
        PRIMARY KEY (scope, year)
      )
      """
    ]
  end

  # V5 — a payer need not have an account (see the moduledoc). Each step is
  # guarded by the catalog, the same DO-block idempotence V1 uses: the
  # column is made nullable only while it is NOT NULL, and the CHECK is
  # added only while it is absent — so a replay does nothing, and never
  # re-validates the CHECK against the whole table.
  defp v5_statements(prefix, p) do
    [
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = '#{prefix}' AND table_name = 'phoenix_kit_invoices'
            AND column_name = 'user_uuid' AND is_nullable = 'YES'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_invoices ALTER COLUMN user_uuid DROP NOT NULL;
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'phoenix_kit_invoices_payer_check'
            AND t.relname = 'phoenix_kit_invoices'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_invoices ADD CONSTRAINT phoenix_kit_invoices_payer_check
            CHECK (user_uuid IS NOT NULL OR NULLIF(billing_details->>'email', '') IS NOT NULL);
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = '#{prefix}' AND table_name = 'phoenix_kit_transactions'
            AND column_name = 'user_uuid' AND is_nullable = 'YES'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_transactions ALTER COLUMN user_uuid DROP NOT NULL;
        END IF;
      END
      $$
      """
    ]
  end

  defp currencies_table(p) do
    """
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_currencies (
      "code" character varying(3) NOT NULL,
      "name" character varying(255) NOT NULL,
      "symbol" character varying(5) NOT NULL,
      "decimal_places" integer DEFAULT 2 NOT NULL,
      "is_default" boolean DEFAULT false NOT NULL,
      "enabled" boolean DEFAULT true NOT NULL,
      "exchange_rate" numeric(15,6) DEFAULT 1 NOT NULL,
      "sort_order" integer DEFAULT 0 NOT NULL,
      "inserted_at" timestamp with time zone NOT NULL,
      "updated_at" timestamp with time zone NOT NULL,
      "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL
    )
    """
  end

  defp orders_table(p) do
    """
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_orders (
      "order_number" character varying(30) NOT NULL,
      "status" character varying(20) DEFAULT 'draft'::character varying NOT NULL,
      "payment_method" character varying(20),
      "line_items" jsonb DEFAULT '[]'::jsonb NOT NULL,
      "subtotal" numeric(15,2) DEFAULT 0 NOT NULL,
      "tax_amount" numeric(15,2) DEFAULT 0 NOT NULL,
      "tax_rate" numeric(5,4) DEFAULT 0 NOT NULL,
      "discount_amount" numeric(15,2) DEFAULT 0 NOT NULL,
      "discount_code" character varying(50),
      "total" numeric(15,2) NOT NULL,
      "currency" character varying(3) DEFAULT 'EUR'::character varying NOT NULL,
      "billing_snapshot" jsonb DEFAULT '{}'::jsonb,
      "notes" text,
      "internal_notes" text,
      "metadata" jsonb DEFAULT '{}'::jsonb,
      "confirmed_at" timestamp with time zone,
      "paid_at" timestamp with time zone,
      "cancelled_at" timestamp with time zone,
      "inserted_at" timestamp with time zone NOT NULL,
      "updated_at" timestamp with time zone NOT NULL,
      "checkout_session_id" character varying(255),
      "checkout_url" text,
      "checkout_expires_at" timestamp with time zone,
      "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
      "user_uuid" uuid,
      "billing_profile_uuid" uuid,
      "payment_option_uuid" uuid
    )
    """
  end

  defp payment_options_table(p) do
    """
    CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_payment_options (
      "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
      "name" character varying(255) NOT NULL,
      "code" character varying(50) NOT NULL,
      "type" character varying(20) DEFAULT 'offline'::character varying NOT NULL,
      "provider" character varying(50),
      "description" text,
      "instructions" text,
      "icon" character varying(100) DEFAULT 'hero-banknotes'::character varying,
      "active" boolean DEFAULT false,
      "position" integer DEFAULT 0,
      "requires_billing_profile" boolean DEFAULT true,
      "settings" jsonb DEFAULT '{}'::jsonb,
      "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
      "updated_at" timestamp with time zone DEFAULT now() NOT NULL
    )
    """
  end

  # V4 — adoption of the remaining ten core-baseline tables. `prefix` and
  # `p` are the already-validated forms `up_statements/2` derived — this
  # is a private helper of that single call site, not a second entry
  # point that could be handed a mismatched pair.
  #
  # Three index names are mangled per-schema (`pn` — core's own
  # `pn = if prefix == "public", do: "", else: "\#{prefix}_"`). Emitting
  # them bare would create a SECOND index next to core's under a named
  # schema instead of adopting it.
  defp v4_statements(prefix, p) do
    pn = if prefix == "public", do: "", else: "#{prefix}_"

    tables = [
      currencies_table(p),
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_subscription_types (
        "name" character varying(255) NOT NULL,
        "slug" character varying(255) NOT NULL,
        "description" text,
        "price" numeric(15,2) NOT NULL,
        "currency" character varying(3) DEFAULT 'EUR'::character varying NOT NULL,
        "interval" character varying(10) DEFAULT 'month'::character varying NOT NULL,
        "interval_count" integer DEFAULT 1 NOT NULL,
        "trial_days" integer DEFAULT 0 NOT NULL,
        "features" jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
        "active" boolean DEFAULT true NOT NULL,
        "sort_order" integer DEFAULT 0 NOT NULL,
        "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
        "inserted_at" timestamp with time zone NOT NULL,
        "updated_at" timestamp with time zone NOT NULL,
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL
      )
      """,
      payment_options_table(p),
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_billing_profiles (
        "type" character varying(20) DEFAULT 'individual'::character varying NOT NULL,
        "is_default" boolean DEFAULT false NOT NULL,
        "name" character varying(255),
        "first_name" character varying(255),
        "last_name" character varying(255),
        "middle_name" character varying(255),
        "phone" character varying(255),
        "email" character varying(255),
        "company_name" character varying(255),
        "company_vat_number" character varying(20),
        "company_registration_number" character varying(30),
        "company_legal_address" text,
        "address_line1" character varying(255),
        "address_line2" character varying(255),
        "city" character varying(255),
        "state" character varying(255),
        "postal_code" character varying(20),
        "country" character varying(2) DEFAULT 'EE'::character varying,
        "metadata" jsonb DEFAULT '{}'::jsonb,
        "inserted_at" timestamp with time zone NOT NULL,
        "updated_at" timestamp with time zone NOT NULL,
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "user_uuid" uuid
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_payment_methods (
        "provider" character varying(20) NOT NULL,
        "provider_payment_method_id" character varying(255) NOT NULL,
        "provider_customer_id" character varying(255),
        "type" character varying(20) DEFAULT 'card'::character varying NOT NULL,
        "brand" character varying(20),
        "last4" character varying(4),
        "exp_month" integer,
        "exp_year" integer,
        "display_name" character varying(255),
        "is_default" boolean DEFAULT false NOT NULL,
        "status" character varying(20) DEFAULT 'active'::character varying NOT NULL,
        "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
        "inserted_at" timestamp with time zone NOT NULL,
        "updated_at" timestamp with time zone NOT NULL,
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "user_uuid" uuid NOT NULL
      )
      """,
      orders_table(p),
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_invoices (
        "invoice_number" character varying(30) NOT NULL,
        "status" character varying(20) DEFAULT 'draft'::character varying NOT NULL,
        "subtotal" numeric(15,2) DEFAULT 0 NOT NULL,
        "tax_amount" numeric(15,2) DEFAULT 0 NOT NULL,
        "tax_rate" numeric(5,4) DEFAULT 0 NOT NULL,
        "total" numeric(15,2) NOT NULL,
        "currency" character varying(3) DEFAULT 'EUR'::character varying NOT NULL,
        "due_date" date,
        "billing_details" jsonb DEFAULT '{}'::jsonb,
        "line_items" jsonb DEFAULT '[]'::jsonb NOT NULL,
        "payment_terms" character varying(255),
        "bank_details" jsonb DEFAULT '{}'::jsonb,
        "notes" text,
        "metadata" jsonb DEFAULT '{}'::jsonb,
        "receipt_number" character varying(30),
        "receipt_generated_at" timestamp with time zone,
        "receipt_data" jsonb DEFAULT '{}'::jsonb,
        "sent_at" timestamp with time zone,
        "paid_at" timestamp with time zone,
        "voided_at" timestamp with time zone,
        "inserted_at" timestamp with time zone NOT NULL,
        "updated_at" timestamp with time zone NOT NULL,
        "paid_amount" numeric(15,2) DEFAULT 0 NOT NULL,
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "user_uuid" uuid NOT NULL,
        "order_uuid" uuid,
        "subscription_uuid" uuid
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_transactions (
        "transaction_number" character varying(30) NOT NULL,
        "amount" numeric(15,2) NOT NULL,
        "currency" character varying(3) DEFAULT 'EUR'::character varying NOT NULL,
        "payment_method" character varying(20) DEFAULT 'bank'::character varying NOT NULL,
        "description" character varying(255),
        "metadata" jsonb DEFAULT '{}'::jsonb,
        "provider_transaction_id" character varying(255),
        "provider_data" jsonb DEFAULT '{}'::jsonb,
        "inserted_at" timestamp with time zone NOT NULL,
        "updated_at" timestamp with time zone NOT NULL,
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "user_uuid" uuid NOT NULL,
        "invoice_uuid" uuid
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_subscriptions (
        "plan_name" character varying(255) NOT NULL,
        "provider" character varying(20),
        "provider_subscription_id" character varying(255),
        "status" character varying(20) DEFAULT 'active'::character varying NOT NULL,
        "current_period_start" timestamp with time zone NOT NULL,
        "current_period_end" timestamp with time zone NOT NULL,
        "cancel_at_period_end" boolean DEFAULT false NOT NULL,
        "cancelled_at" timestamp with time zone,
        "trial_start" timestamp with time zone,
        "trial_end" timestamp with time zone,
        "grace_period_end" timestamp with time zone,
        "renewal_attempts" integer DEFAULT 0 NOT NULL,
        "last_renewal_attempt_at" timestamp with time zone,
        "last_renewal_error" character varying(255),
        "price" numeric(15,2) NOT NULL,
        "currency" character varying(3) DEFAULT 'EUR'::character varying NOT NULL,
        "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
        "inserted_at" timestamp with time zone NOT NULL,
        "updated_at" timestamp with time zone NOT NULL,
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "user_uuid" uuid NOT NULL,
        "billing_profile_uuid" uuid,
        "payment_method_uuid" uuid,
        "subscription_type_uuid" uuid
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_webhook_events (
        "provider" character varying(20) NOT NULL,
        "event_id" character varying(255) NOT NULL,
        "event_type" character varying(255) NOT NULL,
        "payload" jsonb DEFAULT '{}'::jsonb NOT NULL,
        "processed" boolean DEFAULT false NOT NULL,
        "processed_at" timestamp with time zone,
        "error_message" text,
        "retry_count" integer DEFAULT 0 NOT NULL,
        "inserted_at" timestamp with time zone NOT NULL,
        "updated_at" timestamp with time zone NOT NULL,
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL
      )
      """
    ]

    # primary keys — core's exact constraint names
    pkeys = [
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'phoenix_kit_billing_profiles_pkey'
            AND t.relname = 'phoenix_kit_billing_profiles'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_billing_profiles ADD CONSTRAINT phoenix_kit_billing_profiles_pkey PRIMARY KEY (uuid);
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'phoenix_kit_currencies_pkey'
            AND t.relname = 'phoenix_kit_currencies'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_currencies ADD CONSTRAINT phoenix_kit_currencies_pkey PRIMARY KEY (uuid);
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'phoenix_kit_invoices_pkey'
            AND t.relname = 'phoenix_kit_invoices'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_invoices ADD CONSTRAINT phoenix_kit_invoices_pkey PRIMARY KEY (uuid);
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'phoenix_kit_orders_pkey'
            AND t.relname = 'phoenix_kit_orders'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_orders ADD CONSTRAINT phoenix_kit_orders_pkey PRIMARY KEY (uuid);
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'phoenix_kit_payment_methods_pkey'
            AND t.relname = 'phoenix_kit_payment_methods'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_payment_methods ADD CONSTRAINT phoenix_kit_payment_methods_pkey PRIMARY KEY (uuid);
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'phoenix_kit_payment_options_pkey'
            AND t.relname = 'phoenix_kit_payment_options'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_payment_options ADD CONSTRAINT phoenix_kit_payment_options_pkey PRIMARY KEY (uuid);
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'phoenix_kit_subscription_types_pkey'
            AND t.relname = 'phoenix_kit_subscription_types'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_subscription_types ADD CONSTRAINT phoenix_kit_subscription_types_pkey PRIMARY KEY (uuid);
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'phoenix_kit_subscriptions_pkey'
            AND t.relname = 'phoenix_kit_subscriptions'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_subscriptions ADD CONSTRAINT phoenix_kit_subscriptions_pkey PRIMARY KEY (uuid);
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'phoenix_kit_transactions_pkey'
            AND t.relname = 'phoenix_kit_transactions'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_transactions ADD CONSTRAINT phoenix_kit_transactions_pkey PRIMARY KEY (uuid);
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'phoenix_kit_webhook_events_pkey'
            AND t.relname = 'phoenix_kit_webhook_events'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_webhook_events ADD CONSTRAINT phoenix_kit_webhook_events_pkey PRIMARY KEY (uuid);
        END IF;
      END
      $$
      """
    ]

    # table-level UNIQUE constraints (not indexes)
    uniques = [
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'phoenix_kit_payment_options_code_unique'
            AND t.relname = 'phoenix_kit_payment_options'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_payment_options ADD CONSTRAINT phoenix_kit_payment_options_code_unique UNIQUE (code);
        END IF;
      END
      $$
      """
    ]

    # indexes — bare names, except the three core mangles per-schema.
    #
    # `phoenix_kit_subscription_plans_slug_uidx` is deliberately ABSENT:
    # core's V164 renamed it to `phoenix_kit_subscription_types_slug_uidx`
    # and the manifest carries it as `presence: :legacy_optional`. Emitting
    # it would resurrect, on every existing install, an index core went out
    # of its way to rename away.
    indexes = [
      "CREATE INDEX IF NOT EXISTS phoenix_kit_billing_profiles_user_uuid_idx ON #{p}phoenix_kit_billing_profiles USING btree (user_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_billing_profiles_uuid_idx ON #{p}phoenix_kit_billing_profiles USING btree (uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_currencies_code_uidx ON #{p}phoenix_kit_currencies USING btree (code)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_currencies_uuid_idx ON #{p}phoenix_kit_currencies USING btree (uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_invoices_due_date_idx ON #{p}phoenix_kit_invoices USING btree (due_date)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_invoices_invoice_number_uidx ON #{p}phoenix_kit_invoices USING btree (invoice_number)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_invoices_order_uuid_idx ON #{p}phoenix_kit_invoices USING btree (order_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_invoices_status_idx ON #{p}phoenix_kit_invoices USING btree (status)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_invoices_subscription_uuid_idx ON #{p}phoenix_kit_invoices USING btree (subscription_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_invoices_user_uuid_idx ON #{p}phoenix_kit_invoices USING btree (user_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_invoices_uuid_idx ON #{p}phoenix_kit_invoices USING btree (uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_orders_billing_profile_uuid_idx ON #{p}phoenix_kit_orders USING btree (billing_profile_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_orders_inserted_at_idx ON #{p}phoenix_kit_orders USING btree (inserted_at)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_orders_order_number_uidx ON #{p}phoenix_kit_orders USING btree (order_number)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_orders_payment_option_uuid_index ON #{p}phoenix_kit_orders USING btree (payment_option_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_orders_status_idx ON #{p}phoenix_kit_orders USING btree (status)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_orders_user_uuid_idx ON #{p}phoenix_kit_orders USING btree (user_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_orders_uuid_idx ON #{p}phoenix_kit_orders USING btree (uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_payment_methods_provider_id_uidx ON #{p}phoenix_kit_payment_methods USING btree (provider, provider_payment_method_id)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_payment_methods_user_uuid_idx ON #{p}phoenix_kit_payment_methods USING btree (user_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS #{pn}phoenix_kit_payment_methods_uuid_idx ON #{p}phoenix_kit_payment_methods USING btree (uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_payment_methods_uuid_unique_index ON #{p}phoenix_kit_payment_methods USING btree (uuid)",
      "CREATE INDEX IF NOT EXISTS idx_payment_options_active ON #{p}phoenix_kit_payment_options USING btree (active)",
      "CREATE INDEX IF NOT EXISTS idx_payment_options_position ON #{p}phoenix_kit_payment_options USING btree (\"position\")",
      "CREATE UNIQUE INDEX IF NOT EXISTS #{pn}phoenix_kit_payment_options_uuid_idx ON #{p}phoenix_kit_payment_options USING btree (uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS #{pn}phoenix_kit_subscription_plans_uuid_idx ON #{p}phoenix_kit_subscription_types USING btree (uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_subscription_types_slug_uidx ON #{p}phoenix_kit_subscription_types USING btree (slug)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_subscription_types_uuid_unique_index ON #{p}phoenix_kit_subscription_types USING btree (uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_subscriptions_billing_profile_uuid_idx ON #{p}phoenix_kit_subscriptions USING btree (billing_profile_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_subscriptions_payment_method_uuid_idx ON #{p}phoenix_kit_subscriptions USING btree (payment_method_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_subscriptions_period_end_idx ON #{p}phoenix_kit_subscriptions USING btree (current_period_end)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_subscriptions_provider_idx ON #{p}phoenix_kit_subscriptions USING btree (provider, provider_subscription_id)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_subscriptions_status_idx ON #{p}phoenix_kit_subscriptions USING btree (status)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_subscriptions_subscription_type_uuid_idx ON #{p}phoenix_kit_subscriptions USING btree (subscription_type_uuid) WHERE (subscription_type_uuid IS NOT NULL)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_subscriptions_user_uuid_idx ON #{p}phoenix_kit_subscriptions USING btree (user_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_subscriptions_uuid_idx ON #{p}phoenix_kit_subscriptions USING btree (uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_transactions_invoice_uuid_idx ON #{p}phoenix_kit_transactions USING btree (invoice_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_transactions_payment_method_idx ON #{p}phoenix_kit_transactions USING btree (payment_method)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_transactions_transaction_number_uidx ON #{p}phoenix_kit_transactions USING btree (transaction_number)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_transactions_user_uuid_idx ON #{p}phoenix_kit_transactions USING btree (user_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_transactions_uuid_idx ON #{p}phoenix_kit_transactions USING btree (uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_webhook_events_processed_idx ON #{p}phoenix_kit_webhook_events USING btree (processed)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_webhook_events_provider_event_uidx ON #{p}phoenix_kit_webhook_events USING btree (provider, event_id)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_webhook_events_uuid_idx ON #{p}phoenix_kit_webhook_events USING btree (uuid)"
    ]

    # foreign keys LAST: every referenced table and key exists by now
    fks = [
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'fk_billing_profiles_user_uuid'
            AND t.relname = 'phoenix_kit_billing_profiles'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_billing_profiles ADD CONSTRAINT fk_billing_profiles_user_uuid FOREIGN KEY (user_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL;
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'fk_invoices_order_uuid'
            AND t.relname = 'phoenix_kit_invoices'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_invoices ADD CONSTRAINT fk_invoices_order_uuid FOREIGN KEY (order_uuid) REFERENCES #{p}phoenix_kit_orders(uuid) ON DELETE SET NULL;
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'fk_invoices_user_uuid'
            AND t.relname = 'phoenix_kit_invoices'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_invoices ADD CONSTRAINT fk_invoices_user_uuid FOREIGN KEY (user_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE RESTRICT;
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'fk_orders_billing_profile_uuid'
            AND t.relname = 'phoenix_kit_orders'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_orders ADD CONSTRAINT fk_orders_billing_profile_uuid FOREIGN KEY (billing_profile_uuid) REFERENCES #{p}phoenix_kit_billing_profiles(uuid) ON DELETE SET NULL;
        END IF;
      END
      $$
      """,
      # The ONE guard that keys on the COLUMN rather than the constraint
      # name, because core's V162 does the same, for a reason it states in
      # its own comment: an earlier build of that migration created this FK
      # under Ecto's DEFAULT name. On such a host a name-keyed guard finds
      # no `fk_orders_payment_option`, and "adoption" quietly adds a SECOND
      # foreign key over the same column.
      #
      # The other eight FKs keep name-keyed guards — that is what core's
      # V135 does for them, and adoption reproduces core's guard, not a
      # tidier one.
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT
          FROM information_schema.table_constraints tc
          JOIN information_schema.key_column_usage kcu
            ON kcu.constraint_name = tc.constraint_name
           AND kcu.constraint_schema = tc.constraint_schema
          WHERE tc.table_schema = '#{prefix}'
            AND tc.table_name = 'phoenix_kit_orders'
            AND tc.constraint_type = 'FOREIGN KEY'
            AND kcu.column_name = 'payment_option_uuid'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_orders ADD CONSTRAINT fk_orders_payment_option FOREIGN KEY (payment_option_uuid) REFERENCES #{p}phoenix_kit_payment_options(uuid) ON DELETE SET NULL;
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'fk_orders_user_uuid'
            AND t.relname = 'phoenix_kit_orders'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_orders ADD CONSTRAINT fk_orders_user_uuid FOREIGN KEY (user_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL;
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'phoenix_kit_subscriptions_subscription_type_uuid_fkey'
            AND t.relname = 'phoenix_kit_subscriptions'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_subscriptions ADD CONSTRAINT phoenix_kit_subscriptions_subscription_type_uuid_fkey FOREIGN KEY (subscription_type_uuid) REFERENCES #{p}phoenix_kit_subscription_types(uuid) ON DELETE SET NULL;
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'fk_transactions_invoice_uuid'
            AND t.relname = 'phoenix_kit_transactions'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_transactions ADD CONSTRAINT fk_transactions_invoice_uuid FOREIGN KEY (invoice_uuid) REFERENCES #{p}phoenix_kit_invoices(uuid) ON DELETE RESTRICT;
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'fk_transactions_user_uuid'
            AND t.relname = 'phoenix_kit_transactions'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_transactions ADD CONSTRAINT fk_transactions_user_uuid FOREIGN KEY (user_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE RESTRICT;
        END IF;
      END
      $$
      """
    ]

    tables ++ pkeys ++ uniques ++ indexes ++ fks
  end

  @doc """
  The SQL `down/1` executes, as data. Below V2 this also drops the
  `phoenix_kit_currencies` index and columns V2 added, and below V3 the
  `phoenix_kit_orders` columns V3 added — never the
  `phoenix_kit_payment_provider_configs` table itself. V4 changes no
  shape of its own (pure adoption, like V1), so there is nothing below V4
  to drop beyond the marker. Below V7 the V7 counter table is dropped — the
  only table here that this chain, not core, created.
  """
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ "public", target \\ 0)

  def down_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    # Refuses rather than deletes: see the moduledoc's V5 section.
    drop_v5 =
      if target < 5 do
        [
          """
          DO $$
          BEGIN
            IF EXISTS (SELECT 1 FROM #{p}phoenix_kit_invoices WHERE user_uuid IS NULL)
               OR EXISTS (SELECT 1 FROM #{p}phoenix_kit_transactions WHERE user_uuid IS NULL) THEN
              RAISE EXCEPTION 'phoenix_kit_billing: cannot roll back below V5 while invoices or transactions without a user exist (guest payers). Attribute them to a user or stay on V5.';
            END IF;
          END
          $$
          """,
          "ALTER TABLE #{p}phoenix_kit_invoices DROP CONSTRAINT IF EXISTS phoenix_kit_invoices_payer_check",
          "ALTER TABLE #{p}phoenix_kit_invoices ALTER COLUMN user_uuid SET NOT NULL",
          "ALTER TABLE #{p}phoenix_kit_transactions ALTER COLUMN user_uuid SET NOT NULL"
        ]
      else
        []
      end

    drop_v3 =
      if target < 3 do
        [
          "ALTER TABLE #{p}phoenix_kit_orders DROP COLUMN IF EXISTS base_currency",
          "ALTER TABLE #{p}phoenix_kit_orders DROP COLUMN IF EXISTS exchange_rate",
          "ALTER TABLE #{p}phoenix_kit_orders DROP COLUMN IF EXISTS base_total"
        ]
      else
        []
      end

    drop_v2 =
      if target < 2 do
        [
          "DROP INDEX IF EXISTS #{p}phoenix_kit_currencies_default_uidx",
          "ALTER TABLE #{p}phoenix_kit_currencies DROP COLUMN IF EXISTS rounding_rule",
          "ALTER TABLE #{p}phoenix_kit_currencies DROP COLUMN IF EXISTS rate_updated_at"
        ]
      else
        []
      end

    marker =
      if target > 0 do
        "COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"
      else
        "COMMENT ON TABLE #{p}#{@version_table} IS NULL"
      end

    # The one table this chain creates itself: the counter holds no money
    # record, only the last number handed out.
    drop_v7 =
      if target < 7 do
        ["DROP TABLE IF EXISTS #{p}phoenix_kit_billing_number_sequences"]
      else
        []
      end

    drop_v7 ++ drop_v5 ++ drop_v3 ++ drop_v2 ++ [marker]
  end

  defp parse_version(n) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 0
    end
  end

  # The marker is what every later run reads to decide whether it has
  # anything to do, and nothing downstream sanity-checks the number: a
  # marker of `pkb_schema:999` makes core's `classify/2` answer
  # `:up_to_date` for every version after it, so the next real version is
  # skipped SILENTLY and forever. Applying a body while stamping a
  # version this chain does not have is therefore refused, in both
  # directions. Core's codegen always passes `current_version/0`, so this
  # only fires for a hand-written call — which is exactly the caller that
  # has no other guard.
  defp validate_target!(target) when target > @current_version do
    raise ArgumentError,
          "PhoenixKitBilling.Migrations has no version #{target} " <>
            "(current_version/0 is #{@current_version}); stamping it would make every " <>
            "later version look already applied"
  end

  defp validate_target!(_target), do: :ok

  # `:version` is read from a keyword list AND from a map, because
  # `validated_prefix/1` accepts both — and a shape it accepts must not
  # silently lose the version. Core codegens a keyword list, so the map
  # path is not exercised in production; that is exactly why it was able
  # to sit here defaulting to `@current_version` while `up/1`'s own @doc
  # promised the opposite ("a host pinned to an older chain version must
  # not silently receive a later version's adoption").
  defp target_version(opts, default) when is_list(opts) do
    Keyword.get(opts, :version, default)
  end

  defp target_version(%{} = opts, default), do: Map.get(opts, :version, default)
  defp target_version(_opts, default), do: default

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    # The prefix rules are CORE's, borrowed rather than restated. This
    # chain embeds the prefix directly into index NAMES (V2's default-
    # currency index, V4's `pn`-mangled indexes), and Postgres silently
    # TRUNCATES an identifier past 63 bytes instead of rejecting it — so a
    # prefix core would refuse produces index names that differ from
    # core's while every command still exits 0, breaking the one contract
    # adoption rests on: core's exact object names.
    # `Code.ensure_loaded?` before `function_exported?`: the latter answers
    # false for a module that simply has not been loaded yet, which under a
    # release (and in `mix run --no-start`) is the normal state — the check
    # would silently take the fallback branch and defeat its own purpose.
    helpers = PhoenixKit.Migrations.Postgres.Helpers

    if Code.ensure_loaded?(helpers) and function_exported?(helpers, :validate_prefix!, 1) do
      helpers.validate_prefix!(prefix)
    else
      # Older core without the shared validator: apply core's documented
      # rules here rather than restating a looser local copy that could
      # drift — lower-case identifiers only, capped at 20 bytes (measured
      # from the longest embedded object name, 63 - 1 - 42).
      unless is_binary(prefix) and prefix =~ ~r/^[a-z_][a-z0-9_]*$/ and byte_size(prefix) <= 20 do
        raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
      end
    end

    prefix
  end
end
