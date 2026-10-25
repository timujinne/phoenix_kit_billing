defmodule PhoenixKitBilling.MigrationsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitBilling.Migrations

  @moduledoc """
  Pins the ownership design for `phoenix_kit_payment_provider_configs`:
  this package owns the table's FUTURE shape through its module migration
  chain, while core's V135 baseline still creates the table on every
  install and the chain's V1 merely ADOPTS it (stamps the `pkb_schema:`
  marker, changes no shape).

  No application code in this package reads or writes this table today —
  provider credentials still live in `phoenix_kit_settings`. This version
  is only the adoption step; see the moduledoc in
  `PhoenixKitBilling.Migrations`.

  Every test here is a pure data/string assertion over
  `up_statements/1`/`down_statements/2`/`up/1`/`down/1`-as-source-text and
  core's static `PhoenixKit.Migrations.ExpectedSchema.objects/1` manifest —
  none of them touch a database.
  """

  test "PhoenixKitBilling declares the module-owned migration chain" do
    # Assert the VALUE, not `function_exported?/3` — `use PhoenixKit.Module`
    # injects an overridable default `migration_module/0`, so exportedness
    # says nothing about whether this module declares one.
    assert Code.ensure_loaded?(PhoenixKitBilling)

    assert PhoenixKitBilling.migration_module() == Migrations,
           """
           PhoenixKitBilling no longer declares its migration chain \
           (migration_module/0 returned #{inspect(PhoenixKitBilling.migration_module())}).

           The chain is how phoenix_kit_payment_provider_configs's future shape
           is versioned (pkb_schema marker) and how `mix phoenix_kit.update`
           migrates hosts.
           """
  end

  describe "the coordinator implements the protocol" do
    alias PhoenixKit.Migrations.Postgres.Helpers

    test "current_version/0 and version_table/0" do
      assert Migrations.current_version() == 6
      assert Migrations.version_table() == "phoenix_kit_payment_provider_configs"
    end

    # The marker decides whether any LATER version ever runs: core's
    # `classify/2` reads it and answers `:up_to_date` for every version at
    # or below it. Stamping a version this chain does not have therefore
    # skips V5 and everything after it, silently and permanently.
    test "refuses to stamp a version this chain does not have" do
      too_high = Migrations.current_version() + 1

      assert_raise ArgumentError, ~r/has no version #{too_high}/, fn ->
        Migrations.up_statements("public", too_high)
      end

      assert_raise ArgumentError, ~r/has no version #{too_high}/, fn ->
        Migrations.down_statements("public", too_high)
      end

      # The ceiling itself stays reachable, or the guard would just break
      # the chain instead of bounding it.
      assert Migrations.up_statements("public", Migrations.current_version()) != []
    end

    # This chain embeds the prefix into index NAMES (V4's `pn`), and
    # Postgres TRUNCATES an identifier past 63 bytes silently rather than
    # rejecting it — so a prefix core would refuse yields index names that
    # differ from core's while every command still exits 0, breaking the
    # contract adoption rests on. The rules are therefore core's, and this
    # test compares against core rather than restating them: a local copy
    # is exactly what drifted (upper case allowed, no length bound at all).
    test "every public builder that emits SQL validates its own prefix" do
      for fun <- [:up_statements, :down_statements] do
        assert_raise ArgumentError, fn -> apply(Migrations, fun, ["EVIL\";DROP"]) end
        assert_raise ArgumentError, fn -> apply(Migrations, fun, [String.duplicate("a", 30)]) end
        assert_raise ArgumentError, fn -> apply(Migrations, fun, [123]) end
      end
    end

    test "the prefix rules are core's, case and length included" do
      for prefix <- [
            "public",
            "billing_alt",
            "Billing",
            "9leading_digit",
            "has-dash",
            String.duplicate("a", 20),
            String.duplicate("a", 21),
            String.duplicate("a", 30)
          ] do
        core_accepts =
          try do
            Helpers.validate_prefix!(prefix)
            true
          rescue
            ArgumentError -> false
          end

        ours_accepts =
          try do
            Migrations.up_statements(prefix)
            true
          rescue
            ArgumentError -> false
          end

        assert ours_accepts == core_accepts,
               "prefix #{inspect(prefix)}: core #{if core_accepts, do: "accepts", else: "rejects"}, " <>
                 "this chain #{if ours_accepts, do: "accepts", else: "rejects"} — the two must agree, " <>
                 "or the index names this chain creates stop matching core's"
      end
    end

    test "rejects a prefix that cannot be safely interpolated into DDL" do
      for bad <- ["public.\"; DROP TABLE x; --", "1st", "a-b", ""] do
        assert_raise ArgumentError, fn -> Migrations.up_statements(bad) end
        assert_raise ArgumentError, fn -> Migrations.down_statements(bad, 0) end
      end
    end
  end

  describe "the chain's per-version statement content is pinned (drift guard)" do
    # V1, V2 and V3 are PUBLISHED (0.9.0 and the currency epic release
    # respectively). A host that has already run them will never run them
    # again, so editing their content does not "fix" that host — it
    # silently splits fresh installs from existing ones. Pinning the exact
    # normalised text makes that split a deliberate, visible diff instead
    # of an accidental one buried in a refactor.
    defp normalised(statements),
      do: Enum.map(statements, &(&1 |> String.replace(~r/\s+/, " ") |> String.trim()))

    test "V1's published statements are frozen" do
      v1 = Migrations.up_statements("public", 1) |> normalised()

      assert v1 == [
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_payment_provider_configs ( \"provider\" character varying(20) NOT NULL, \"enabled\" boolean DEFAULT false NOT NULL, \"mode\" character varying(10) DEFAULT 'test'::character varying NOT NULL, \"api_key\" text, \"api_secret\" text, \"webhook_secret\" text, \"webhook_url\" character varying(255), \"last_verified_at\" timestamp with time zone, \"verification_status\" character varying(20) DEFAULT 'pending'::character varying, \"verification_error\" text, \"config\" jsonb DEFAULT '{}'::jsonb NOT NULL, \"inserted_at\" timestamp with time zone NOT NULL, \"updated_at\" timestamp with time zone NOT NULL, \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL )",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_payment_provider_configs_pkey' AND t.relname = 'phoenix_kit_payment_provider_configs' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_payment_provider_configs ADD CONSTRAINT phoenix_kit_payment_provider_configs_pkey PRIMARY KEY (uuid); END IF; END $$",
               "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_payment_provider_configs_provider_uidx ON public.phoenix_kit_payment_provider_configs USING btree (provider)",
               "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_payment_provider_configs_uuid_idx ON public.phoenix_kit_payment_provider_configs USING btree (uuid)",
               "COMMENT ON TABLE public.phoenix_kit_payment_provider_configs IS 'pkb_schema:1'"
             ]
    end

    test "V2's published statements are frozen" do
      v2_only =
        (Migrations.up_statements("public", 2) -- Migrations.up_statements("public", 1))
        |> normalised()

      assert v2_only == [
               "UPDATE public.phoenix_kit_currencies SET is_default = false WHERE is_default AND uuid <> ( SELECT uuid FROM public.phoenix_kit_currencies WHERE is_default ORDER BY sort_order, inserted_at, uuid LIMIT 1 )",
               "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_currencies_default_uidx ON public.phoenix_kit_currencies USING btree (is_default) WHERE is_default",
               "ALTER TABLE public.phoenix_kit_currencies ADD COLUMN IF NOT EXISTS rounding_rule character varying(16) DEFAULT 'exact' NOT NULL",
               "ALTER TABLE public.phoenix_kit_currencies ADD COLUMN IF NOT EXISTS rate_updated_at timestamp with time zone",
               "COMMENT ON TABLE public.phoenix_kit_payment_provider_configs IS 'pkb_schema:2'"
             ]
    end

    test "V3's published statements are frozen" do
      v3_only =
        (Migrations.up_statements("public", 3) -- Migrations.up_statements("public", 2))
        |> normalised()

      assert v3_only == [
               "ALTER TABLE public.phoenix_kit_orders ADD COLUMN IF NOT EXISTS base_currency character varying(3)",
               "ALTER TABLE public.phoenix_kit_orders ADD COLUMN IF NOT EXISTS exchange_rate numeric(15,6)",
               "ALTER TABLE public.phoenix_kit_orders ADD COLUMN IF NOT EXISTS base_total numeric(15,2)",
               "COMMENT ON TABLE public.phoenix_kit_payment_provider_configs IS 'pkb_schema:3'"
             ]
    end

    # V4 is NOT yet published — nothing has shipped that could be split
    # from a fresh install by editing it, so the stakes here are "catch an
    # accidental edit while working on something else", not "protect a
    # public contract". A full verbatim transcription of V4's ~75
    # statements (ten tables' worth of CREATE TABLE/index/constraint DDL)
    # would just be a second, hand-copied source of the exact same text —
    # busywork with its own transcription-error risk, not an independent
    # check. A content fingerprint plus an explicit statement count catches
    # the same accidental-edit case (any changed statement changes the
    # hash) without that duplication. If this ever needs to become a real
    # verbatim pin (e.g. once V4 ships), replace this with the same
    # literal-list style as V1-V3 above.
    test "V4's statement content is fingerprinted" do
      v4_only =
        (Migrations.up_statements("public", 4) -- Migrations.up_statements("public", 3))
        |> normalised()

      assert length(v4_only) == 75

      fingerprint =
        :sha256
        |> :crypto.hash(Enum.join(v4_only, "\n"))
        |> Base.encode16(case: :lower)

      assert fingerprint == "a7530bceaca5cf1a696bee1bcf10f6553835b7b5a75d8dcff7d917d4c4c6a707",
             "V4's statement content changed — if this is deliberate, update the " <>
               "pinned fingerprint in this test; if not, something drifted"
    end
  end

  describe "the chain DDL adopts core's V135 shape" do
    test "V1 uses core's exact object names (shape-identical adoption)" do
      statements = Enum.join(Migrations.up_statements(), "\n")

      for name <- [
            "phoenix_kit_payment_provider_configs_pkey",
            "phoenix_kit_payment_provider_configs_provider_uidx",
            "phoenix_kit_payment_provider_configs_uuid_idx"
          ] do
        assert statements =~ name,
               "V1 no longer creates #{name} — it must stay shape-identical to core's V135"
      end
    end

    test "up stamps the version marker, and stamps it last" do
      statements = Migrations.up_statements()

      assert List.last(statements) ==
               "COMMENT ON TABLE public.phoenix_kit_payment_provider_configs IS 'pkb_schema:6'",
             "the marker must be stamped after the DDL it certifies, not before"
    end

    # `up/1` and `down/1` accept a map as well as a keyword list, because
    # `validated_prefix/1` does. A shape the function ACCEPTS must not
    # silently lose `:version` — that is how `up/1` could contradict its
    # own @doc, defaulting a map to the latest version while promising a
    # pinned host would not be advanced.
    test "a target below current_version applies only that far" do
      assert length(Migrations.up_statements("public", 1)) == 5
      assert length(Migrations.up_statements("billing_alt", 1)) == 5

      refute Enum.any?(
               Migrations.up_statements("public", 1),
               &String.contains?(&1, "phoenix_kit_invoices")
             ),
             "V1-only application emitted a V4 table"

      assert List.last(Migrations.up_statements("public", 1)) =~ "pkb_schema:1"
    end

    test "applying up to version 0 is not an operation" do
      assert Migrations.up_statements("public", 0) == []
      assert Migrations.up_statements("billing_alt", 0) == []
    end

    test "every up statement is guarded (IF NOT EXISTS / DO-block idempotence)" do
      # V1 runs on installs where core's V135 already created everything, so
      # every statement must be a no-op against an object that is already
      # there.
      #
      # The set is asserted before it is iterated: filtering to the COMMENT
      # and then looping means a degraded `up_statements/1` (down to just
      # its marker) would run this loop zero times and stay green while
      # every other guard vanished. Emptiness/shrinkage of the set is
      # covered where it is reachable as a real regression — the "up/1
      # emits exactly these operations" test below compares the whole set,
      # so a disappearing statement fails there instead.
      ddl = Enum.reject(Migrations.up_statements(), &String.starts_with?(&1, "COMMENT"))

      # V2's pre-index repair is the one statement that creates nothing, so
      # `IF NOT EXISTS` does not apply to it. It is idempotent by
      # construction instead: it demotes every default row but one, so a
      # second run finds nothing left to demote. Matched narrowly — any
      # OTHER unguarded statement still fails below.
      {repairs, creates} =
        Enum.split_with(ddl, &String.starts_with?(String.trim(&1), "UPDATE "))

      for stmt <- repairs do
        assert stmt =~ ~r/SET is_default = false/,
               "the only unguarded statement V2 may emit is the default-currency " <>
                 "repair; this one writes something else:\n#{stmt}"

        assert stmt =~ "LIMIT 1",
               "the repair must leave exactly one default row, or re-running it " <>
                 "is not a no-op:\n#{stmt}"
      end

      for stmt <- creates do
        assert stmt =~ "IF NOT EXISTS",
               "statement is not idempotent against a core-created table:\n#{stmt}"
      end
    end
  end

  describe "the chain can never destroy the table" do
    alias PhoenixKit.Migrations.ExpectedSchema

    # Compared against the WHOLE expected content, not scanned for a
    # forbidden substring — a substring check only sees statements the
    # builder produced, so anything appended past it (a literal
    # `execute("DROP TABLE ...")` in `up/1`) would be invisible to it. That
    # path is closed by the source-text test below, which checks what is
    # executed rather than what is built.
    #
    # This test and "no statement anywhere in the data-level chain can drop
    # the table, truncate, or delete rows" below are the two halves of one
    # guarantee: this test pins the EXACT drop statements `down/1` is
    # allowed to emit (index + two columns on phoenix_kit_currencies below
    # V2, three columns on phoenix_kit_orders below V3, nothing at all
    # below V4 — V4 is pure adoption like V1 — and never the
    # phoenix_kit_payment_provider_configs table), and the other test
    # proves nothing MORE destructive slips in anywhere.
    test "down/1 emits exactly the marker bookkeeping, in every target and prefix" do
      v5_undo_public = v5_undo("public")
      v5_undo_alt = v5_undo("billing_alt")

      v3_drops_public = [
        "ALTER TABLE public.phoenix_kit_orders DROP COLUMN IF EXISTS base_currency",
        "ALTER TABLE public.phoenix_kit_orders DROP COLUMN IF EXISTS exchange_rate",
        "ALTER TABLE public.phoenix_kit_orders DROP COLUMN IF EXISTS base_total"
      ]

      v2_drops_public = [
        "DROP INDEX IF EXISTS public.phoenix_kit_currencies_default_uidx",
        "ALTER TABLE public.phoenix_kit_currencies DROP COLUMN IF EXISTS rounding_rule",
        "ALTER TABLE public.phoenix_kit_currencies DROP COLUMN IF EXISTS rate_updated_at"
      ]

      v3_drops_alt = [
        "ALTER TABLE billing_alt.phoenix_kit_orders DROP COLUMN IF EXISTS base_currency",
        "ALTER TABLE billing_alt.phoenix_kit_orders DROP COLUMN IF EXISTS exchange_rate",
        "ALTER TABLE billing_alt.phoenix_kit_orders DROP COLUMN IF EXISTS base_total"
      ]

      v2_drops_alt = [
        "DROP INDEX IF EXISTS billing_alt.phoenix_kit_currencies_default_uidx",
        "ALTER TABLE billing_alt.phoenix_kit_currencies DROP COLUMN IF EXISTS rounding_rule",
        "ALTER TABLE billing_alt.phoenix_kit_currencies DROP COLUMN IF EXISTS rate_updated_at"
      ]

      assert Migrations.down_statements("public", 0) ==
               v5_undo_public ++
                 v3_drops_public ++
                 v2_drops_public ++
                 ["COMMENT ON TABLE public.phoenix_kit_payment_provider_configs IS NULL"]

      assert Migrations.down_statements("public", 1) ==
               v5_undo_public ++
                 v3_drops_public ++
                 v2_drops_public ++
                 [
                   "COMMENT ON TABLE public.phoenix_kit_payment_provider_configs IS 'pkb_schema:1'"
                 ]

      assert Migrations.down_statements("billing_alt", 0) ==
               v5_undo_alt ++
                 v3_drops_alt ++
                 v2_drops_alt ++
                 ["COMMENT ON TABLE billing_alt.phoenix_kit_payment_provider_configs IS NULL"]

      # target 2: below V3, so the orders columns still get dropped, but
      # the currencies index/columns (added at V2, kept at target >= 2) do not.
      assert Migrations.down_statements("billing_alt", 2) ==
               v5_undo_alt ++
                 v3_drops_alt ++
                 [
                   "COMMENT ON TABLE billing_alt.phoenix_kit_payment_provider_configs IS 'pkb_schema:2'"
                 ]

      # target 3: V3's own additions are kept; only V5 is undone.
      assert Migrations.down_statements("billing_alt", 3) ==
               v5_undo_alt ++
                 [
                   "COMMENT ON TABLE billing_alt.phoenix_kit_payment_provider_configs IS 'pkb_schema:3'"
                 ]

      # target 4: V5 undone. V4 itself is pure adoption (like V1) — it
      # changes no shape of its own, so it contributes nothing to drop.
      assert Migrations.down_statements("billing_alt", 4) ==
               v5_undo_alt ++
                 [
                   "COMMENT ON TABLE billing_alt.phoenix_kit_payment_provider_configs IS 'pkb_schema:4'"
                 ]

      # target 5: V6 undone — it adopted tables, so nothing to drop, marker only.
      assert Migrations.down_statements("billing_alt", 5) ==
               [
                 "COMMENT ON TABLE billing_alt.phoenix_kit_payment_provider_configs IS 'pkb_schema:5'"
               ]

      # target 6 == current_version: nothing to undo, marker only.
      assert Migrations.down_statements("billing_alt", 6) ==
               [
                 "COMMENT ON TABLE billing_alt.phoenix_kit_payment_provider_configs IS 'pkb_schema:6'"
               ]
    end

    # V5's rollback, pinned verbatim — the drift guard's job is to make any
    # change to what a rollback executes a deliberate edit here. It REFUSES
    # while guest payers exist rather than deleting or re-attributing money
    # records, and it drops only the CHECK V5 added — never a table.
    defp v5_undo(schema) do
      [
        """
        DO $$
        BEGIN
          IF EXISTS (SELECT 1 FROM #{schema}.phoenix_kit_invoices WHERE user_uuid IS NULL)
             OR EXISTS (SELECT 1 FROM #{schema}.phoenix_kit_transactions WHERE user_uuid IS NULL) THEN
            RAISE EXCEPTION 'phoenix_kit_billing: cannot roll back below V5 while invoices or transactions without a user exist (guest payers). Attribute them to a user or stay on V5.';
          END IF;
        END
        $$
        """,
        "ALTER TABLE #{schema}.phoenix_kit_invoices DROP CONSTRAINT IF EXISTS phoenix_kit_invoices_payer_check",
        "ALTER TABLE #{schema}.phoenix_kit_invoices ALTER COLUMN user_uuid SET NOT NULL",
        "ALTER TABLE #{schema}.phoenix_kit_transactions ALTER COLUMN user_uuid SET NOT NULL"
      ]
    end

    # For `up/1` the expected content is the full set of OPERATIONS rather
    # than the full SQL text. An operation is `{verb, object}`, immune to
    # reformatting and still failing on any statement added, removed or
    # retargeted — including a destructive one, which cannot enter this set
    # without changing it.
    @up_operations [
      {"CREATE TABLE", "phoenix_kit_payment_provider_configs"},
      {"DO", "phoenix_kit_payment_provider_configs_pkey"},
      {"CREATE UNIQUE INDEX", "phoenix_kit_payment_provider_configs_provider_uidx"},
      {"CREATE UNIQUE INDEX", "phoenix_kit_payment_provider_configs_uuid_idx"},
      {"COMMENT ON TABLE", "phoenix_kit_payment_provider_configs"}
    ]

    test "up_statements/2 at target 1 emits exactly these V1 operations and no others" do
      for prefix <- ["public", "billing_alt"] do
        actual = Enum.map(Migrations.up_statements(prefix, 1), &operation/1)

        assert Enum.sort(actual) == Enum.sort(@up_operations),
               """
               up_statements(#{inspect(prefix)}, 1) does not emit the expected set of
               operations.

               unexpected: #{inspect(Enum.sort(actual) -- Enum.sort(@up_operations))}
               missing:    #{inspect(Enum.sort(@up_operations) -- Enum.sort(actual))}

               Every statement this chain emits runs against a core-created
               table. Adding one is a chain version (V2+), not something to
               slip past this list.
               """
      end
    end

    # V4's expected set is CORE'S MANIFEST for the ten newly-adopted
    # tables, not a hand-typed list — a hand-typed list is maintained by
    # the same hand that adds a statement, so it catches a slip but never a
    # deliberate one; the manifest is written on core's side, so this fails
    # both when the chain emits an object core does not declare AND when
    # core declares an object the chain stopped adopting. It is also the
    # only formulation that survives a named schema, where core mangles
    # three of these index names per-schema and a fixed list cannot.
    @v4_adopted_tables ~w(
      phoenix_kit_billing_profiles
      phoenix_kit_currencies
      phoenix_kit_invoices
      phoenix_kit_orders
      phoenix_kit_transactions
      phoenix_kit_payment_methods
      phoenix_kit_subscriptions
      phoenix_kit_webhook_events
      phoenix_kit_payment_options
      phoenix_kit_subscription_types
    )

    test "up_statements/2 at target 4 emits exactly the index/constraint operations core's manifest declares for the ten adopted tables" do
      for prefix <- ["public", "billing_alt"] do
        not_v4 =
          ~r/phoenix_kit_payment_provider_configs|phoenix_kit_currencies_default_uidx|rounding_rule|rate_updated_at|base_currency|base_total|ADD COLUMN IF NOT EXISTS exchange_rate/

        actual =
          Migrations.up_statements(prefix, 4)
          |> Enum.reject(&(String.starts_with?(String.trim(&1), "UPDATE ") or &1 =~ not_v4))
          |> Enum.map(&operation/1)

        expected = v4_expected_operations(prefix)

        assert Enum.sort(actual) == Enum.sort(expected),
               """
               up_statements(#{inspect(prefix)}, 4) does not emit the operation set
               core's ExpectedSchema declares for V4's ten adopted tables.

               unexpected: #{inspect(Enum.sort(actual) -- Enum.sort(expected))}
               missing:    #{inspect(Enum.sort(expected) -- Enum.sort(actual))}
               """
      end
    end

    defp v4_expected_operations(prefix) do
      objects =
        ExpectedSchema.objects(prefix)
        |> Enum.filter(fn object ->
          case object.check do
            {_kind, %{table: table}} ->
              # `:legacy_optional` marks an object a later core version
              # renamed or retired. Core does not expect it to exist any
              # more, so adopting it would recreate it on every install.
              table in @v4_adopted_tables and object.class in [:index, :constraint] and
                Map.get(object, :presence) == :required

            _ ->
              false
          end
        end)
        |> Enum.map(fn object ->
          name = object.check |> elem(1) |> Map.fetch!(:name)

          case object.class do
            :constraint -> {"DO", name}
            :index -> {index_verb(object.create), name}
          end
        end)

      tables = Enum.map(@v4_adopted_tables, &{"CREATE TABLE", &1})

      tables ++ objects
    end

    defp index_verb(create) do
      if String.starts_with?(create, "CREATE UNIQUE INDEX"),
        do: "CREATE UNIQUE INDEX",
        else: "CREATE INDEX"
    end

    # `ON DELETE SET NULL` / `ON DELETE RESTRICT` are part of a foreign
    # key's DEFINITION — the word DELETE there describes what Postgres does
    # to a child row when a PARENT is deleted, and V4 adopting core's FKs
    # means reproducing core's referential actions verbatim. Scanning the
    # raw text for the token would flag every one of them, so the clause is
    # removed before the scan. `the referential-action strip does not blind
    # the destructive scan` below proves the removal did not blind the
    # check.
    defp strip_referential_actions(statement) do
      String.replace(
        statement,
        ~r/ON\s+(DELETE|UPDATE)\s+(CASCADE|RESTRICT|NO\s+ACTION|SET\s+NULL|SET\s+DEFAULT)/i,
        "ON <referential action>"
      )
    end

    test "the referential-action strip does not blind the destructive scan" do
      forbidden = ~r/\b(DROP TABLE|TRUNCATE|DELETE)\b/i

      mutant =
        "ALTER TABLE public.phoenix_kit_invoices ADD CONSTRAINT x FOREIGN KEY (order_uuid) " <>
          "REFERENCES public.phoenix_kit_orders(uuid) ON DELETE SET NULL; DROP TABLE public.phoenix_kit_invoices"

      assert strip_referential_actions(mutant) =~ forbidden

      assert strip_referential_actions("DELETE FROM public.phoenix_kit_invoices") =~ forbidden
      assert strip_referential_actions("TRUNCATE public.phoenix_kit_orders") =~ forbidden
    end

    # Core's V162 guards this one FK by COLUMN, not by name, and says why
    # in its own comment: an earlier build created it under Ecto's default
    # name. Adoption has to reproduce THAT guard — a name-keyed one finds
    # nothing on such a host and adds a second FK over the same column.
    test "the payment-option FK is guarded by column, the way core guards it" do
      [statement] =
        Enum.filter(
          Migrations.up_statements("public"),
          &String.contains?(&1, "ADD CONSTRAINT fk_orders_payment_option")
        )

      assert statement =~ "kcu.column_name = 'payment_option_uuid'",
             "the guard no longer keys on the column — a host carrying this FK " <>
               "under Ecto's default name would get a duplicate:\n#{statement}"

      refute statement =~ "c.conname = 'fk_orders_payment_option'",
             "the guard keys on the constraint NAME again:\n#{statement}"
    end

    test "no statement anywhere in the data-level chain can drop the table, truncate, or delete rows" do
      # Narrowed from a bare DROP to DROP TABLE: V2's down/1 legitimately
      # emits "DROP INDEX" and "ALTER TABLE ... DROP COLUMN" against
      # phoenix_kit_currencies — what must never appear anywhere is a
      # statement that could destroy a core-created TABLE, or bulk-mutate
      # its rows. Referential actions (`ON DELETE SET NULL`/`RESTRICT`) are
      # stripped first — those are part of V4's foreign key DEFINITIONS,
      # not a destructive operation on their own.
      forbidden = ~r/\b(DROP TABLE|TRUNCATE|DELETE)\b/i

      for prefix <- ["public", "billing_alt"] do
        for stmt <- Migrations.up_statements(prefix) do
          refute strip_referential_actions(stmt) =~ forbidden,
                 "up_statements(#{inspect(prefix)}) contains: #{stmt}"
        end

        for target <- [0, 1, 2, 3, 4] do
          for stmt <- Migrations.down_statements(prefix, target) do
            refute stmt =~ forbidden,
                   "down_statements(#{inspect(prefix)}, #{target}) contains: #{stmt}"
          end
        end
      end
    end

    # `{verb, object}` for one statement. The DO block is identified by the
    # constraint it adds, since its verb says nothing about its target.
    defp operation(statement) do
      normalized = statement |> String.replace(~r/\s+/, " ") |> String.trim()

      if String.starts_with?(normalized, "DO ") do
        [_, constraint] = Regex.run(~r/ADD CONSTRAINT (\w+)/, normalized)
        {"DO", constraint}
      else
        [_, verb, object] =
          Regex.run(
            ~r/^(CREATE UNIQUE INDEX|CREATE INDEX|CREATE TABLE|COMMENT ON TABLE|DROP TABLE|DROP INDEX|TRUNCATE|DELETE FROM|ALTER TABLE)(?: IF NOT EXISTS)? (?:\w+\.)?(\w+)/,
            normalized
          )

        {verb, object}
      end
    end
  end

  describe "what reaches the database is what the tests above inspect" do
    # The tests above read `up_statements/1` and `down_statements/2`. The
    # database gets `up/1` and `down/1`. Nothing connected the two, so a
    # literal `execute("DROP TABLE ...")` written straight into `up/1`
    # would have passed every one of them — the guard was watching the data
    # while the function did the work.
    #
    # Checked against the source text, because this suite has no repo and
    # cannot run a migration.
    @source "lib/phoenix_kit_billing/migrations.ex"

    test "neither direction executes SQL of its own" do
      source = File.read!(@source)

      refute source =~ ~r/execute\(/,
             """
             #{@source} calls execute/1 with an argument of its own.

             Every statement this chain runs must come from up_statements/1 or
             down_statements/2, because those are what the tests above compare
             against their expected content. A statement executed directly is
             invisible to all of them.
             """

      assert length(Regex.scan(~r/&execute\/1/, source)) == 2,
             "expected exactly two `&execute/1` references — one per direction — " <>
               "in #{@source}"
    end

    test "each direction executes its own builder" do
      source = File.read!(@source)

      assert source =~ ~r/up_statements\(target\)\s*\|>\s*Enum\.each\(&execute\/1\)/,
             "up/1 no longer pipes up_statements/2 into execute/1 — whatever it " <>
               "runs instead is not what the up_statements-based tests above check"

      assert source =~ ~r/down_statements\(target\)\s*\|>\s*Enum\.each\(&execute\/1\)/,
             "down/1 no longer pipes down_statements/2 into execute/1 — whatever it " <>
               "runs instead is not what `down/1 emits exactly the marker " <>
               "bookkeeping` checks"
    end

    # Scoped to the two functions' own bodies, not the whole file — the
    # moduledoc legitimately discusses "never drops the table" in prose,
    # which a whole-file, case-insensitive scan would flag as a false
    # positive on the English word rather than a SQL token.
    test "up/1 and down/1 themselves contain no DROP/TRUNCATE/DELETE token" do
      source = File.read!(@source)

      [up_body] = Regex.run(~r/def up\(.*?\n  end\n/s, source)
      [down_body] = Regex.run(~r/def down\(.*?\n  end\n/s, source)

      for {name, body} <- [{"up/1", up_body}, {"down/1", down_body}] do
        refute body =~ ~r/DROP|TRUNCATE|DELETE/i,
               "#{name}'s own body in #{@source} contains a DROP/TRUNCATE/DELETE token"
      end
    end
  end

  describe "V1 stays aligned with core's manifest (while core audits the table)" do
    alias PhoenixKit.Migrations.ExpectedSchema

    # Core's V135 baseline still creates this table and core's
    # ExpectedSchema audits that shape, so until the first shape-changing
    # chain version the two DDLs must agree. This test is optional
    # documentation more than a guard against drift this package could
    # introduce (V1 has no second copy of the shape to drift from), but it
    # doubles as proof that V1 changes nothing.
    #
    # The comparison is PER FIELD and asserts both key sets match in full
    # (not just present keys) — a parse that silently dropped some of
    # core's columns, or a V1 column core does not declare, must fail
    # here rather than be skipped.
    test "every column core declares matches V1's, in full" do
      core = core_columns_for("phoenix_kit_payment_provider_configs")
      ours = v1_columns()

      assert Map.keys(ours) -- Map.keys(core) == [],
             "V1 creates columns core's manifest does not declare: " <>
               inspect(Map.keys(ours) -- Map.keys(core))

      assert Map.keys(core) -- Map.keys(ours) == [],
             "V1 does not create columns core's manifest declares: " <>
               inspect(Map.keys(core) -- Map.keys(ours))

      for {column, expected} <- core do
        assert Map.fetch!(ours, column) == expected,
               """
               #{column}: V1 and core's manifest disagree on the column's shape.

               V1:              #{inspect(Map.fetch!(ours, column))}
               core's manifest: #{inspect(expected)}

               V1 is an adoption and must be shape-identical to core's
               baseline. A deliberate change is a chain version (V2+).
               """
      end
    end

    # `%{type, default, not_null}` per column, from the newest revision.
    defp core_columns_for(table) do
      prefix = "column:#{table}."

      ExpectedSchema.objects("public")
      |> Enum.filter(&(&1.class == :column and String.starts_with?(&1.id, prefix)))
      |> Map.new(fn object ->
        {_version, shape} = List.last(object.revisions)

        {String.replace_prefix(object.id, prefix, ""),
         %{type: shape.type, default: shape.default, not_null: shape.not_null}}
      end)
    end

    # The same shape, parsed back out of the CREATE TABLE V1 emits.
    defp v1_columns do
      [create | _] = Migrations.up_statements("public", 1)
      parse_create_columns(create)
    end

    defp parse_create_columns(create) do
      ~r/^\s*"(\w+)"\s+(.+?),?$/m
      |> Regex.scan(create)
      |> Map.new(fn [_line, name, definition] -> {name, parse_column(definition)} end)
    end

    defp parse_column(definition) do
      {definition, not_null} =
        case String.replace_suffix(definition, " NOT NULL", "") do
          ^definition -> {definition, false}
          trimmed -> {trimmed, true}
        end

      case String.split(definition, " DEFAULT ", parts: 2) do
        [type] -> %{type: type, default: nil, not_null: not_null}
        [type, default] -> %{type: type, default: default, not_null: not_null}
      end
    end
  end

  describe "V2 — currencies: default uniqueness + rounding/rate columns" do
    test "up_statements/2 at target 2 adds the partial unique index and both columns" do
      stmts = Migrations.up_statements("public", 2)

      assert Enum.any?(
               stmts,
               &(&1 =~
                   ~r/CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_currencies_default_uidx ON public\.phoenix_kit_currencies USING btree \(is_default\) WHERE is_default/)
             )

      assert Enum.any?(
               stmts,
               &(&1 =~
                   ~r/ADD COLUMN IF NOT EXISTS rounding_rule character varying\(16\) DEFAULT 'exact' NOT NULL/)
             )

      assert Enum.any?(
               stmts,
               &(&1 =~ ~r/ADD COLUMN IF NOT EXISTS rate_updated_at timestamp with time zone/)
             )

      assert List.last(stmts) =~ "pkb_schema:2"
    end

    test "up_statements/2 at target 1 is the V1 adoption only" do
      stmts = Migrations.up_statements("public", 1)
      refute Enum.any?(stmts, &(&1 =~ "phoenix_kit_currencies"))
      assert List.last(stmts) =~ "pkb_schema:1"
    end

    test "V2 demotes surplus default rows BEFORE creating the unique index" do
      stmts = Migrations.up_statements("public", 2)

      demote =
        Enum.find_index(
          stmts,
          &(&1 =~ ~r/UPDATE public\.phoenix_kit_currencies SET is_default = false/)
        )

      index =
        Enum.find_index(
          stmts,
          &(&1 =~ "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_currencies_default_uidx")
        )

      assert demote,
             "V2 must repair a table that already holds two default rows — " <>
               "CREATE UNIQUE INDEX aborts on exactly the databases this index " <>
               "exists to protect"

      assert demote < index, "the demotion must run before the index is created"

      # It keeps one default rather than clearing them all: a table with no
      # default row makes `get_default_currency/0` return nil everywhere.
      demote_stmt = Enum.at(stmts, demote)
      assert demote_stmt =~ "LIMIT 1"
      assert demote_stmt =~ "uuid <> ("
      refute demote_stmt =~ ~r/\bDELETE\b/i
    end

    test "the changeset declares the constraint under the exact name V2 creates" do
      # Two lists that must stay in sync: the DDL index name and the
      # `unique_constraint/3` name in `Currency.changeset/2`. If they drift,
      # a second default row raises Ecto.ConstraintError instead of
      # returning {:error, changeset}.
      declared =
        %PhoenixKitBilling.Currency{}
        |> PhoenixKitBilling.Currency.changeset(%{})
        |> Map.fetch!(:constraints)
        |> Enum.map(& &1.constraint)

      assert "phoenix_kit_currencies_default_uidx" in declared

      assert Enum.any?(
               Migrations.up_statements("public", 2),
               &(&1 =~ "phoenix_kit_currencies_default_uidx")
             )
    end

    test "down_statements/2 to 1 drops the index and both columns, never the table" do
      stmts = Migrations.down_statements("public", 1)

      assert Enum.any?(
               stmts,
               &(&1 =~ "DROP INDEX IF EXISTS public.phoenix_kit_currencies_default_uidx")
             )

      assert Enum.any?(stmts, &(&1 =~ "DROP COLUMN IF EXISTS rounding_rule"))
      assert Enum.any?(stmts, &(&1 =~ "DROP COLUMN IF EXISTS rate_updated_at"))
      refute Enum.any?(stmts, &(&1 =~ ~r/DROP TABLE/i))
      assert List.last(stmts) =~ "pkb_schema:1"
    end
  end

  describe "V3 — orders: frozen base_currency/exchange_rate/base_total columns" do
    test "up_statements/2 at target 3 adds all three columns, with core's own future types" do
      stmts = Migrations.up_statements("public", 3)

      assert Enum.any?(
               stmts,
               &(&1 ==
                   "ALTER TABLE public.phoenix_kit_orders ADD COLUMN IF NOT EXISTS base_currency character varying(3)")
             )

      assert Enum.any?(
               stmts,
               &(&1 ==
                   "ALTER TABLE public.phoenix_kit_orders ADD COLUMN IF NOT EXISTS exchange_rate numeric(15,6)")
             )

      assert Enum.any?(
               stmts,
               &(&1 ==
                   "ALTER TABLE public.phoenix_kit_orders ADD COLUMN IF NOT EXISTS base_total numeric(15,2)")
             )

      assert List.last(stmts) =~ "pkb_schema:3"
    end

    test "up_statements/2 at target 2 does not touch phoenix_kit_orders" do
      stmts = Migrations.up_statements("public", 2)
      refute Enum.any?(stmts, &(&1 =~ "phoenix_kit_orders"))
      assert List.last(stmts) =~ "pkb_schema:2"
    end

    test "down_statements/2 to 2 drops all three columns, never the table" do
      stmts = Migrations.down_statements("public", 2)

      assert Enum.any?(
               stmts,
               &(&1 == "ALTER TABLE public.phoenix_kit_orders DROP COLUMN IF EXISTS base_currency")
             )

      assert Enum.any?(
               stmts,
               &(&1 == "ALTER TABLE public.phoenix_kit_orders DROP COLUMN IF EXISTS exchange_rate")
             )

      assert Enum.any?(
               stmts,
               &(&1 == "ALTER TABLE public.phoenix_kit_orders DROP COLUMN IF EXISTS base_total")
             )

      refute Enum.any?(stmts, &(&1 =~ ~r/DROP TABLE/i))
      assert List.last(stmts) =~ "pkb_schema:2"
    end

    test "the columns match PhoenixKitBilling.Order's own field types" do
      # Two lists that must stay in sync: the DDL and the schema's `field/2`
      # declarations. A drift here means `Order.changeset/2` casts a shape
      # the database cannot store (or vice versa) without any test noticing
      # until a real insert fails.
      alias PhoenixKitBilling.Order

      fields = Order.__schema__(:fields)
      assert :base_currency in fields
      assert :exchange_rate in fields
      assert :base_total in fields

      assert Order.__schema__(:type, :base_currency) == :string
      assert Order.__schema__(:type, :exchange_rate) == :decimal
      assert Order.__schema__(:type, :base_total) == :decimal
    end
  end

  describe "V4 — adoption of the remaining ten core-baseline tables" do
    alias PhoenixKit.Migrations.ExpectedSchema

    @v4_tables ~w(
      phoenix_kit_billing_profiles
      phoenix_kit_currencies
      phoenix_kit_invoices
      phoenix_kit_orders
      phoenix_kit_transactions
      phoenix_kit_payment_methods
      phoenix_kit_subscriptions
      phoenix_kit_webhook_events
      phoenix_kit_payment_options
      phoenix_kit_subscription_types
    )

    # Columns this chain's OWN later versions already own (V2 on
    # currencies, V3 on orders) — see the moduledoc's V4 section. V4's
    # CREATE TABLE deliberately omits them, so core's manifest (which, as
    # of core's own V185, ALSO independently declares
    # base_currency/exchange_rate/base_total on orders — see the
    # moduledoc) is expected to disagree on exactly this set, and nothing
    # else.
    @v4_known_column_gaps %{
      "phoenix_kit_orders" => ~w(base_currency base_total exchange_rate)
    }

    test "up_statements/2 at target 4 creates all ten tables" do
      stmts = Migrations.up_statements("public", 4)

      for table <- @v4_tables do
        assert Enum.any?(
                 stmts,
                 &String.contains?(&1, "CREATE TABLE IF NOT EXISTS public.#{table} ")
               ),
               "V4 does not create #{table}"
      end

      assert List.last(stmts) =~ "pkb_schema:4"
    end

    test "up_statements/2 at target 3 does not touch any V4 table" do
      stmts = Migrations.up_statements("public", 3)

      for table <- @v4_tables, table not in ["phoenix_kit_currencies", "phoenix_kit_orders"] do
        refute Enum.any?(stmts, &String.contains?(&1, table)), "V3 touched #{table}"
      end

      assert List.last(stmts) =~ "pkb_schema:3"
    end

    test "down_statements/2 to 3 drops nothing V4 added (V4 is pure adoption)" do
      # Rolling back to 3 and to 4 differ ONLY in the marker: V4 changed no
      # shape, so it adds nothing to undo. (Both undo V5.)
      [marker3 | rest3] = Enum.reverse(Migrations.down_statements("public", 3))
      [marker4 | rest4] = Enum.reverse(Migrations.down_statements("public", 4))

      assert rest3 == rest4

      assert marker3 ==
               "COMMENT ON TABLE public.phoenix_kit_payment_provider_configs IS 'pkb_schema:3'"

      assert marker4 ==
               "COMMENT ON TABLE public.phoenix_kit_payment_provider_configs IS 'pkb_schema:4'"
    end

    # Same guard as V1's "every column core declares matches V1's, in
    # full" test, extended to the other nine tables — this is the check
    # that would have caught the historical mistake this content was
    # originally written with: transcribing a CREATE TABLE from core's
    # V135 baseline alone misses later core columns (V162 added
    # `payment_option_uuid` to orders). `phoenix_kit_orders` is the one
    # exception, and only for the three columns V3 (and, independently,
    # core's own V185) already own — see `@v4_known_column_gaps` above.
    test "every column core declares for each adopted table is in V4's CREATE TABLE (except columns this chain's own later versions own)" do
      creates = v4_creates()

      for table <- @v4_tables do
        core = core_columns_for(table)
        ours = Map.fetch!(creates, table)
        known_gap = Map.get(@v4_known_column_gaps, table, [])

        missing = Map.keys(core) -- Map.keys(ours)

        assert Enum.sort(missing) == Enum.sort(known_gap),
               "#{table}: V4 does not create columns core declares (beyond the known gap): " <>
                 inspect(Enum.sort(missing) -- Enum.sort(known_gap))

        assert Map.keys(ours) -- Map.keys(core) == [],
               "#{table}: V4 creates columns core does not declare: " <>
                 inspect(Map.keys(ours) -- Map.keys(core))

        for {column, expected} <- core, column not in known_gap do
          assert Map.fetch!(ours, column) == expected,
                 """
                 #{table}.#{column}: V4 and core's manifest disagree.

                 V4:              #{inspect(Map.fetch!(ours, column))}
                 core's manifest: #{inspect(expected)}
                 """
        end
      end
    end

    defp v4_creates do
      Migrations.up_statements("public", 4)
      |> Enum.filter(&String.starts_with?(&1, "CREATE TABLE"))
      |> Map.new(fn create ->
        [_, table] = Regex.run(~r/CREATE TABLE IF NOT EXISTS public\.(\w+)/, create)
        {table, parse_create_columns(create)}
      end)
    end
  end
end
