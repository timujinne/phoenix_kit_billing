defmodule PhoenixKitBilling.TrashRaceTest do
  @moduledoc """
  Trashing an order against a concurrent invoice insert, invoice restore and
  update, under real concurrency (separate connections, outside the sandbox;
  `async: false` because it changes the sandbox mode for the run).

  Whichever commits first wins and the other finds out: an order is never in
  the trash with an open invoice, and a trashed order is never changed.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, Order}
  alias PhoenixKitBilling.Test.Repo

  setup do
    Sandbox.mode(Repo, :auto)
    PhoenixKit.Settings.update_setting("billing_enabled", "true")

    {:ok, user} =
      Auth.register_user(%{
        "email" => "trash-race-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234567"
      })

    {:ok, order} =
      Billing.create_order(user, %{
        "total" => Decimal.new("10.00"),
        "currency" => "EUR",
        "billing_snapshot" => %{"email" => "g@example.com"}
      })

    on_exit(fn ->
      Repo.delete_all(from(i in Invoice, where: i.user_uuid == ^user.uuid))
      Repo.delete_all(from(o in Order, where: o.user_uuid == ^user.uuid))
      Repo.delete_all(from(u in User, where: u.uuid == ^user.uuid))
      Sandbox.mode(Repo, :manual)
    end)

    %{order: order, user: user}
  end

  # Runs `fun` in a transaction that stays open, holding what `fun` locked,
  # until told to commit.
  defp hold_open(fun) do
    test_pid = self()

    task =
      Task.async(fn ->
        Repo.transaction(fn ->
          result = fun.()
          send(test_pid, {:holding, result})

          receive do
            :commit -> result
          end
        end)
      end)

    assert_receive {:holding, result}, 5_000
    {task, result}
  end

  defp commit(holder) do
    send(holder.pid, :commit)
    assert {:ok, {:ok, _}} = Task.yield(holder, 5_000)
  end

  test "an invoice created first: the trash waits, then refuses", %{order: order} do
    {creator, {:ok, invoice}} = hold_open(fn -> Billing.create_invoice_from_order(order) end)

    trasher = Task.async(fn -> Billing.trash_order(order) end)
    assert Task.yield(trasher, 300) == nil

    commit(creator)
    assert {:ok, {:error, :order_has_open_invoices}} = Task.yield(trasher, 5_000)

    refute Order.trashed?(Billing.get_order!(order.uuid))
    assert Billing.get_invoice!(invoice.uuid).order_uuid == order.uuid
  end

  test "a trash committed first: the invoice insert waits, then is refused and leaves nothing",
       %{order: order, user: user} do
    {trasher, {:ok, _}} = hold_open(fn -> Billing.trash_order(order) end)

    creator =
      Task.async(fn -> Billing.create_invoice_from_order(Billing.get_order!(order.uuid)) end)

    assert Task.yield(creator, 300) == nil

    commit(trasher)
    assert {:ok, {:error, :order_trashed}} = Task.yield(creator, 5_000)

    assert Repo.aggregate(from(i in Invoice, where: i.user_uuid == ^user.uuid), :count) == 0
    assert Order.trashed?(Billing.get_order!(order.uuid))
  end

  test "a trash committed first: an update from the stale struct waits, then is refused",
       %{order: order} do
    {trasher, {:ok, _}} = hold_open(fn -> Billing.trash_order(order) end)

    updater = Task.async(fn -> Billing.update_order(order, %{"notes" => "late"}) end)
    assert Task.yield(updater, 300) == nil

    commit(trasher)
    assert {:ok, {:error, :order_trashed}} = Task.yield(updater, 5_000)

    assert Billing.get_order!(order.uuid).notes == nil
  end

  test "a trash committed first: a confirmation from the stale struct is refused", %{order: order} do
    {trasher, {:ok, _}} = hold_open(fn -> Billing.trash_order(order) end)

    confirmer = Task.async(fn -> Billing.confirm_order(order) end)
    assert Task.yield(confirmer, 300) == nil

    commit(trasher)
    assert {:ok, {:error, :order_trashed}} = Task.yield(confirmer, 5_000)

    assert Billing.get_order!(order.uuid).status == "draft"
  end

  test "an invoice restored first: the trash waits, then refuses", %{order: order} do
    {:ok, invoice} = Billing.create_invoice_from_order(order)
    {:ok, trashed_invoice} = Billing.trash_invoice(invoice)

    {restorer, {:ok, _}} = hold_open(fn -> Billing.restore_invoice(trashed_invoice) end)

    trasher = Task.async(fn -> Billing.trash_order(order) end)
    assert Task.yield(trasher, 300) == nil

    commit(restorer)
    assert {:ok, {:error, :order_has_open_invoices}} = Task.yield(trasher, 5_000)

    refute Order.trashed?(Billing.get_order!(order.uuid))
  end

  test "an order trashed first: restoring its invoice waits, then is refused", %{order: order} do
    {:ok, invoice} = Billing.create_invoice_from_order(order)
    {:ok, trashed_invoice} = Billing.trash_invoice(invoice)

    {trasher, {:ok, _}} = hold_open(fn -> Billing.trash_order(order) end)

    restorer = Task.async(fn -> Billing.restore_invoice(trashed_invoice) end)
    assert Task.yield(restorer, 300) == nil

    commit(trasher)
    assert {:ok, {:error, :order_trashed}} = Task.yield(restorer, 5_000)

    assert Invoice.trashed?(Billing.get_invoice!(invoice.uuid))
  end
end
