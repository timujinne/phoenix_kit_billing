defmodule PhoenixKitBilling.Integration.VoidInvoiceTrailTest do
  @moduledoc """
  `void_invoice/3` leaves a trail in the invoice's `metadata` and never touches
  `notes`, which are customer-visible and printed on the invoice.
  """

  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Invoice

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
end
