defmodule PhoenixKitBilling.Web.ListingLvsTest do
  @moduledoc """
  LiveView smoke tests for the main billing list pages mounted by the
  test router: Orders, Invoices, Currencies, Subscriptions.

  Each LV's `mount/3` checks `Billing.enabled?()` and redirects to
  `/admin` when the module is disabled, so we set `billing_enabled=true`
  globally — which forces `async: false`.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing

  # The user has to be a REAL row, not `fake_scope/1`'s generated uuid: the
  # "renders a seeded ..." tests below insert an order and an invoice, and both
  # tables carry an FK to `phoenix_kit_users` (`fk_orders_user_uuid` /
  # `fk_invoices_user_uuid`). With an unpersisted scope user those inserts
  # raise `Ecto.ConstraintError` — which is what they did, silently, for as
  # long as this suite ran without a reachable database.
  setup %{conn: conn} do
    Settings.update_setting("billing_enabled", "true")
    user = fixture_user()
    scope = fake_scope(user_uuid: user.uuid, email: user.email)
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, user: user}
  end

  describe "Orders" do
    test "mounts and shows the empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/billing/orders")
      assert html =~ "Orders"
      assert html =~ "No orders found"
    end

    test "renders a seeded order", %{conn: conn, user: user} do
      {:ok, order} =
        Billing.create_order(user.uuid, %{
          "total" => Decimal.new("99.00"),
          "currency" => "EUR",
          "billing_snapshot" => %{"email" => "g@example.com"}
        })

      {:ok, _view, html} = live(conn, "/en/admin/billing/orders")
      assert html =~ order.order_number
    end
  end

  describe "Invoices" do
    test "mounts and shows the empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/billing/invoices")
      assert html =~ "Invoices"
      assert html =~ "No invoices found"
    end

    test "renders a seeded invoice", %{conn: conn, user: user} do
      {:ok, invoice} =
        Billing.create_invoice(user.uuid, %{total: Decimal.new("50.00"), currency: "EUR"})

      {:ok, _view, html} = live(conn, "/en/admin/billing/invoices")
      assert html =~ invoice.invoice_number
    end
  end

  describe "Currencies" do
    test "mounts and lists the seeded currencies", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/billing/currencies")
      assert html =~ "Currencies"
      # EUR is seeded by core migration V31.
      assert html =~ "EUR"
    end
  end

  describe "Subscriptions" do
    test "mounts and shows the empty state", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, "/en/admin/billing/subscriptions")
      assert html =~ "Subscriptions"
      assert html =~ "No subscriptions found"
    end
  end
end
