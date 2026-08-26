defmodule PhoenixKitBilling.Test.LiveDatabaseGuardTest do
  @moduledoc """
  S014: pure unit coverage for `check!/1`'s own decision — separate from
  `PhoenixKitBilling.LiveDatabaseGuardWiringTest`, which proves the module
  is actually reachable from `test_helper.exs`'s real boot sequence, not
  just that its logic is correct in isolation.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitBilling.Test.LiveDatabaseGuard

  describe "check!/1" do
    test "raises for each of this container's known live databases" do
      for db <- ~w(phoenix_kit_dev decor_3d_print_dev phoenixkit_hello_world_dev) do
        assert_raise LiveDatabaseGuard.LiveDatabaseError, ~r/#{db}/, fn ->
          LiveDatabaseGuard.check!(db)
        end
      end
    end

    test "the raised message says WHY, not just which database" do
      assert_raise LiveDatabaseGuard.LiveDatabaseError,
                   ~r/PGDATABASE leaks into every shell/,
                   fn -> LiveDatabaseGuard.check!("phoenix_kit_dev") end
    end

    test "passes an isolated test database name straight through" do
      assert :ok = LiveDatabaseGuard.check!("phoenix_kit_billing_test")
    end

    test "a name that merely CONTAINS a known live database's name is not a match" do
      # Substring matching would be its own bug: a scratch DB deliberately
      # named to include "phoenix_kit_dev" for debugging purposes (or a
      # partition suffix landing awkwardly) must not be refused — only an
      # EXACT match to a known live database is ever the actual live one.
      assert :ok = LiveDatabaseGuard.check!("not_phoenix_kit_dev_but_looks_like_it")
      assert :ok = LiveDatabaseGuard.check!("phoenix_kit_dev_backup")
    end

    test "an empty or unusual name is never mistaken for a live database" do
      assert :ok = LiveDatabaseGuard.check!("")
      assert :ok = LiveDatabaseGuard.check!("phoenix_kit_billing_test1")
    end
  end
end
