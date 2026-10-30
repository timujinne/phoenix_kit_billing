defmodule PhoenixKitBilling.StripeRefundRaceTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, Transaction, WebhookEvent, WebhookProcessor}
  alias PhoenixKitBilling.Test.Repo

  setup do
    # Separate connections are essential: sandbox tasks would only take turns
    # on one connection and could never expose the ledger race.
    Sandbox.mode(Repo, :auto)
    user = PhoenixKitBilling.DataCase.fixture_user()

    {:ok, invoice} = Billing.create_invoice(user, %{total: "30.00", currency: "EUR"})
    invoice = invoice |> Ecto.Changeset.change(status: "sent") |> Repo.update!()

    {:ok, _payment} =
      Billing.record_payment(
        invoice,
        %{amount: "30.00", payment_method: "stripe", provider_transaction_id: invoice.uuid},
        nil
      )

    on_exit(fn ->
      Repo.delete_all(from(t in Transaction, where: t.invoice_uuid == ^invoice.uuid))
      Repo.delete_all(from(i in Invoice, where: i.uuid == ^invoice.uuid))
      Repo.delete_all(from(w in WebhookEvent, where: like(w.event_id, ^"#{invoice.uuid}:%")))
      Repo.delete_all(from(u in User, where: u.uuid == ^user.uuid))
      Sandbox.mode(Repo, :manual)
    end)

    %{invoice: invoice}
  end

  test "concurrent deliveries reconcile a running total once", %{invoice: invoice} do
    parent = self()
    handler = "refund-read-#{invoice.uuid}"

    :ok =
      :telemetry.attach(
        handler,
        [:phoenix_kit_billing, :test, :repo, :query],
        &__MODULE__.hold_refund_read/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    first =
      Task.async(fn ->
        Process.put(:hold_refund_read, true)
        deliver(invoice, "first")
      end)

    assert_receive {:refund_read, first_pid}, 5_000
    second = Task.async(fn -> deliver(invoice, "second") end)

    # A second delivery must wait for the invoice lock. On the broken path
    # it instead completes using the same uncommitted ledger total.
    second_result = Task.yield(second, 300)
    send(first_pid, :continue)

    assert {:ok, %Transaction{}} = Task.await(first, 5_000)

    refunds =
      Repo.all(from(t in Transaction, where: t.invoice_uuid == ^invoice.uuid and t.amount < 0))

    assert [%Transaction{amount: amount}] = refunds
    assert Decimal.equal?(amount, Decimal.new("-10.00"))
    assert Decimal.equal?(Repo.get!(Invoice, invoice.uuid).paid_amount, Decimal.new("20.00"))
    assert is_nil(second_result)
    assert {:ok, :already_refunded} = Task.await(second, 5_000)
  end

  def hold_refund_read(_event, _measurements, metadata, parent) do
    if Process.get(:hold_refund_read, false) and
         Regex.match?(~r/^SELECT \w+\."amount", \w+\."provider_data" FROM/, metadata.query) do
      Process.delete(:hold_refund_read)
      send(parent, {:refund_read, self()})

      receive do
        :continue -> :ok
      after
        5_000 -> raise "refund read was not released"
      end
    end
  end

  defp deliver(invoice, suffix) do
    WebhookProcessor.process(%{
      event_id: "#{invoice.uuid}:#{suffix}",
      provider: :stripe,
      type: "refund.created",
      data: %{
        charge_id: "ch_#{invoice.uuid}",
        payment_intent_id: invoice.uuid,
        amount_refunded_total: 1000,
        currency: "EUR"
      }
    })
  end
end
