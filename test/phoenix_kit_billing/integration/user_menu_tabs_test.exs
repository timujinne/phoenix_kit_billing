defmodule PhoenixKitBilling.Integration.UserMenuTabsTest do
  use PhoenixKitBilling.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKit.Dashboard.Registry, as: TabRegistry
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.Components.UserDashboardNav

  defmodule StubShop do
    @moduledoc false
    def module_key, do: "shop"
    def permission_metadata, do: %{key: "shop", label: "Shop", icon: "hero-shopping-cart"}
    def enabled?, do: PhoenixKit.Settings.get_boolean_setting("shop_enabled", false)
  end

  setup do
    :ok = ModuleRegistry.register(StubShop)
    on_exit(fn -> ModuleRegistry.unregister(StubShop) end)
    assert {:ok, _} = Settings.update_setting("shop_enabled", "true")

    start_supervised!(TabRegistry)
    # Wait for core's deferred module-tab loading before reading its ETS table.
    :sys.get_state(TabRegistry)

    %{scope: Scope.for_user(fixture_user())}
  end

  test "core loads both entries and renders localized links under the host prefix", %{
    scope: scope
  } do
    assert Enum.map(billing_menu_tabs(scope), &{&1.id, &1.path}) == [
             {:dashboard_orders, "/dashboard/billing-orders"},
             {:dashboard_billing_profiles, "/dashboard/billing-profiles"}
           ]

    assert {:ok, _} = Settings.update_setting("languages_enabled", "true")
    original_prefix = :persistent_term.get({PhoenixKit.Config, :url_prefix})
    on_exit(fn -> :persistent_term.put({PhoenixKit.Config, :url_prefix}, original_prefix) end)
    :persistent_term.put({PhoenixKit.Config, :url_prefix}, "/portal")
    Gettext.put_locale(PhoenixKitBilling.Gettext, "ru")

    html =
      render_component(&UserDashboardNav.user_menu_tab_links/1,
        scope: scope,
        current_locale: "ru"
      )

    assert html =~ "href=\"/portal/ru/dashboard/billing-orders\""
    assert html =~ "href=\"/portal/ru/dashboard/billing-profiles\""
    assert html =~ Gettext.dgettext(PhoenixKitBilling.Gettext, "default", "My Orders")
    assert html =~ Gettext.dgettext(PhoenixKitBilling.Gettext, "default", "Billing Profiles")
  end

  test "switching the shop off hides the entries without removing the dashboard tabs", %{
    scope: scope
  } do
    assert length(billing_menu_tabs(scope)) == 2
    assert {:ok, _} = Settings.update_setting("shop_enabled", "false")

    assert billing_menu_tabs(scope) == []

    assert Enum.map(billing_dashboard_tabs(scope), & &1.id) == [
             :dashboard_orders,
             :dashboard_billing_profiles
           ]

    assert {:ok, _} = Settings.update_setting("shop_enabled", "true")
    assert length(billing_menu_tabs(scope)) == 2
  end

  test "an absent shop or scope yields no billing dropdown entries", %{scope: scope} do
    assert length(billing_menu_tabs(scope)) == 2
    assert TabRegistry.get_user_menu_tabs(nil) == []

    :ok = ModuleRegistry.unregister(StubShop)
    assert billing_menu_tabs(scope) == []
  end

  defp billing_menu_tabs(scope) do
    scope
    |> TabRegistry.get_user_menu_tabs()
    |> Enum.filter(&(&1.id in [:dashboard_orders, :dashboard_billing_profiles]))
  end

  defp billing_dashboard_tabs(scope) do
    [scope: scope]
    |> TabRegistry.get_user_tabs()
    |> Enum.filter(&(&1.id in [:dashboard_orders, :dashboard_billing_profiles]))
  end
end
