defmodule PhoenixKitBilling.Integration.TrashOrdersTest do
  @moduledoc """
  Moving an order to the trash and back. The decision is made on the locked
  row, not on the struct the caller read earlier; refusals come back as
  values, so a transaction of the caller's stays usable; and a trashed order
  refuses everything that would change it.
  """

  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Events, Order}

  setup do
    user = fixture_user()
    {:ok, user: user, actor: fixture_user().uuid}
  end

  defp create_order(user, attrs \\ %{}) do
    {:ok, order} =
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

    order
  end

  defp stored(order), do: Billing.get_order!(order.uuid)

  defp trashed(user, actor) do
    order = create_order(user)
    {:ok, trashed} = Billing.trash_order(order, actor_uuid: actor)
    trashed
  end

  describe "trash_order/2" do
    test "trashes a draft order: when, by whom, and nothing else changes", %{
      user: user,
      actor: actor
    } do
      order = create_order(user)
      before_revision = Order.revision(order)

      assert {:ok, trashed} = Billing.trash_order(order, actor_uuid: actor)

      assert %DateTime{} = trashed.trashed_at
      assert trashed.trashed_by_uuid == actor
      assert trashed.status == "draft"

      row = stored(order)
      assert Order.trashed?(row)
      assert row.trashed_at == trashed.trashed_at
      assert row.trashed_by_uuid == actor
      assert row.status == "draft"
      assert row.metadata == order.metadata
      assert Order.revision(row) == before_revision
    end

    test "trashes a cancelled order and leaves it cancelled", %{user: user, actor: actor} do
      {:ok, cancelled} = Billing.cancel_order(create_order(user), "no longer needed")

      assert {:ok, trashed} = Billing.trash_order(cancelled, actor_uuid: actor)
      assert trashed.status == "cancelled"
      assert stored(cancelled).cancelled_at == cancelled.cancelled_at
    end

    test "the actor is optional", %{user: user} do
      assert {:ok, trashed} = Billing.trash_order(create_order(user))
      assert %DateTime{} = trashed.trashed_at
      assert trashed.trashed_by_uuid == nil
    end

    test "updated_at stays what it was", %{user: user, actor: actor} do
      order = create_order(user)

      assert {:ok, trashed} = Billing.trash_order(order, actor_uuid: actor, reason: "Duplicate")

      assert trashed.updated_at == order.updated_at
      assert stored(order).updated_at == order.updated_at
    end

    test "a reason is appended to the stored internal notes", %{user: user, actor: actor} do
      order = create_order(user, %{"internal_notes" => "Called the customer"})

      # Written after the caller read the struct.
      order
      |> Ecto.Changeset.change(internal_notes: "Called the customer\n\nSecond note")
      |> Repo.update!()

      assert {:ok, trashed} =
               Billing.trash_order(order, actor_uuid: actor, reason: "  Created by mistake  ")

      assert trashed.internal_notes =~
               ~r/\ACalled the customer\n\nSecond note\n\nTrashed \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC: Created by mistake\z/

      row = stored(order)
      assert row.internal_notes == trashed.internal_notes
      assert Order.trashed?(row)
      assert row.trashed_by_uuid == actor
      assert row.status == "draft"
      assert row.notes == order.notes
    end

    test "a reason on an order without notes is the whole note", %{user: user} do
      order = create_order(user)

      assert {:ok, trashed} = Billing.trash_order(order, reason: "Created by mistake")

      assert trashed.internal_notes =~
               ~r/\ATrashed \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC: Created by mistake\z/
    end

    test "a long reason is cut like the void and cancel reasons", %{user: user} do
      order = create_order(user)
      max = Billing.reason_max_length()

      assert {:ok, trashed} = Billing.trash_order(order, reason: String.duplicate("é", max + 50))

      [_, reason] = String.split(trashed.internal_notes, " UTC: ", parts: 2)
      assert String.length(reason) == max
    end

    test "without a reason, or a blank one, the notes are untouched", %{user: user} do
      for opts <- [[], [reason: nil], [reason: "   "]] do
        order = create_order(user, %{"internal_notes" => "Called the customer"})

        assert {:ok, trashed} = Billing.trash_order(order, opts)
        assert trashed.internal_notes == "Called the customer"
        assert stored(order).internal_notes == "Called the customer"
      end

      order = create_order(user)
      assert {:ok, trashed} = Billing.trash_order(order)
      assert trashed.internal_notes == nil
    end

    test "a refused trash writes no note", %{user: user} do
      pending = create_order(user, %{"status" => "pending", "internal_notes" => "Keep"})

      assert {:error, :order_not_trashable} = Billing.trash_order(pending, reason: "Nope")
      assert stored(pending).internal_notes == "Keep"
    end

    test "the changeset cannot forge the trash fields, with or without notes", %{user: user} do
      order = create_order(user)

      forged =
        Order.changeset(order, %{
          "internal_notes" => "A note",
          "trashed_at" => "2026-03-01T10:00:00Z",
          "trashed_by_uuid" => Ecto.UUID.generate()
        })

      assert forged.changes.internal_notes == "A note"
      refute Map.has_key?(forged.changes, :trashed_at)
      refute Map.has_key?(forged.changes, :trashed_by_uuid)
    end

    test "any other status is refused, and the order stays where it was", %{user: user} do
      pending = create_order(user, %{"status" => "pending"})
      confirmed = create_order(user) |> confirm()
      paid = create_order(user) |> confirm() |> pay()

      refunded =
        create_order(user)
        |> confirm()
        |> pay()
        |> then(fn order ->
          {:ok, refunded} = Billing.mark_order_refunded(order)
          refunded
        end)

      for order <- [pending, confirmed, paid, refunded] do
        assert {:error, :order_not_trashable} = Billing.trash_order(order)
        refute Order.trashed?(stored(order))
      end
    end

    test "an order that is in the trash already is refused", %{user: user, actor: actor} do
      trashed = trashed(user, actor)

      assert {:error, :already_trashed} = Billing.trash_order(trashed)
      assert {:error, :already_trashed} = Billing.trash_order(%{trashed | trashed_at: nil})
      assert stored(trashed).trashed_at == trashed.trashed_at
    end

    test "an order that has gone is not found", %{user: user} do
      order = create_order(user)
      {:ok, _} = Billing.delete_order(order)

      assert {:error, :not_found} = Billing.trash_order(order)
    end

    test "an open invoice blocks it, whatever its status but void", %{user: user} do
      for status <- ~w(draft sent overdue paid) do
        order = create_order(user)
        {:ok, invoice} = Billing.create_invoice_from_order(order)

        invoice |> Ecto.Changeset.change(status: status) |> Repo.update!()

        assert {:error, :order_has_open_invoices} = Billing.trash_order(order), status
        refute Order.trashed?(stored(order)), status
      end
    end

    test "a void invoice or a trashed invoice does not block it", %{user: user} do
      voided_for = create_order(user)
      {:ok, invoice} = Billing.create_invoice_from_order(voided_for)
      {:ok, _} = Billing.void_invoice(invoice)

      trashed_for = create_order(user)
      {:ok, draft} = Billing.create_invoice_from_order(trashed_for)
      {:ok, _} = Billing.trash_invoice(draft)

      assert {:ok, _} = Billing.trash_order(voided_for)
      assert {:ok, _} = Billing.trash_order(trashed_for)
    end

    test "a cancelled order whose invoice is still open is refused until it is voided", %{
      user: user
    } do
      order = create_order(user)
      {:ok, invoice} = Billing.create_invoice_from_order(order)
      {:ok, cancelled} = Billing.cancel_order(order)

      assert {:error, :order_has_open_invoices} = Billing.trash_order(cancelled)

      {:ok, _} = Billing.void_invoice(invoice)
      assert {:ok, _} = Billing.trash_order(cancelled)
    end
  end

  describe "trash_order/2 decides on the locked row" do
    test "a draft confirmed since the struct was read is not trashed", %{user: user} do
      stale = create_order(user)
      {:ok, _} = Billing.confirm_order(stale)

      assert {:error, :order_not_trashable} = Billing.trash_order(stale)

      row = stored(stale)
      assert row.status == "confirmed"
      refute Order.trashed?(row)
    end

    test "an invoice created since the struct was read blocks it", %{user: user} do
      stale = create_order(user)
      {:ok, _} = Billing.create_invoice_from_order(Billing.get_order!(stale.uuid))

      assert {:error, :order_has_open_invoices} = Billing.trash_order(stale)
      refute Order.trashed?(stored(stale))
    end

    test "an order trashed since the struct was read is refused as already trashed", %{
      user: user
    } do
      stale = create_order(user)
      {:ok, _} = Billing.trash_order(Billing.get_order!(stale.uuid))

      assert {:error, :already_trashed} = Billing.trash_order(stale)
    end
  end

  describe "refusals are values, not rollbacks" do
    test "a caller's transaction stays usable after any of them", %{user: user} do
      confirmed = create_order(user) |> confirm()
      already = trashed(user, nil)
      draft = create_order(user)
      {:ok, _} = Billing.create_invoice_from_order(draft)
      not_trashed = create_order(user)

      assert {:ok, {refusals, other_uuid}} =
               Repo.transaction(fn ->
                 refusals = [
                   Billing.trash_order(confirmed),
                   Billing.trash_order(already),
                   Billing.trash_order(draft),
                   Billing.restore_order(not_trashed)
                 ]

                 {:ok, other} =
                   Billing.create_order(user, %{
                     "total" => Decimal.new("5.00"),
                     "currency" => "EUR",
                     "billing_snapshot" => %{"email" => "g@example.com"}
                   })

                 {refusals, other.uuid}
               end)

      assert refusals == [
               {:error, :order_not_trashable},
               {:error, :already_trashed},
               {:error, :order_has_open_invoices},
               {:error, :not_trashed}
             ]

      assert Billing.get_order(other_uuid)
    end
  end

  describe "restore_order/2" do
    test "clears when and by whom, and changes nothing else", %{user: user, actor: actor} do
      trashed = trashed(user, actor)

      assert {:ok, restored} = Billing.restore_order(trashed)
      assert restored.trashed_at == nil
      assert restored.trashed_by_uuid == nil

      row = stored(trashed)
      refute Order.trashed?(row)
      assert row.trashed_by_uuid == nil
      assert row.status == "draft"
      assert Order.revision(row) == Order.revision(trashed)
    end

    test "an order that is not in the trash is refused", %{user: user} do
      order = create_order(user)

      assert {:error, :not_trashed} = Billing.restore_order(order)
    end

    test "decides on the stored row: a stale struct that says trashed is not enough", %{
      user: user
    } do
      trashed = trashed(user, nil)
      {:ok, _} = Billing.restore_order(trashed)

      assert {:error, :not_trashed} = Billing.restore_order(trashed)
    end

    test "an order that has gone is not found", %{user: user} do
      trashed = trashed(user, nil)
      Repo.delete!(trashed)

      assert {:error, :not_found} = Billing.restore_order(trashed)
    end

    test "a restored order can be changed again and trashed again", %{user: user} do
      trashed = trashed(user, nil)
      {:ok, restored} = Billing.restore_order(trashed)

      assert {:ok, updated} = Billing.update_order(restored, %{"notes" => "back"})
      assert updated.notes == "back"
      assert {:ok, _} = Billing.confirm_order(updated)
    end
  end

  describe "a trashed order refuses to change" do
    setup %{user: user, actor: actor} do
      trashed = trashed(user, actor)
      # A struct read before the order went to the trash.
      stale = %{trashed | trashed_at: nil, trashed_by_uuid: nil}
      {:ok, trashed: trashed, stale: stale}
    end

    test "update_order/2", %{trashed: trashed, stale: stale} do
      for order <- [trashed, stale] do
        assert {:error, :order_trashed} = Billing.update_order(order, %{"notes" => "x"})
      end

      assert stored(trashed).notes == nil
    end

    test "update_order/2 that renumbers", %{trashed: trashed, stale: stale} do
      for order <- [trashed, stale] do
        assert {:error, :order_trashed} =
                 Billing.update_order(order, %{"order_number" => "ORD-2026-9999"})
      end

      assert stored(trashed).order_number == trashed.order_number
    end

    test "confirm_order/1", %{trashed: trashed, stale: stale} do
      for order <- [trashed, stale] do
        assert {:error, :order_trashed} = Billing.confirm_order(order)
      end

      assert stored(trashed).status == "draft"
    end

    test "cancel_order/3", %{trashed: trashed, stale: stale} do
      for order <- [trashed, stale] do
        assert {:error, :order_trashed} = Billing.cancel_order(order, "why")
      end

      row = stored(trashed)
      assert row.status == "draft"
      assert row.internal_notes == nil
    end

    test "mark_order_paid/2 and mark_order_refunded/1", %{trashed: trashed, stale: stale} do
      for order <- [trashed, stale] do
        assert {:error, :order_trashed} = Billing.mark_order_paid(order)
        assert {:error, :order_trashed} = Billing.mark_order_refunded(order)
      end

      assert stored(trashed).status == "draft"
    end

    test "create_invoice_from_order/2", %{trashed: trashed, stale: stale} do
      for order <- [trashed, stale] do
        assert {:error, :order_trashed} = Billing.create_invoice_from_order(order)
      end

      assert Billing.list_invoices_for_order(trashed.uuid, trashed: :include) == []
    end

    test "create_invoice/2 with the order's uuid", %{user: user, trashed: trashed} do
      assert {:error, :order_trashed} =
               Billing.create_invoice(user, %{
                 total: Decimal.new("1.00"),
                 currency: "EUR",
                 order_uuid: trashed.uuid
               })

      assert Billing.list_invoices_for_order(trashed.uuid, trashed: :include) == []
    end

    test "delete_order/1", %{trashed: trashed, stale: stale} do
      for order <- [trashed, stale] do
        assert {:error, :order_trashed} = Billing.delete_order(order)
      end

      assert Billing.get_order(trashed.uuid)
    end

    test "the refusals leave a caller's transaction usable", %{user: user, trashed: trashed} do
      assert {:ok, refusals} =
               Repo.transaction(fn ->
                 refusals = [
                   Billing.update_order(trashed, %{"notes" => "x"}),
                   Billing.confirm_order(trashed),
                   Billing.cancel_order(trashed),
                   Billing.mark_order_paid(trashed),
                   Billing.create_invoice_from_order(trashed),
                   Billing.delete_order(trashed)
                 ]

                 {:ok, _} =
                   Billing.create_order(user, %{
                     "total" => Decimal.new("5.00"),
                     "currency" => "EUR",
                     "billing_snapshot" => %{"email" => "g@example.com"}
                   })

                 refusals
               end)

      assert Enum.all?(refusals, &(&1 == {:error, :order_trashed}))
    end

    test "an external system can still mark it", %{trashed: trashed} do
      assert {:ok, marked} =
               Billing.put_order_sync(trashed, %{
                 state: "synced",
                 revision: Order.revision(trashed)
               })

      assert Order.sync(marked)["state"] == "synced"
      assert Order.trashed?(stored(trashed))
    end
  end

  describe "billing's own fields cannot be forged" do
    test "create_order/2 ignores trashed_at and trashed_by_uuid", %{user: user, actor: actor} do
      order =
        create_order(user, %{
          "trashed_at" => "2026-01-01T00:00:00Z",
          "trashed_by_uuid" => actor
        })

      row = stored(order)
      refute Order.trashed?(row)
      assert row.trashed_by_uuid == nil
    end

    test "update_order/2 neither trashes nor restores", %{user: user, actor: actor} do
      order = create_order(user)

      assert {:ok, updated} =
               Billing.update_order(order, %{
                 "trashed_at" => "2026-01-01T00:00:00Z",
                 "trashed_by_uuid" => actor
               })

      refute Order.trashed?(updated)
      refute Order.trashed?(stored(order))
    end
  end

  describe "events" do
    setup %{user: user} do
      Events.subscribe_orders()
      Events.subscribe_user_orders(user.uuid)
      :ok
    end

    test "trash_order/2 announces :order_trashed, and only that", %{user: user} do
      order = create_order(user)
      flush_events()

      {:ok, trashed} = Billing.trash_order(order)

      uuid = trashed.uuid
      assert_receive {:order_trashed, %Order{uuid: ^uuid, trashed_at: %DateTime{}}}
      assert_receive {:order_trashed, %Order{uuid: ^uuid}}
      refute_received {:order_updated, _}
      refute_received {:order_cancelled, _}
      refute_received {:order_trashed, _}
    end

    test "restore_order/2 announces :order_restored", %{user: user} do
      {:ok, trashed} = Billing.trash_order(create_order(user))
      flush_events()

      {:ok, restored} = Billing.restore_order(trashed)

      uuid = restored.uuid
      assert_receive {:order_restored, %Order{uuid: ^uuid, trashed_at: nil}}
      assert_receive {:order_restored, %Order{uuid: ^uuid}}
      refute_received {:order_updated, _}
    end

    test "a refusal announces nothing", %{user: user} do
      confirmed = create_order(user) |> confirm()
      flush_events()

      assert {:error, :order_not_trashable} = Billing.trash_order(confirmed)
      assert {:error, :not_trashed} = Billing.restore_order(confirmed)

      refute_received {:order_trashed, _}
      refute_received {:order_restored, _}
    end
  end

  defp flush_events do
    receive do
      _ -> flush_events()
    after
      0 -> :ok
    end
  end

  defp confirm(order) do
    {:ok, confirmed} = Billing.confirm_order(order)
    confirmed
  end

  defp pay(order) do
    {:ok, paid} = Billing.mark_order_paid(order)
    paid
  end
end
