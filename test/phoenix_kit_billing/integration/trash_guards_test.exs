defmodule PhoenixKitBilling.Integration.TrashGuardsTest do
  @moduledoc """
  An order in the trash or cancelled takes no new invoice - created for it or
  moved onto it - a refused renumbering does not move the counter, and trashing
  or restoring leaves `updated_at` alone.
  """

  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, NumberSequence, Order}

  setup do
    {:ok, user: fixture_user()}
  end

  defp order(user, attrs \\ %{}) do
    {:ok, order} =
      Billing.create_order(
        user,
        Map.merge(
          %{
            "total" => Decimal.new("10.00"),
            "currency" => "EUR",
            "billing_snapshot" => %{"email" => "g@example.com"}
          },
          attrs
        )
      )

    order
  end

  defp standalone(user) do
    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("5.00"), currency: "EUR"})

    invoice
  end

  defp counter(scope) do
    Repo.get_by(NumberSequence, scope: scope, year: Date.utc_today().year)
  end

  describe "an invoice for a cancelled order" do
    setup %{user: user} do
      {:ok, cancelled} = Billing.cancel_order(order(user))
      {:ok, cancelled: cancelled}
    end

    test "create_invoice_from_order/2 is refused", %{cancelled: cancelled} do
      assert {:error, :order_cancelled} = Billing.create_invoice_from_order(cancelled)

      # Also from a struct read before the cancel.
      stale = %{cancelled | status: "draft"}
      assert {:error, :order_cancelled} = Billing.create_invoice_from_order(stale)
      assert Billing.list_invoices_for_order(cancelled.uuid, trashed: :include) == []
    end

    test "create_invoice/2 with its uuid is refused", %{user: user, cancelled: cancelled} do
      assert {:error, :order_cancelled} =
               Billing.create_invoice(user, %{
                 total: Decimal.new("1.00"),
                 currency: "EUR",
                 order_uuid: cancelled.uuid
               })
    end

    test "update_invoice/2 cannot move an invoice onto it", %{user: user, cancelled: cancelled} do
      invoice = standalone(user)

      assert {:error, :order_cancelled} =
               Billing.update_invoice(invoice, %{order_uuid: cancelled.uuid})

      assert Billing.get_invoice!(invoice.uuid).order_uuid == nil
    end

    test "an invoice it had before the cancel is untouched", %{user: user} do
      order = order(user)
      {:ok, invoice} = Billing.create_invoice_from_order(order)
      {:ok, _} = Billing.cancel_order(order)

      assert {:ok, _} = Billing.update_invoice(invoice, %{notes: "still editable"})
      assert Billing.get_invoice!(invoice.uuid).order_uuid == order.uuid
    end
  end

  describe "update_invoice/2 re-linking to an order in the trash" do
    setup %{user: user} do
      {:ok, trashed} = Billing.trash_order(order(user))
      {:ok, trashed: trashed}
    end

    test "is refused, and the invoice stays where it was", %{user: user, trashed: trashed} do
      invoice = standalone(user)

      assert {:error, :order_trashed} =
               Billing.update_invoice(invoice, %{"order_uuid" => trashed.uuid})

      assert Billing.get_invoice!(invoice.uuid).order_uuid == nil
    end

    test "leaves a caller's transaction usable", %{user: user, trashed: trashed} do
      invoice = standalone(user)

      assert {:ok, {:error, :order_trashed}} =
               Repo.transaction(fn ->
                 refusal = Billing.update_invoice(invoice, %{order_uuid: trashed.uuid})
                 {:ok, _} = Billing.update_invoice(invoice, %{notes: "after"})
                 refusal
               end)
    end

    test "a re-link to an order that takes invoices, or none, works", %{user: user} do
      open = order(user)
      invoice = standalone(user)

      assert {:ok, linked} = Billing.update_invoice(invoice, %{order_uuid: open.uuid})
      assert linked.order_uuid == open.uuid
      assert {:ok, unlinked} = Billing.update_invoice(linked, %{order_uuid: nil})
      assert unlinked.order_uuid == nil
    end

    test "an invoice that keeps its order can be edited whatever the order's state", %{
      user: user
    } do
      order = order(user)
      {:ok, invoice} = Billing.create_invoice_from_order(order)
      {:ok, _} = Billing.cancel_order(order)

      assert {:ok, _} = Billing.update_invoice(invoice, %{order_uuid: order.uuid, notes: "x"})
    end
  end

  describe "a refused renumbering" do
    test "does not move the counter", %{user: user} do
      {:ok, trashed} = Billing.trash_order(order(user))
      before = counter("order").last_value

      assert {:error, :order_trashed} =
               Billing.update_order(trashed, %{
                 "order_number" => "ORD-#{Date.utc_today().year}-9000"
               })

      assert counter("order").last_value == before
    end

    test "an invoice re-link refused for its order does not move the invoice counter", %{
      user: user
    } do
      {:ok, trashed} = Billing.trash_order(order(user))
      invoice = standalone(user)
      before = counter("invoice").last_value

      assert {:error, :order_trashed} =
               Billing.update_invoice(invoice, %{
                 order_uuid: trashed.uuid,
                 invoice_number: "INV-#{Date.utc_today().year}-9000"
               })

      assert counter("invoice").last_value == before
    end
  end

  describe "trashing and restoring leave updated_at alone" do
    setup do
      {:ok, long_ago: ~U[2020-05-05 10:00:00Z]}
    end

    test "for an order", %{user: user, long_ago: long_ago} do
      order = order(user)
      Repo.update_all(from(o in Order, where: o.uuid == ^order.uuid), set: [updated_at: long_ago])

      {:ok, trashed} = Billing.trash_order(order)
      assert trashed.updated_at == long_ago
      assert Billing.get_order!(order.uuid).updated_at == long_ago

      {:ok, restored} = Billing.restore_order(trashed)
      assert restored.updated_at == long_ago
      assert Billing.get_order!(order.uuid).updated_at == long_ago
    end

    test "for an invoice", %{user: user, long_ago: long_ago} do
      invoice = standalone(user)

      Repo.update_all(from(i in Invoice, where: i.uuid == ^invoice.uuid),
        set: [updated_at: long_ago]
      )

      {:ok, trashed} = Billing.trash_invoice(invoice)
      assert trashed.updated_at == long_ago
      assert Billing.get_invoice!(invoice.uuid).updated_at == long_ago

      {:ok, restored} = Billing.restore_invoice(trashed)
      assert restored.updated_at == long_ago
      assert Billing.get_invoice!(invoice.uuid).updated_at == long_ago
    end
  end

  describe "readers" do
    test "get_order_by_uuid/2 hides trashed invoices from a :preload too", %{user: user} do
      order = order(user)
      {:ok, shown} = Billing.create_invoice_from_order(order)
      {:ok, hidden} = Billing.create_invoice_from_order(order)
      {:ok, _} = Billing.trash_invoice(hidden)

      loaded = Billing.get_order_by_uuid(order.uuid, preload: [:invoices])
      assert Enum.map(loaded.invoices, & &1.uuid) == [shown.uuid]

      loaded = Billing.get_order_by_uuid(order.uuid, preload: [invoices: :transactions])
      assert Enum.map(loaded.invoices, & &1.uuid) == [shown.uuid]
    end

    test "a void invoice of an order in the trash stays in the invoice lists", %{user: user} do
      order = order(user)
      {:ok, invoice} = Billing.create_invoice_from_order(order)
      {:ok, _} = Billing.void_invoice(invoice)
      {:ok, _} = Billing.trash_order(order)

      assert invoice.uuid in Enum.map(Billing.list_invoices(%{}), & &1.uuid)
    end
  end

  describe "update_order/2 decides on the stored status" do
    test "a stale draft cannot un-cancel an order", %{user: user} do
      stale = order(user)
      {:ok, _} = Billing.cancel_order(Billing.get_order!(stale.uuid))

      assert {:error, :order_not_editable} =
               Billing.update_order(stale, %{"status" => "confirmed"})

      stored = Billing.get_order!(stale.uuid)
      assert stored.status == "cancelled"
      assert stored.confirmed_at == nil
    end

    test "a stale draft cannot edit a cancelled order either", %{user: user} do
      stale = order(user)
      {:ok, _} = Billing.cancel_order(Billing.get_order!(stale.uuid))

      assert {:error, :order_not_editable} = Billing.update_order(stale, %{"notes" => "late"})
      assert Billing.get_order!(stale.uuid).notes == nil
    end

    test "nor a confirmed, paid or refunded one", %{user: user} do
      stale = order(user)
      {:ok, confirmed} = Billing.confirm_order(Billing.get_order!(stale.uuid))
      assert {:error, :order_not_editable} = Billing.update_order(stale, %{"notes" => "late"})

      {:ok, paid} = Billing.mark_order_paid(confirmed)
      assert {:error, :order_not_editable} = Billing.update_order(stale, %{"notes" => "late"})

      {:ok, _} = Billing.mark_order_refunded(paid)
      assert {:error, :order_not_editable} = Billing.update_order(stale, %{"notes" => "late"})
    end

    test "a status change from a struct that is behind the stored status is refused", %{
      user: user
    } do
      stale = order(user)

      {:ok, pending} =
        Billing.update_order(Billing.get_order!(stale.uuid), %{"status" => "pending"})

      assert {:error, :order_not_editable} =
               Billing.update_order(stale, %{"status" => "confirmed"})

      assert Billing.get_order!(stale.uuid).status == "pending"

      # From a current struct the same move is fine.
      assert {:ok, %{status: "confirmed"}} =
               Billing.update_order(pending, %{"status" => "confirmed"})
    end

    test "a plain edit of a draft or pending order still works", %{user: user} do
      order = order(user)
      assert {:ok, edited} = Billing.update_order(order, %{"notes" => "a"})
      assert {:ok, _} = Billing.update_order(edited, %{"status" => "pending", "notes" => "b"})
    end

    test "the refusal leaves the counter alone and a caller's transaction usable", %{user: user} do
      stale = order(user)
      {:ok, _} = Billing.cancel_order(Billing.get_order!(stale.uuid))
      before = counter("order").last_value

      assert {:ok, {:error, :order_not_editable}} =
               Repo.transaction(fn ->
                 refusal =
                   Billing.update_order(stale, %{
                     "order_number" => "ORD-#{Date.utc_today().year}-9000"
                   })

                 {:ok, _} =
                   Billing.create_order(user, %{
                     "total" => Decimal.new("1.00"),
                     "currency" => "EUR",
                     "billing_snapshot" => %{"email" => "g@example.com"}
                   })

                 refusal
               end)

      # The create took one number; the refused renumbering lifted nothing.
      assert counter("order").last_value == before + 1
    end
  end

  describe "restore_invoice/2 onto an order" do
    defp trashed_invoice_of(order) do
      {:ok, invoice} = Billing.create_invoice_from_order(order)
      {:ok, trashed} = Billing.trash_invoice(invoice)
      trashed
    end

    test "that is cancelled is refused, and the invoice stays in the trash", %{user: user} do
      order = order(user)
      trashed = trashed_invoice_of(order)
      {:ok, _} = Billing.cancel_order(order)

      assert {:error, :order_cancelled} = Billing.restore_invoice(trashed)
      assert Invoice.trashed?(Billing.get_invoice!(trashed.uuid))
    end

    test "that is a draft or pending is allowed", %{user: user} do
      draft = order(user)
      pending = order(user, %{"status" => "pending"})

      for order <- [draft, pending] do
        trashed = trashed_invoice_of(order)
        assert {:ok, restored} = Billing.restore_invoice(trashed)
        refute Invoice.trashed?(restored)
      end
    end

    test "a refusal leaves a caller's transaction usable", %{user: user} do
      order = order(user)
      trashed = trashed_invoice_of(order)
      {:ok, _} = Billing.cancel_order(order)

      assert {:ok, {:error, :order_cancelled}} =
               Repo.transaction(fn ->
                 refusal = Billing.restore_invoice(trashed)

                 {:ok, _} =
                   Billing.create_invoice(user.uuid, %{
                     total: Decimal.new("1.00"),
                     currency: "EUR"
                   })

                 refusal
               end)
    end

    test "an invoice without an order is restored as before", %{user: user} do
      {:ok, trashed} = Billing.trash_invoice(standalone(user))
      assert {:ok, _} = Billing.restore_invoice(trashed)
    end
  end
end
