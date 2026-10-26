defmodule PhoenixKitBilling.Integration.ReinstateOrderTest do
  @moduledoc """
  `reinstate_order/3` takes a cancelled order back to the status it was
  cancelled from, keeps a trail of who did it and why, and settles an order
  whose invoice was paid while it was cancelled.
  """

  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Events, Invoice, Order}
  alias PhoenixKitBilling.Test.Repo

  setup do
    {:ok, user: fixture_user()}
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

  defp cancelled_from(user, "draft"), do: cancel(create_order(user))
  defp cancelled_from(user, "pending"), do: cancel(create_order(user, %{"status" => "pending"}))

  defp cancelled_from(user, "confirmed") do
    {:ok, confirmed} = Billing.confirm_order(create_order(user))
    cancel(confirmed)
  end

  defp cancel(order) do
    {:ok, cancelled} = Billing.cancel_order(order, "first thoughts")
    cancelled
  end

  defp paid_order(user) do
    {:ok, confirmed} = Billing.confirm_order(create_order(user))
    {:ok, paid} = Billing.mark_order_paid(confirmed)
    paid
  end

  defp sent_invoice_for(order) do
    {:ok, invoice} = Billing.create_invoice_from_order(order)
    {:ok, sent} = invoice |> Invoice.status_changeset("sent") |> Repo.update()
    sent
  end

  defp flush_events do
    receive do
      {_event, %Order{}} -> flush_events()
    after
      0 -> :ok
    end
  end

  describe "reinstate_order/3" do
    for status <- ~w(draft pending confirmed) do
      test "an order cancelled from #{status} goes back to #{status}", %{user: user} do
        cancelled = cancelled_from(user, unquote(status))
        assert cancelled.status == "cancelled"

        assert {:ok, reinstated} = Billing.reinstate_order(cancelled, "customer called back")

        assert reinstated.status == unquote(status)
        assert reinstated.cancelled_at == nil
        assert Billing.get_order!(cancelled.uuid).status == unquote(status)
      end
    end

    test "an order cancelled before the trail existed goes back to pending", %{user: user} do
      cancelled = cancelled_from(user, "confirmed")

      {:ok, _} =
        cancelled
        |> Ecto.Changeset.change(metadata: Map.delete(cancelled.metadata, "cancelled_from"))
        |> Repo.update()

      assert {:ok, reinstated} = Billing.reinstate_order(Billing.get_order!(cancelled.uuid))
      assert reinstated.status == "pending"
    end

    test "keeps the trail: who, why, when and the status it went back to", %{user: user} do
      cancelled = cancelled_from(user, "pending")
      actor = fixture_user()

      assert {:ok, reinstated} =
               Billing.reinstate_order(cancelled, "  customer called back  ",
                 actor_uuid: actor.uuid
               )

      trail = reinstated.metadata["reinstated"]
      assert trail["status"] == "pending"
      assert trail["reason"] == "customer called back"
      assert trail["by_uuid"] == actor.uuid
      assert {:ok, _at, 0} = DateTime.from_iso8601(trail["at"])

      # The cancellation's own trail stays as it was.
      assert reinstated.metadata["cancelled_from"] == "pending"
      assert Billing.get_order!(cancelled.uuid).metadata["reinstated"] == trail
    end

    test "without an actor (the system) and without a reason", %{user: user} do
      cancelled = cancelled_from(user, "draft")

      assert {:ok, reinstated} = Billing.reinstate_order(cancelled)

      assert reinstated.metadata["reinstated"]["by_uuid"] == nil
      assert reinstated.metadata["reinstated"]["reason"] == nil
    end

    test "appends a dated line to internal_notes and keeps what was there", %{user: user} do
      order = create_order(user, %{"internal_notes" => "Called the customer"})
      cancelled = cancel(order)

      assert {:ok, reinstated} = Billing.reinstate_order(cancelled, "customer called back")

      assert [first, second, third] = String.split(reinstated.internal_notes, "\n\n")
      assert first == "Called the customer"
      assert second =~ ~r/\ACancelled .* UTC: first thoughts\z/
      assert third =~ ~r/\AReinstated \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC: customer called back\z/
    end

    test "a stale struct does not drop notes written after it was read", %{user: user} do
      cancelled = cancelled_from(user, "draft")
      stale = Billing.get_order!(cancelled.uuid)

      {:ok, _} =
        cancelled
        |> Ecto.Changeset.change(internal_notes: cancelled.internal_notes <> "\n\nWritten later")
        |> Repo.update()

      assert {:ok, reinstated} = Billing.reinstate_order(stale, "back")
      assert reinstated.internal_notes =~ ~r/Written later\n\nReinstated .* UTC: back\z/
    end

    test "without a reason the notes are left alone", %{user: user} do
      cancelled = cancelled_from(user, "draft")

      assert {:ok, reinstated} = Billing.reinstate_order(cancelled, "   ")
      assert reinstated.internal_notes == cancelled.internal_notes
    end

    test "moves the revision on, so the order is sent to the external system again", %{
      user: user
    } do
      cancelled = cancelled_from(user, "confirmed")

      {:ok, marked} =
        Billing.put_order_sync(cancelled, %{state: "synced", revision: Order.revision(cancelled)})

      assert Order.sync(marked)["state"] == "synced"

      assert {:ok, reinstated} = Billing.reinstate_order(marked)
      assert Order.revision(reinstated) == Order.revision(cancelled) + 1
      assert Order.sync(reinstated)["state"] == "pending"
    end

    test "the trail cannot be written or dropped through update_order/2", %{user: user} do
      {:ok, reinstated} = Billing.reinstate_order(cancelled_from(user, "draft"), "back")
      trail = reinstated.metadata["reinstated"]

      {:ok, updated} =
        Billing.update_order(reinstated, %{"metadata" => %{"reinstated" => %{"reason" => "x"}}})

      assert updated.metadata["reinstated"] == trail

      {:ok, updated} = Billing.update_order(updated, %{"metadata" => %{}})
      assert updated.metadata["reinstated"] == trail
    end

    test "can be cancelled and reinstated again", %{user: user} do
      {:ok, once} = Billing.reinstate_order(cancelled_from(user, "pending"), "first")
      {:ok, cancelled_again} = Billing.cancel_order(once, "second")

      assert cancelled_again.metadata["cancelled_from"] == "pending"
      assert {:ok, twice} = Billing.reinstate_order(cancelled_again, "third")
      assert twice.status == "pending"
      assert twice.metadata["reinstated"]["reason"] == "third"
    end

    test "decides on the stored status, not the stale struct's", %{user: user} do
      cancelled = cancelled_from(user, "draft")
      {:ok, _} = Billing.reinstate_order(cancelled)

      assert {:error, :order_not_reinstatable} = Billing.reinstate_order(cancelled, "again")
      assert Billing.get_order!(cancelled.uuid).status == "draft"
    end
  end

  describe "reinstate_order/3 refuses" do
    test "an order that is not cancelled", %{user: user} do
      draft = create_order(user)
      pending = create_order(user, %{"status" => "pending"})
      {:ok, confirmed} = Billing.confirm_order(create_order(user))
      paid = paid_order(user)
      {:ok, refunded} = Billing.mark_order_refunded(paid_order(user))

      for order <- [draft, pending, confirmed, paid, refunded] do
        assert {:error, :order_not_reinstatable} = Billing.reinstate_order(order, "x"),
               "#{order.status} was reinstated"

        stored = Billing.get_order!(order.uuid)
        assert stored.status == order.status
        assert stored.metadata["reinstated"] == nil
      end
    end

    test "an order in the trash, until it is restored", %{user: user} do
      cancelled = cancelled_from(user, "confirmed")
      {:ok, trashed} = Billing.trash_order(cancelled)

      assert {:error, :order_trashed} = Billing.reinstate_order(trashed, "x")
      assert {:error, :order_trashed} = Billing.reinstate_order(cancelled, "x")
      assert Billing.get_order!(cancelled.uuid).status == "cancelled"

      {:ok, restored} = Billing.restore_order(trashed)
      assert {:ok, reinstated} = Billing.reinstate_order(restored, "x")
      assert reinstated.status == "confirmed"
    end

    test "and a refusal leaves the notes alone", %{user: user} do
      order = create_order(user, %{"internal_notes" => "Keep me"})

      assert {:error, :order_not_reinstatable} = Billing.reinstate_order(order, "x")
      assert Billing.get_order!(order.uuid).internal_notes == "Keep me"
    end
  end

  describe "an invoice paid while the order was cancelled" do
    test "the order is reinstated as paid", %{user: user} do
      {:ok, confirmed} = Billing.confirm_order(create_order(user))
      invoice = sent_invoice_for(confirmed)
      cancelled = cancel(confirmed)

      {:ok, _paid_invoice} = Billing.mark_invoice_paid(invoice)
      assert Billing.get_order!(cancelled.uuid).status == "cancelled"

      assert {:ok, reinstated} = Billing.reinstate_order(cancelled, "paid after all")

      assert reinstated.status == "paid"
      assert %DateTime{} = reinstated.paid_at
      assert reinstated.payment_method == "bank"
      assert reinstated.metadata["reinstated"]["status"] == "confirmed"
      assert Billing.get_order!(cancelled.uuid).status == "paid"
    end

    test "an order cancelled from pending is confirmed, then paid", %{user: user} do
      pending = create_order(user, %{"status" => "pending"})
      invoice = sent_invoice_for(pending)
      cancelled = cancel(pending)
      {:ok, _} = Billing.mark_invoice_paid(invoice)

      assert {:ok, reinstated} = Billing.reinstate_order(cancelled)

      assert reinstated.status == "paid"
      assert %DateTime{} = reinstated.confirmed_at
      assert reinstated.metadata["reinstated"]["status"] == "pending"
    end

    test "an order cancelled from draft is confirmed, then paid", %{user: user} do
      draft = create_order(user)
      invoice = sent_invoice_for(draft)
      cancelled = cancel(draft)
      {:ok, _} = Billing.mark_invoice_paid(invoice)

      assert {:ok, reinstated} = Billing.reinstate_order(cancelled)

      assert reinstated.status == "paid"
      assert %DateTime{} = reinstated.confirmed_at
      assert reinstated.metadata["reinstated"]["status"] == "draft"
    end

    test "an invoice partly refunded since does not make the order paid", %{user: user} do
      {:ok, confirmed} = Billing.confirm_order(create_order(user))
      invoice = sent_invoice_for(confirmed)
      cancelled = cancel(confirmed)
      {:ok, paid_invoice} = Billing.mark_invoice_paid(invoice)
      {:ok, _tx} = Billing.record_refund(paid_invoice, %{amount: "40.00", reason: "x"}, nil)

      refunded_in_part = Billing.get_invoice!(invoice.uuid)
      assert refunded_in_part.status == "paid"
      assert Decimal.lt?(refunded_in_part.paid_amount, refunded_in_part.total)

      assert {:ok, reinstated} = Billing.reinstate_order(cancelled)
      assert reinstated.status == "confirmed"
    end

    test "an invoice refunded in full (void) leaves the order where it was", %{user: user} do
      {:ok, confirmed} = Billing.confirm_order(create_order(user))
      invoice = sent_invoice_for(confirmed)
      cancelled = cancel(confirmed)
      {:ok, paid_invoice} = Billing.mark_invoice_paid(invoice)
      {:ok, _tx} = Billing.record_refund(paid_invoice, %{amount: "99.00", reason: "x"}, nil)
      assert Billing.get_invoice!(invoice.uuid).status == "void"

      assert {:ok, reinstated} = Billing.reinstate_order(cancelled)
      assert reinstated.status == "confirmed"
    end

    test "an open, unpaid invoice leaves the order where it was", %{user: user} do
      {:ok, confirmed} = Billing.confirm_order(create_order(user))
      _invoice = sent_invoice_for(confirmed)

      assert {:ok, reinstated} = Billing.reinstate_order(cancel(confirmed))
      assert reinstated.status == "confirmed"
    end

    test "a void invoice leaves the order where it was", %{user: user} do
      {:ok, confirmed} = Billing.confirm_order(create_order(user))
      {:ok, _} = Billing.void_invoice(sent_invoice_for(confirmed))

      assert {:ok, reinstated} = Billing.reinstate_order(cancel(confirmed))
      assert reinstated.status == "confirmed"
    end
  end

  describe "events" do
    setup %{user: user} do
      Events.subscribe_orders()
      Events.subscribe_user_orders(user.uuid)
      :ok
    end

    test "announces :order_reinstated on the orders and the user's topic", %{user: user} do
      cancelled = cancelled_from(user, "confirmed")
      flush_events()

      {:ok, reinstated} = Billing.reinstate_order(cancelled)

      uuid = reinstated.uuid
      assert_receive {:order_reinstated, %Order{uuid: ^uuid, status: "confirmed"}}
      assert_receive {:order_reinstated, %Order{uuid: ^uuid}}
      refute_received {:order_paid, _}
      refute_received {:order_cancelled, _}
    end

    test "with an invoice paid meanwhile, :order_paid follows", %{user: user} do
      {:ok, confirmed} = Billing.confirm_order(create_order(user))
      invoice = sent_invoice_for(confirmed)
      cancelled = cancel(confirmed)
      {:ok, _} = Billing.mark_invoice_paid(invoice)
      flush_events()

      {:ok, reinstated} = Billing.reinstate_order(cancelled)

      uuid = reinstated.uuid
      assert_receive {:order_reinstated, %Order{uuid: ^uuid, status: "confirmed"}}
      assert_receive {:order_paid, %Order{uuid: ^uuid, status: "paid"}}
    end

    test "a refusal announces nothing", %{user: user} do
      order = create_order(user)
      flush_events()

      {:error, :order_not_reinstatable} = Billing.reinstate_order(order)
      refute_received {:order_reinstated, _}
    end
  end
end
