defmodule PhoenixKitBilling.NumberSequencesRaceTest do
  @moduledoc """
  Numbers under real concurrency. The sandbox shares one connection, so tasks
  inside it only take turns; these tests leave it (`:auto` mode) and use
  separate connections that really race for the counter row, then delete what
  they committed. `async: false`: it changes the sandbox mode for the whole run.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Invoice
  alias PhoenixKitBilling.Order
  alias PhoenixKitBilling.Test.Repo
  alias PhoenixKitBilling.Transaction

  @sequences "phoenix_kit_billing_number_sequences"

  setup do
    Sandbox.mode(Repo, :auto)
    PhoenixKit.Settings.update_setting("billing_enabled", "true")
    Repo.delete_all(from(s in @sequences))

    {:ok, user} =
      Auth.register_user(%{
        "email" => "numbers-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234567"
      })

    on_exit(fn ->
      Repo.delete_all(from(t in Transaction, where: t.user_uuid == ^user.uuid))
      Repo.delete_all(from(i in Invoice, where: i.user_uuid == ^user.uuid))
      Repo.delete_all(from(o in Order, where: o.user_uuid == ^user.uuid))
      Repo.delete_all(from(s in @sequences))
      Repo.delete_all(from(u in User, where: u.uuid == ^user.uuid))
      Sandbox.mode(Repo, :manual)
    end)

    %{user: user}
  end

  defp parallel(count, fun) do
    1..count
    |> Enum.map(fn n -> Task.async(fn -> fun.(n) end) end)
    |> Enum.map(&Task.await(&1, 30_000))
  end

  defp order_attrs do
    %{
      "total" => Decimal.new("10.00"),
      "currency" => "EUR",
      "status" => "pending",
      "billing_snapshot" => %{"email" => "buyer@example.com"}
    }
  end

  # The suffix numbers, sorted.
  defp sequence(records, field) do
    records
    |> Enum.map(fn {:ok, record} ->
      record |> Map.fetch!(field) |> String.split("-") |> List.last()
    end)
    |> Enum.sort()
  end

  defp expected(range), do: Enum.map(range, &String.pad_leading(to_string(&1), 4, "0"))

  test "concurrent orders, the first of the year among them, get distinct consecutive numbers", %{
    user: user
  } do
    # No counter row yet: every task races to create it.
    first = parallel(8, fn _ -> Billing.create_order(user, order_attrs()) end)
    assert Enum.all?(first, &match?({:ok, _}, &1))
    assert sequence(first, :order_number) == expected(1..8)

    # Counter row exists: every task races for its lock.
    second = parallel(8, fn _ -> Billing.create_order(user, order_attrs()) end)
    assert Enum.all?(second, &match?({:ok, _}, &1))
    assert sequence(first ++ second, :order_number) == expected(1..16)
  end

  test "concurrent orders after a delete never meet a taken number", %{user: user} do
    {:ok, first} = Billing.create_order(user, order_attrs())
    {:ok, _} = Billing.create_order(user, order_attrs())
    Repo.delete!(first)

    results = parallel(6, fn _ -> Billing.create_order(user, order_attrs()) end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert sequence(results, :order_number) == expected(3..8)
  end

  test "concurrent standalone invoices get distinct consecutive numbers", %{user: user} do
    attrs = %{
      total: Decimal.new("10.00"),
      currency: "EUR",
      billing_details: %{"email" => "b@example.com"}
    }

    results = parallel(8, fn _ -> Billing.create_invoice(user, attrs) end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert sequence(results, :invoice_number) == expected(1..8)
  end

  test "concurrent receipts get distinct consecutive numbers", %{user: user} do
    {:ok, order} = Billing.create_order(user, order_attrs())

    invoices =
      for _ <- 1..6 do
        {:ok, invoice} = Billing.create_invoice_from_order(order)

        {:ok, partly} =
          invoice |> Ecto.Changeset.change(%{paid_amount: Decimal.new("4.00")}) |> Repo.update()

        partly
      end

    results = parallel(6, fn n -> Billing.generate_receipt(Enum.at(invoices, n - 1)) end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert sequence(results, :receipt_number) == expected(1..6)
  end

  test "concurrent payments and mark-paid on different invoices get distinct transaction numbers",
       %{user: user} do
    {:ok, order} = Billing.create_order(user, order_attrs())

    invoices =
      for _ <- 1..8 do
        {:ok, invoice} = Billing.create_invoice_from_order(order)
        {:ok, sent} = invoice |> Ecto.Changeset.change(%{status: "sent"}) |> Repo.update()
        sent
      end

    results =
      parallel(8, fn n ->
        invoice = Enum.at(invoices, n - 1)

        if rem(n, 2) == 0 do
          Billing.record_payment(
            invoice,
            %{amount: Decimal.new("10.00"), payment_method: "bank"},
            nil
          )
        else
          Billing.mark_invoice_paid(invoice)
        end
      end)

    assert Enum.all?(results, &match?({:ok, _}, &1))

    numbers =
      from(t in Transaction, where: t.user_uuid == ^user.uuid, select: t.transaction_number)
      |> Repo.all()
      |> Enum.map(&(&1 |> String.split("-") |> List.last()))
      |> Enum.sort()

    assert numbers == expected(1..8)

    receipts =
      from(i in Invoice, where: i.user_uuid == ^user.uuid, select: i.receipt_number)
      |> Repo.all()
      |> Enum.map(&(&1 |> String.split("-") |> List.last()))
      |> Enum.sort()

    assert receipts == expected(1..8)
  end

  test "concurrent receipts for one invoice issue exactly one", %{user: user} do
    {:ok, order} = Billing.create_order(user, order_attrs())
    {:ok, invoice} = Billing.create_invoice_from_order(order)

    {:ok, stale} =
      invoice |> Ecto.Changeset.change(%{paid_amount: Decimal.new("4.00")}) |> Repo.update()

    # Every caller holds the same stale struct, which has no receipt yet.
    results = parallel(6, fn _ -> Billing.generate_receipt(stale) end)

    assert [{:ok, issued}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert issued.receipt_number =~ ~r/-0001$/

    others = Enum.reject(results, &match?({:ok, _}, &1))
    assert others == List.duplicate({:error, :receipt_already_generated}, 5)

    assert Repo.get!(Invoice, invoice.uuid).receipt_number == issued.receipt_number
    assert Repo.one(from(s in @sequences, where: s.scope == "receipt", select: s.last_value)) == 1
  end

  # Two first-of-the-year creates that both miss the counter row: the second one
  # reaches the INSERT while the first one's row is still uncommitted, waits on
  # it, and must then take the next value instead of failing on the key.
  test "the second of two creates that both found no counter row takes the next value", %{
    user: user
  } do
    test_pid = self()

    first =
      Task.async(fn ->
        Repo.transaction(fn ->
          {:ok, order} = Billing.create_order(user, order_attrs())
          send(test_pid, {:first_inserted, order})

          receive do
            :commit -> order
          end
        end)
      end)

    assert_receive {:first_inserted, first_order}, 5_000

    second = Task.async(fn -> Billing.create_order(user, order_attrs()) end)

    # The second create is stuck on the first one's uncommitted counter row.
    :ok = wait_until_a_backend_waits_on_a_lock()
    send(first.pid, :commit)

    assert {:ok, ^first_order} = Task.await(first, 30_000)
    assert {:ok, second_order} = Task.await(second, 30_000)

    assert first_order.order_number =~ ~r/-0001$/
    assert second_order.order_number =~ ~r/-0002$/
  end

  defp wait_until_a_backend_waits_on_a_lock(attempts \\ 200) do
    waiting =
      Repo.query!("""
      SELECT count(*) FROM pg_stat_activity
      WHERE datname = current_database() AND wait_event_type = 'Lock'
      """).rows

    cond do
      waiting != [[0]] ->
        :ok

      attempts == 0 ->
        flunk("no create ever waited on the counter row")

      true ->
        receive do
        after
          25 -> wait_until_a_backend_waits_on_a_lock(attempts - 1)
        end
    end
  end
end
