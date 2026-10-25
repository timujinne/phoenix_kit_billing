defmodule PhoenixKitBilling.Integration.InvoiceUpdateLockTest do
  @moduledoc """
  `update_invoice/2` edits a draft on the locked row. Statuses move only
  through send, void and pay, and `metadata["void"]` is billing's own: a stale
  struct or a crafted param cannot undo a void or wipe its trail.
  """

  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Invoice

  setup do
    user = fixture_user()

    {:ok, draft} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    {:ok, user: user, draft: draft}
  end

  test "still edits a draft", %{draft: draft} do
    assert {:ok, updated} = Billing.update_invoice(draft, %{notes: "Net 30"})
    assert updated.notes == "Net 30"
    assert Billing.get_invoice!(draft.uuid).notes == "Net 30"
  end

  test "a stale draft struct cannot undo a void", %{draft: draft} do
    {:ok, _voided} = Billing.void_invoice(Billing.get_invoice!(draft.uuid), "Duplicate")

    assert {:error, :invoice_not_editable} = Billing.update_invoice(draft, %{status: "sent"})

    stored = Billing.get_invoice!(draft.uuid)
    assert stored.status == "void"
    assert stored.metadata["void"]["reason"] == "Duplicate"
  end

  test "a stale draft struct cannot wipe the void trail", %{draft: draft} do
    {:ok, _voided} = Billing.void_invoice(Billing.get_invoice!(draft.uuid), "Duplicate")

    assert {:error, :invoice_not_editable} =
             Billing.update_invoice(draft, %{metadata: %{"source" => "shop"}})

    assert Billing.get_invoice!(draft.uuid).metadata["void"]["reason"] == "Duplicate"
  end

  test "a draft edit cannot change the status", %{draft: draft} do
    assert {:error, changeset} = Billing.update_invoice(draft, %{status: "paid"})
    assert %{status: [_ | _]} = errors_on(changeset)
    assert Billing.get_invoice!(draft.uuid).status == "draft"
  end

  test "a draft edit cannot forge or drop metadata[\"void\"]", %{draft: draft} do
    assert {:ok, updated} =
             Billing.update_invoice(draft, %{
               metadata: %{"source" => "shop", "void" => %{"reason" => "forged"}}
             })

    assert updated.metadata == %{"source" => "shop"}
  end

  test "an invoice deleted meanwhile is reported", %{draft: draft} do
    Repo.delete!(draft)
    assert {:error, :invoice_not_found} = Billing.update_invoice(draft, %{notes: "x"})
  end

  describe "Invoice.changeset/2" do
    test "keeps the stored void trail whatever the input says" do
      invoice = %Invoice{
        status: "void",
        metadata: %{"void" => %{"reason" => "Duplicate"}},
        __meta__: %{%Invoice{}.__meta__ | state: :loaded}
      }

      changeset =
        Invoice.changeset(invoice, %{metadata: %{"void" => %{"reason" => "forged"}, "a" => 1}})

      metadata = Ecto.Changeset.get_field(changeset, :metadata)

      assert metadata == %{"void" => %{"reason" => "Duplicate"}, "a" => 1}
    end

    test "drops a void trail from a new invoice's input" do
      changeset =
        Invoice.changeset(%Invoice{}, %{
          user_uuid: Ecto.UUID.generate(),
          total: Decimal.new("1"),
          currency: "EUR",
          metadata: %{"void" => %{"reason" => "forged"}, "a" => 1}
        })

      assert Ecto.Changeset.get_field(changeset, :metadata) == %{"a" => 1}
    end
  end
end
