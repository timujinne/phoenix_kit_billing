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

  All eleven `phoenix_kit_billing` tables are core baseline tables: core's
  V135 created them, and later core versions have amended them (V162 added
  `payment_option_uuid`, its FK and its index to `phoenix_kit_orders`; V164
  added the `subscription_types` slug index). This chain ADOPTS that shape
  table by table — it does not redesign it.

  Adoption happens in two published versions, and each is frozen once
  released:

    * **V1** — `phoenix_kit_payment_provider_configs` (shipped in 0.9.0).
    * **V2** — the remaining ten: billing profiles, currencies, invoices,
      orders, transactions, payment methods, subscriptions, webhook
      events, payment options, subscription types.

  Both are pure Phase-0 adoptions, and the property that makes them safe
  is the same in both:

    * on an existing install the tables are already there, every
      `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS` /
      guarded `ADD CONSTRAINT` finds its object and does nothing, and the
      only new object in the database is the version marker;
    * on a future install whose core baseline no longer creates them, the
      same statements create them — shape-identical to core's, under
      core's exact index and constraint names.

  Because neither version changes any shape, core's `ExpectedSchema`
  manifest stays accurate and NO core release is required for either. A
  version that DOES change a shape (V3+) is a separate, deliberate step
  that first needs the changed objects added to core's manifest
  `@excluded_exact` — not something to fold into an adoption.

  Nothing in this package's `lib/` reads or writes
  `phoenix_kit_payment_provider_configs` today; the payment-provider
  credentials this package actually uses live in `phoenix_kit_settings`
  via `PhoenixKitBilling.Providers`, and this chain changes NONE of that.

  ## What `down/1` is NOT

  `down/1` unstamps (or lowers) the version marker. It NEVER drops,
  truncates or deletes anything — not the eleven tables, not a row in
  them. These hold invoices, orders and transactions: rolling a billing
  release back must cost the operator a version marker, never a payment
  record. Only core's own baseline rollback owns dropping core's tables.

  That is not a promise made in prose alone —
  `test/phoenix_kit_billing/migrations_money_safety_test.exs` seeds real
  rows in the money tables, runs a real `down(version: 0)` as a
  migration, and requires the rows to still be there, with a mutation
  case that proves the check fails against a rollback that does delete.

  The migrated version is tracked as a `pkb_schema:<N>` COMMENT on
  `phoenix_kit_payment_provider_configs` (the marker convention from the
  projects/legal chains, namespaced). A marker-less table reads as
  version 0 — the core-baseline shape before this chain existed.
  """

  use Ecto.Migration

  @current_version 2
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

  @doc """
  Applies every chain version up to `target` (`:version` in `opts`,
  defaulting to `current_version/0`) — idempotent in every direction.

  Core codegens a literal `up(prefix: ..., version: <target>)` call, and
  `target` is honoured rather than ignored: a host pinned to an older
  chain version must not silently receive a later version's adoption.
  """
  def up(opts \\ []) do
    prefix = validated_prefix(opts)

    target =
      if is_list(opts), do: Keyword.get(opts, :version, @current_version), else: @current_version

    prefix
    |> up_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc "Rolls back to `target` (`:version` in `opts`). Never drops the table — see the moduledoc."
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    # The protocol only ever calls down/1 with a keyword list (core codegens
    # a literal `down(prefix: ..., version: ...)` call — see
    # /app/lib/mix/tasks/phoenix_kit.update.ex:1178), so the map branch is
    # dead in practice, same as validated_prefix/1's %{prefix: prefix} branch.
    target = if is_list(opts), do: Keyword.get(opts, :version, 0), else: 0

    prefix
    |> down_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc """
  The SQL `up/1` executes for `target`, as data — the testable single
  source. The ownership tests parse these statements to prove that the
  object names are core's names, that each CREATE stays shape-identical
  to core's `ExpectedSchema` manifest, and that nothing here can drop a
  table.
  """
  @spec up_statements(String.t(), non_neg_integer()) :: [String.t()]
  def up_statements(prefix \\ "public", target \\ @current_version)
      when is_integer(target) and target >= 0 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    v1 = if target >= 1, do: v1_statements(p, prefix), else: []
    v2 = if target >= 2, do: v2_statements(p, prefix), else: []

    v1 ++ v2 ++ [marker_statement(p, target)]
  end

  @doc "V1 — adoption of `phoenix_kit_payment_provider_configs` (unchanged since publication)."
  @spec v1_statements(String.t(), String.t()) :: [String.t()]
  def v1_statements(p, prefix) do
    [
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
  end

  @doc """
  V2 — adoption of the remaining ten billing tables.

  Same Phase-0 contract as V1: every statement reproduces core's CURRENT
  shape for the table (the `ExpectedSchema` manifest, which is core's
  V135 baseline plus V162's `payment_option_uuid` column/FK/index on
  orders and V164's `subscription_types` slug index) under core's exact
  object names, so an install where core already created these tables
  sees a pure no-op and the manifest stays accurate with NO core release.

  Statement order is load-bearing: tables, then primary keys and unique
  constraints, then indexes, then foreign keys last — by which point
  every referenced table and referenced key exists, whatever order the
  tables themselves were created in.

  Three index names are mangled per-schema (`\#{pn}` — core's own
  `pn = if prefix == "public", do: "", else: "\#{prefix}_"`). Emitting
  them bare would create a SECOND index next to core's under a named
  schema instead of adopting it.
  """
  @spec v2_statements(String.t(), String.t()) :: [String.t()]
  def v2_statements(p, prefix) do
    pn = if prefix == "public", do: "", else: "#{prefix}_"

    tables = [
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
      """,
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
      """,
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
      """,
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
      # foreign key over the same column. Reproduced before this guard was
      # changed: pre-creating the FK as
      # `phoenix_kit_orders_payment_option_uuid_fkey` and running the
      # name-keyed version left two FKs on `payment_option_uuid`.
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

  @spec marker_statement(String.t(), non_neg_integer()) :: String.t()
  defp marker_statement(p, version) do
    "COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{version}'"
  end

  @doc "The SQL `down/1` executes, as data (marker bookkeeping only)."
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ "public", target \\ 0)
      when is_integer(target) and target >= 0 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    if target > 0 do
      ["COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"]
    else
      ["COMMENT ON TABLE #{p}#{@version_table} IS NULL"]
    end
  end

  defp parse_version(n) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 0
    end
  end

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    # Interpolated into DDL — same guard the projects/legal chains use.
    unless prefix =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/ do
      raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
    end

    prefix
  end
end
