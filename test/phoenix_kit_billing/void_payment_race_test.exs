defmodule PhoenixKitBilling.VoidPaymentRaceTest do
  @moduledoc """
  A void and a payment racing for the same invoice, under real concurrency.
  The sandbox shares one connection, so tasks inside it only take turns; these
  tests leave it (`:auto` mode) and use separate connections that really race
  for the row lock, then delete what they committed. `async: false`: it
  changes the sandbox mode for the whole run.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, Transaction}
  alias PhoenixKitBilling.Test.Repo

  setup do
    Sandbox.mode(Repo, :auto)
    PhoenixKit.Settings.update_setting("billing_enabled", "true")

    {:ok, user} =
      Auth.register_user(%{
        "email" => "void-race-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234567"
      })

    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    {:ok, sent} = invoice |> Invoice.status_changeset("sent") |> Repo.update()

    on_exit(fn ->
      Repo.delete_all(from(t in Transaction, where: t.invoice_uuid == ^invoice.uuid))
      Repo.delete_all(from(i in Invoice, where: i.uuid == ^invoice.uuid))
      Repo.delete_all(from(u in User, where: u.uuid == ^user.uuid))
      Sandbox.mode(Repo, :manual)
    end)

    %{invoice: sent}
  end

  # Runs `fun` in a transaction that stays open (holding whatever row locks
  # `fun` took) until it is told to commit.
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

  defp transaction_count(invoice),
    do: Repo.aggregate(from(t in Transaction, where: t.invoice_uuid == ^invoice.uuid), :count)

  test "a void committed first: the payment is refused and records nothing", %{invoice: invoice} do
    {voider, {:ok, _voided}} = hold_open(fn -> Billing.void_invoice(invoice, "Duplicate") end)

    payer =
      Task.async(fn ->
        Billing.record_payment(invoice, %{amount: "100.00", payment_method: "bank"}, nil)
      end)

    # It cannot answer while the void holds the row.
    assert Task.yield(payer, 300) == nil

    send(voider.pid, :commit)
    assert {:ok, {:ok, {:ok, _}}} = Task.yield(voider, 5_000)

    # The payment passed `payable?` on its stale struct, then met the lock.
    assert {:ok, {:error, :not_payable}} = Task.yield(payer, 5_000)

    assert transaction_count(invoice) == 0
    stored = Billing.get_invoice!(invoice.uuid)
    assert stored.status == "void"
    assert Decimal.equal?(stored.paid_amount, 0)
  end

  test "a payment committed first: the void is refused and the invoice stays paid", %{
    invoice: invoice
  } do
    {payer, {:ok, _transaction}} =
      hold_open(fn ->
        Billing.record_payment(invoice, %{amount: "100.00", payment_method: "bank"}, nil)
      end)

    voider = Task.async(fn -> Billing.void_invoice(invoice, "Duplicate") end)

    assert Task.yield(voider, 300) == nil

    send(payer.pid, :commit)
    assert {:ok, {:ok, {:ok, _}}} = Task.yield(payer, 5_000)
    assert {:ok, {:error, :invoice_not_voidable}} = Task.yield(voider, 5_000)

    stored = Billing.get_invoice!(invoice.uuid)
    assert stored.status == "paid"
    assert Decimal.equal?(stored.paid_amount, Decimal.new("100.00"))
    refute Map.has_key?(stored.metadata, "void")
    assert transaction_count(invoice) == 1
  end

  test "a void committed first: Mark paid is refused and records nothing", %{invoice: invoice} do
    {voider, {:ok, _voided}} = hold_open(fn -> Billing.void_invoice(invoice) end)

    marker = Task.async(fn -> Billing.mark_invoice_paid(invoice) end)
    assert Task.yield(marker, 300) == nil

    send(voider.pid, :commit)
    assert {:ok, {:ok, {:ok, _}}} = Task.yield(voider, 5_000)
    assert {:ok, {:error, :invoice_not_payable}} = Task.yield(marker, 5_000)

    assert transaction_count(invoice) == 0
    assert Billing.get_invoice!(invoice.uuid).status == "void"
  end

  test "a void committed first: a resend of the stale struct is refused and the trail stays", %{
    invoice: invoice
  } do
    {voider, {:ok, _voided}} = hold_open(fn -> Billing.void_invoice(invoice, "Duplicate") end)

    sender =
      Task.async(fn ->
        Billing.send_invoice(invoice, to_email: "customer@example.com", send_email: false)
      end)

    assert Task.yield(sender, 300) == nil

    send(voider.pid, :commit)
    assert {:ok, {:ok, {:ok, _}}} = Task.yield(voider, 5_000)
    assert {:ok, {:error, :invoice_not_sendable}} = Task.yield(sender, 5_000)

    stored = Billing.get_invoice!(invoice.uuid)
    assert stored.status == "void"
    assert stored.metadata["void"]["reason"] == "Duplicate"
    refute Map.has_key?(stored.metadata, "send_history")
  end
end
