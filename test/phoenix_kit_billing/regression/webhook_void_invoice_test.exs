defmodule PhoenixKitBilling.Regression.WebhookVoidInvoiceTest do
  @moduledoc """
  A provider confirms a payment for an invoice that was voided meanwhile. The
  money must not be booked on the void invoice, and the provider must not
  keep retrying an event that can never succeed: it is answered as processed,
  and the operators are told, because the charge needs refunding at the
  provider.
  """

  use PhoenixKitBilling.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Notifications
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, Transaction, WebhookEvent, WebhookProcessor}

  setup do
    Notifications.enable_system()

    # The first registered user is the Owner, so the notifications have an
    # audience; the customer is a different, later user.
    admin = fixture_user()
    customer = fixture_user()

    {:ok, invoice} =
      Billing.create_invoice(customer.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    {:ok, sent} = invoice |> Invoice.status_changeset("sent") |> Repo.update()

    %{admin: admin, customer: customer, invoice: sent}
  end

  defp payment_event(invoice, event_id) do
    %{
      event_id: event_id,
      provider: :stripe,
      type: "checkout.completed",
      data: %{
        mode: "payment",
        invoice_uuid: invoice.uuid,
        amount_total: 10_000,
        currency: "EUR",
        payment_intent_id: "pi_void_1"
      }
    }
  end

  defp texts(user) do
    {rows, _total} = Notifications.list_for_user(user.uuid)
    Enum.map(rows, & &1.metadata["notification_text"])
  end

  test "a payment for a void invoice is not recorded, not retried, and the admins are told", %{
    admin: admin,
    customer: customer,
    invoice: invoice
  } do
    {:ok, _voided} = Billing.void_invoice(invoice, "Duplicate")

    log =
      capture_log([level: :error], fn ->
        assert {:ok, :invoice_void} =
                 WebhookProcessor.process(payment_event(invoice, "evt_void_1"))
      end)

    assert log =~ "void"
    assert log =~ invoice.uuid

    assert Repo.aggregate(Transaction, :count) == 0

    stored = Billing.get_invoice!(invoice.uuid)
    assert stored.status == "void"
    assert Decimal.equal?(stored.paid_amount, 0)

    # Marked processed, so a provider retry is a duplicate, not another try.
    assert %WebhookEvent{processed: true} = Repo.get_by!(WebhookEvent, event_id: "evt_void_1")

    assert {:error, :duplicate_event} =
             WebhookProcessor.process(payment_event(invoice, "evt_void_1"))

    assert [text] = texts(admin)
    assert text =~ "void invoice #{invoice.invoice_number}"
    assert texts(customer) == []
  end

  test "a draft invoice keeps the old behaviour: the event fails and can be retried", %{
    customer: customer
  } do
    {:ok, draft} =
      Billing.create_invoice(customer.uuid, %{total: Decimal.new("10.00"), currency: "EUR"})

    capture_log(fn ->
      assert {:error, {:invalid_status, "draft"}} =
               WebhookProcessor.process(payment_event(draft, "evt_draft_1"))
    end)

    assert Repo.aggregate(Transaction, :count) == 0

    assert %WebhookEvent{processed: false, retry_count: 1} =
             Repo.get_by!(WebhookEvent, event_id: "evt_draft_1")
  end

  test "the charge is kept on the void trail, and the log carries ids only", %{invoice: invoice} do
    {:ok, _voided} = Billing.void_invoice(invoice, "Duplicate")

    event =
      put_in(payment_event(invoice, "evt_void_trail").data[:customer_email], "leak@example.com")

    log =
      capture_log([level: :error], fn ->
        assert {:ok, :invoice_void} = WebhookProcessor.process(event)
      end)

    refute log =~ "leak@example.com"
    assert log =~ "pi_void_1"

    assert [entry] = Billing.get_invoice!(invoice.uuid).metadata["void"]["payments_after_void"]

    assert %{
             "provider" => "stripe",
             "charge_id" => "pi_void_1",
             "amount" => amount,
             "currency" => "EUR",
             "event_id" => "evt_void_trail"
           } = entry

    assert Decimal.equal?(Decimal.new(amount), 100)
  end

  test "the charge keeps the currency the webhook reports", %{invoice: invoice} do
    {:ok, _voided} = Billing.void_invoice(invoice)

    event = put_in(payment_event(invoice, "evt_void_usd").data[:currency], "USD")
    capture_log(fn -> assert {:ok, :invoice_void} = WebhookProcessor.process(event) end)

    assert [%{"currency" => "USD"}] =
             Billing.get_invoice!(invoice.uuid).metadata["void"]["payments_after_void"]
  end

  test "the admins' notification leads to the invoice itself", %{admin: admin, invoice: invoice} do
    {:ok, _voided} = Billing.void_invoice(invoice)
    capture_log(fn -> WebhookProcessor.process(payment_event(invoice, "evt_void_link")) end)

    {[notification], _total} = Notifications.list_for_user(admin.uuid)
    assert notification.metadata["notification_link"] =~ "/invoices/#{invoice.uuid}"
  end
end
