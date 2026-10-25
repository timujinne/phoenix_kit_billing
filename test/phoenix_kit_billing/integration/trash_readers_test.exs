defmodule PhoenixKitBilling.Integration.TrashReadersTest do
  @moduledoc """
  Whatever lists, counts or sums orders and invoices leaves the trash out by
  default; `trashed: :only` shows just the trash and `trashed: :include` both.
  Lookups by identity (`get_order/2`, `get_invoice/2`, by number) still find a
  trashed row.
  """

  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Invoice

  setup do
    user = fixture_user()
    other = fixture_user()
    {:ok, user: user, other: other}
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

  defp invoice(user, attrs \\ %{}) do
    {:ok, invoice} =
      Billing.create_invoice(
        user.uuid,
        Map.merge(%{total: Decimal.new("10.00"), currency: "EUR"}, attrs)
      )

    invoice
  end

  defp uuids(records), do: records |> Enum.map(& &1.uuid) |> Enum.sort()

  defp orders_with_one_in_trash(user) do
    kept = order(user)
    gone = order(user)
    {:ok, _} = Billing.trash_order(gone)
    {kept, Billing.get_order!(gone.uuid)}
  end

  defp invoices_with_one_in_trash(user) do
    kept = invoice(user)
    gone = invoice(user)
    {:ok, _} = Billing.trash_invoice(gone)
    {kept, Billing.get_invoice!(gone.uuid)}
  end

  describe "orders" do
    test "list_orders/1 leaves the trash out, and takes trashed: :only | :include", %{user: user} do
      {kept, gone} = orders_with_one_in_trash(user)

      assert uuids(Billing.list_orders(%{})) == [kept.uuid]
      assert uuids(Billing.list_orders(%{trashed: :only})) == [gone.uuid]
      assert uuids(Billing.list_orders(%{trashed: :include})) == uuids([kept, gone])
      assert uuids(Billing.list_orders(trashed: :only)) == [gone.uuid]
    end

    test "it combines with the other filters", %{user: user} do
      {_kept, gone} = orders_with_one_in_trash(user)

      assert uuids(Billing.list_orders(%{trashed: :only, status: "draft"})) == [gone.uuid]
      assert Billing.list_orders(%{trashed: :only, status: "paid"}) == []
    end

    test "an unknown value reads as the default: the trash stays out", %{user: user} do
      {kept, _gone} = orders_with_one_in_trash(user)

      assert uuids(Billing.list_orders(%{trashed: :bogus})) == [kept.uuid]
      assert uuids(Billing.list_orders(%{trashed: "only"})) == [kept.uuid]
    end

    test "list_user_orders/3 is the customer's list: no trash, and only their own", %{
      user: user,
      other: other
    } do
      {kept, gone} = orders_with_one_in_trash(user)
      _others = order(other)

      assert uuids(Billing.list_user_orders(user.uuid)) == [kept.uuid]
      assert uuids(Billing.list_user_orders(user.uuid, %{trashed: :only})) == [gone.uuid]

      assert uuids(Billing.list_user_orders(user.uuid, %{trashed: :include})) ==
               uuids([kept, gone])
    end

    test "the invoices preloaded on a customer's orders leave the trash out too", %{user: user} do
      order = order(user)
      {:ok, shown} = Billing.create_invoice_from_order(order)
      {:ok, hidden} = Billing.create_invoice_from_order(order)
      {:ok, _} = Billing.trash_invoice(hidden)

      for preload <- [[:invoices], [invoices: :transactions]] do
        assert [%{invoices: invoices}] =
                 Billing.list_user_orders(user.uuid, %{}, preload: preload)

        assert uuids(invoices) == [shown.uuid]
      end

      assert [%{invoices: invoices}] =
               Billing.list_user_orders(user.uuid, %{}, preload: [invoices: :transactions])

      assert Enum.all?(invoices, &is_list(&1.transactions))
    end

    test "list_orders_with_count/1 counts what it lists", %{user: user} do
      {kept, gone} = orders_with_one_in_trash(user)
      before = elem(Billing.list_orders_with_count([]), 1)

      assert {[%{uuid: uuid}], 1} =
               Billing.list_orders_with_count(trashed: :only, search: gone.order_number)

      assert uuid == gone.uuid

      assert {[], 0} = Billing.list_orders_with_count(search: gone.order_number)
      assert {[%{uuid: _}], 1} = Billing.list_orders_with_count(search: kept.order_number)

      {_, trash_total} = Billing.list_orders_with_count(trashed: :only)
      {_, all_total} = Billing.list_orders_with_count(trashed: :include)
      assert all_total == before + trash_total
    end

    test "list_orders_with_count/1 puts the newest trashed first in the trash", %{user: user} do
      first = order(user)
      second = order(user)
      {:ok, _} = Billing.trash_order(first)
      {:ok, _} = Billing.trash_order(second)

      Repo.update_all(
        from(o in PhoenixKitBilling.Order, where: o.uuid == ^first.uuid),
        set: [trashed_at: ~U[2030-01-01 00:00:00Z]]
      )

      {[newest | _], _} = Billing.list_orders_with_count(trashed: :only)
      assert newest.uuid == first.uuid
    end

    test "lookups by identity still find a trashed order", %{user: user} do
      {_kept, gone} = orders_with_one_in_trash(user)

      assert Billing.get_order(gone.uuid)
      assert Billing.get_order!(gone.uuid)
      assert Billing.get_order_by_number(gone.order_number)
    end

    test "get_order_by_uuid/2 serves public URLs: a trashed order is not found unless asked for",
         %{user: user} do
      {kept, gone} = orders_with_one_in_trash(user)

      assert Billing.get_order_by_uuid(kept.uuid)
      assert Billing.get_order_by_uuid(gone.uuid) == nil
      assert Billing.get_order_by_uuid(gone.uuid, trashed: :include)
    end
  end

  describe "invoices" do
    test "list_invoices/1 leaves the trash out, and takes trashed: :only | :include", %{
      user: user
    } do
      {kept, gone} = invoices_with_one_in_trash(user)

      assert uuids(Billing.list_invoices(%{})) == [kept.uuid]
      assert uuids(Billing.list_invoices(%{trashed: :only})) == [gone.uuid]
      assert uuids(Billing.list_invoices(%{trashed: :include})) == uuids([kept, gone])
      assert uuids(Billing.list_invoices(trashed: :only)) == [gone.uuid]
    end

    test "list_user_invoices/2 - the customer's and the rollup panel's list", %{
      user: user,
      other: other
    } do
      {kept, gone} = invoices_with_one_in_trash(user)
      _others = invoice(other)

      assert uuids(Billing.list_user_invoices(user.uuid)) == [kept.uuid]
      assert uuids(Billing.list_user_invoices(user.uuid, %{limit: 5})) == [kept.uuid]
      assert uuids(Billing.list_user_invoices(user.uuid, %{trashed: :only})) == [gone.uuid]
    end

    test "list_invoices_with_count/1 counts what it lists", %{user: user} do
      {kept, gone} = invoices_with_one_in_trash(user)

      assert {[%{uuid: uuid}], 1} =
               Billing.list_invoices_with_count(trashed: :only, search: gone.invoice_number)

      assert uuid == gone.uuid
      assert {[], 0} = Billing.list_invoices_with_count(search: gone.invoice_number)
      assert {[_], 1} = Billing.list_invoices_with_count(search: kept.invoice_number)
    end

    test "list_invoices_for_order/2 is what an order shows of its invoices", %{user: user} do
      order = order(user)
      {:ok, shown} = Billing.create_invoice_from_order(order)
      {:ok, hidden} = Billing.create_invoice_from_order(order)
      {:ok, _} = Billing.trash_invoice(hidden)

      assert uuids(Billing.list_invoices_for_order(order.uuid)) == [shown.uuid]
      assert uuids(Billing.list_invoices_for_order(order.uuid, trashed: :only)) == [hidden.uuid]

      assert uuids(Billing.list_invoices_for_order(order.uuid, trashed: :include)) ==
               uuids([shown, hidden])
    end

    test "lookups by identity still find a trashed invoice", %{user: user} do
      {_kept, gone} = invoices_with_one_in_trash(user)

      assert Billing.get_invoice(gone.uuid)
      assert Billing.get_invoice!(gone.uuid)
      assert Billing.get_invoice_by_number(gone.invoice_number)
    end

    test "a trashed invoice keeps its number used", %{user: user} do
      {_kept, gone} = invoices_with_one_in_trash(user)

      assert {:error, changeset} =
               Billing.create_invoice(user.uuid, %{
                 total: Decimal.new("1.00"),
                 currency: "EUR",
                 invoice_number: gone.invoice_number
               })

      assert %{invoice_number: [_ | _]} = errors_on(changeset)
    end
  end

  describe "dashboard figures" do
    test "orders and invoices in the trash are not counted", %{user: user} do
      before = Billing.get_dashboard_stats()
      config_before = Billing.get_config()

      _ = orders_with_one_in_trash(user)
      _ = invoices_with_one_in_trash(user)

      stats = Billing.get_dashboard_stats()
      assert stats.total_orders == before.total_orders + 1
      assert stats.orders_this_month == before.orders_this_month + 1
      assert stats.total_invoices == before.total_invoices + 1
      assert stats.invoices_this_month == before.invoices_this_month + 1

      config = Billing.get_config()
      assert config.orders_count == config_before.orders_count + 1
      assert config.invoices_count == config_before.invoices_count + 1

      assert [%{value: orders}, %{value: invoices} | _] = Billing.module_stats()
      assert orders == config.orders_count
      assert invoices == config.invoices_count
    end

    test "a trashed invoice adds nothing to the revenue figures or the status counts", %{
      user: user
    } do
      before = Billing.get_dashboard_stats()

      # Even a sum that should count is left out once the invoice is trashed.
      {:ok, invoice} =
        Billing.create_invoice(user.uuid, %{total: Decimal.new("40.00"), currency: "EUR"})

      {:ok, sent} = invoice |> Invoice.status_changeset("sent") |> Repo.update()

      Repo.update_all(
        from(i in Invoice, where: i.uuid == ^sent.uuid),
        set: [trashed_at: ~U[2026-01-01 00:00:00Z]]
      )

      stats = Billing.get_dashboard_stats()
      assert stats.pending_revenue == before.pending_revenue
      assert stats.pending_invoices_count == before.pending_invoices_count
    end
  end

  describe "what stays counted" do
    test "a trashed order still holds its currency", %{user: user} do
      {:ok, currency} =
        Billing.create_currency(%{code: "chf", name: "Swiss Franc", symbol: "Fr"})

      {:ok, trashed} = Billing.trash_order(order(user, %{"currency" => "CHF"}))
      assert trashed.trashed_at

      assert {:error, :currency_in_use} = Billing.delete_currency(currency)
    end

    test "a trashed order's number is not handed out again", %{user: user} do
      {_kept, gone} = orders_with_one_in_trash(user)
      next = order(user)

      assert next.order_number != gone.order_number
    end
  end
end
