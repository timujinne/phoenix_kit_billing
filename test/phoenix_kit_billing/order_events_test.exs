defmodule PhoenixKitBilling.OrderEventsTest do
  @moduledoc """
  The durable order-event hook.

  Not async: a real Oban runs in manual testing mode under its default name,
  because that is what `OrderEvents.enqueue/2` inserts through - without one the
  insert fails into its rescue, and "an event was enqueued" could not be observed
  at all.
  """
  use PhoenixKitBilling.DataCase, async: false
  use Oban.Testing, repo: PhoenixKitBilling.Test.Repo

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Events, Invoice, Order, OrderEvents, WebhookProcessor}

  alias PhoenixKitBilling.Workers.{
    InvoiceEventWorker,
    OrderEventWorker,
    SubscriptionDunningWorker,
    SubscriptionRenewalWorker
  }

  defmodule Handler do
    @moduledoc false
    # Reports what it was handed, including the order's status AT DELIVERY,
    # which is how the "as it is now, not a snapshot" promise is checked.
    def handle_order_event(event, order) do
      send(
        Application.fetch_env!(:phoenix_kit_billing, :order_events_test_pid),
        {:handled, event, order.uuid, order.status}
      )

      :ok
    end
  end

  defmodule FailingHandler do
    @moduledoc false
    def handle_order_event(_event, _order), do: {:error, :downstream_unavailable}
  end

  defmodule RaisingHandler do
    @moduledoc false
    def handle_order_event(_event, _order), do: raise("downstream exploded")
  end

  defmodule PaidOnlyHandler do
    @moduledoc false
    def handle_order_event(:paid, _order), do: :ok
  end

  defmodule OddHandler do
    @moduledoc false
    def handle_order_event(_event, _order), do: :whatever
  end

  setup do
    start_supervised!({Oban, repo: PhoenixKitBilling.Test.Repo, testing: :manual})
    Application.put_env(:phoenix_kit_billing, :order_event_handlers, [Handler])
    Application.put_env(:phoenix_kit_billing, :order_events_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_billing, :order_event_handlers)
      Application.delete_env(:phoenix_kit_billing, :order_events_test_pid)
    end)

    %{order: new_order(fixture_user())}
  end

  defp new_order(user) do
    {:ok, order} =
      Billing.create_order(user, %{
        "total" => Decimal.new("30.00"),
        "currency" => "EUR",
        "billing_snapshot" => %{"email" => "payer@example.com"}
      })

    order
  end

  defp confirmed(order) do
    {:ok, confirmed} = Billing.confirm_order(order)
    confirmed
  end

  defp paid(order) do
    {:ok, paid} = order |> confirmed() |> Billing.mark_order_paid()
    paid
  end

  # An order with a sent invoice for its whole total.
  defp invoiced(order) do
    {:ok, invoice} = Billing.create_invoice_from_order(order)
    {:ok, sent} = invoice |> Invoice.status_changeset("sent") |> Repo.update()
    sent
  end

  defp jobs, do: all_enqueued(worker: OrderEventWorker)

  defp assert_one_event(event, order) do
    assert [job] = jobs()

    assert %{
             "event" => ^event,
             "order_uuid" => uuid,
             "event_uuid" => event_uuid,
             "handler" => handler
           } = job.args

    assert uuid == order.uuid
    assert handler == inspect(Handler)
    assert {:ok, _} = Ecto.UUID.cast(event_uuid)
    job
  end

  describe "paid" do
    test "mark_order_paid/2 enqueues it", %{order: order} do
      {:ok, _} = order |> confirmed() |> Billing.mark_order_paid()

      assert_one_event("paid", order)
    end

    test "a payment that settles the invoice enqueues it, in the payment's transaction", %{
      order: order
    } do
      invoice = invoiced(order)

      {:ok, _} = Billing.record_payment(invoice, %{amount: "30.00"}, nil)

      assert Repo.get!(Order, order.uuid).status == "paid"
      assert_one_event("paid", order)
    end

    test "the admin Mark paid on the invoice enqueues it", %{order: order} do
      {:ok, _} = order |> invoiced() |> Billing.mark_invoice_paid()

      assert Repo.get!(Order, order.uuid).status == "paid"
      assert_one_event("paid", order)
    end

    test "a provider webhook enqueues it, once however often it is delivered", %{order: order} do
      invoice = invoiced(order)

      event = %{
        event_id: "evt_order_event_#{System.unique_integer([:positive])}",
        provider: :stripe,
        type: "checkout.completed",
        data: %{
          mode: "payment",
          invoice_uuid: invoice.uuid,
          amount_total: 3000,
          currency: "EUR",
          payment_intent_id: "pi_order_event"
        }
      }

      assert {:ok, %Invoice{status: "paid"}} = WebhookProcessor.process(event)

      # The same event again, and the same payment under another event id.
      assert {:error, :duplicate_event} = WebhookProcessor.process(event)
      assert {:ok, _} = WebhookProcessor.process(%{event | event_id: "#{event.event_id}_again"})

      assert Repo.get!(Order, order.uuid).status == "paid"
      assert_one_event("paid", order)
    end

    test "a part payment is not one: the order is not paid yet", %{order: order} do
      {:ok, _} = order |> invoiced() |> Billing.record_payment(%{amount: "10.00"}, nil)

      assert jobs() == []
    end
  end

  describe "refunded" do
    test "mark_order_refunded/1 enqueues it", %{order: order} do
      paid = paid(order)
      Repo.delete_all(Oban.Job)

      {:ok, _} = Billing.mark_order_refunded(paid)

      assert_one_event("refunded", order)
    end

    test "a full refund of the invoice enqueues it", %{order: order} do
      invoice = invoiced(order)
      {:ok, _} = Billing.record_payment(invoice, %{amount: "30.00"}, nil)
      Repo.delete_all(Oban.Job)

      {:ok, _} =
        invoice.uuid |> Billing.get_invoice!() |> Billing.record_refund(%{amount: "30.00"}, nil)

      assert Repo.get!(Order, order.uuid).status == "refunded"
      assert_one_event("refunded", order)
    end

    test "a partial refund leaves the order paid and fires no order event", %{order: order} do
      invoice = invoiced(order)
      {:ok, _} = Billing.record_payment(invoice, %{amount: "30.00"}, nil)
      Repo.delete_all(Oban.Job)

      {:ok, _} =
        invoice.uuid |> Billing.get_invoice!() |> Billing.record_refund(%{amount: "10.00"}, nil)

      assert Repo.get!(Order, order.uuid).status == "paid"
      assert jobs() == []
    end
  end

  describe "cancelled" do
    test "cancel_order/3 enqueues it", %{order: order} do
      {:ok, _} = Billing.cancel_order(order, "Changed mind")

      assert_one_event("cancelled", order)
    end
  end

  describe "reinstated" do
    defp events_enqueued, do: Enum.map(jobs(), & &1.args["event"])

    test "reinstate_order/3 enqueues it", %{order: order} do
      {:ok, cancelled} = Billing.cancel_order(order)
      Repo.delete_all(Oban.Job)

      {:ok, _} = Billing.reinstate_order(cancelled, "customer called back")

      assert_one_event("reinstated", order)
    end

    test "cancel, reinstate, cancel: :cancelled twice, :reinstated once", %{order: order} do
      {:ok, cancelled} = Billing.cancel_order(order)
      {:ok, reinstated} = Billing.reinstate_order(cancelled)
      {:ok, _} = Billing.cancel_order(reinstated)

      assert Enum.sort(events_enqueued()) == ["cancelled", "cancelled", "reinstated"]
      assert jobs() |> Enum.map(& &1.args["event_uuid"]) |> Enum.uniq() |> length() == 3
    end

    test "an invoice paid meanwhile settles the order: :paid follows", %{order: order} do
      invoice = invoiced(order)
      {:ok, cancelled} = Billing.cancel_order(order)
      {:ok, _} = Billing.mark_invoice_paid(invoice)
      Repo.delete_all(Oban.Job)

      {:ok, settled} = Billing.reinstate_order(cancelled)

      assert settled.status == "paid"
      assert Enum.sort(events_enqueued()) == ["paid", "reinstated"]
    end

    test "a refused reinstate enqueues nothing", %{order: order} do
      assert {:error, :order_not_reinstatable} = Billing.reinstate_order(order)
      assert jobs() == []
    end

    test "a rolled-back reinstate leaves no job", %{order: order} do
      {:ok, cancelled} = Billing.cancel_order(order)
      Repo.delete_all(Oban.Job)

      rolled_back(fn -> {:ok, _} = Billing.reinstate_order(cancelled) end)

      assert jobs() == []
      assert Repo.get!(Order, order.uuid).status == "cancelled"
    end
  end

  describe "one job per handler" do
    setup do
      Application.put_env(:phoenix_kit_billing, :order_event_handlers, [Handler, FailingHandler])
    end

    test "for each event, sharing one event_uuid", %{order: order} do
      paid = paid(order)

      assert [%{args: first}, %{args: second}] = jobs()
      assert first["event_uuid"] == second["event_uuid"]
      assert first["handler"] != second["handler"]

      Repo.delete_all(Oban.Job)
      {:ok, _} = Billing.mark_order_refunded(paid)
      assert length(jobs()) == 2

      Repo.delete_all(Oban.Job)
      {:ok, _} = Billing.cancel_order(new_order(fixture_user()))
      assert length(jobs()) == 2
    end

    test "two events of one order do not share an event_uuid", %{order: order} do
      paid = paid(order)
      [%{args: %{"event_uuid" => paid_uuid}} | _] = jobs()
      Repo.delete_all(Oban.Job)

      {:ok, _} = Billing.mark_order_refunded(paid)

      [%{args: %{"event_uuid" => refunded_uuid}} | _] = jobs()
      refute paid_uuid == refunded_uuid
    end
  end

  test "no handler, no job", %{order: order} do
    Application.put_env(:phoenix_kit_billing, :order_event_handlers, [])

    {:ok, _} = order |> confirmed() |> Billing.mark_order_paid()

    assert jobs() == []
  end

  describe "enqueued inside the transaction of the transition" do
    # Rollbacks cannot show this: they need a transaction of their own around the
    # call, and that would undo an enqueue placed after the transition's commit
    # too. Nor can `Repo.in_transaction?/0` at the insert: `Oban.insert!/1` opens a
    # transaction for a unique job, so it is always true there. The order of the
    # statements can: nothing may commit between the status and the job.
    setup do
      handler_id = {__MODULE__, make_ref()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:phoenix_kit_billing, :test, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          step =
            cond do
              query == "begin" -> :begin
              query == "commit" -> :commit
              query =~ ~r/^UPDATE .*phoenix_kit_orders/ -> :order_update
              query =~ ~r/^INSERT .*oban_jobs/ -> :job_insert
              true -> nil
            end

          if step && self() == test_pid, do: send(test_pid, {:step, step})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    defp steps(fun) do
      flush_steps()
      fun.()
      flush_steps()
    end

    defp flush_steps(acc \\ []) do
      receive do
        {:step, step} -> flush_steps([step | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "mark_order_paid/2", %{order: order} do
      confirmed = confirmed(order)

      assert steps(fn -> Billing.mark_order_paid(confirmed) end) ==
               [:begin, :order_update, :job_insert, :commit]
    end

    test "mark_order_refunded/1", %{order: order} do
      paid = paid(order)

      assert steps(fn -> Billing.mark_order_refunded(paid) end) ==
               [:begin, :order_update, :job_insert, :commit]
    end

    test "cancel_order/3", %{order: order} do
      assert steps(fn -> Billing.cancel_order(order) end) ==
               [:begin, :order_update, :job_insert, :commit]
    end

    test "reinstate_order/3", %{order: order} do
      {:ok, cancelled} = Billing.cancel_order(order)

      steps = steps(fn -> Billing.reinstate_order(cancelled) end)

      assert Enum.take(steps, 1) == [:begin]
      assert List.last(steps) == :commit
      assert Enum.count(steps, &(&1 == :commit)) == 1

      assert Enum.find_index(steps, &(&1 == :order_update)) <
               Enum.find_index(steps, &(&1 == :job_insert))
    end

    test "a payment through the invoice: one transaction, ending after the job", %{order: order} do
      invoice = invoiced(order)

      steps = steps(fn -> Billing.record_payment(invoice, %{amount: "30.00"}, nil) end)

      assert Enum.count(steps, &(&1 == :commit)) == 1
      assert List.last(steps) == :commit
      assert :job_insert in steps
    end
  end

  describe "commits with the transition or not at all" do
    defp rolled_back(fun) do
      assert {:error, :undone} =
               Repo.transaction(fn ->
                 fun.()
                 Repo.rollback(:undone)
               end)
    end

    test "a rolled-back payment leaves no job", %{order: order} do
      confirmed = confirmed(order)

      rolled_back(fn -> {:ok, _} = Billing.mark_order_paid(confirmed) end)

      assert jobs() == []
      assert Repo.get!(Order, order.uuid).status == "confirmed"
    end

    test "a rolled-back refund leaves no job", %{order: order} do
      paid = paid(order)
      Repo.delete_all(Oban.Job)

      rolled_back(fn -> {:ok, _} = Billing.mark_order_refunded(paid) end)

      assert jobs() == []
      assert Repo.get!(Order, order.uuid).status == "paid"
    end

    test "a rolled-back cancel leaves no job", %{order: order} do
      rolled_back(fn -> {:ok, _} = Billing.cancel_order(order) end)

      assert jobs() == []
      assert Repo.get!(Order, order.uuid).status == "draft"
    end

    test "a rolled-back invoice payment leaves no job", %{order: order} do
      invoice = invoiced(order)

      rolled_back(fn -> {:ok, _} = Billing.record_payment(invoice, %{amount: "30.00"}, nil) end)

      assert jobs() == []
      assert Repo.get!(Order, order.uuid).status == "draft"
    end
  end

  describe "a refused transition enqueues nothing" do
    test "paying an order that is not confirmed", %{order: order} do
      assert {:error, :order_not_payable} = Billing.mark_order_paid(order)
      assert jobs() == []
    end

    test "paying an order twice fires once", %{order: order} do
      paid = paid(order)

      assert {:error, :order_not_payable} = Billing.mark_order_paid(paid)
      assert_one_event("paid", order)
    end

    test "the stored status decides, not a stale struct", %{order: order} do
      stale = confirmed(order)
      {:ok, _} = Billing.cancel_order(stale)
      Repo.delete_all(Oban.Job)

      assert {:error, :order_not_payable} = Billing.mark_order_paid(stale)
      assert jobs() == []
    end

    test "refunding an unpaid order", %{order: order} do
      assert {:error, :order_not_refundable} = Billing.mark_order_refunded(order)
      assert jobs() == []
    end

    test "cancelling a paid order", %{order: order} do
      paid = paid(order)
      Repo.delete_all(Oban.Job)

      assert {:error, :order_not_cancellable} = Billing.cancel_order(paid)
      assert jobs() == []
    end

    test "an order in the trash", %{order: order} do
      {:ok, trashed} = Billing.trash_order(order)

      assert {:error, :order_trashed} = Billing.cancel_order(trashed)
      assert jobs() == []
    end
  end

  test "the trash fires nothing: it changes no status", %{order: order} do
    {:ok, trashed} = Billing.trash_order(order)
    {:ok, _} = Billing.restore_order(trashed)

    assert jobs() == []
  end

  test "the invoice's own event and the PubSub broadcast are untouched", %{order: order} do
    Application.put_env(:phoenix_kit_billing, :invoice_event_handlers, [__MODULE__.InvoiceHandler])

    on_exit(fn -> Application.delete_env(:phoenix_kit_billing, :invoice_event_handlers) end)

    Events.subscribe_orders()
    invoice = invoiced(order)

    {:ok, _} = Billing.record_payment(invoice, %{amount: "30.00"}, nil)

    assert_receive {:order_paid, %Order{status: "paid"}}
    assert [_one] = all_enqueued(worker: InvoiceEventWorker)
    assert_one_event("paid", order)
  end

  defmodule InvoiceHandler do
    @moduledoc false
    def handle_invoice_event(_event, _invoice), do: :ok
  end

  describe "handler discovery" do
    defmodule DeclaringModule do
      @moduledoc false
      def billing_order_event_handlers, do: [PhoenixKitBilling.OrderEventsTest.FailingHandler]
    end

    defmodule BrokenModule do
      @moduledoc false
      def billing_order_event_handlers, do: raise("no handlers for you")
    end

    defmodule NotAHandler do
      @moduledoc false
    end

    # Read from the runtime registry (a :persistent_term), not by scanning ebin
    # directories on disk: this runs inside the transaction holding the row lock.
    test "a module registered with PhoenixKit contributes its declared handlers" do
      PhoenixKit.ModuleRegistry.register(DeclaringModule)
      on_exit(fn -> PhoenixKit.ModuleRegistry.unregister(DeclaringModule) end)

      assert FailingHandler in OrderEvents.handlers()
      assert Handler in OrderEvents.handlers()
    end

    test "a module whose callback raises costs its own handlers, not the event" do
      PhoenixKit.ModuleRegistry.register(BrokenModule)
      on_exit(fn -> PhoenixKit.ModuleRegistry.unregister(BrokenModule) end)

      assert OrderEvents.handlers() == [Handler]
    end

    test "a module without handle_order_event/2 is not a handler" do
      Application.put_env(:phoenix_kit_billing, :order_event_handlers, [NotAHandler, Handler])

      assert OrderEvents.handlers() == [Handler]
    end
  end

  describe "delivered by the worker" do
    defp args(order, handler, event \\ "paid") do
      %{
        "event" => event,
        "order_uuid" => order.uuid,
        "event_uuid" => Ecto.UUID.generate(),
        "handler" => inspect(handler)
      }
    end

    test "the handler gets the order as it is now, not a snapshot", %{order: order} do
      paid = paid(order)
      [job] = jobs()
      {:ok, _} = Billing.mark_order_refunded(paid)

      assert :ok = perform_job(OrderEventWorker, job.args)

      uuid = order.uuid
      assert_receive {:handled, :paid, ^uuid, "refunded"}
    end

    test "every event reaches the handler under its atom", %{order: order} do
      for event <- OrderEvents.events() do
        assert :ok = perform_job(OrderEventWorker, args(order, Handler, Atom.to_string(event)))
        assert_receive {:handled, ^event, _uuid, _status}
      end
    end

    test "a handler's error is returned, so Oban retries it", %{order: order} do
      Application.put_env(:phoenix_kit_billing, :order_event_handlers, [FailingHandler])

      assert {:error, :downstream_unavailable} =
               perform_job(OrderEventWorker, args(order, FailingHandler))
    end

    test "a handler that raises is retried by Oban", %{order: order} do
      Application.put_env(:phoenix_kit_billing, :order_event_handlers, [RaisingHandler])

      assert_raise RuntimeError, "downstream exploded", fn ->
        perform_job(OrderEventWorker, args(order, RaisingHandler))
      end
    end

    test "any other return is an error, not a silent success", %{order: order} do
      Application.put_env(:phoenix_kit_billing, :order_event_handlers, [OddHandler])

      assert {:error, {:unexpected_return, :whatever}} =
               perform_job(OrderEventWorker, args(order, OddHandler))
    end

    # Job arguments are data. A name that resolves to a loaded module but not to
    # a REGISTERED handler must never be called.
    test "a job naming an unregistered module is cancelled, never invoked", %{order: order} do
      assert {:cancel, :handler_not_registered} =
               perform_job(OrderEventWorker, %{args(order, Handler) | "handler" => "File"})
    end

    test "a handler unregistered since the job was enqueued is cancelled", %{order: order} do
      {:ok, _} = Billing.cancel_order(order)
      [job] = jobs()
      Application.put_env(:phoenix_kit_billing, :order_event_handlers, [])

      assert {:cancel, :handler_not_registered} = perform_job(OrderEventWorker, job.args)
      refute_received {:handled, _, _, _}
    end

    test "an order that no longer exists is cancelled, not retried forever" do
      assert {:cancel, :order_not_found} =
               perform_job(OrderEventWorker, args(%{uuid: Ecto.UUID.generate()}, Handler))
    end

    test "a handler with no clause for an event fails the job", %{order: order} do
      Application.put_env(:phoenix_kit_billing, :order_event_handlers, [PaidOnlyHandler])

      assert_raise FunctionClauseError, fn ->
        perform_job(OrderEventWorker, args(order, PaidOnlyHandler, "refunded"))
      end
    end

    test "an event this code does not know is cancelled", %{order: order} do
      assert {:cancel, :unknown_event} =
               perform_job(OrderEventWorker, args(order, Handler, "exploded"))
    end
  end

  describe "the job" do
    test "runs on :billing, with 20 attempts" do
      changes = OrderEventWorker.new(%{}).changes

      assert changes.queue == "billing"
      assert OrderEventWorker.__opts__()[:max_attempts] == 20
    end

    test "is unique on the event and the handler", %{order: order} do
      args = args(order, Handler)

      assert %{conflict?: false} = args |> OrderEventWorker.new() |> Oban.insert!()
      assert %{conflict?: true} = args |> OrderEventWorker.new() |> Oban.insert!()

      other_handler = %{args | "handler" => inspect(FailingHandler)}
      assert %{conflict?: false} = other_handler |> OrderEventWorker.new() |> Oban.insert!()
    end
  end

  # Oban never runs a queue the node does not list, so a worker on an undeclared
  # queue waits forever and nothing fails.
  test "billing declares the queue every one of its workers runs on" do
    for worker <- [
          OrderEventWorker,
          InvoiceEventWorker,
          SubscriptionRenewalWorker,
          SubscriptionDunningWorker
        ] do
      queue = worker.new(%{}).changes.queue |> String.to_existing_atom()

      assert Keyword.has_key?(Billing.oban_queues(), queue),
             "#{inspect(worker)} runs on #{inspect(queue)}, which oban_queues/0 does not declare"
    end
  end
end

defmodule PhoenixKitBilling.OrderEventsWithoutObanTest do
  @moduledoc """
  With no Oban running, a transition must still commit: a notification that
  cannot be queued is logged, never a reason to roll money back.
  """
  use PhoenixKitBilling.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, Order, OrderEvents}

  defmodule Handler do
    @moduledoc false
    def handle_order_event(_event, _order), do: :ok
  end

  setup do
    Application.put_env(:phoenix_kit_billing, :order_event_handlers, [Handler])
    on_exit(fn -> Application.delete_env(:phoenix_kit_billing, :order_event_handlers) end)

    {:ok, order} =
      Billing.create_order(fixture_user(), %{
        "total" => Decimal.new("5.00"),
        "currency" => "EUR",
        "billing_snapshot" => %{"email" => "payer@example.com"}
      })

    %{order: order}
  end

  test "enqueue/2 says so instead of raising", %{order: order} do
    capture_log(fn -> assert OrderEvents.enqueue(:paid, order) == :not_enqueued end)
  end

  test "mark_order_paid/2 still pays, and says the event was not queued", %{order: order} do
    {:ok, confirmed} = Billing.confirm_order(order)

    log =
      capture_log(fn ->
        assert {:ok, %Order{status: "paid"}} = Billing.mark_order_paid(confirmed)
      end)

    assert log =~ "NOT enqueued"
    assert Repo.get!(Order, order.uuid).status == "paid"
  end

  test "a payment through the invoice still commits", %{order: order} do
    {:ok, invoice} = Billing.create_invoice_from_order(order)
    {:ok, sent} = invoice |> Invoice.status_changeset("sent") |> Repo.update()

    log =
      capture_log(fn ->
        assert {:ok, _} = Billing.record_payment(sent, %{amount: "5.00"}, nil)
      end)

    assert log =~ "NOT enqueued"
    assert Repo.get!(Invoice, sent.uuid).status == "paid"
    assert Repo.get!(Order, order.uuid).status == "paid"
  end

  test "cancel_order/3 still cancels", %{order: order} do
    capture_log(fn ->
      assert {:ok, %Order{status: "cancelled"}} = Billing.cancel_order(order)
    end)
  end
end
