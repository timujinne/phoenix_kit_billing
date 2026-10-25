defmodule PhoenixKitBilling.Integration.OrderCancelForgeryTest do
  @moduledoc """
  An integration reads `metadata["cancelled_from"] == "draft"` as "this order
  was never sent anywhere". Only `cancel_order/3` may write it, and only
  `cancel_order/3` may cancel an existing order: the order form and any other
  caller of `create_order/2` / `update_order/2` pass operator-supplied params
  to `Order.changeset/2`.
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

  @forged %{"cancelled_from" => "draft", "cancelled_by_uuid" => "forged", "kept" => "yes"}

  describe "update_order/2" do
    test "refuses to cancel an order, and leaves it untouched", %{user: user} do
      {:ok, order} = create_order(user, %{"status" => "pending"})

      assert {:error, changeset} =
               Billing.update_order(order, %{
                 "status" => "cancelled",
                 "cancelled_at" => "2026-01-01T00:00:00Z",
                 "metadata" => %{"cancelled_from" => "draft"}
               })

      assert %{status: [_ | _]} = errors_on(changeset)

      stored = Billing.get_order!(order.uuid)
      assert stored.status == "pending"
      assert stored.cancelled_at == nil
      refute Map.has_key?(stored.metadata, "cancelled_from")
    end

    test "ignores a cancelled_at on its own", %{user: user} do
      {:ok, order} = create_order(user)

      assert {:ok, updated} =
               Billing.update_order(order, %{"cancelled_at" => "2026-01-01T00:00:00Z"})

      assert updated.cancelled_at == nil
    end

    test "keeps the stored cancellation trail whatever the params say", %{user: user} do
      {:ok, order} = create_order(user)
      actor = fixture_user()
      {:ok, cancelled} = Billing.cancel_order(order, "x", actor_uuid: actor.uuid)

      # A cancelled order is not editable, so go below update_order/2 to prove
      # the changeset itself keeps the keys.
      changeset =
        Order.changeset(cancelled, %{"metadata" => Map.put(@forged, "cancelled_from", "paid")})

      metadata = Ecto.Changeset.get_field(changeset, :metadata)
      assert metadata["cancelled_from"] == "draft"
      assert metadata["cancelled_by_uuid"] == actor.uuid
    end

    test "drops forged keys from the metadata it stores, keeping the others", %{user: user} do
      {:ok, order} = create_order(user, %{"status" => "pending"})

      assert {:ok, updated} = Billing.update_order(order, %{"metadata" => @forged})

      assert updated.metadata["kept"] == "yes"
      refute Map.has_key?(updated.metadata, "cancelled_from")
      refute Map.has_key?(updated.metadata, "cancelled_by_uuid")
      refute Map.has_key?(Billing.get_order!(order.uuid).metadata, "cancelled_from")
    end

    test "still moves a draft along its legitimate statuses", %{user: user} do
      {:ok, order} = create_order(user)

      assert {:ok, pending} = Billing.update_order(order, %{"status" => "pending"})
      assert {:ok, confirmed} = Billing.update_order(pending, %{"status" => "confirmed"})
      assert confirmed.status == "confirmed"
    end
  end

  describe "create_order/2" do
    test "drops forged cancellation keys", %{user: user} do
      {:ok, order} = create_order(user, %{"metadata" => @forged})

      assert order.metadata["kept"] == "yes"
      refute Map.has_key?(order.metadata, "cancelled_from")
      refute Map.has_key?(order.metadata, "cancelled_by_uuid")
    end
  end

  describe "cancel_order/3" do
    test "still writes the trail, whatever the stored metadata held", %{user: user} do
      {:ok, order} = create_order(user, %{"status" => "pending", "metadata" => %{"a" => 1}})

      assert {:ok, cancelled} = Billing.cancel_order(order, "x")
      assert cancelled.metadata["cancelled_from"] == "pending"
      assert cancelled.metadata["a"] == 1
      assert cancelled.metadata["revision"] == 2

      stored = Billing.get_order!(order.uuid)
      assert stored.metadata["cancelled_from"] == "pending"
      assert stored.metadata["a"] == 1
    end

    test "always writes cancelled_by_uuid: nil without an actor", %{user: user} do
      {:ok, order} = create_order(user)

      assert {:ok, cancelled} = Billing.cancel_order(order)
      assert Map.fetch!(cancelled.metadata, "cancelled_by_uuid") == nil
    end
  end
end
