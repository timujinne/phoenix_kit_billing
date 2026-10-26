defmodule PhoenixKitBilling.NumberSequencesTest do
  @moduledoc """
  Order, invoice and receipt numbers come from a counter taken in the same
  transaction as the insert that uses the number. They used to be
  `count(rows of the year) + 1`, so deleting any row but the last handed out a
  number already taken - the insert failed on the unique index, and kept
  failing, which blocked every new order or invoice of the year.
  """

  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Events
  alias PhoenixKitBilling.Invoice
  alias PhoenixKitBilling.Order
  alias PhoenixKitBilling.Test.NumberClock
  alias PhoenixKitBilling.Transaction

  @sequences "phoenix_kit_billing_number_sequences"

  setup do
    # Rolled back with the test's sandbox transaction.
    Repo.delete_all(from(s in @sequences))
    %{user: fixture_user()}
  end

  # At runtime: a module attribute would freeze the year at compile time.
  defp year, do: Date.utc_today().year

  # An install that predates the counter: the numbered rows stay, the counter goes.
  defp forget_counter, do: Repo.delete_all(from(s in @sequences))

  # Where the counter stands: an old node, or a person, has taken numbers it
  # has not reached.
  defp rewind(scope, value),
    do: Repo.update_all(from(s in @sequences, where: s.scope == ^scope), set: [last_value: value])

  defp number(prefix, n, year \\ year()),
    do: "#{prefix}-#{year}-#{String.pad_leading(to_string(n), 4, "0")}"

  defp last_value(scope, year \\ year()) do
    Repo.one(
      from(s in @sequences, where: s.scope == ^scope and s.year == ^year, select: s.last_value)
    )
  end

  defp order_attrs(extra \\ %{}) do
    Map.merge(
      %{
        "total" => Decimal.new("10.00"),
        "currency" => "EUR",
        "status" => "pending",
        "billing_snapshot" => %{"email" => "buyer@example.com"}
      },
      extra
    )
  end

  defp new_order(user, extra \\ %{}) do
    {:ok, order} = Billing.create_order(user, order_attrs(extra))
    order
  end

  # A plain insert: gives a row a number without touching the counter.
  defp insert_order(user, order_number, extra \\ []) do
    {:ok, order} = Billing.create_order(user, order_attrs(%{"order_number" => order_number}))

    if extra != [],
      do: Repo.update_all(from(o in Order, where: o.uuid == ^order.uuid), set: extra)

    order
  end

  defp new_invoice(order) do
    {:ok, invoice} = Billing.create_invoice_from_order(order)
    invoice
  end

  # A paid invoice has ledger rows pointing at it.
  defp delete_invoice(invoice) do
    Repo.delete_all(from(t in Transaction, where: t.invoice_uuid == ^invoice.uuid))
    Repo.delete!(invoice)
  end

  defp sent(invoice) do
    {:ok, sent} = invoice |> Ecto.Changeset.change(%{status: "sent"}) |> Repo.update()
    sent
  end

  describe "orders" do
    test "numbers run on from 0001", %{user: user} do
      assert new_order(user).order_number == number("ORD", 1)
      assert new_order(user).order_number == number("ORD", 2)
      assert last_value("order") == 2
    end

    test "a nil or blank order_number is not a supplied one", %{user: user} do
      blanks = [
        %{"order_number" => nil},
        %{"order_number" => ""},
        %{"order_number" => "  "},
        %{order_number: nil}
      ]

      numbers = for blank <- blanks, do: new_order(user, blank).order_number
      assert numbers == for(n <- 1..4, do: number("ORD", n))
      assert last_value("order") == 4
    end

    test "deleting an order of the year does not free its number", %{user: user} do
      [_first, second, third] = for _ <- 1..3, do: new_order(user, %{"status" => "draft"})

      {:ok, _} = Billing.delete_order(second)
      assert new_order(user).order_number == number("ORD", 4)

      {:ok, _} = Billing.delete_order(third)
      assert new_order(user).order_number == number("ORD", 5)
    end

    test "create_order/1 takes its number from the same counter", %{user: user} do
      assert new_order(user).order_number == number("ORD", 1)

      assert {:ok, order} = Billing.create_order(order_attrs(%{"user_uuid" => user.uuid}))
      assert order.order_number == number("ORD", 2)
    end

    test "an insert that fails its changeset gives its number back", %{user: user} do
      assert new_order(user).order_number == number("ORD", 1)

      assert {:error, %Ecto.Changeset{}} =
               Billing.create_order(user, order_attrs(%{"total" => Decimal.new("-1")}))

      assert last_value("order") == 1
      assert new_order(user).order_number == number("ORD", 2)
    end

    test "a failed order announces nothing, a created one does", %{user: user} do
      Events.subscribe_orders()

      assert {:error, _} =
               Billing.create_order(user, order_attrs(%{"total" => Decimal.new("-1")}))

      refute_receive {:order_created, _}

      order = new_order(user)
      assert_receive {:order_created, ^order}
    end

    test "a counter-less year starts after the numbers already there", %{user: user} do
      # Fewer rows than the highest number: the count alone would hand out
      # 0003, which is taken.
      insert_order(user, number("ORD", 3))
      insert_order(user, number("ORD", 10))
      forget_counter()

      assert new_order(user).order_number == number("ORD", 11)
      assert last_value("order") == 11
    end

    test "a counter-less year also counts rows whose number is not in the format", %{user: user} do
      for n <- ["A", "B", "C"], do: insert_order(user, "MANUAL-#{n}")

      assert new_order(user).order_number == number("ORD", 4)
    end

    test "the numbers of another year do not count", %{user: user} do
      old = insert_order(user, number("ORD", 99, year() - 1))

      Repo.update_all(from(o in Order, where: o.uuid == ^old.uuid),
        set: [inserted_at: DateTime.new!(Date.new!(year() - 1, 6, 1), ~T[12:00:00])]
      )

      assert new_order(user).order_number == number("ORD", 1)
      assert last_value("order", year() - 1) == nil
    end

    test "a number the caller supplies does not use up a counter value", %{user: user} do
      assert insert_order(user, "CUSTOM-1").order_number == "CUSTOM-1"
      assert last_value("order") == nil

      assert new_order(user).order_number == number("ORD", 2)
    end

    test "a changed prefix carries on the year's sequence", %{user: user} do
      assert new_order(user).order_number == number("ORD", 1)

      PhoenixKit.Settings.update_setting("billing_order_prefix", "SO")
      on_exit(fn -> PhoenixKit.Settings.update_setting("billing_order_prefix", "ORD") end)

      assert new_order(user).order_number == number("SO", 2)
    end

    test "a number typed by hand that collides is an error, not a raise", %{user: user} do
      insert_order(user, "TAKEN-1")

      assert {:error, changeset} =
               Billing.create_order(user, order_attrs(%{"order_number" => "TAKEN-1"}))

      assert %{order_number: [_]} = errors_on(changeset)
    end

    test "a supplied number ahead of the counter lifts it without using a value", %{user: user} do
      assert new_order(user).order_number == number("ORD", 1)
      assert insert_order(user, number("ORD", 3)).order_number == number("ORD", 3)
      assert last_value("order") == 3

      # The counter was lifted to 3, so the next one is 4: 0002 is skipped
      # rather than 0003 met.
      assert new_order(user).order_number == number("ORD", 4)
    end

    test "a supplied number behind the counter leaves it alone", %{user: user} do
      for _ <- 1..3, do: new_order(user)
      insert_order(user, "OTHER-#{year() - 1}-0900")

      assert last_value("order") == 3
      assert new_order(user).order_number == number("ORD", 4)
    end

    test "a supplied number lifts a year with no counter row to the rows already there", %{
      user: user
    } do
      for n <- ["A", "B", "C"], do: insert_order(user, "MANUAL-#{n}")

      assert insert_order(user, number("ORD", 2)).order_number == number("ORD", 2)
      assert last_value("order") == 3
      assert new_order(user).order_number == number("ORD", 4)
    end

    test "a supplied number higher than the rows there lifts a year with no counter row to it", %{
      user: user
    } do
      for _ <- 1..4, do: new_order(user)
      forget_counter()

      assert insert_order(user, number("ORD", 30)).order_number == number("ORD", 30)
      assert last_value("order") == 30
      assert new_order(user).order_number == number("ORD", 31)
    end

    test "a number that is not zero-padded does not lift the counter", %{user: user} do
      assert new_order(user).order_number == number("ORD", 1)

      assert insert_order(user, "ORD-#{year()}-7").order_number == "ORD-#{year()}-7"
      assert last_value("order") == 1
    end

    test "only a number with the configured prefix lifts the counter", %{user: user} do
      assert new_order(user).order_number == number("ORD", 1)

      assert insert_order(user, number("OTHER", 50)).order_number == number("OTHER", 50)
      assert last_value("order") == 1

      assert new_order(user).order_number == number("ORD", 2)
    end

    test "a number changed by update_order lifts the counter too", %{user: user} do
      order = new_order(user)

      assert {:ok, _} = Billing.update_order(order, %{"order_number" => number("ORD", 10)})
      assert last_value("order") == 10
      assert new_order(user).order_number == number("ORD", 11)
    end

    test "a number changed by update_order that fails validation takes nothing", %{user: user} do
      order = new_order(user)

      assert {:error, %Ecto.Changeset{}} =
               Billing.update_order(order, %{
                 "order_number" => number("ORD", 10),
                 "total" => Decimal.new("-1")
               })

      assert last_value("order") == 1
    end
  end

  describe "invoices from an order" do
    setup %{user: user}, do: %{order: new_order(user)}

    test "numbers run on from 0001 and a deleted invoice's number is not reused", %{order: order} do
      first = new_invoice(order)
      second = new_invoice(order)
      assert first.invoice_number == number("INV", 1)
      assert second.invoice_number == number("INV", 2)

      Repo.delete!(first)
      assert new_invoice(order).invoice_number == number("INV", 3)

      Repo.delete!(second)
      assert new_invoice(order).invoice_number == number("INV", 4)
    end

    test "the order and invoice counters are separate", %{order: order} do
      assert new_invoice(order).invoice_number == number("INV", 1)
      assert last_value("order") == 1
      assert last_value("invoice") == 1
    end

    test "a counter-less year starts after the numbers already there", %{order: order} do
      for n <- [2, 7] do
        {:ok, _} = Billing.create_invoice_from_order(order, invoice_number: number("INV", n))
      end

      forget_counter()
      assert new_invoice(order).invoice_number == number("INV", 8)
    end

    test "a number the caller supplies does not use up a counter value", %{order: order} do
      {:ok, invoice} = Billing.create_invoice_from_order(order, invoice_number: "OWN-1")
      assert invoice.invoice_number == "OWN-1"
      assert last_value("invoice") == nil

      assert new_invoice(order).invoice_number == number("INV", 2)
    end

    test "a supplied number that collides is an error, not a raise", %{order: order} do
      {:ok, _} = Billing.create_invoice_from_order(order, invoice_number: "OWN-1")

      assert {:error, changeset} =
               Billing.create_invoice_from_order(order, invoice_number: "OWN-1")

      assert %{invoice_number: [_]} = errors_on(changeset)
    end

    test "a supplied number ahead of the counter lifts it without using a value", %{order: order} do
      assert new_invoice(order).invoice_number == number("INV", 1)

      {:ok, supplied} = Billing.create_invoice_from_order(order, invoice_number: number("INV", 3))
      assert supplied.invoice_number == number("INV", 3)
      assert last_value("invoice") == 3

      assert new_invoice(order).invoice_number == number("INV", 4)
    end

    test "a number changed by update_invoice lifts the counter, the receipt number the receipt one",
         %{order: order} do
      invoice = new_invoice(order)

      assert {:ok, _} =
               Billing.update_invoice(invoice, %{
                 "invoice_number" => number("INV", 10),
                 "receipt_number" => number("RCP", 6)
               })

      assert last_value("invoice") == 10
      assert last_value("receipt") == 6
      assert new_invoice(order).invoice_number == number("INV", 11)
    end

    test "a failed insert announces nothing", %{order: order} do
      Events.subscribe_invoices()
      {:ok, _} = Billing.create_invoice_from_order(order, invoice_number: "OWN-1")
      assert_receive {:invoice_created, _}

      assert {:error, _} = Billing.create_invoice_from_order(order, invoice_number: "OWN-1")
      refute_receive {:invoice_created, _}
    end
  end

  describe "standalone invoices" do
    defp standalone(user, extra \\ %{}) do
      Billing.create_invoice(
        user,
        Map.merge(
          %{
            total: Decimal.new("10.00"),
            currency: "EUR",
            billing_details: %{"email" => "b@example.com"}
          },
          extra
        )
      )
    end

    test "share the invoice counter with invoices from an order", %{user: user} do
      order = new_order(user)

      assert {:ok, first} = standalone(user)
      assert new_invoice(order).invoice_number == number("INV", 2)
      assert first.invoice_number == number("INV", 1)

      Repo.delete!(first)
      assert {:ok, next} = standalone(user)
      assert next.invoice_number == number("INV", 3)
    end

    test "a failed insert gives the number back", %{user: user} do
      assert {:ok, _} = standalone(user)
      assert {:error, %Ecto.Changeset{}} = standalone(user, %{total: Decimal.new("-1")})
      assert last_value("invoice") == 1

      assert {:ok, next} = standalone(user)
      assert next.invoice_number == number("INV", 2)
    end

    test "a number the caller supplies does not use up a counter value", %{user: user} do
      assert {:ok, invoice} = standalone(user, %{invoice_number: "OWN-1"})
      assert invoice.invoice_number == "OWN-1"
      assert last_value("invoice") == nil

      assert {:error, changeset} = standalone(user, %{invoice_number: "OWN-1"})
      assert %{invoice_number: [_]} = errors_on(changeset)
    end

    test "a nil or blank invoice_number is not a supplied one", %{user: user} do
      string_keyed = %{
        "total" => Decimal.new("10.00"),
        "currency" => "EUR",
        "billing_details" => %{"email" => "b@example.com"}
      }

      assert {:ok, a} = standalone(user, %{invoice_number: nil})
      assert {:ok, b} = standalone(user, %{invoice_number: ""})
      assert {:ok, c} = Billing.create_invoice(user, Map.put(string_keyed, "invoice_number", nil))
      assert {:ok, d} = Billing.create_invoice(user, Map.put(string_keyed, "invoice_number", " "))

      assert Enum.map([a, b, c, d], & &1.invoice_number) ==
               for(n <- 1..4, do: number("INV", n))

      assert last_value("invoice") == 4
    end

    test "string-keyed attributes get a generated number too", %{user: user} do
      attrs = %{
        "total" => Decimal.new("10.00"),
        "currency" => "EUR",
        "billing_details" => %{"email" => "b@example.com"}
      }

      assert {:ok, invoice} = Billing.create_invoice(user, attrs)
      assert invoice.invoice_number == number("INV", 1)
    end

    test "a supplied number under a string key counts as supplied too", %{user: user} do
      attrs = %{
        "total" => Decimal.new("10.00"),
        "currency" => "EUR",
        "billing_details" => %{"email" => "b@example.com"},
        "invoice_number" => number("INV", 5)
      }

      assert {:ok, invoice} = Billing.create_invoice(user, attrs)
      assert invoice.invoice_number == number("INV", 5)
      assert last_value("invoice") == 5

      assert {:ok, next} = standalone(user)
      assert next.invoice_number == number("INV", 6)
    end

    test "a supplied number ahead of the counter lifts it without using a value", %{user: user} do
      assert {:ok, first} = standalone(user)
      assert {:ok, supplied} = standalone(user, %{invoice_number: number("INV", 5)})

      assert {first.invoice_number, supplied.invoice_number} ==
               {number("INV", 1), number("INV", 5)}

      assert {:ok, next} = standalone(user)
      assert next.invoice_number == number("INV", 6)
    end

    test "a counter-less year starts after the numbers already there", %{user: user} do
      assert {:ok, _} = standalone(user, %{invoice_number: number("INV", 12)})
      forget_counter()

      assert {:ok, next} = standalone(user)
      assert next.invoice_number == number("INV", 13)
    end

    test "the invoices of another year do not count", %{user: user} do
      {:ok, old} = standalone(user, %{invoice_number: number("INV", 40, year() - 1)})

      Repo.update_all(from(i in Invoice, where: i.uuid == ^old.uuid),
        set: [inserted_at: DateTime.new!(Date.new!(year() - 1, 6, 1), ~T[12:00:00])]
      )

      assert {:ok, next} = standalone(user)
      assert next.invoice_number == number("INV", 1)
    end
  end

  describe "receipts" do
    setup %{user: user} do
      order = new_order(user)
      %{order: order}
    end

    test "mark_invoice_paid numbers receipts from the receipt counter", %{order: order} do
      first = order |> new_invoice() |> sent()
      second = order |> new_invoice() |> sent()

      assert {:ok, paid_first} = Billing.mark_invoice_paid(first)
      assert {:ok, paid_second} = Billing.mark_invoice_paid(second)

      assert paid_first.receipt_number == number("RCP", 1)
      assert paid_second.receipt_number == number("RCP", 2)
    end

    test "a deleted invoice's receipt number is not reused", %{order: order} do
      first = order |> new_invoice() |> sent()
      second = order |> new_invoice() |> sent()
      third = order |> new_invoice() |> sent()

      assert {:ok, paid_first} = Billing.mark_invoice_paid(first)
      delete_invoice(paid_first)

      assert {:ok, paid_second} = Billing.mark_invoice_paid(second)
      assert paid_second.receipt_number == number("RCP", 2)

      delete_invoice(paid_second)
      assert {:ok, paid_third} = Billing.mark_invoice_paid(third)
      assert paid_third.receipt_number == number("RCP", 3)
    end

    test "generate_receipt takes the next receipt number", %{order: order} do
      invoice = order |> new_invoice() |> sent()
      assert {:ok, paid} = Billing.mark_invoice_paid(invoice)
      assert paid.receipt_number == number("RCP", 1)

      partly = order |> new_invoice() |> sent()

      {:ok, partly} =
        partly |> Ecto.Changeset.change(%{paid_amount: Decimal.new("4.00")}) |> Repo.update()

      assert {:ok, receipt} = Billing.generate_receipt(partly)
      assert receipt.receipt_number == number("RCP", 2)
      assert last_value("receipt") == 2
    end

    test "generate_receipt refusing an invoice does not use a number", %{order: order} do
      invoice = order |> new_invoice() |> sent()
      assert {:error, :no_payments} = Billing.generate_receipt(invoice)
      assert last_value("receipt") == nil
    end

    test "a payment that settles an invoice numbers its receipt from the same counter", %{
      order: order
    } do
      invoice = order |> new_invoice() |> sent()
      assert {:ok, _} = Billing.record_payment(invoice, %{amount: Decimal.new("10.00")}, nil)
      assert Billing.get_invoice(invoice.uuid).receipt_number == number("RCP", 1)

      other = order |> new_invoice() |> sent()
      assert {:ok, paid} = Billing.mark_invoice_paid(other)
      assert paid.receipt_number == number("RCP", 2)
    end

    test "a counter-less year starts after the receipt numbers already there", %{order: order} do
      invoice = order |> new_invoice() |> sent()

      invoice
      |> Ecto.Changeset.change(%{
        receipt_number: number("RCP", 9),
        receipt_generated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update!()

      other = order |> new_invoice() |> sent()
      assert {:ok, paid} = Billing.mark_invoice_paid(other)
      assert paid.receipt_number == number("RCP", 10)
    end

    test "a receipt number of this year written long before it still counts", %{order: order} do
      invoice = order |> new_invoice() |> sent()

      invoice
      |> Ecto.Changeset.change(%{
        receipt_number: number("RCP", 50),
        receipt_generated_at: DateTime.new!(Date.new!(year() - 1, 6, 1), ~T[12:00:00])
      })
      |> Repo.update!()

      other = order |> new_invoice() |> sent()
      assert {:ok, paid} = Billing.mark_invoice_paid(other)
      assert paid.receipt_number == number("RCP", 51)
    end

    test "the receipts of another year do not count", %{order: order} do
      invoice = order |> new_invoice() |> sent()

      invoice
      |> Ecto.Changeset.change(%{
        receipt_number: number("RCP", 30, year() - 1),
        receipt_generated_at: DateTime.new!(Date.new!(year() - 1, 6, 1), ~T[12:00:00])
      })
      |> Repo.update!()

      other = order |> new_invoice() |> sent()
      assert {:ok, paid} = Billing.mark_invoice_paid(other)
      assert paid.receipt_number == number("RCP", 1)
    end
  end

  describe "transactions" do
    setup %{user: user} do
      %{invoice: user |> new_order() |> new_invoice() |> sent()}
    end

    defp pay(invoice, amount \\ "1.00", extra \\ %{}) do
      Billing.record_payment(
        invoice,
        Map.merge(%{amount: Decimal.new(amount), payment_method: "bank"}, extra),
        nil
      )
    end

    test "numbers run on from 0001", %{invoice: invoice} do
      assert {:ok, first} = pay(invoice)
      assert {:ok, second} = pay(invoice)

      assert first.transaction_number == number("TXN", 1)
      assert second.transaction_number == number("TXN", 2)
      assert last_value("transaction") == 2
    end

    test "deleting a transaction does not free its number", %{invoice: invoice} do
      [_, second, third] = for _ <- 1..3, do: elem(pay(invoice), 1)

      Repo.delete!(second)
      assert {:ok, next} = pay(invoice)
      assert next.transaction_number == number("TXN", 4)

      Repo.delete!(third)
      assert {:ok, next} = pay(invoice)
      assert next.transaction_number == number("TXN", 5)
    end

    test "a settlement from mark_invoice_paid takes its number from the same counter", %{
      invoice: invoice
    } do
      assert {:ok, first} = pay(invoice)
      assert {:ok, _} = Billing.mark_invoice_paid(Billing.get_invoice(invoice.uuid))

      [_, settlement] =
        Repo.all(
          from(t in Transaction,
            where: t.invoice_uuid == ^invoice.uuid,
            order_by: t.transaction_number
          )
        )

      assert first.transaction_number == number("TXN", 1)
      assert settlement.transaction_number == number("TXN", 2)
    end

    test "a counter-less year starts after the numbers already there", %{invoice: invoice} do
      for n <- [3, 10] do
        Repo.insert!(%Transaction{
          transaction_number: number("TXN", n),
          amount: Decimal.new("1.00"),
          currency: "EUR",
          payment_method: "bank",
          invoice_uuid: invoice.uuid,
          user_uuid: invoice.user_uuid
        })
      end

      assert last_value("transaction") == nil
      assert {:ok, next} = pay(invoice)
      assert next.transaction_number == number("TXN", 11)
    end

    test "a payment that fails its changeset gives the number back", %{invoice: invoice} do
      assert {:ok, _} = pay(invoice)
      assert {:error, %Ecto.Changeset{}} = pay(invoice, "1.00", %{payment_method: "bogus"})
      assert last_value("transaction") == 1

      assert {:ok, next} = pay(invoice)
      assert next.transaction_number == number("TXN", 2)
    end

    test "generate_transaction_number/0 hands out the next value" do
      assert Billing.generate_transaction_number() == number("TXN", 1)
      assert Billing.generate_transaction_number() == number("TXN", 2)
    end
  end

  describe "inside the caller's transaction" do
    # A changeset that fails validation is an ordinary error: the caller's
    # transaction goes on, and its next query runs.
    defp inside_transaction(fun) do
      {:ok, result} = Repo.transaction(fn -> fun.() end)
      result
    end

    test "an invalid order is an error and the caller carries on", %{user: user} do
      {error, count} =
        inside_transaction(fn ->
          error = Billing.create_order(user, order_attrs(%{"total" => Decimal.new("-1")}))
          {error, Repo.aggregate(Order, :count)}
        end)

      assert {:error, %Ecto.Changeset{}} = error
      assert count == 0
    end

    test "an invalid order, then a valid one, in one transaction", %{user: user} do
      {error, order} =
        inside_transaction(fn ->
          error = Billing.create_order(user, order_attrs(%{"total" => Decimal.new("-1")}))
          {error, new_order(user)}
        end)

      assert {:error, %Ecto.Changeset{}} = error
      assert order.order_number == number("ORD", 1)
    end

    test "an invalid invoice from an order is an error and the caller carries on", %{user: user} do
      order = new_order(user)

      {error, count} =
        inside_transaction(fn ->
          error = Billing.create_invoice_from_order(%{order | total: nil})
          {error, Repo.aggregate(Invoice, :count)}
        end)

      assert {:error, %Ecto.Changeset{}} = error
      assert count == 0
      assert last_value("invoice") == nil
    end

    test "an invalid standalone invoice is an error and the caller carries on", %{user: user} do
      {error, invoice} =
        inside_transaction(fn ->
          error = standalone(user, %{total: Decimal.new("-1")})
          {error, standalone(user)}
        end)

      assert {:error, %Ecto.Changeset{}} = error
      assert {:ok, %Invoice{invoice_number: invoice_number}} = invoice
      assert invoice_number == number("INV", 1)
    end

    test "an order update that fails validation is an error and the caller carries on", %{
      user: user
    } do
      order = new_order(user)

      count =
        inside_transaction(fn ->
          assert {:error, %Ecto.Changeset{}} =
                   Billing.update_order(order, %{
                     "order_number" => number("ORD", 10),
                     "total" => Decimal.new("-1")
                   })

          Repo.aggregate(Order, :count)
        end)

      assert count == 1
    end

    test "a receipt refused up front is an error and the caller carries on", %{user: user} do
      invoice = user |> new_order() |> new_invoice() |> sent()

      count =
        inside_transaction(fn ->
          assert {:error, :no_payments} = Billing.generate_receipt(invoice)
          Repo.aggregate(Invoice, :count)
        end)

      assert count == 1
    end
  end

  describe "how far back the seed looks" do
    test "a number on a row from the last days of the previous year still counts", %{user: user} do
      insert_order(user, number("ORD", 7),
        inserted_at: DateTime.new!(Date.new!(year() - 1, 12, 31), ~T[12:00:00])
      )

      forget_counter()
      assert new_order(user).order_number == number("ORD", 8)
    end

    test "a number on an older row does not", %{user: user} do
      insert_order(user, number("ORD", 7),
        inserted_at: DateTime.new!(Date.new!(year() - 1, 12, 30), ~T[12:00:00])
      )

      forget_counter()
      assert new_order(user).order_number == number("ORD", 1)
    end
  end

  describe "the rows of the year are counted by their timestamp" do
    # Numbers that are not in the counter's shape, so only the row count can
    # place the next number.
    defp boundary_instants do
      y = year()

      [
        DateTime.new!(Date.new!(y - 1, 12, 31), ~T[23:59:59]),
        DateTime.new!(Date.new!(y, 1, 1), ~T[00:00:00]),
        DateTime.new!(Date.new!(y, 12, 31), ~T[23:59:59]),
        DateTime.new!(Date.new!(y + 1, 1, 1), ~T[00:00:00])
      ]
    end

    test "orders: the last second before the year and the first after it are out", %{user: user} do
      for {at, n} <- Enum.with_index(boundary_instants(), 1),
          do: insert_order(user, "LEGACY-#{n}", inserted_at: at)

      forget_counter()
      assert new_order(user).order_number == number("ORD", 3)
    end

    test "invoices: the last second before the year and the first after it are out", %{
      user: user
    } do
      order = new_order(user)

      for {at, n} <- Enum.with_index(boundary_instants(), 1) do
        {:ok, invoice} = Billing.create_invoice_from_order(order, invoice_number: "LEGACY-#{n}")

        Repo.update_all(from(i in Invoice, where: i.uuid == ^invoice.uuid),
          set: [inserted_at: at]
        )
      end

      forget_counter()
      assert new_invoice(order).invoice_number == number("INV", 3)
    end

    test "transactions: the last second before the year and the first after it are out", %{
      user: user
    } do
      invoice = user |> new_order() |> new_invoice() |> sent()

      for {at, n} <- Enum.with_index(boundary_instants(), 1) do
        Repo.insert!(%Transaction{
          transaction_number: "LEGACY-#{n}",
          amount: Decimal.new("1.00"),
          currency: "EUR",
          payment_method: "bank",
          invoice_uuid: invoice.uuid,
          user_uuid: invoice.user_uuid,
          inserted_at: at,
          updated_at: at
        })
      end

      forget_counter()
      assert Billing.generate_transaction_number() == number("TXN", 3)
    end

    test "receipts: the last second before the year and the first after it are out", %{
      user: user
    } do
      order = new_order(user)

      for {at, n} <- Enum.with_index(boundary_instants(), 1) do
        order
        |> new_invoice()
        |> Ecto.Changeset.change(%{receipt_number: "LEGACY-#{n}", receipt_generated_at: at})
        |> Repo.update!()
      end

      forget_counter()
      paid = order |> new_invoice() |> sent() |> Billing.mark_invoice_paid()
      assert {:ok, %Invoice{receipt_number: receipt}} = paid
      assert receipt == number("RCP", 3)
    end
  end

  describe "the year of a number is read once per operation" do
    # The first read says this year, any later one the next: an operation that
    # reads the clock again would draw a number of the new year.
    defp clock_flips_after_first_read do
      NumberClock.set([
        Date.new!(year(), 12, 31),
        Date.new!(year() + 1, 1, 1)
      ])
    end

    test "a create that skips a taken number and retries stays in one year", %{user: user} do
      insert_order(user, number("ORD", 1))
      rewind("order", 0)

      clock_flips_after_first_read()
      order = new_order(user)

      assert order.order_number == number("ORD", 2)
      assert NumberClock.reads() == 1
      assert last_value("order", year() + 1) == nil
    end

    test "an update that changes two numbers stays in one year", %{user: user} do
      invoice = user |> new_order() |> new_invoice()

      clock_flips_after_first_read()

      assert {:ok, _} =
               Billing.update_invoice(invoice, %{
                 invoice_number: number("INV", 20),
                 receipt_number: number("RCP", 30)
               })

      assert NumberClock.reads() == 1
      assert {last_value("invoice"), last_value("receipt")} == {20, 30}
      assert {last_value("invoice", year() + 1), last_value("receipt", year() + 1)} == {nil, nil}
    end

    test "generate_transaction_number/0 reads it once" do
      clock_flips_after_first_read()

      assert Billing.generate_transaction_number() == number("TXN", 1)
      assert NumberClock.reads() == 1
    end

    test "generate_receipt/1 reads it once", %{user: user} do
      invoice = user |> new_order() |> new_invoice() |> sent()

      {:ok, partly} =
        invoice |> Ecto.Changeset.change(%{paid_amount: Decimal.new("4.00")}) |> Repo.update()

      clock_flips_after_first_read()

      assert {:ok, receipt} = Billing.generate_receipt(partly)
      assert receipt.receipt_number == number("RCP", 1)
      assert NumberClock.reads() == 1
    end

    test "a supplied number is lifted into the year the operation started in", %{user: user} do
      clock_flips_after_first_read()
      assert {:ok, _} = standalone(user, %{invoice_number: number("INV", 7)})

      assert NumberClock.reads() == 1
      assert last_value("invoice") == 7
    end
  end

  describe "a failed create says what it was doing" do
    test "so a form can show the errors", %{user: user} do
      assert {:error, %Ecto.Changeset{action: :insert}} =
               Billing.create_order(user, order_attrs(%{"total" => Decimal.new("-1")}))

      assert {:error, %Ecto.Changeset{action: :insert}} =
               standalone(user, %{total: Decimal.new("-1")})

      order = new_order(user)

      assert {:error, %Ecto.Changeset{action: :insert}} =
               Billing.create_invoice_from_order(%{order | total: nil})

      assert {:error, %Ecto.Changeset{action: :update}} =
               Billing.update_order(order, %{"total" => Decimal.new("-1")})
    end
  end

  describe "a number taken outside the counter is skipped" do
    # The row an old node, or a person, made with a number the counter has not
    # reached: the counter is put back to where it stood before.
    test "an order", %{user: user} do
      for _ <- 1..3, do: new_order(user)
      insert_order(user, number("ORD", 4))
      rewind("order", 3)

      assert new_order(user).order_number == number("ORD", 5)
      assert last_value("order") == 5
    end

    test "an invoice from an order", %{user: user} do
      order = new_order(user)
      for _ <- 1..3, do: new_invoice(order)
      {:ok, _} = Billing.create_invoice_from_order(order, invoice_number: number("INV", 4))
      rewind("invoice", 3)

      assert new_invoice(order).invoice_number == number("INV", 5)
    end

    test "a standalone invoice", %{user: user} do
      for _ <- 1..3, do: standalone(user)
      assert {:ok, _} = standalone(user, %{invoice_number: number("INV", 4)})
      rewind("invoice", 3)

      assert {:ok, next} = standalone(user)
      assert next.invoice_number == number("INV", 5)
    end

    test "a transaction", %{user: user} do
      invoice = user |> new_order() |> new_invoice() |> sent()
      for _ <- 1..3, do: pay(invoice)

      Repo.insert!(%Transaction{
        transaction_number: number("TXN", 4),
        amount: Decimal.new("1.00"),
        currency: "EUR",
        payment_method: "bank",
        invoice_uuid: invoice.uuid,
        user_uuid: invoice.user_uuid
      })

      rewind("transaction", 3)

      assert {:ok, next} = pay(invoice)
      assert next.transaction_number == number("TXN", 5)
    end

    test "inside the caller's transaction, which carries on", %{user: user} do
      for _ <- 1..3, do: new_order(user)
      insert_order(user, number("ORD", 4))
      rewind("order", 3)

      {order, count} =
        inside_transaction(fn ->
          order = new_order(user)
          {order, Repo.aggregate(Order, :count)}
        end)

      assert order.order_number == number("ORD", 5)
      assert count == 5
    end

    test "a run of them longer than the bound is stepped over in one create", %{user: user} do
      for _ <- 1..3, do: new_order(user)
      for n <- 4..33, do: insert_order(user, number("ORD", n))
      rewind("order", 3)

      assert new_order(user).order_number == number("ORD", 34)
    end

    test "that also holds when the caller rolls back on any error", %{user: user} do
      for n <- 1..30, do: insert_order(user, number("ORD", n))
      rewind("order", 0)

      assert {:ok, order} =
               Repo.transaction(fn ->
                 case Billing.create_order(user, order_attrs()) do
                   {:ok, order} -> order
                   {:error, changeset} -> Repo.rollback(changeset)
                 end
               end)

      assert order.order_number == number("ORD", 31)
    end

    test "up to a bound, then an error that keeps the progress", %{user: user} do
      # Rows too old for the look-ahead at the highest number, so only the
      # skipping is left.
      for n <- 1..21, do: insert_order(user, number("ORD", n))

      Repo.update_all(from(o in Order),
        set: [inserted_at: DateTime.new!(Date.new!(year() - 2, 6, 1), ~T[12:00:00])]
      )

      rewind("order", 0)

      {error, count} =
        inside_transaction(fn ->
          error = Billing.create_order(user, order_attrs())
          {error, Repo.aggregate(Order, :count)}
        end)

      # 20 numbers tried, all taken: an error that says so, the caller's
      # transaction usable...
      assert {:error, changeset} = error
      assert %{order_number: [message]} = errors_on(changeset)
      assert message =~ "generated numbers were already taken"
      assert count == 21
      # ...and the counter left past them, so the next create gets through.
      assert last_value("order") == 20
      assert new_order(user).order_number == number("ORD", 22)
    end

    test "but not an error of another kind", %{user: user} do
      assert new_order(user).order_number == number("ORD", 1)

      assert {:error, changeset} = Billing.create_order(Ecto.UUID.generate(), order_attrs())
      assert %{user_uuid: [_]} = errors_on(changeset)

      # The number went back with the failed insert.
      assert last_value("order") == 1
    end
  end
end
