defmodule PhoenixKitBilling.Integration.CancelOrderTest do
  @moduledoc """
  `cancel_order/3` appends to `internal_notes` instead of overwriting them and
  remembers the status the order was cancelled from.
  """

  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling, as: Billing

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

  describe "cancel_order/3" do
    test "writes a dated line with the reason when the order had no notes", %{user: user} do
      {:ok, order} = create_order(user)

      assert {:ok, cancelled} = Billing.cancel_order(order, "changed mind")

      assert cancelled.status == "cancelled"

      assert cancelled.internal_notes =~
               ~r/\ACancelled \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC: changed mind\z/
    end

    test "appends after the existing notes, separated by a blank line", %{user: user} do
      {:ok, order} = create_order(user, %{"internal_notes" => "Called the customer"})

      assert {:ok, cancelled} = Billing.cancel_order(order, "changed mind")

      assert [first, second] = String.split(cancelled.internal_notes, "\n\n")
      assert first == "Called the customer"
      assert second =~ ~r/\ACancelled \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC: changed mind\z/
    end

    test "a stale struct does not drop notes written after it was read", %{user: user} do
      {:ok, order} = create_order(user)
      stale = Billing.get_order!(order.uuid)

      {:ok, _} = Billing.update_order(order, %{"internal_notes" => "Written later"})

      assert {:ok, cancelled} = Billing.cancel_order(stale, "changed mind")
      assert cancelled.internal_notes =~ ~r/\AWritten later\n\nCancelled .* UTC: changed mind\z/
      assert Billing.get_order!(order.uuid).internal_notes == cancelled.internal_notes
    end

    test "without a reason the notes are left alone", %{user: user} do
      {:ok, order} = create_order(user, %{"internal_notes" => "Called the customer"})

      assert {:ok, cancelled} = Billing.cancel_order(order)
      assert cancelled.internal_notes == "Called the customer"

      {:ok, other} = create_order(user)
      assert {:ok, cancelled} = Billing.cancel_order(other, "  ")
      assert cancelled.internal_notes == nil
    end

    test "a reason longer than the form allows is cut", %{user: user} do
      {:ok, order} = create_order(user)
      max = Billing.reason_max_length()

      assert {:ok, cancelled} = Billing.cancel_order(order, String.duplicate("é", max + 100))
      [_, reason] = String.split(cancelled.internal_notes, "UTC: ")
      assert String.length(reason) == max
    end

    test "remembers the status the order was cancelled from", %{user: user} do
      {:ok, draft} = create_order(user)
      assert {:ok, cancelled} = Billing.cancel_order(draft)
      assert cancelled.metadata["cancelled_from"] == "draft"

      {:ok, pending} = create_order(user, %{"status" => "pending"})
      assert {:ok, cancelled} = Billing.cancel_order(pending, "x")
      assert cancelled.metadata["cancelled_from"] == "pending"

      {:ok, order} = create_order(user)
      {:ok, confirmed} = Billing.confirm_order(order)
      assert {:ok, cancelled} = Billing.cancel_order(confirmed)
      assert cancelled.metadata["cancelled_from"] == "confirmed"
    end

    test "cancelled_from is the stored status, not the stale struct's", %{user: user} do
      {:ok, order} = create_order(user)
      {:ok, _confirmed} = Billing.confirm_order(order)

      assert {:ok, cancelled} = Billing.cancel_order(order)
      assert cancelled.metadata["cancelled_from"] == "confirmed"
    end

    test "keeps the other metadata keys, taken from the stored row", %{user: user} do
      {:ok, order} = create_order(user, %{"metadata" => %{"source" => "shop"}})
      stale = Billing.get_order!(order.uuid)
      {:ok, _} = Billing.update_order(order, %{"metadata" => %{"source" => "shop", "ref" => "7"}})

      assert {:ok, cancelled} = Billing.cancel_order(stale, "x")
      assert cancelled.metadata["source"] == "shop"
      assert cancelled.metadata["ref"] == "7"
      assert cancelled.metadata["cancelled_from"] == "draft"
      assert is_integer(cancelled.metadata["revision"])
    end

    test "records who cancelled it", %{user: user} do
      {:ok, order} = create_order(user)
      actor = fixture_user()

      assert {:ok, cancelled} = Billing.cancel_order(order, "x", actor_uuid: actor.uuid)
      assert cancelled.metadata["cancelled_by_uuid"] == actor.uuid
    end

    test "a cancelled order cannot be cancelled again and keeps its notes", %{user: user} do
      {:ok, order} = create_order(user)
      {:ok, cancelled} = Billing.cancel_order(order, "first")

      assert {:error, :order_not_cancellable} = Billing.cancel_order(cancelled, "second")
      assert Billing.get_order!(order.uuid).internal_notes == cancelled.internal_notes
    end
  end
end
