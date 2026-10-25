defmodule PhoenixKitBilling.Integration.RefusalsInOuterTransactionTest do
  @moduledoc """
  A refusal found on the locked row is returned as a value, like
  `transition_order/2` does. A rollback would doom a transaction the caller
  already holds, and everything the caller does after the refusal with it.
  """

  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Invoice

  setup do
    user = fixture_user()
    {:ok, user: user}
  end

  defp sent_invoice(user) do
    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    {:ok, sent} = invoice |> Invoice.status_changeset("sent") |> Repo.update()
    sent
  end

  test "refusals of void, send, update and the void trail leave the caller's transaction usable",
       %{user: user} do
    stale = sent_invoice(user)
    {:ok, voided} = Billing.void_invoice(Billing.get_invoice!(stale.uuid))
    not_void = sent_invoice(user)

    assert {:ok, {refusals, other_uuid}} =
             Repo.transaction(fn ->
               refusals = [
                 Billing.void_invoice(stale),
                 Billing.send_invoice(stale, to_email: "c@example.com", send_email: false),
                 Billing.update_invoice(%{stale | status: "draft"}, %{notes: "x"}),
                 Billing.record_payment_after_void(not_void, %{charge_id: "ch_1"}),
                 Billing.record_checkout_session(stale, :stripe, %{id: "cs_1", url: "u"})
               ]

               {:ok, other} =
                 Billing.create_invoice(user.uuid, %{total: Decimal.new("5.00"), currency: "EUR"})

               {refusals, other.uuid}
             end)

    assert refusals == [
             {:error, :invoice_not_voidable},
             {:error, :invoice_not_sendable},
             {:error, :invoice_not_editable},
             {:error, :invoice_not_void},
             {:error, :invoice_not_payable}
           ]

    assert Billing.get_invoice(other_uuid)
    assert Billing.get_invoice!(voided.uuid).status == "void"
  end

  test "delete_order refusals leave the caller's transaction usable", %{user: user} do
    {:ok, order} =
      Billing.create_order(user, %{
        "total" => Decimal.new("10.00"),
        "currency" => "EUR",
        "billing_snapshot" => %{"email" => "g@example.com"}
      })

    {:ok, _invoice} = Billing.create_invoice_from_order(order)

    {:ok, confirmed_draft} =
      Billing.create_order(user, %{
        "total" => Decimal.new("10.00"),
        "currency" => "EUR",
        "billing_snapshot" => %{"email" => "g@example.com"}
      })

    stale = confirmed_draft
    {:ok, _} = Billing.confirm_order(confirmed_draft)

    assert {:ok, refusals} =
             Repo.transaction(fn ->
               refusals = [Billing.delete_order(order), Billing.delete_order(stale)]
               _ = Billing.get_order(order.uuid)
               refusals
             end)

    assert refusals == [{:error, :order_has_invoices}, {:error, :can_only_delete_drafts}]
  end
end
