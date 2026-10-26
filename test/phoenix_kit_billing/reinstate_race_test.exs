defmodule PhoenixKitBilling.ReinstateRaceTest do
  @moduledoc """
  Reinstating a cancelled order against a second reinstate and against the
  trash, under real concurrency (separate connections, outside the sandbox;
  `async: false` because it changes the sandbox mode for the run).

  Whichever commits first wins and the other waits for it, then decides on
  what it committed: an order is reinstated once, and never out of the trash.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Order
  alias PhoenixKitBilling.Test.Repo

  setup do
    Sandbox.mode(Repo, :auto)
    PhoenixKit.Settings.update_setting("billing_enabled", "true")

    {:ok, user} =
      Auth.register_user(%{
        "email" => "reinstate-race-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234567"
      })

    {:ok, order} =
      Billing.create_order(user, %{
        "total" => Decimal.new("10.00"),
        "currency" => "EUR",
        "billing_snapshot" => %{"email" => "g@example.com"}
      })

    {:ok, confirmed} = Billing.confirm_order(order)
    {:ok, cancelled} = Billing.cancel_order(confirmed, "first")

    on_exit(fn ->
      Repo.delete_all(from(o in Order, where: o.user_uuid == ^user.uuid))
      Repo.delete_all(from(u in User, where: u.uuid == ^user.uuid))
      Sandbox.mode(Repo, :manual)
    end)

    %{order: cancelled}
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

  test "two reinstates: the second waits, then refuses, and one note is written", %{
    order: order
  } do
    {first, {:ok, reinstated}} = hold_open(fn -> Billing.reinstate_order(order, "one") end)
    assert reinstated.status == "confirmed"

    second = Task.async(fn -> Billing.reinstate_order(order, "two") end)
    assert Task.yield(second, 300) == nil

    commit(first)
    assert {:ok, {:error, :order_not_reinstatable}} = Task.yield(second, 5_000)

    stored = Billing.get_order!(order.uuid)
    assert stored.status == "confirmed"
    assert stored.metadata["reinstated"]["reason"] == "one"
    assert length(Regex.scan(~r/Reinstated /, stored.internal_notes)) == 1
  end

  test "a trash committed first: the reinstate waits, then refuses", %{order: order} do
    {trasher, {:ok, _trashed}} = hold_open(fn -> Billing.trash_order(order) end)

    reinstater = Task.async(fn -> Billing.reinstate_order(order, "late") end)
    assert Task.yield(reinstater, 300) == nil

    commit(trasher)
    assert {:ok, {:error, :order_trashed}} = Task.yield(reinstater, 5_000)

    stored = Billing.get_order!(order.uuid)
    assert stored.status == "cancelled"
    assert Order.trashed?(stored)
  end

  test "a reinstate committed first: the trash waits, then refuses", %{order: order} do
    {reinstater, {:ok, _}} = hold_open(fn -> Billing.reinstate_order(order, "back") end)

    trasher = Task.async(fn -> Billing.trash_order(order) end)
    assert Task.yield(trasher, 300) == nil

    commit(reinstater)
    assert {:ok, {:error, :order_not_trashable}} = Task.yield(trasher, 5_000)

    stored = Billing.get_order!(order.uuid)
    assert stored.status == "confirmed"
    refute Order.trashed?(stored)
  end
end
