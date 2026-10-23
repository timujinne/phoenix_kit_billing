defmodule PhoenixKitBilling.Web.InvoiceDetailPaymentLinkTest do
  @moduledoc """
  The links to a payment's printable confirmation — the "Print Payment
  Confirmation" menu item on the invoice page and the "View payment
  confirmation online" link in the e-mail — were built as
  `.../invoices/:id/payment/:txn_uuid`, a path no route serves, so both
  404'd. The route is `.../invoices/:invoice_uuid/payment-confirmation/:transaction_uuid`.

  Each test resolves the link it got against the router, instead of comparing
  strings, so it fails for any link that does not reach the print page.

  `phoenix_kit_emails` is not installed in this suite, so the e-mail test
  compiles a stand-in `Templates` that reports its variables, and removes it
  again on exit (same approach as `integration/email_send_opts_test.exs`).
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Test.Router

  @stub PhoenixKit.Modules.Emails.Templates

  setup %{conn: conn} do
    Settings.update_setting("billing_enabled", "true")
    user = fixture_user()
    scope = fake_scope(user_uuid: user.uuid, email: user.email)
    conn = put_test_scope(conn, scope)

    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    {:ok, invoice, _email_result} =
      Billing.send_invoice(invoice, to_email: "customer@example.com", send_email: false)

    {:ok, payment} = Billing.record_payment(invoice, %{amount: "100.00"}, nil)

    {:ok, conn: conn, invoice: Billing.get_invoice!(invoice.uuid), payment: payment}
  end

  # The links are built without the default locale segment, which the host
  # app's router serves; the test router only mounts the `/en` scope.
  defp resolved_route(path) do
    Phoenix.Router.route_info(Router, "GET", "/en" <> path, "localhost")
  end

  test "the menu link on the invoice page reaches the payment confirmation page", %{
    conn: conn,
    invoice: invoice,
    payment: payment
  } do
    {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

    selector = "#transaction-menu-#{payment.uuid} a[role='menuitem'][target='_blank']"
    assert has_element?(view, selector)

    [_, href] = Regex.run(~r/href="([^"]+)"/, view |> element(selector) |> render())

    assert %{path_params: path_params} = resolved_route(href)

    assert path_params == %{
             "invoice_uuid" => invoice.uuid,
             "transaction_uuid" => payment.uuid
           }

    assert {PhoenixKitBilling.Web.PaymentConfirmationPrint, _action, _opts, _extra} =
             resolved_route(href).phoenix_live_view
  end

  test "the link in the payment confirmation e-mail reaches the payment confirmation page", %{
    conn: conn,
    invoice: invoice,
    payment: payment
  } do
    refute Code.ensure_loaded?(@stub),
           "a real #{inspect(@stub)} is loaded; this test would replace it"

    :persistent_term.put({__MODULE__, :pid}, self())

    Code.compile_string("""
    defmodule PhoenixKit.Modules.Emails.Templates do
      def send_email(template, email, variables, opts) do
        pid = :persistent_term.get({#{inspect(__MODULE__)}, :pid})
        send(pid, {:send_email, template, email, variables, opts})
        {:ok, :stubbed}
      end
    end
    """)

    on_exit(fn ->
      :code.purge(@stub)
      :code.delete(@stub)
      :code.purge(@stub)
      :persistent_term.erase({__MODULE__, :pid})
    end)

    {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

    view
    |> element(
      "button[phx-click='open_send_payment_confirmation_modal'][phx-value-transaction-uuid='#{payment.uuid}']"
    )
    |> render_click()

    view
    |> form("form[phx-submit=send_payment_confirmation]", %{"email" => "customer@example.com"})
    |> render_submit()

    assert_received {:send_email, "billing_payment_confirmation", _email,
                     %{"payment_url" => payment_url}, _opts}

    assert %URI{scheme: scheme, host: host, path: path} = URI.parse(payment_url)
    assert scheme in ["http", "https"]
    assert is_binary(host)

    assert %{path_params: %{"invoice_uuid" => invoice_uuid, "transaction_uuid" => payment_uuid}} =
             resolved_route(path)

    assert invoice_uuid == invoice.uuid
    assert payment_uuid == payment.uuid
  end
end
