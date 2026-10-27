defmodule PhoenixKitBilling.Web.DetailPagesAuthzTest do
  @moduledoc """
  The detail and form pages have no admin tab of their own, so core's route
  gate admits any holder of the base `"billing"` key. Each page therefore
  checks, at mount, the capability that gates the same records on their
  list tab - and the base Dashboard shows a section only to the holder of
  that section's capability.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKitBilling, as: Billing

  defp conn_with(conn, permissions) do
    put_test_scope(conn, fake_scope(roles: ["Employee"], permissions: permissions))
  end

  defp assert_refused(conn, path) do
    assert {:error, {:live_redirect, %{to: to, flash: %{"error" => message}}}} = live(conn, path)
    assert to =~ "/admin/billing"
    assert message == "You don't have permission to do that"
  end

  setup do
    user = fixture_user()

    {:ok, order} =
      Billing.create_order(user, %{
        "total" => Decimal.new("99.00"),
        "currency" => "EUR",
        "billing_snapshot" => %{"email" => "g@example.com"}
      })

    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    {:ok, type} =
      Billing.create_subscription_type(%{
        name: "Pro",
        slug: "pro-#{System.unique_integer([:positive])}",
        price: Decimal.new("29.99")
      })

    {:ok, subscription} =
      Billing.create_subscription(user.uuid, %{subscription_type_uuid: type.uuid})

    {:ok, profile} =
      Billing.create_billing_profile(user, %{
        "type" => "individual",
        "first_name" => "Jane",
        "last_name" => "Roe",
        "country" => "EE"
      })

    {:ok,
     order: order, invoice: invoice, type: type, subscription: subscription, profile: profile}
  end

  defp pages(ctx) do
    [
      {"/en/admin/billing/orders/new", "billing.manage_orders"},
      {"/en/admin/billing/orders/#{ctx.order.uuid}", "billing.manage_orders"},
      {"/en/admin/billing/orders/#{ctx.order.uuid}/edit", "billing.manage_orders"},
      {"/en/admin/billing/invoices/#{ctx.invoice.uuid}", "billing.manage_invoices"},
      {"/en/admin/billing/subscriptions/new", "billing.manage_subscriptions"},
      {"/en/admin/billing/subscriptions/#{ctx.subscription.uuid}",
       "billing.manage_subscriptions"},
      {"/en/admin/billing/subscriptions/#{ctx.subscription.uuid}/edit",
       "billing.manage_subscriptions"},
      {"/en/admin/billing/subscription-types/new", "billing.manage_subscriptions"},
      {"/en/admin/billing/subscription-types/#{ctx.type.uuid}/edit",
       "billing.manage_subscriptions"},
      {"/en/admin/billing/profiles/new", "billing.manage_orders"},
      {"/en/admin/billing/profiles/#{ctx.profile.uuid}/edit", "billing.manage_orders"}
    ]
  end

  test "the base key alone opens no detail or form page", %{conn: conn} = ctx do
    conn = conn_with(conn, ["billing"])

    for {path, _key} <- pages(ctx), do: assert_refused(conn, path)
  end

  test "a sibling capability does not open another capability's page", %{conn: conn} = ctx do
    for {path, key} <- pages(ctx) do
      siblings = billing_permissions() -- [key]
      assert_refused(conn_with(conn, siblings), path)
    end
  end

  test "the holder of the page's capability opens it", %{conn: conn} = ctx do
    for {path, key} <- pages(ctx) do
      assert {:ok, _view, _html} = live(conn_with(conn, ["billing", key]), path)
    end
  end

  describe "base Dashboard" do
    test "a base-only holder sees no order or invoice figures", %{conn: conn} = ctx do
      {:ok, _view, html} = live(conn_with(conn, ["billing"]), "/en/admin/billing/")

      refute html =~ ctx.order.order_number
      refute html =~ ctx.invoice.invoice_number
      refute html =~ "Recent Orders"
      refute html =~ "Recent Invoices"
      refute html =~ "Paid Revenue"
      refute html =~ "Total Orders"
      refute html =~ "Payment Providers"
      refute html =~ "Active Currencies"
    end

    test "each capability reveals only its own section", %{conn: conn} = ctx do
      {:ok, _view, html} =
        live(conn_with(conn, ["billing", "billing.manage_orders"]), "/en/admin/billing/")

      assert html =~ ctx.order.order_number
      assert html =~ "Total Orders"
      refute html =~ ctx.invoice.invoice_number
      refute html =~ "Paid Revenue"
      refute html =~ "Active Currencies"

      {:ok, _view, html} =
        live(conn_with(conn, ["billing", "billing.manage_invoices"]), "/en/admin/billing/")

      assert html =~ ctx.invoice.invoice_number
      assert html =~ "Paid Revenue"
      refute html =~ ctx.order.order_number
      refute html =~ "Total Orders"
      refute html =~ "Active Currencies"
    end

    test "settings holders see currencies on load and refresh", %{conn: conn} do
      {:ok, view, html} =
        live(conn_with(conn, ["billing", "billing.manage_settings"]), "/en/admin/billing/")

      assert html =~ "Active Currencies"
      assert has_element?(view, "a[href='/admin/billing/currencies']")

      assert view |> element("button[phx-click='refresh']") |> render_click() =~
               "Active Currencies"
    end

    test "dashboard navigation reloads recent records", %{conn: conn} = ctx do
      {:ok, view, _html} =
        live(conn_with(conn, ["billing", "billing.manage_orders"]), "/en/admin/billing/")

      assert {:ok, order} =
               Billing.create_order(ctx.order.user_uuid, %{
                 "total" => Decimal.new("7.00"),
                 "currency" => "EUR",
                 "billing_snapshot" => %{"email" => "g@example.com"}
               })

      refute render(view) =~ order.order_number
      assert render_patch(view, "/en/admin/billing/?refresh=1") =~ order.order_number
    end
  end
end
