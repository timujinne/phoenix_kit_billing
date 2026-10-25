defmodule PhoenixKitBilling.DeleteOrderRaceTest do
  @moduledoc """
  `delete_order/1` against a concurrent invoice insert and a concurrent
  confirmation, under real concurrency (separate connections, outside the
  sandbox; `async: false` because it changes the sandbox mode for the run).
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
        "email" => "delete-race-#{System.unique_integer([:positive])}@example.com",
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

  test "an invoice created first is never detached: the delete waits, then refuses", %{
    order: order
  } do
    {creator, {:ok, invoice}} = hold_open(fn -> Billing.create_invoice_from_order(order) end)

    deleter = Task.async(fn -> Billing.delete_order(order) end)
    assert Task.yield(deleter, 300) == nil

    send(creator.pid, :commit)
    assert {:ok, {:ok, {:ok, _}}} = Task.yield(creator, 5_000)
    assert {:ok, {:error, :order_has_invoices}} = Task.yield(deleter, 5_000)

    assert %Order{} = Billing.get_order(order.uuid)
    assert Billing.get_invoice!(invoice.uuid).order_uuid == order.uuid
  end

  test "a delete committed first: the invoice insert fails and leaves nothing behind", %{
    order: order,
    user: user
  } do
    {deleter, {:ok, _}} = hold_open(fn -> Billing.delete_order(order) end)

    creator = Task.async(fn -> Billing.create_invoice_from_order(order) end)
    assert Task.yield(creator, 300) == nil

    send(deleter.pid, :commit)
    assert {:ok, {:ok, {:ok, _}}} = Task.yield(deleter, 5_000)

    assert {:ok, {:error, _}} = Task.yield(creator, 5_000)
    assert Repo.aggregate(from(i in Invoice, where: i.user_uuid == ^user.uuid), :count) == 0
  end

  test "a confirmation committed first: the delete from the stale struct is refused", %{
    order: order
  } do
    {confirmer, {:ok, _}} = hold_open(fn -> Billing.confirm_order(order) end)

    deleter = Task.async(fn -> Billing.delete_order(order) end)
    assert Task.yield(deleter, 300) == nil

    send(confirmer.pid, :commit)
    assert {:ok, {:ok, {:ok, _}}} = Task.yield(confirmer, 5_000)
    assert {:ok, {:error, :can_only_delete_drafts}} = Task.yield(deleter, 5_000)

    assert Billing.get_order!(order.uuid).status == "confirmed"
  end
end
