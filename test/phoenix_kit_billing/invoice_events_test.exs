defmodule PhoenixKitBilling.InvoiceEventsTest do
  @moduledoc """
  The durable invoice-event hook, and guest payers (billing V5).

  Not async: a real Oban runs in manual testing mode under its default name,
  because that is what `InvoiceEvents.enqueue/2` inserts through — without
  one the insert fails into its rescue, and "an event was enqueued" could
  not be observed at all.
  """
  use PhoenixKitBilling.DataCase, async: false
  use Oban.Testing, repo: PhoenixKitBilling.Test.Repo

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Events, Invoice, InvoiceEvents}
  alias PhoenixKitBilling.Workers.InvoiceEventWorker

  defmodule Handler do
    @moduledoc false
    # Reports what it was handed — including the invoice's status AT
    # DELIVERY, which is how the "as it is now, not a snapshot" promise is
    # checked.
    def handle_invoice_event(event, invoice) do
      send(
        Application.fetch_env!(:phoenix_kit_billing, :events_test_pid),
        {:handled, event, invoice.uuid, invoice.status}
      )

      :ok
    end
  end

  defmodule FailingHandler do
    @moduledoc false
    def handle_invoice_event(_event, _invoice), do: {:error, :downstream_unavailable}
  end

  setup do
    start_supervised!({Oban, repo: PhoenixKitBilling.Test.Repo, testing: :manual})
    Application.put_env(:phoenix_kit_billing, :invoice_event_handlers, [Handler])
    Application.put_env(:phoenix_kit_billing, :events_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_billing, :invoice_event_handlers)
      Application.delete_env(:phoenix_kit_billing, :events_test_pid)
    end)

    %{invoice: sent_invoice(fixture_user(), "30.00")}
  end

  defp sent_invoice(user_or_nil, total, attrs \\ %{}) do
    {:ok, invoice} =
      Billing.create_invoice(
        user_or_nil,
        Map.merge(%{total: Decimal.new(total), currency: "EUR"}, attrs)
      )

    {:ok, sent} = invoice |> Invoice.status_changeset("sent") |> Repo.update()
    sent
  end

  defp args(event, invoice),
    do: %{"event" => event, "invoice_uuid" => invoice.uuid, "handler" => inspect(Handler)}

  describe "enqueued with the change that caused it" do
    test "automatic order confirmation and payment are broadcast after the transaction", %{
      invoice: invoice
    } do
      {:ok, order} =
        Billing.create_order(invoice.user_uuid, %{
          "total" => Decimal.new("30.00"),
          "currency" => "EUR",
          "billing_snapshot" => %{"email" => "payer@example.com"}
        })

      {:ok, invoice} = invoice |> Ecto.Changeset.change(order_uuid: order.uuid) |> Repo.update()
      Events.subscribe_user_orders(order.user_uuid)
      observe_order_broadcasts_at_enqueue()

      assert {:ok, _payment} = Billing.record_payment(invoice, %{amount: "30.00"}, nil)

      assert_receive {:order_events_at_enqueue, []}
      assert_receive {:order_confirmed, %{uuid: uuid, status: "confirmed"}}
      assert uuid == order.uuid
      assert_receive {:order_paid, %{uuid: ^uuid, status: "paid", payment_method: "bank"}}
      refute_receive {:order_paid, %{uuid: ^uuid}}
    end

    test "a linked order refund is broadcast after the transaction", %{invoice: invoice} do
      {:ok, order} =
        Billing.create_order(invoice.user_uuid, %{
          "total" => Decimal.new("30.00"),
          "currency" => "EUR",
          "billing_snapshot" => %{"email" => "payer@example.com"}
        })

      {:ok, invoice} = invoice |> Ecto.Changeset.change(order_uuid: order.uuid) |> Repo.update()
      {:ok, _payment} = Billing.record_payment(invoice, %{amount: "30.00"}, nil)

      Events.subscribe_user_orders(order.user_uuid)
      observe_order_broadcasts_at_enqueue()

      assert {:ok, _refund} =
               Billing.record_refund(Billing.get_invoice!(invoice.uuid), %{amount: "30.00"}, nil)

      assert_receive {:order_events_at_enqueue, []}
      assert_receive {:order_refunded, %{uuid: uuid, status: "refunded"}}
      assert uuid == order.uuid
      refute_receive {:order_refunded, %{uuid: ^uuid}}
    end

    test "the admin Mark paid enqueues :paid for every handler", %{invoice: invoice} do
      {:ok, _} = Billing.mark_invoice_paid(invoice)
      assert_enqueued(worker: InvoiceEventWorker, args: args("paid", invoice))
    end

    # The bug this hook exists for: a provider webhook pays through
    # record_payment/3, which never announced the invoice as paid at all.
    test "a payment that settles the invoice enqueues :paid AND broadcasts it, after commit",
         %{invoice: invoice} do
      Events.subscribe_invoices()

      {:ok, _txn} =
        Billing.record_payment(invoice, %{amount: "30.00", payment_method: "everypay"}, nil)

      assert_enqueued(worker: InvoiceEventWorker, args: args("paid", invoice))
      assert_receive {:invoice_paid, %Invoice{uuid: uuid, status: "paid"}}
      assert uuid == invoice.uuid
    end

    test "a part payment is not a :paid event", %{invoice: invoice} do
      {:ok, _} =
        Billing.record_payment(invoice, %{amount: "10.00", payment_method: "everypay"}, nil)

      refute_enqueued(worker: InvoiceEventWorker)
    end

    test "a void enqueues :voided", %{invoice: invoice} do
      {:ok, _} = Billing.void_invoice(invoice, "Booking cancelled")
      assert_enqueued(worker: InvoiceEventWorker, args: args("voided", invoice))
    end

    test "a refund enqueues :refunded", %{invoice: invoice} do
      {:ok, _} =
        Billing.record_payment(invoice, %{amount: "30.00", payment_method: "everypay"}, nil)

      paid = Billing.get_invoice(invoice.uuid)

      {:ok, _} = Billing.record_refund(paid, %{amount: "30.00", description: "Hall flooded"}, nil)
      assert_enqueued(worker: InvoiceEventWorker, args: args("refunded", invoice))
    end

    test "each handler gets its own job, so one failing cannot hold another up", %{
      invoice: invoice
    } do
      Application.put_env(:phoenix_kit_billing, :invoice_event_handlers, [Handler, FailingHandler])

      {:ok, _} = Billing.mark_invoice_paid(invoice)

      assert length(all_enqueued(worker: InvoiceEventWorker)) == 2
    end
  end

  # Oban inserts the durable event before the billing transaction returns.
  # Inspect the subscriber's mailbox synchronously at that insert, so a test
  # cannot pass just because a pre-commit event was read after the call returned.
  defp observe_order_broadcasts_at_enqueue do
    handler_id = {__MODULE__, make_ref()}
    subscriber = self()

    :telemetry.attach(
      handler_id,
      [:phoenix_kit_billing, :test, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == subscriber and String.starts_with?(metadata.query, "INSERT") and
             String.contains?(metadata.query, "oban_jobs") do
          send(subscriber, {:order_events_at_enqueue, drain_order_events()})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp drain_order_events(events \\ []) do
    receive do
      {event, _order} = message when event in [:order_confirmed, :order_paid, :order_refunded] ->
        drain_order_events([message | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  describe "handler discovery" do
    defmodule DeclaringModule do
      @moduledoc false
      def billing_invoice_event_handlers,
        do: [PhoenixKitBilling.InvoiceEventsTest.FailingHandler]
    end

    # Read from the runtime registry (a :persistent_term), not by scanning
    # ebin directories on disk — this runs inside the payment transaction.
    test "a module registered with PhoenixKit contributes its declared handlers" do
      PhoenixKit.ModuleRegistry.register(DeclaringModule)
      on_exit(fn -> PhoenixKit.ModuleRegistry.unregister(DeclaringModule) end)

      assert FailingHandler in InvoiceEvents.handlers()
      assert Handler in InvoiceEvents.handlers()
    end
  end

  describe "delivered by the worker" do
    test "the handler gets the invoice as it is now, not a snapshot", %{invoice: invoice} do
      {:ok, _} = Billing.mark_invoice_paid(invoice)
      [job] = all_enqueued(worker: InvoiceEventWorker)

      assert :ok = perform_job(InvoiceEventWorker, job.args)
      assert_receive {:handled, :paid, uuid, "paid"}
      assert uuid == invoice.uuid
    end

    test "a handler's error is returned, so Oban retries it", %{invoice: invoice} do
      Application.put_env(:phoenix_kit_billing, :invoice_event_handlers, [FailingHandler])

      assert {:error, :downstream_unavailable} =
               perform_job(InvoiceEventWorker, %{
                 "event" => "paid",
                 "invoice_uuid" => invoice.uuid,
                 "event_uuid" => Ecto.UUID.generate(),
                 "handler" => inspect(FailingHandler)
               })
    end

    # Job arguments are data. A name that resolves to a loaded module but not
    # to a REGISTERED handler must never be called.
    test "a job naming an unregistered module is cancelled, never invoked", %{invoice: invoice} do
      assert {:cancel, :handler_not_registered} =
               perform_job(InvoiceEventWorker, %{
                 "event" => "paid",
                 "invoice_uuid" => invoice.uuid,
                 "event_uuid" => Ecto.UUID.generate(),
                 "handler" => "File"
               })
    end

    test "an invoice that no longer exists is cancelled, not retried forever" do
      assert {:cancel, :invoice_not_found} =
               perform_job(InvoiceEventWorker, %{
                 "event" => "paid",
                 "invoice_uuid" => Ecto.UUID.generate(),
                 "event_uuid" => Ecto.UUID.generate(),
                 "handler" => inspect(Handler)
               })
    end
  end

  describe "guest payers (billing V5)" do
    test "an invoice can be made out to an email, with no account" do
      {:ok, guest} =
        Billing.create_invoice(nil, %{
          total: Decimal.new("15.00"),
          currency: "EUR",
          billing_details: %{"email" => "guest@example.com", "name" => "Walk-in"}
        })

      assert guest.user_uuid == nil
    end

    test "the database itself refuses an invoice with neither a user nor an email" do
      assert_raise Postgrex.Error, ~r/phoenix_kit_invoices_payer_check/, fn ->
        Repo.query!("""
        INSERT INTO phoenix_kit_invoices (uuid, invoice_number, status, total, currency, billing_details, inserted_at, updated_at)
        VALUES (gen_random_uuid(), 'INV-GUEST-NONE', 'draft', 10, 'EUR', '{}'::jsonb, now(), now())
        """)
      end
    end

    # The failure V5 exists for: a provider-confirmed payment on a guest
    # invoice has no admin actor and no invoice user. The transaction insert
    # used to fail — card charged, invoice left unpaid.
    test "a guest's payment settles their invoice" do
      guest = sent_invoice(nil, "15.00", %{billing_details: %{"email" => "guest@example.com"}})

      assert {:ok, txn} =
               Billing.record_payment(guest, %{amount: "15.00", payment_method: "everypay"}, nil)

      assert txn.user_uuid == nil
      assert Billing.get_invoice(guest.uuid).status == "paid"
    end

    test "a guest invoice is sent to its billing email" do
      {:ok, draft} =
        Billing.create_invoice(nil, %{
          total: Decimal.new("15.00"),
          currency: "EUR",
          billing_details: %{"email" => "guest@example.com"}
        })

      assert {:ok, sent, _email} = Billing.send_invoice(draft)
      assert [%{"email" => "guest@example.com"} | _] = sent.metadata["send_history"]
    end
  end
end

defmodule PhoenixKitBilling.InvoiceEventsWithoutObanTest do
  @moduledoc """
  With no Oban running, a payment must still commit: a notification that
  cannot be queued is logged, never a reason to roll money back.
  """
  use PhoenixKitBilling.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Invoice

  defmodule Handler do
    @moduledoc false
    def handle_invoice_event(_event, _invoice), do: :ok
  end

  setup do
    Application.put_env(:phoenix_kit_billing, :invoice_event_handlers, [Handler])
    on_exit(fn -> Application.delete_env(:phoenix_kit_billing, :invoice_event_handlers) end)
    :ok
  end

  test "mark_invoice_paid still pays, and says the event was not queued" do
    {:ok, invoice} =
      Billing.create_invoice(fixture_user(), %{total: Decimal.new("5.00"), currency: "EUR"})

    {:ok, sent} = invoice |> Invoice.status_changeset("sent") |> Repo.update()

    log =
      capture_log(fn ->
        assert {:ok, %Invoice{status: "paid"}} = Billing.mark_invoice_paid(sent)
      end)

    assert log =~ "NOT enqueued"
  end
end
