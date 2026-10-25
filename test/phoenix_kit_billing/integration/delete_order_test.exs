defmodule PhoenixKitBilling.Integration.DeleteOrderTest do
  @moduledoc """
  `delete_order/1` never detaches an invoice from its order.
  """

  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Order

  setup do
    {:ok, user: fixture_user()}
  end

  defp create_order(user, attrs \\ %{}) do
    Billing.create_order(
      user,
      Map.merge(
        %{
          "total" => Decimal.new("99.00"),
          "currency" => "EUR",
          "billing_snapshot" => %{"email" => "g@example.com"},
          "line_items" => [%{"name" => "Item", "total" => "99.00"}]
        },
        attrs
      )
    )
  end

  describe "delete_order/1" do
    test "deletes a draft without invoices", %{user: user} do
      {:ok, draft} = create_order(user)

      assert {:ok, _} = Billing.delete_order(draft)
      assert Billing.get_order(draft.uuid) == nil
    end

    test "refuses a draft that has an invoice, and detaches nothing", %{user: user} do
      {:ok, draft} = create_order(user)
      {:ok, invoice} = Billing.create_invoice_from_order(draft)

      assert {:error, :order_has_invoices} = Billing.delete_order(draft)

      assert %Order{} = Billing.get_order(draft.uuid)
      assert Billing.get_invoice!(invoice.uuid).order_uuid == draft.uuid
    end

    test "refuses a draft whose only invoice is void", %{user: user} do
      {:ok, draft} = create_order(user)
      {:ok, invoice} = Billing.create_invoice_from_order(draft)
      {:ok, _voided} = Billing.void_invoice(invoice, "Mistake")

      assert {:error, :order_has_invoices} = Billing.delete_order(draft)
      assert Billing.get_invoice!(invoice.uuid).order_uuid == draft.uuid
    end

    test "refuses a stale draft struct once the order was confirmed", %{user: user} do
      {:ok, stale} = create_order(user)
      {:ok, _confirmed} = Billing.confirm_order(Billing.get_order!(stale.uuid))

      assert {:error, :can_only_delete_drafts} = Billing.delete_order(stale)
      assert Billing.get_order!(stale.uuid).status == "confirmed"
    end

    test "reports an order that is already gone instead of raising", %{user: user} do
      {:ok, draft} = create_order(user)
      {:ok, _} = Billing.delete_order(draft)

      assert {:error, :not_found} = Billing.delete_order(draft)
    end

    test "still refuses an order that is not a draft", %{user: user} do
      {:ok, order} = create_order(user)
      {:ok, confirmed} = Billing.confirm_order(order)

      assert {:error, :can_only_delete_drafts} = Billing.delete_order(confirmed)
    end
  end
end
