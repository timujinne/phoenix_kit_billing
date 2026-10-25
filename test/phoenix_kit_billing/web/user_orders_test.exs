defmodule PhoenixKitBilling.Web.UserOrdersTest do
  @moduledoc """
  Regression tests for the customer-facing "My Orders" LiveView
  (`/dashboard/billing-orders`).

  `Billing.list_user_orders/3`'s new `:preload` option is what makes this
  page work at all — the association is unloaded by default, and the
  template reads `order.invoices` and `invoice.transactions` for every
  order it renders. Test 1 below doubles as the regression guard for that:
  confirmed red (`** (Ecto.Association.NotLoaded) ...` /
  `Protocol.UndefinedError` on `Enum.empty?(order.invoices)`, depending on
  which line hits the unloaded struct first) against a version of
  `UserOrders.mount/3` with `preload: [invoices: :transactions]` dropped
  from the `list_user_orders/3` call, green again once restored.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Web.UserOrders

  setup %{conn: conn} do
    Settings.update_setting("billing_enabled", "true")
    user = fixture_user()
    scope = fake_scope(user_uuid: user.uuid, email: user.email)
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, user: user}
  end

  defp fixture_order_chain(user) do
    {:ok, order} =
      Billing.create_order(user.uuid, %{
        "total" => Decimal.new("100.00"),
        "currency" => "EUR",
        "billing_snapshot" => %{"email" => user.email}
      })

    {:ok, invoice} = Billing.create_invoice_from_order(order)

    {:ok, invoice, :skipped} =
      Billing.send_invoice(invoice, to_email: user.email, send_email: false)

    {:ok, _payment} = Billing.record_payment(invoice, %{amount: "60.00"}, nil)
    paid_invoice = Billing.get_invoice!(invoice.uuid)
    {:ok, _refund} = Billing.record_refund(paid_invoice, %{amount: "10.00"}, nil)

    order
  end

  describe "UserOrders" do
    test "renders the current user's own orders, invoices, and transactions", %{
      conn: conn,
      user: user
    } do
      order = fixture_order_chain(user)
      invoice = Billing.get_order(order.uuid, preload: [:invoices]).invoices |> hd()

      {:ok, _view, html} = live(conn, "/en/dashboard/billing-orders")

      assert html =~ order.order_number
      assert html =~ invoice.invoice_number
      assert html =~ "Payment"
      assert html =~ "Refund"
    end

    test "never shows another user's orders", %{conn: conn, user: user} do
      order = fixture_order_chain(user)

      other_user = fixture_user()

      {:ok, other_order} =
        Billing.create_order(other_user.uuid, %{
          "total" => Decimal.new("50.00"),
          "currency" => "EUR",
          "billing_snapshot" => %{"email" => other_user.email}
        })

      {:ok, _view, html} = live(conn, "/en/dashboard/billing-orders")

      assert html =~ order.order_number
      refute html =~ other_order.order_number

      # The two checks above only rule out ONE specific string leaking —
      # order_number is a predictable, sequential "PREFIX-YEAR-NNNN" value
      # (see generate_order_number/1), so a subtler scoping bug that still
      # happened to exclude that one string wouldn't be caught by them
      # alone. Assert directly on the query result too: exactly the
      # current user's order, identified by uuid rather than by a
      # guessable formatted number.
      assert [%{uuid: uuid}] = Billing.list_user_orders(user.uuid)
      assert uuid == order.uuid
    end

    test "shows the empty state for a user with no orders", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/dashboard/billing-orders")

      assert html =~ "No orders yet"
      # `id="orders-list"` only renders in the non-empty branch — checking
      # for it instead of a CSS class survives a styling refactor that a
      # class-based check wouldn't (it would go red on a cosmetic change
      # and stay silently green on a real regression that kept the old
      # classes but broke the emptiness check itself).
      refute html =~ ~s(id="orders-list")
    end
  end

  describe "the trash" do
    test "an order in the trash is not on the customer's page", %{conn: conn, user: user} do
      {:ok, kept} =
        Billing.create_order(user.uuid, %{
          "total" => Decimal.new("10.00"),
          "currency" => "EUR",
          "billing_snapshot" => %{"email" => user.email}
        })

      {:ok, gone} =
        Billing.create_order(user.uuid, %{
          "total" => Decimal.new("20.00"),
          "currency" => "EUR",
          "billing_snapshot" => %{"email" => user.email}
        })

      {:ok, _} = Billing.trash_order(gone)

      {:ok, _view, html} = live(conn, "/en/dashboard/billing-orders")

      assert html =~ kept.order_number
      refute html =~ gone.order_number
    end

    test "an invoice in the trash is not shown on its order", %{conn: conn, user: user} do
      {:ok, order} =
        Billing.create_order(user.uuid, %{
          "total" => Decimal.new("10.00"),
          "currency" => "EUR",
          "billing_snapshot" => %{"email" => user.email}
        })

      {:ok, shown} = Billing.create_invoice_from_order(order)
      {:ok, hidden} = Billing.create_invoice_from_order(order)
      {:ok, _} = Billing.trash_invoice(hidden)

      {:ok, _view, html} = live(conn, "/en/dashboard/billing-orders")

      assert html =~ shown.invoice_number
      refute html =~ hidden.invoice_number
    end
  end

  describe "localized_date/1" do
    # The test router only mirrors "/en/..." (see its own moduledoc), so
    # this goes straight at the formatting logic via Gettext.put_locale/2
    # rather than through a route this test setup doesn't have.
    test "puts the month first, with a comma, only for English" do
      date = ~D[2026-08-07]

      Gettext.put_locale(PhoenixKitWeb.Gettext, "en")
      assert UserOrders.localized_date(date) == "Aug 07, 2026"
    end

    test "puts the day first, no comma, for every other supported locale" do
      date = ~D[2026-08-07]

      Gettext.put_locale(PhoenixKitWeb.Gettext, "ru")
      assert UserOrders.localized_date(date) == "07 Авг 2026"

      Gettext.put_locale(PhoenixKitWeb.Gettext, "et")
      assert UserOrders.localized_date(date) == "07 Aug 2026"
    end
  end
end
