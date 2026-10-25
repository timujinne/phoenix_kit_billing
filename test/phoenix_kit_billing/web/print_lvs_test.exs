defmodule PhoenixKitBilling.Web.PrintLvsTest do
  @moduledoc """
  Regression tests for the four printable/receipt LiveViews: InvoicePrint,
  ReceiptPrint, CreditNotePrint, PaymentConfirmationPrint.

  Each document loader fetches the invoice with an explicit `:preload` list that
  must cover every association the corresponding `.heex` template reads.
  `Billing.get_invoice/2` only preloads `:order` by default, and
  `%Ecto.Association.NotLoaded{}` is truthy — so a template guard like
  `if @invoice.user do ... @invoice.user.email` still crashes with
  `KeyError: key :email not found in: #Ecto.Association.NotLoaded<...>`
  when `:user` is missing from the preload list, exactly as reported by
  the owner against `/receipt` and `/print`.

  These tests build a real, persisted invoice (with a real transaction)
  and mount the print route directly, so they exercise the actual
  `Billing.get_invoice/2`/`Billing.get_transaction/2` calls, not a stub.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Paths

  setup %{conn: conn} do
    Settings.update_setting("billing_enabled", "true")
    user = fixture_user()
    scope = fake_scope(user_uuid: user.uuid, email: user.email)
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, user: user}
  end

  defp fixture_sent_invoice(user) do
    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    # `to_email` is passed explicitly so this fixture doesn't depend on
    # `Billing.send_invoice/2`'s own (separate, out-of-scope) preload
    # handling of `invoice.user`.
    {:ok, invoice, _email_result} =
      Billing.send_invoice(invoice, to_email: "customer@example.com", send_email: false)

    invoice
  end

  describe "InvoicePrint" do
    test "renders the customer's email for an invoice with no payments yet", %{
      conn: conn,
      user: user
    } do
      invoice = fixture_sent_invoice(user)

      {:ok, _view, html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}/print")

      assert html =~ user.email
    end
  end

  describe "ReceiptPrint" do
    test "renders the customer's email once the invoice is paid", %{conn: conn, user: user} do
      invoice = fixture_sent_invoice(user)
      {:ok, invoice} = Billing.mark_invoice_paid(invoice)

      {:ok, _view, html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}/receipt")

      assert html =~ user.email
    end
  end

  describe "CreditNotePrint" do
    test "renders the customer's email for a refund transaction", %{conn: conn, user: user} do
      invoice = fixture_sent_invoice(user)
      {:ok, _payment} = Billing.record_payment(invoice, %{amount: "100.00"}, nil)
      paid_invoice = Billing.get_invoice!(invoice.uuid)

      {:ok, refund} =
        Billing.record_refund(paid_invoice, %{amount: "40.00", description: "damaged"}, nil)

      {:ok, _view, html} =
        live(conn, "/en/admin/billing/invoices/#{invoice.uuid}/credit-note/#{refund.uuid}")

      assert html =~ user.email
    end
  end

  describe "PaymentConfirmationPrint" do
    test "renders the customer's email for a payment transaction", %{conn: conn, user: user} do
      invoice = fixture_sent_invoice(user)
      {:ok, payment} = Billing.record_payment(invoice, %{amount: "25.00"}, nil)

      {:ok, _view, html} =
        live(
          conn,
          "/en/admin/billing/invoices/#{invoice.uuid}/payment-confirmation/#{payment.uuid}"
        )

      assert html =~ user.email
    end
  end

  for {document, expected_type, error} <- [
        {"payment-confirmation", :payment, "Transaction is not a payment"},
        {"credit-note", :refund, "Transaction is not a refund"}
      ] do
    @document document
    @expected_type expected_type
    @type_error error

    test "#{document} refuses a transaction belonging to another invoice", %{
      conn: conn,
      user: user
    } do
      invoice = fixture_sent_invoice(user)
      other_invoice = fixture_sent_invoice(fixture_user())
      {:ok, payment} = Billing.record_payment(other_invoice, %{amount: "25.00"}, nil)

      transaction =
        if @expected_type == :payment do
          payment
        else
          {:ok, refund} =
            Billing.record_refund(
              Billing.get_invoice!(other_invoice.uuid),
              %{amount: "10.00"},
              nil
            )

          refund
        end

      assert {:error,
              {:live_redirect, %{to: target, flash: %{"error" => "Transaction not found"}}}} =
               live(
                 conn,
                 "/en/admin/billing/invoices/#{invoice.uuid}/#{@document}/#{transaction.uuid}"
               )

      assert target == Paths.invoice_detail(invoice.uuid)
    end

    test "#{document} explains an incorrect transaction type", %{conn: conn, user: user} do
      invoice = fixture_sent_invoice(user)
      {:ok, payment} = Billing.record_payment(invoice, %{amount: "25.00"}, nil)

      transaction =
        if @expected_type == :refund do
          payment
        else
          {:ok, refund} =
            Billing.record_refund(Billing.get_invoice!(invoice.uuid), %{amount: "10.00"}, nil)

          refund
        end

      assert {:error, {:live_redirect, %{to: target, flash: %{"error" => message}}}} =
               live(
                 conn,
                 "/en/admin/billing/invoices/#{invoice.uuid}/#{@document}/#{transaction.uuid}"
               )

      assert target == Paths.invoice_detail(invoice.uuid)
      assert message == @type_error
    end

    test "#{document} rechecks the invoice when route parameters change", %{
      conn: conn,
      user: user
    } do
      invoice = fixture_sent_invoice(user)
      other_invoice = fixture_sent_invoice(user)
      {:ok, payment} = Billing.record_payment(invoice, %{amount: "25.00"}, nil)

      transaction =
        if @expected_type == :payment do
          payment
        else
          {:ok, refund} =
            Billing.record_refund(Billing.get_invoice!(invoice.uuid), %{amount: "10.00"}, nil)

          refund
        end

      # PostgreSQL accepts either UUID spelling; validate against the loaded
      # invoice's UUID rather than rejecting a valid uppercase route parameter.
      {:ok, view, _html} =
        live(
          conn,
          "/en/admin/billing/invoices/#{String.upcase(invoice.uuid)}/#{@document}/#{transaction.uuid}"
        )

      render_patch(
        view,
        "/en/admin/billing/invoices/#{other_invoice.uuid}/#{@document}/#{transaction.uuid}"
      )

      assert_redirect(view, Paths.invoice_detail(other_invoice.uuid))
    end
  end
end
