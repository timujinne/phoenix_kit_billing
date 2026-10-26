defmodule PhoenixKitBilling.Integration.VoidInvoiceTrailTest do
  @moduledoc """
  `void_invoice/3` leaves a trail in the invoice's `metadata` and never touches
  `notes`, which are customer-visible and printed on the invoice.
  """

  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, Transaction}

  setup do
    {:ok, user: fixture_user()}
  end

  defp sent_invoice(user, attrs \\ %{}) do
    {:ok, invoice} =
      Billing.create_invoice(
        user.uuid,
        Map.merge(%{total: Decimal.new("100.00"), currency: "EUR"}, attrs)
      )

    {:ok, sent} = invoice |> Invoice.status_changeset("sent") |> Repo.update()
    sent
  end

  describe "void_invoice/3" do
    test "keeps the notes and records the reason, the actor and the time in metadata", %{
      user: user
    } do
      invoice = sent_invoice(user, %{notes: "Thanks for your order"})
      actor = fixture_user()

      assert {:ok, voided} =
               Billing.void_invoice(invoice, "  Booking cancelled  ", actor_uuid: actor.uuid)

      assert voided.status == "void"
      assert voided.notes == "Thanks for your order"

      assert %{"reason" => "Booking cancelled", "by_uuid" => by, "at" => at} =
               voided.metadata["void"]

      assert by == actor.uuid
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(at)

      stored = Billing.get_invoice!(invoice.uuid)
      assert stored.notes == "Thanks for your order"
      assert stored.metadata["void"] == voided.metadata["void"]
      assert stored.voided_at
    end

    test "keeps the other metadata keys, taken from the stored row", %{user: user} do
      invoice = sent_invoice(user, %{metadata: %{"source" => "shop"}})

      # Written after the caller read the struct.
      invoice
      |> Ecto.Changeset.change(metadata: %{"source" => "shop", "ref" => "42"})
      |> Repo.update!()

      assert {:ok, voided} = Billing.void_invoice(invoice, "Duplicate")
      assert voided.metadata["source"] == "shop"
      assert voided.metadata["ref"] == "42"
      assert voided.metadata["void"]["reason"] == "Duplicate"
    end

    test "without a reason or an actor the trail still has the time", %{user: user} do
      invoice = sent_invoice(user)

      assert {:ok, voided} = Billing.void_invoice(invoice)
      assert voided.metadata["void"]["reason"] == nil
      assert voided.metadata["void"]["by_uuid"] == nil
      assert is_binary(voided.metadata["void"]["at"])
      assert voided.notes == invoice.notes
    end

    test "a blank reason is stored as nil", %{user: user} do
      invoice = sent_invoice(user)

      assert {:ok, voided} = Billing.void_invoice(invoice, "   ")
      assert voided.metadata["void"]["reason"] == nil
    end

    test "a reason longer than the form allows is cut", %{user: user} do
      invoice = sent_invoice(user)
      max = Billing.reason_max_length()

      assert {:ok, voided} = Billing.void_invoice(invoice, String.duplicate("é", max + 100))
      assert String.length(voided.metadata["void"]["reason"]) == max
    end

    test "a paid invoice is not voidable", %{user: user} do
      invoice = sent_invoice(user)
      {:ok, paid} = Billing.mark_invoice_paid(invoice)

      assert {:error, :invoice_not_voidable} = Billing.void_invoice(paid, "Oops")
      assert Billing.get_invoice!(invoice.uuid).status == "paid"
    end

    test "a stale struct cannot void an invoice that was paid meanwhile", %{user: user} do
      stale = sent_invoice(user)
      {:ok, _paid} = Billing.mark_invoice_paid(Billing.get_invoice!(stale.uuid))

      assert {:error, :invoice_not_voidable} = Billing.void_invoice(stale, "Too late")

      stored = Billing.get_invoice!(stale.uuid)
      assert stored.status == "paid"
      refute Map.has_key?(stored.metadata, "void")
    end

    test "a partly paid invoice is refused and nothing changes", %{user: user} do
      invoice = sent_invoice(user)

      {:ok, _tx} =
        Billing.record_payment(invoice, %{amount: "40.00", payment_method: "bank"}, nil)

      partly_paid = Billing.get_invoice!(invoice.uuid)
      assert partly_paid.status == "sent"
      assert Invoice.has_payments?(partly_paid)

      assert {:error, :invoice_has_payments} = Billing.void_invoice(partly_paid, "Oops")

      stored = Billing.get_invoice!(invoice.uuid)
      assert stored.status == "sent"
      assert Decimal.equal?(stored.paid_amount, "40.00")
      assert stored.voided_at == nil
      refute Map.has_key?(stored.metadata, "void")
      assert Repo.aggregate(Transaction, :count) == 1
    end

    test "a stale struct cannot void an invoice that took a payment meanwhile", %{user: user} do
      stale = sent_invoice(user)
      assert Decimal.equal?(stale.paid_amount, 0)

      {:ok, _tx} =
        Billing.record_payment(
          Billing.get_invoice!(stale.uuid),
          %{amount: "10.00", payment_method: "bank"},
          nil
        )

      assert {:error, :invoice_has_payments} = Billing.void_invoice(stale, "Too late")

      stored = Billing.get_invoice!(stale.uuid)
      assert stored.status == "sent"
      assert Decimal.equal?(stored.paid_amount, "10.00")
      refute Map.has_key?(stored.metadata, "void")
    end

    test "the refusal leaves a caller's transaction usable", %{user: user} do
      invoice = sent_invoice(user)

      {:ok, _tx} =
        Billing.record_payment(invoice, %{amount: "40.00", payment_method: "bank"}, nil)

      assert {:ok, :still_usable} =
               Repo.transaction(fn ->
                 assert {:error, :invoice_has_payments} = Billing.void_invoice(invoice)
                 :still_usable
               end)
    end

    test "voiding twice is refused and keeps the first trail", %{user: user} do
      invoice = sent_invoice(user)
      {:ok, _} = Billing.void_invoice(invoice, "First")

      assert {:error, :invoice_not_voidable} = Billing.void_invoice(invoice, "Second")
      assert Billing.get_invoice!(invoice.uuid).metadata["void"]["reason"] == "First"
    end
  end

  describe "Invoice.open?/1" do
    test "is every status but void" do
      for status <- ~w(draft sent paid overdue) do
        assert Invoice.open?(%Invoice{status: status})
      end

      refute Invoice.open?(%Invoice{status: "void"})
    end
  end

  describe "Invoice.void_reason/1" do
    test "reads the reason from the trail" do
      assert Invoice.void_reason(%Invoice{metadata: %{"void" => %{"reason" => "Duplicate"}}}) ==
               "Duplicate"
    end

    test "is nil without a reason, a trail or metadata" do
      assert Invoice.void_reason(%Invoice{metadata: %{"void" => %{"reason" => nil}}}) == nil
      assert Invoice.void_reason(%Invoice{metadata: %{"void" => %{"reason" => ""}}}) == nil
      assert Invoice.void_reason(%Invoice{metadata: %{}}) == nil
      assert Invoice.void_reason(%Invoice{metadata: nil}) == nil
    end
  end

  describe "record_payment_after_void/2" do
    @charge %{
      provider: :stripe,
      charge_id: "ch_1",
      amount: Decimal.new("100.00"),
      currency: "EUR",
      event_id: "evt_1"
    }

    test "appends the charge to the void trail, keeping the rest of it", %{user: user} do
      invoice = sent_invoice(user)
      {:ok, voided} = Billing.void_invoice(invoice, "Duplicate")

      assert {:ok, updated} = Billing.record_payment_after_void(voided, @charge)

      assert %{"reason" => "Duplicate", "payments_after_void" => [entry]} =
               updated.metadata["void"]

      assert %{
               "provider" => "stripe",
               "charge_id" => "ch_1",
               "amount" => "100.00",
               "currency" => "EUR",
               "event_id" => "evt_1",
               "at" => at
             } = entry

      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(at)
      assert map_size(entry) == 6
      assert Invoice.payments_after_void(Billing.get_invoice!(invoice.uuid)) == [entry]
    end

    test "appends to the stored trail and counts an event once", %{user: user} do
      {:ok, voided} = Billing.void_invoice(sent_invoice(user), "Duplicate")

      {:ok, _} = Billing.record_payment_after_void(voided, @charge)

      {:ok, _} =
        Billing.record_payment_after_void(voided, %{
          @charge
          | charge_id: "ch_2",
            event_id: "evt_2"
        })

      {:ok, again} = Billing.record_payment_after_void(voided, @charge)

      assert [%{"charge_id" => "ch_1"}, %{"charge_id" => "ch_2"}] =
               again.metadata["void"]["payments_after_void"]
    end

    test "counts a charge once even when another event reports it", %{user: user} do
      {:ok, voided} = Billing.void_invoice(sent_invoice(user), "Duplicate")

      {:ok, _} = Billing.record_payment_after_void(voided, @charge)
      {:ok, again} = Billing.record_payment_after_void(voided, %{@charge | event_id: "evt_other"})

      assert [%{"charge_id" => "ch_1", "event_id" => "evt_1"}] =
               again.metadata["void"]["payments_after_void"]
    end

    test "works on an invoice voided before the trail existed", %{user: user} do
      invoice = sent_invoice(user)
      {:ok, old} = invoice |> Invoice.status_changeset("void") |> Repo.update()

      assert {:ok, updated} = Billing.record_payment_after_void(old, @charge)
      assert [_] = updated.metadata["void"]["payments_after_void"]
      assert Invoice.void_reason(updated) == nil
    end

    test "refuses an invoice that is not void", %{user: user} do
      assert {:error, :invoice_not_void} =
               Billing.record_payment_after_void(sent_invoice(user), @charge)
    end
  end

  describe "Invoice.payments_after_void/1" do
    test "is empty without a trail" do
      assert Invoice.payments_after_void(%Invoice{metadata: %{}}) == []
      assert Invoice.payments_after_void(%Invoice{metadata: %{"void" => %{}}}) == []
    end
  end
end
