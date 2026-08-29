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
    test "current_version/0 and version_table/0" do
      assert Migrations.current_version() == 2
      assert Migrations.version_table() == "phoenix_kit_payment_provider_configs"
    end

    test "rejects a prefix that cannot be safely interpolated into DDL" do
      for bad <- ["public.\"; DROP TABLE x; --", "1st", "a-b", ""] do
        assert_raise ArgumentError, fn -> Migrations.up_statements(bad) end
        assert_raise ArgumentError, fn -> Migrations.down_statements(bad, 0) end
      end
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

    # V1 shipped in 0.9.0. A host that has run it will never run it again,
    # so editing it does not "fix" that host — it silently splits fresh
    # installs from existing ones. This pins V1's published content so the
    # split has to be deliberate: the four statements below are exactly
    # what 0.9.0 executes, verified against the published tag's source.
    test "V1's published statements are frozen" do
      v1 = Migrations.v1_statements("public.", "public")

      assert length(v1) == 4

      normalised = Enum.map(v1, &(&1 |> String.replace(~r/\s+/, " ") |> String.trim()))

      assert normalised == [
               "CREATE TABLE IF NOT EXISTS public.phoenix_kit_payment_provider_configs ( \"provider\" character varying(20) NOT NULL, \"enabled\" boolean DEFAULT false NOT NULL, \"mode\" character varying(10) DEFAULT 'test'::character varying NOT NULL, \"api_key\" text, \"api_secret\" text, \"webhook_secret\" text, \"webhook_url\" character varying(255), \"last_verified_at\" timestamp with time zone, \"verification_status\" character varying(20) DEFAULT 'pending'::character varying, \"verification_error\" text, \"config\" jsonb DEFAULT '{}'::jsonb NOT NULL, \"inserted_at\" timestamp with time zone NOT NULL, \"updated_at\" timestamp with time zone NOT NULL, \"uuid\" uuid DEFAULT public.uuid_generate_v7() NOT NULL )",
               "DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid JOIN pg_namespace n ON n.oid = t.relnamespace WHERE c.conname = 'phoenix_kit_payment_provider_configs_pkey' AND t.relname = 'phoenix_kit_payment_provider_configs' AND n.nspname = 'public' ) THEN ALTER TABLE public.phoenix_kit_payment_provider_configs ADD CONSTRAINT phoenix_kit_payment_provider_configs_pkey PRIMARY KEY (uuid); END IF; END $$",
               "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_payment_provider_configs_provider_uidx ON public.phoenix_kit_payment_provider_configs USING btree (provider)",
               "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_payment_provider_configs_uuid_idx ON public.phoenix_kit_payment_provider_configs USING btree (uuid)"
             ]

      refute Enum.any?(v1, &String.starts_with?(&1, "COMMENT")),
             "the marker is stamped by the chain for its TARGET version, not baked into V1"
    end

    test "up stamps the version marker, and stamps it last" do
      statements = Migrations.up_statements()

      assert List.last(statements) ==
               "COMMENT ON TABLE public.phoenix_kit_payment_provider_configs IS 'pkb_schema:2'",
             "the marker must be stamped after the DDL it certifies, not before"
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

      for stmt <- ddl do
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
    test "down/1 emits exactly the marker bookkeeping, in every target and prefix" do
      assert Migrations.down_statements("public", 0) ==
               ["COMMENT ON TABLE public.phoenix_kit_payment_provider_configs IS NULL"]

      assert Migrations.down_statements("public", 1) ==
               ["COMMENT ON TABLE public.phoenix_kit_payment_provider_configs IS 'pkb_schema:1'"]

      assert Migrations.down_statements("billing_alt", 0) ==
               ["COMMENT ON TABLE billing_alt.phoenix_kit_payment_provider_configs IS NULL"]

      assert Migrations.down_statements("billing_alt", 2) ==
               [
                 "COMMENT ON TABLE billing_alt.phoenix_kit_payment_provider_configs IS 'pkb_schema:2'"
               ]
    end

    # For `up/1` the expected content is the full set of OPERATIONS rather
    # than the full SQL text. An operation is `{verb, object}`, immune to
    # reformatting and still failing on any statement added, removed or
    # retargeted — including a destructive one, which cannot enter this set
    # without changing it.
    # The expected set is CORE'S MANIFEST for the eleven tables this chain
    # adopts, not a hand-typed list. A hand-typed list is maintained by the
    # same hand that adds a statement, so it catches a slip but never a
    # deliberate one; the manifest is written on core's side, so this fails
    # both when the chain emits an object core does not declare AND when
    # core declares an object the chain stopped adopting. It is also the
    # only formulation that survives a named schema, where core mangles
    # three of these index names per-schema and a fixed list cannot.
    @adopted_tables ~w(
      phoenix_kit_payment_provider_configs
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

    test "up/1 emits exactly the operations core's manifest declares, and no others" do
      for prefix <- ["public", "billing_alt"] do
        actual = Enum.map(Migrations.up_statements(prefix), &operation/1)
        expected = expected_operations(prefix)

        assert Enum.sort(actual) == Enum.sort(expected),
               """
               up_statements(#{inspect(prefix)}) does not emit the operation set
               core's ExpectedSchema declares for the adopted tables.

               unexpected: #{inspect(Enum.sort(actual) -- Enum.sort(expected))}
               missing:    #{inspect(Enum.sort(expected) -- Enum.sort(actual))}

               Every statement this chain emits runs against a core-created
               table. Adding one is a chain version, not something to slip
               past this comparison.
               """
      end
    end

    # Pins the SIZE independently of the comparison above: if the manifest
    # filter silently matched nothing (a renamed field, a changed check
    # shape), both sides of that assertion would shrink together and stay
    # green while proving nothing.
    test "the adopted operation set is the size this chain was written for" do
      assert length(expected_operations("public")) == 79
    end

    defp expected_operations(prefix) do
      objects =
        ExpectedSchema.objects(prefix)
        |> Enum.filter(fn object ->
          case object.check do
            {_kind, %{table: table}} ->
              # `:legacy_optional` marks an object a later core version
              # renamed or retired. Core does not expect it to exist any
              # more, so adopting it would recreate it on every install.
              table in @adopted_tables and object.class in [:index, :constraint] and
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

      tables = Enum.map(@adopted_tables, &{"CREATE TABLE", &1})

      tables ++ objects ++ [{"COMMENT ON TABLE", "phoenix_kit_payment_provider_configs"}]
    end

    defp index_verb(create) do
      if String.starts_with?(create, "CREATE UNIQUE INDEX"),
        do: "CREATE UNIQUE INDEX",
        else: "CREATE INDEX"
    end

    # `ON DELETE SET NULL` / `ON DELETE RESTRICT` are part of a foreign key's
    # DEFINITION — the word DELETE there describes what Postgres does to a
    # child row when a PARENT is deleted, and adopting core's FKs means
    # reproducing core's referential actions verbatim. Scanning the raw text
    # for the token would flag every one of them, so the clause is removed
    # before the scan. `delete_teeth/0` below proves the removal did not
    # blind the check.
    defp strip_referential_actions(statement) do
      String.replace(
        statement,
        ~r/ON\s+(DELETE|UPDATE)\s+(CASCADE|RESTRICT|NO\s+ACTION|SET\s+NULL|SET\s+DEFAULT)/i,
        "ON <referential action>"
      )
    end

    test "the referential-action strip does not blind the destructive scan" do
      forbidden = ~r/\b(DROP|TRUNCATE|DELETE)\b/i

      # A statement that carries a legitimate referential action AND a real
      # destructive verb must still be caught.
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
    # nothing on such a host and adds a second FK over the same column
    # (reproduced against a real database before this was fixed).
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

    test "no statement anywhere in the data-level chain can drop/truncate/delete" do
      forbidden = ~r/\b(DROP|TRUNCATE|DELETE)\b/i

      for prefix <- ["public", "billing_alt"] do
        for stmt <- Migrations.up_statements(prefix) do
          refute strip_referential_actions(stmt) =~ forbidden,
                 "up_statements(#{inspect(prefix)}) contains: #{stmt}"
        end

        for target <- [0, 1, 2] do
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
             "up/1 no longer pipes up_statements/1 into execute/1 — whatever it " <>
               "runs instead is not what `up/1 emits exactly these operations` checks"

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
      core = core_columns()
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
    defp core_columns do
      ExpectedSchema.objects("public")
      |> Enum.filter(
        &(&1.class == :column and
            String.starts_with?(&1.id, "column:phoenix_kit_payment_provider_configs."))
      )
      |> Map.new(fn object ->
        {_version, shape} = List.last(object.revisions)

        {String.replace_prefix(object.id, "column:phoenix_kit_payment_provider_configs.", ""),
         %{type: shape.type, default: shape.default, not_null: shape.not_null}}
      end)
    end

    # The same shape, parsed back out of the CREATE TABLE V1 emits.
    defp v1_columns do
      [create | _] = Migrations.up_statements()

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

  describe "V2 stays aligned with core's manifest for all ten adopted tables" do
    alias PhoenixKit.Migrations.ExpectedSchema

    @v2_tables ~w(
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

    # The V1 test below proves one table's columns match core. This does
    # the same for the other ten, and it is the guard that would have
    # caught the mistake this version was originally written with:
    # transcribing the CREATE TABLE from core's V135 alone, when V162 had
    # since added `payment_option_uuid` to orders. A column core declares
    # and V2 does not create is a table that comes out WRONG on any future
    # install that gets it from this chain instead of core's baseline.
    test "every column core declares for each adopted table is in V2's CREATE TABLE" do
      creates = v2_creates()

      for table <- @v2_tables do
        core = core_columns_for(table)
        ours = Map.fetch!(creates, table)

        assert Map.keys(core) -- Map.keys(ours) == [],
               "#{table}: V2 does not create columns core declares: " <>
                 inspect(Map.keys(core) -- Map.keys(ours))

        assert Map.keys(ours) -- Map.keys(core) == [],
               "#{table}: V2 creates columns core does not declare: " <>
                 inspect(Map.keys(ours) -- Map.keys(core))

        for {column, expected} <- core do
          assert Map.fetch!(ours, column) == expected,
                 """
                 #{table}.#{column}: V2 and core's manifest disagree.

                 V2:              #{inspect(Map.fetch!(ours, column))}
                 core's manifest: #{inspect(expected)}
                 """
        end
      end
    end

    # Pins the SIZE of what the filter above matched. Without it, a filter
    # that matched NOTHING would make every assertion in the test above
    # compare two empty maps and iterate zero times — green, and proving
    # nothing at all.
    test "the manifest filter actually matches core's columns" do
      totals = Map.new(@v2_tables, &{&1, map_size(core_columns_for(&1))})

      assert totals == %{
               "phoenix_kit_billing_profiles" => 23,
               "phoenix_kit_currencies" => 11,
               "phoenix_kit_invoices" => 27,
               "phoenix_kit_orders" => 27,
               "phoenix_kit_transactions" => 13,
               "phoenix_kit_payment_methods" => 16,
               "phoenix_kit_subscriptions" => 24,
               "phoenix_kit_webhook_events" => 11,
               "phoenix_kit_payment_options" => 14,
               "phoenix_kit_subscription_types" => 15
             }
    end

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

    defp v2_creates do
      Migrations.v2_statements("public.", "public")
      |> Enum.filter(&String.starts_with?(&1, "CREATE TABLE"))
      |> Map.new(fn create ->
        [_, table] = Regex.run(~r/CREATE TABLE IF NOT EXISTS public\.(\w+)/, create)

        columns =
          ~r/^\s*"(\w+)"\s+(.+?),?$/m
          |> Regex.scan(create)
          |> Map.new(fn [_line, name, definition] -> {name, parse_column(definition)} end)

        {table, columns}
      end)
    end
  end
end
