defmodule PhoenixKitBilling.UserMenuTabsTest do
  @moduledoc """
  "My Orders" and "Billing Profiles" join the avatar dropdown only beside a
  shop: without a storefront a visitor has no orders of their own, so the
  entries would be noise in every signed-in user's menu.
  """
  # Not async: the positive test registers a stand-in "shop" module in the
  # global `PhoenixKit.ModuleRegistry`.
  use ExUnit.Case, async: false

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.ModuleRegistry

  defmodule StubShop do
    @moduledoc false
    # Just enough of `PhoenixKit.Module` for the registry to learn the "shop" key
    # and ask `enabled?/0`; the registry reads every callback through `safe_call`.
    def module_key, do: "shop"
    def permission_metadata, do: %{key: "shop", label: "Shop", icon: "hero-shopping-cart"}
    def enabled?, do: :persistent_term.get(__MODULE__, true)
  end

  test "both user tabs are gated on the shop module" do
    tabs = PhoenixKitBilling.user_dashboard_tabs()
    assert Enum.map(tabs, & &1.id) == [:dashboard_orders, :dashboard_billing_profiles]

    for tab <- tabs do
      assert tab.metadata[:user_menu] == (&PhoenixKitBilling.user_menu_with_shop?/1),
             "#{inspect(tab.id)} is not gated on the shop"
    end
  end

  test "with no shop module installed, nothing reaches the dropdown" do
    # This suite runs without phoenix_kit_ecommerce, so core knows no "shop" key.
    refute PhoenixKitBilling.user_menu_with_shop?(nil)

    for tab <- PhoenixKitBilling.user_dashboard_tabs() do
      refute Tab.user_menu?(tab, nil)
    end
  end

  describe "with a shop module registered" do
    setup do
      :ok = ModuleRegistry.register(StubShop)
      on_exit(fn -> ModuleRegistry.unregister(StubShop) end)
    end

    test "the tabs reach the dropdown while the shop is enabled" do
      :persistent_term.put(StubShop, true)
      on_exit(fn -> :persistent_term.erase(StubShop) end)

      assert PhoenixKitBilling.user_menu_with_shop?(nil)

      for tab <- PhoenixKitBilling.user_dashboard_tabs() do
        assert Tab.user_menu?(tab, nil), "#{inspect(tab.id)} missing from the dropdown"
      end
    end

    test "they leave it again when the shop is switched off" do
      :persistent_term.put(StubShop, false)
      on_exit(fn -> :persistent_term.erase(StubShop) end)

      refute PhoenixKitBilling.user_menu_with_shop?(nil)

      for tab <- PhoenixKitBilling.user_dashboard_tabs() do
        refute Tab.user_menu?(tab, nil)
      end
    end
  end
end
