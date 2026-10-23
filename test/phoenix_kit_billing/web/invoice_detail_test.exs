defmodule PhoenixKitBilling.Web.InvoiceDetailTest do
  @moduledoc """
  Regression test for `PhoenixKitBilling.Web.InvoiceDetail.Actions.reload_invoice/1`.

  `handle_params/3` fetches the invoice with
  `preload: [:order, :transactions, :user]`, so `@invoice.user` is safe on
  first render. But `record_payment/1` and `record_refund/1` both call the
  private `reload_invoice/1` afterwards, which re-fetches the invoice with
  `preload: [:order, :transactions]` — dropping `:user`. The next render
  hits `invoice_detail.html.heex`'s `<%= if @invoice.user do %>` /
  `{@invoice.user.email}` block, and since `%Ecto.Association.NotLoaded{}`
  is truthy, `.email` on it raises the same
  `KeyError: key :email not found in: #Ecto.Association.NotLoaded<...>`
  the owner hit on the print routes.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing

  setup %{conn: conn} do
    Settings.update_setting("billing_enabled", "true")
    user = fixture_user()
    scope = fake_scope(user_uuid: user.uuid, email: user.email)
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, user: user}
  end

  test "recording a payment keeps the invoice's user renderable", %{conn: conn, user: user} do
    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    {:ok, invoice, _email_result} =
      Billing.send_invoice(invoice, to_email: "customer@example.com", send_email: false)

    {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

    view |> element("button[phx-click=open_payment_modal]") |> render_click()

    payment_form =
      form(view, "form[phx-submit=record_payment]", %{
        "amount" => "50.00",
        "payment_method" => "bank",
        "description" => ""
      })

    # `record_payment`'s handler reads `socket.assigns.payment_amount` etc,
    # not the submit event's params — so the change event that keeps those
    # assigns in sync must fire first, exactly like a real browser typing
    # into the field before clicking submit.
    render_change(payment_form)
    html = render_submit(payment_form)

    assert html =~ user.email
  end

  test "recording a refund keeps the invoice's user renderable", %{conn: conn, user: user} do
    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    {:ok, invoice, _email_result} =
      Billing.send_invoice(invoice, to_email: "customer@example.com", send_email: false)

    {:ok, _payment} = Billing.record_payment(invoice, %{amount: "100.00"}, nil)

    {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

    view |> element("button[phx-click=open_refund_modal]") |> render_click()

    refund_form =
      form(view, "form[phx-submit=record_refund]", %{
        "amount" => "20.00",
        "payment_method" => "bank",
        "description" => "damaged"
      })

    # Same as the payment form above: `refund_description` defaults to ""
    # and `record_refund` bails out early with a flash when it's blank, so
    # without this `render_change` the refund is never actually attempted
    # and the test would pass without ever exercising `reload_invoice/1`.
    render_change(refund_form)
    html = render_submit(refund_form)

    assert html =~ user.email
  end

  test "transactions render actions in a three-dot menu, not always-visible buttons", %{
    conn: conn,
    user: user
  } do
    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    {:ok, invoice, _email_result} =
      Billing.send_invoice(invoice, to_email: "customer@example.com", send_email: false)

    {:ok, payment} = Billing.record_payment(invoice, %{amount: "100.00"}, nil)
    invoice = Billing.get_invoice!(invoice.uuid)

    {:ok, refund} =
      Billing.record_refund(invoice, %{amount: "20.00", description: "damaged"}, nil)

    {:ok, view, html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

    assert has_element?(view, "#transaction-menu-#{payment.uuid}")
    assert has_element?(view, "#transaction-menu-#{refund.uuid}")

    assert has_element?(
             view,
             "a[role='menuitem'][href*='/payment-confirmation/#{payment.uuid}']"
           )

    assert has_element?(
             view,
             "button[role='menuitem'][phx-click='open_send_payment_confirmation_modal'][phx-value-transaction-uuid='#{payment.uuid}']"
           )

    assert has_element?(
             view,
             "a[role='menuitem'][href*='/credit-note/#{refund.uuid}']"
           )

    assert has_element?(
             view,
             "button[role='menuitem'][phx-click='open_send_credit_note_modal'][phx-value-transaction-uuid='#{refund.uuid}']"
           )

    refute html =~ "btn-success btn-xs"
    refute html =~ "btn-warning btn-xs"
  end
end
