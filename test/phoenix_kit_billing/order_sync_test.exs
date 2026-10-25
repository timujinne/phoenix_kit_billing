defmodule PhoenixKitBilling.OrderSyncTest do
  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Order

  setup do
    {:ok, order} =
      Billing.create_order(fixture_user(), %{
        "total" => Decimal.new("99.00"),
        "currency" => "EUR",
        "status" => "pending",
        "billing_snapshot" => %{"email" => "g@example.com"},
        "line_items" => [%{"name" => "Item", "total" => "99.00"}],
        "metadata" => %{"source" => "test"}
      })

    {:ok, order: order}
  end

  defp stored(order), do: Repo.get!(Order, order.uuid)

  defp back_date(order) do
    old = DateTime.add(DateTime.utc_now(), -3600) |> DateTime.truncate(:second)
    Repo.update_all(from(o in Order, where: o.uuid == ^order.uuid), set: [updated_at: old])
    old
  end

  describe "revision" do
    test "a new order is at revision 1, whatever the attrs say" do
      {:ok, order} =
        Billing.create_order(fixture_user(), %{
          "total" => Decimal.new("5.00"),
          "currency" => "EUR",
          "billing_snapshot" => %{"email" => "g@example.com"},
          "metadata" => %{"revision" => 40, "sync" => %{"state" => "synced"}}
        })

      assert Order.revision(order) == 1
      refute Map.has_key?(order.metadata, "sync")
    end

    test "an order stored before the counter existed reads as 1", %{order: order} do
      Repo.update_all(from(o in Order, where: o.uuid == ^order.uuid), set: [metadata: %{}])
      assert Order.revision(stored(order)) == 1
    end

    test "an update of what an external system reads adds 1", %{order: order} do
      assert {:ok, order} = Billing.update_order(order, %{"notes" => "call first"})
      assert Order.revision(order) == 2
      assert Order.revision(stored(order)) == 2

      assert {:ok, order} =
               Billing.update_order(order, %{
                 "line_items" => [%{"name" => "Other", "total" => "1"}]
               })

      assert Order.revision(order) == 3

      assert {:ok, order} = Billing.update_order(order, %{"total" => Decimal.new("100.00")})
      assert Order.revision(order) == 4
    end

    test "every field the export reads moves it: number, buyer and the three times", %{
      order: order
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      changes = [
        %{"order_number" => "ORD-RENUMBERED"},
        %{"user_uuid" => fixture_user().uuid},
        %{"confirmed_at" => now},
        %{"paid_at" => now}
      ]

      final =
        Enum.reduce(changes, order, fn change, current ->
          assert {:ok, updated} = Billing.update_order(current, change)
          assert Order.revision(updated) == Order.revision(current) + 1, inspect(change)
          updated
        end)

      assert Order.revision(final) == 5
    end

    test "a status change adds 1", %{order: order} do
      assert {:ok, order} = Billing.confirm_order(order)
      assert Order.revision(order) == 2
      assert {:ok, order} = Billing.mark_order_paid(order)
      assert Order.revision(order) == 3
    end

    test "a metadata key other than the owned ones adds 1 and keeps the others", %{order: order} do
      assert {:ok, order} =
               Billing.update_order(order, %{"metadata" => %{"source" => "test", "extra" => 1}})

      assert Order.revision(order) == 2
      assert order.metadata["extra"] == 1
    end

    test "an update that changes nothing, or only internal notes, does not move it", %{
      order: order
    } do
      assert {:ok, order} = Billing.update_order(order, %{"notes" => nil})
      assert Order.revision(order) == 1

      assert {:ok, order} = Billing.update_order(order, %{"internal_notes" => "for the staff"})
      assert Order.revision(order) == 1
    end

    test "metadata sent with an update cannot reset the revision or the mark", %{order: order} do
      {:ok, order} = Billing.update_order(order, %{"notes" => "a"})
      {:ok, order} = Billing.put_order_sync(order, %{state: "synced", revision: 2})

      assert {:ok, order} =
               Billing.update_order(order, %{
                 "metadata" => %{"source" => "form", "revision" => 1, "sync" => %{}}
               })

      assert Order.revision(order) == 3
      assert order.metadata["sync"]["state"] == "synced"
      assert order.metadata["source"] == "form"
    end

    test "an update from a stale struct counts on the stored revision", %{order: order} do
      {:ok, _first} = Billing.update_order(order, %{"notes" => "first"})
      assert {:ok, second} = Billing.update_order(order, %{"discount_code" => "X1"})

      assert Order.revision(second) == 3
      assert Order.revision(stored(order)) == 3
    end

    test "an update from a stale struct keeps a mark written meanwhile", %{order: order} do
      {:ok, _} =
        Billing.put_order_sync(order, %{
          revision: Order.revision(order),
          state: "synced",
          external_id: "ext-1"
        })

      assert {:ok, updated} = Billing.update_order(order, %{"notes" => "later"})

      assert updated.metadata["sync"]["external_id"] == "ext-1"
      assert Order.sync(updated)["state"] == "pending"
    end
  end

  describe "put_order_sync/2" do
    test "writes only metadata[\"sync\"]: status, amounts, updated_at and revision stay", %{
      order: order
    } do
      old = back_date(order)
      before = stored(order)

      assert {:ok, marked} =
               Billing.put_order_sync(order, %{
                 state: "synced",
                 revision: 1,
                 external_id: "ext-1",
                 external_number: "N-1",
                 external_status: "Accepted"
               })

      assert marked.updated_at == old
      assert marked.status == before.status
      assert Decimal.equal?(marked.total, before.total)
      assert marked.line_items == before.line_items
      assert Order.revision(marked) == 1
      assert marked.metadata["source"] == "test"

      assert %{
               "state" => "synced",
               "revision" => 1,
               "external_id" => "ext-1",
               "external_number" => "N-1",
               "external_status" => "Accepted",
               "synced_at" => synced_at
             } = marked.metadata["sync"]

      assert is_binary(synced_at)
      assert stored(order).updated_at == old
    end

    test "works in every status and takes a uuid", %{order: order} do
      {:ok, confirmed} = Billing.confirm_order(order)
      {:ok, paid} = Billing.mark_order_paid(confirmed)

      assert {:ok, marked} =
               Billing.put_order_sync(paid.uuid, %{
                 "state" => "synced",
                 "revision" => Order.revision(paid)
               })

      assert marked.status == "paid"

      {:ok, other} =
        Billing.create_order(fixture_user(), %{
          "total" => Decimal.new("1.00"),
          "currency" => "EUR",
          "status" => "pending",
          "billing_snapshot" => %{"email" => "g@example.com"}
        })

      {:ok, cancelled} = Billing.cancel_order(other)

      assert {:ok, _} =
               Billing.put_order_sync(cancelled, %{
                 revision: Order.revision(cancelled),
                 state: "failed",
                 error: "no"
               })
    end

    test "broadcasts no order event" do
      {:ok, order} =
        Billing.create_order(fixture_user(), %{
          "total" => Decimal.new("1.00"),
          "currency" => "EUR",
          "billing_snapshot" => %{"email" => "g@example.com"}
        })

      Billing.Events.subscribe_orders()
      {:ok, order} = Billing.update_order(order, %{"notes" => "heard"})
      assert_receive {:order_updated, _}

      assert {:ok, _} =
               Billing.put_order_sync(order, %{revision: Order.revision(order), state: "synced"})

      refute_receive {:order_updated, _}, 50
    end

    test "refuses a revision that is no longer the current one and writes nothing", %{
      order: order
    } do
      {:ok, order} = Billing.update_order(order, %{"notes" => "changed"})

      assert {:error, :stale_revision} =
               Billing.put_order_sync(order, %{state: "synced", revision: 1})

      refute Map.has_key?(stored(order).metadata, "sync")
      assert Order.sync(stored(order))["state"] == "pending"

      assert {:ok, marked} = Billing.put_order_sync(order, %{state: "synced", revision: 2})
      assert marked.metadata["sync"]["revision"] == 2
    end

    test "refuses a mark with no revision: it could land on one the system never saw", %{
      order: order
    } do
      assert {:error, cs} = Billing.put_order_sync(order, %{state: "synced"})
      assert %{revision: ["can't be blank"]} = errors_on(cs)
      assert {:error, cs} = Billing.put_order_sync(order, %{state: "synced", revision: nil})
      assert %{revision: ["can't be blank"]} = errors_on(cs)
      refute Map.has_key?(stored(order).metadata, "sync")
    end

    test "failed keeps the id the order already has and shows the error", %{order: order} do
      {:ok, _} =
        Billing.put_order_sync(order, %{
          state: "synced",
          revision: 1,
          external_id: "ext-1",
          external_number: "N-1"
        })

      assert {:ok, failed} =
               Billing.put_order_sync(order, %{
                 revision: Order.revision(order),
                 state: "failed",
                 error: "locked"
               })

      assert Order.sync(failed) == %{
               "state" => "failed",
               "external_id" => "ext-1",
               "external_number" => "N-1",
               "external_status" => nil,
               "synced_at" => failed.metadata["sync"]["synced_at"],
               "error" => "locked",
               "revision" => 1
             }

      assert {:ok, again} =
               Billing.put_order_sync(order, %{revision: Order.revision(order), state: "synced"})

      refute Map.has_key?(again.metadata["sync"], "error")
    end

    test "the same call twice leaves the mark as it is", %{order: order} do
      attrs = %{state: "synced", revision: 1, external_id: "ext-1"}
      {:ok, first} = Billing.put_order_sync(order, attrs)
      {:ok, second} = Billing.put_order_sync(order, attrs)
      assert second.metadata["sync"] == first.metadata["sync"]
    end

    test "answers not_found and validation errors", %{order: order} do
      assert {:error, :not_found} =
               Billing.put_order_sync(Ecto.UUID.generate(), %{state: "synced", revision: 1})

      assert {:error, :not_found} =
               Billing.put_order_sync("nope", %{state: "synced", revision: 1})

      assert {:error, cs} = Billing.put_order_sync(order, %{state: "pending", revision: 1})
      assert %{state: [_ | _]} = errors_on(cs)
      assert {:error, cs} = Billing.put_order_sync(order, %{})
      assert %{state: ["can't be blank"], revision: ["can't be blank"]} = errors_on(cs)
      assert {:error, cs} = Billing.put_order_sync(order, %{state: "synced", revision: 0})
      assert %{revision: [_ | _]} = errors_on(cs)

      assert {:error, cs} =
               Billing.put_order_sync(order, %{
                 state: "failed",
                 revision: 1,
                 error: String.duplicate("x", 2001)
               })

      assert %{error: [_ | _]} = errors_on(cs)
    end
  end

  describe "sync/1 and where_sync/2" do
    defp ids(query), do: query |> Repo.all() |> MapSet.new(& &1.uuid)

    test "an unmarked order is pending; a mark settles it; a change reopens it", %{order: order} do
      assert Order.sync(order)["state"] == "pending"

      {:ok, marked} =
        Billing.put_order_sync(order, %{
          revision: Order.revision(order),
          state: "synced",
          external_id: "ext-1"
        })

      assert Order.sync(marked)["state"] == "synced"

      {:ok, changed} = Billing.update_order(marked, %{"notes" => "later"})
      sync = Order.sync(changed)
      assert sync["state"] == "pending"
      assert sync["external_id"] == "ext-1"
      assert sync["revision"] == 2
    end

    test "the filters agree with sync/1", %{order: pending} do
      {:ok, synced} =
        Billing.create_order(fixture_user(), %{
          "total" => Decimal.new("1.00"),
          "currency" => "EUR",
          "billing_snapshot" => %{"email" => "g@example.com"}
        })

      {:ok, synced} =
        Billing.put_order_sync(synced, %{revision: Order.revision(synced), state: "synced"})

      {:ok, failed} =
        Billing.create_order(fixture_user(), %{
          "total" => Decimal.new("2.00"),
          "currency" => "EUR",
          "billing_snapshot" => %{"email" => "g@example.com"}
        })

      {:ok, failed} =
        Billing.put_order_sync(failed, %{
          revision: Order.revision(failed),
          state: "failed",
          error: "x"
        })

      {:ok, reopened} =
        Billing.create_order(fixture_user(), %{
          "total" => Decimal.new("3.00"),
          "currency" => "EUR",
          "billing_snapshot" => %{"email" => "g@example.com"}
        })

      {:ok, reopened} =
        Billing.put_order_sync(reopened, %{revision: Order.revision(reopened), state: "synced"})

      {:ok, reopened} = Billing.update_order(reopened, %{"notes" => "later"})

      all = [pending, synced, failed, reopened]
      mine = MapSet.new(all, & &1.uuid)

      scoped = fn mode ->
        from(o in Order, where: o.uuid in ^MapSet.to_list(mine))
        |> Order.where_sync(mode)
        |> ids()
      end

      assert scoped.(:any) == mine
      assert scoped.(:synced) == MapSet.new([synced.uuid])
      assert scoped.(:pending) == MapSet.new([pending.uuid, reopened.uuid])

      for order <- all do
        state = Order.sync(order)["state"]
        assert order.uuid in scoped.(:pending) == (state == "pending")
        assert order.uuid in scoped.(:synced) == (state == "synced")
      end
    end

    test "a revision that is not a whole number does not fail the query", %{order: order} do
      scope = from(o in Order, where: o.uuid == ^order.uuid)

      for {stored, current} <- [
            {"x", 1},
            {1.5, 1},
            {nil, 1},
            {%{"a" => 1}, 1},
            {0, 1},
            {-3, 1},
            {1, "x"},
            {1, 1.5},
            {1, 0}
          ] do
        Repo.update_all(scope,
          set: [
            metadata: %{
              "revision" => current,
              "sync" => %{"state" => "synced", "revision" => stored}
            }
          ]
        )

        row = stored(order)

        for mode <- [:pending, :synced, :any] do
          assert %MapSet{} = ids(Order.where_sync(scope, mode)), inspect({stored, current, mode})
        end

        # Where the stored mark is for revision 1 and the order reads as 1, it is current.
        expected = if stored == 1, do: "synced", else: "pending"
        assert Order.sync(row)["state"] == expected, inspect({stored, current})
        assert order.uuid in ids(Order.where_sync(scope, :synced)) == (expected == "synced")
        assert order.uuid in ids(Order.where_sync(scope, :pending)) == (expected == "pending")
      end
    end

    test "an order stored without a revision counts as revision 1", %{order: order} do
      Repo.update_all(from(o in Order, where: o.uuid == ^order.uuid),
        set: [metadata: %{"sync" => %{"state" => "synced", "revision" => 1}}]
      )

      scope = from(o in Order, where: o.uuid == ^order.uuid)
      assert ids(Order.where_sync(scope, :synced)) == MapSet.new([order.uuid])
      assert ids(Order.where_sync(scope, :pending)) == MapSet.new()
    end
  end
end
