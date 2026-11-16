defmodule PhoenixKitBilling.SubscriptionBillingTest do
  @moduledoc """
  The renewal and dunning workers over a stubbed Stripe: what reaches the card, the
  ledger and the subscription.

  A renewal leaves an open invoice when the card is declined, and dunning used to
  charge the plan price past it: the money came in with no invoice and no ledger
  row, and the invoice stayed open. The invoice of the period is what both workers
  charge now, committed before the provider call, so a retry finds it.
  """

  use PhoenixKitBilling.DataCase, async: false
  use Oban.Testing, repo: PhoenixKitBilling.Test.Repo

  import ExUnit.CaptureLog

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing

  alias PhoenixKitBilling.{
    Invoice,
    PaymentMethod,
    Providers,
    Subscription,
    Transaction,
    WebhookProcessor
  }

  alias PhoenixKitBilling.Workers.{
    SubscriptionCharge,
    SubscriptionDunningWorker,
    SubscriptionRenewalWorker
  }

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual})
    Settings.update_setting("billing_stripe_enabled", "true")
    Settings.update_setting("billing_stripe_secret_key", "sk_test_123")
    Application.put_env(:phoenix_kit_billing, :stripe_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_billing, :stripe_req_options)
      Settings.update_setting("billing_stripe_enabled", "false")
      Settings.update_setting("billing_stripe_secret_key", "")
    end)

    :ok
  end

  # `during` runs where the provider would be answering, so a test can change the
  # world between the charge and what follows it.
  defp approve(during \\ fn -> :ok end) do
    stub(fn conn ->
      during.()
      id = System.unique_integer([:positive])

      Req.Test.json(conn, %{
        "id" => "pi_#{id}",
        "status" => "succeeded",
        "latest_charge" => "ch_#{id}"
      })
    end)
  end

  defp decline do
    stub(fn conn ->
      conn
      |> Plug.Conn.put_status(402)
      |> Req.Test.json(%{"error" => %{"code" => "card_declined", "message" => "Declined"}})
    end)
  end

  defp stub(answer) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:charge, URI.decode_query(body), idempotency_key(conn)})
      answer.(conn)
    end)
  end

  defp idempotency_key(conn) do
    conn |> Plug.Conn.get_req_header("idempotency-key") |> List.first()
  end

  defp subscription!(attrs \\ %{}) do
    user = fixture_user()

    {:ok, type} =
      Billing.create_subscription_type(%{
        name: "Plan",
        slug: "plan-#{System.unique_integer([:positive])}",
        price: Decimal.new("5.00"),
        currency: "EUR"
      })

    {:ok, method} =
      %PaymentMethod{}
      |> PaymentMethod.changeset(%{
        provider: "stripe",
        provider_payment_method_id: "pm_#{System.unique_integer([:positive])}",
        provider_customer_id: "cus_1",
        user_uuid: user.uuid,
        status: "active"
      })
      |> Repo.insert()

    {:ok, subscription} =
      Billing.create_subscription(user.uuid, %{
        subscription_type_uuid: type.uuid,
        payment_method_uuid: method.uuid,
        trial_days: 30
      })

    subscription
    |> Ecto.Changeset.change(
      Map.merge(
        %{status: "active", trial_end: nil, current_period_end: in_seconds(3600)},
        attrs
      )
    )
    |> Repo.update!()
  end

  defp in_seconds(seconds) do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)
  end

  defp past_due_subscription! do
    subscription = subscription!()
    decline()
    {:ok, _} = renew(subscription)
    flush_charges()
    Repo.delete_all(Oban.Job)
    reload(subscription)
  end

  defp renew(subscription) do
    SubscriptionRenewalWorker.perform(%Oban.Job{
      args: %{"subscription_uuid" => subscription.uuid}
    })
  end

  defp dun(subscription) do
    SubscriptionDunningWorker.perform(%Oban.Job{
      args: %{"subscription_uuid" => subscription.uuid}
    })
  end

  defp reload(subscription), do: Repo.get!(Subscription, subscription.uuid)

  defp invoices(subscription) do
    Repo.all(from(i in Invoice, where: i.user_uuid == ^subscription.user_uuid))
  end

  defp ledger(invoice) do
    Repo.all(from(t in Transaction, where: t.invoice_uuid == ^invoice.uuid))
  end

  defp flush_charges(acc \\ []) do
    receive do
      {:charge, body, key} -> flush_charges([{body, key} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp dunning_jobs, do: all_enqueued(worker: SubscriptionDunningWorker)

  describe "a renewal" do
    test "puts the charge on the ledger and starts the next period" do
      subscription = subscription!()
      approve()

      assert {:ok, _} = renew(subscription)

      assert [%Invoice{status: "paid"} = invoice] = invoices(subscription)
      assert invoice.subscription_uuid == subscription.uuid
      assert [%Transaction{provider_transaction_id: "ch_" <> _} = row] = ledger(invoice)
      assert Decimal.equal?(row.amount, "5.00")

      renewed = reload(subscription)
      assert renewed.status == "active"
      assert renewed.current_period_start == subscription.current_period_end
      assert DateTime.compare(renewed.current_period_end, subscription.current_period_end) == :gt
    end

    test "names its invoice to the provider, so the webhook can find it" do
      subscription = subscription!()
      approve()

      assert {:ok, _} = renew(subscription)

      assert [%Invoice{uuid: uuid}] = invoices(subscription)
      assert [{%{"metadata[invoice_uuid]" => ^uuid}, _key}] = flush_charges()
    end

    test "declined, leaves the invoice open for dunning" do
      subscription = subscription!()
      decline()

      assert {:ok, _} = renew(subscription)

      assert [%Invoice{status: "sent"} = invoice] = invoices(subscription)
      assert invoice.subscription_uuid == subscription.uuid
      assert ledger(invoice) == []

      assert %Subscription{status: "past_due", renewal_attempts: 1} = reload(subscription)
      assert [_job] = dunning_jobs()
    end

    test "after a crash past the charge, retries on the same invoice with the same key" do
      subscription = subscription!()
      approve(fn -> raise "the node went down" end)

      assert_raise RuntimeError, fn -> renew(subscription) end

      # The transaction around the charge is gone, the invoice is not.
      assert [%Invoice{status: "sent"} = invoice] = invoices(subscription)

      approve()
      assert {:ok, _} = renew(subscription)

      assert [%Invoice{status: "paid", uuid: uuid}] = invoices(subscription)
      assert uuid == invoice.uuid

      assert [{_first, key}, {_second, key}] = flush_charges()
      assert is_binary(key)
    end

    test "after a crash past the charge, is paid by the charge's webhook, not a second charge" do
      subscription = subscription!()
      approve(fn -> raise "the node went down" end)
      assert_raise RuntimeError, fn -> renew(subscription) end

      # What Stripe was told is what its event comes back with.
      assert [{charged, _key}] = flush_charges()

      payload = %{
        "id" => "evt_#{System.unique_integer([:positive])}",
        "type" => "payment_intent.succeeded",
        "data" => %{
          "object" => %{
            "id" => "pi_crashed",
            "latest_charge" => "ch_crashed",
            "amount" => 500,
            "currency" => "eur",
            "metadata" => %{"invoice_uuid" => charged["metadata[invoice_uuid]"]}
          }
        }
      }

      {:ok, event} = Providers.handle_webhook_event(:stripe, payload)
      assert {:ok, _} = WebhookProcessor.process(event)

      approve()
      assert {:ok, _} = renew(subscription)

      assert flush_charges() == []
      assert [%Invoice{status: "paid"} = invoice] = invoices(subscription)
      assert [%Transaction{provider_transaction_id: "ch_crashed"}] = ledger(invoice)
      assert DateTime.compare(reload(subscription).current_period_end, in_seconds(3600)) == :gt
    end

    test "that the ledger refuses after the charge goes past due, with no dunning" do
      subscription = subscription!()

      approve(fn ->
        Repo.update_all(from(i in Invoice, where: i.user_uuid == ^subscription.user_uuid),
          set: [status: "void"]
        )
      end)

      log =
        capture_log(fn ->
          result = renew(subscription)
          refute match?({:error, _}, result)
        end)

      assert log =~ "failed to record it"

      # Past due, so no renewal picks it up, and nothing scheduled to charge it again.
      assert %Subscription{status: "past_due"} = reload(subscription)
      assert dunning_jobs() == []
      assert [%Invoice{status: "sent"}] = invoices(subscription)
    end

    test "does not charge a subscription paused since the job was queued" do
      subscription = subscription!(%{status: "paused"})
      approve()

      assert {:ok, _} = renew(subscription)

      assert flush_charges() == []
      assert invoices(subscription) == []
      assert reload(subscription).status == "paused"
    end

    test "commits the invoice before the provider call, so no counter waits on it" do
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
              query =~ ~r/^INSERT .*phoenix_kit_invoices/ -> :invoice_insert
              true -> nil
            end

          if step && self() == test_pid, do: send(test_pid, {:step, step})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      subscription = subscription!()
      approve(fn -> send(test_pid, {:step, :charge}) end)
      assert {:ok, _} = renew(subscription)

      steps = flush_steps()
      before_charge = Enum.take_while(steps, &(&1 != :charge))

      assert :commit in Enum.drop_while(before_charge, &(&1 != :invoice_insert))
    end

    defp flush_steps(acc \\ []) do
      receive do
        {:step, step} -> flush_steps([step | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end
  end

  describe "a subscription set to cancel at the period end" do
    defp fan_out, do: SubscriptionRenewalWorker.perform(%Oban.Job{args: %{}})

    defp queued?(subscription) do
      all_enqueued(worker: SubscriptionRenewalWorker)
      |> Enum.any?(&(&1.args["subscription_uuid"] == subscription.uuid))
    end

    test "is ended by the daily run once the period is over, and not charged" do
      subscription =
        subscription!(%{cancel_at_period_end: true, current_period_end: in_seconds(-3600)})

      approve()

      assert :ok = fan_out()
      assert queued?(subscription)

      assert {:ok, _} = renew(subscription)

      assert %Subscription{status: "cancelled"} = reload(subscription)
      assert flush_charges() == []
    end

    test "is left alone by the daily run while the period lasts" do
      subscription = subscription!(%{cancel_at_period_end: true})

      assert :ok = fan_out()

      refute queued?(subscription)
    end

    test "is not ended early by a job queued before the flag was set" do
      subscription = subscription!(%{cancel_at_period_end: true})
      approve()

      assert {:ok, _} = renew(subscription)

      assert %Subscription{status: "active"} = reload(subscription)
      assert flush_charges() == []
    end

    test "that is paused still ends with its period" do
      subscription =
        subscription!(%{
          status: "paused",
          cancel_at_period_end: true,
          current_period_end: in_seconds(-3600)
        })

      assert :ok = fan_out()
      assert queued?(subscription)

      assert {:ok, _} = renew(subscription)

      assert %Subscription{status: "cancelled"} = reload(subscription)
    end
  end

  describe "a dunning retry" do
    test "pays the invoice the renewal left open" do
      subscription = past_due_subscription!()
      [open] = invoices(subscription)
      approve()

      assert {:ok, _} = dun(subscription)

      assert [%Invoice{status: "paid", uuid: uuid} = paid] = invoices(subscription)
      assert uuid == open.uuid
      assert [%Transaction{provider_transaction_id: "ch_" <> _}] = ledger(paid)

      assert %Subscription{status: "active", renewal_attempts: 0} = reload(subscription)
    end

    test "makes the invoice when the period has none" do
      subscription = subscription!(%{status: "past_due", renewal_attempts: 1})
      approve()

      assert {:ok, _} = dun(subscription)

      assert [%Invoice{status: "paid"} = invoice] = invoices(subscription)
      assert invoice.subscription_uuid == subscription.uuid
      assert [_row] = ledger(invoice)
    end

    test "does not charge an invoice paid by other means, and moves the subscription on" do
      subscription = past_due_subscription!()
      [open] = invoices(subscription)
      assert {:ok, _} = Billing.mark_invoice_paid(open)
      approve()

      assert {:ok, _} = dun(subscription)

      assert flush_charges() == []
      assert [%Invoice{status: "paid"}] = invoices(subscription)
      assert %Subscription{status: "active"} = reload(subscription)
    end

    test "after a void of the invoice makes another, as the subscription is still owed" do
      subscription = past_due_subscription!()
      [voided] = invoices(subscription)
      assert {:ok, _} = Billing.void_invoice(voided)
      approve()

      assert {:ok, _} = dun(subscription)

      assert [%Invoice{status: "paid"} = paid] =
               Enum.reject(invoices(subscription), &(&1.uuid == voided.uuid))

      assert [_row] = ledger(paid)
    end

    test "declined, waits for its next day instead of having Oban retry it" do
      subscription = past_due_subscription!()
      decline()

      result = dun(subscription)

      refute match?({:error, _}, result)
      assert %Subscription{status: "past_due", renewal_attempts: 2} = reload(subscription)
      assert [%Oban.Job{state: "scheduled"}] = dunning_jobs()
    end

    test "uses a new key after a decline, or the provider would replay the decline" do
      subscription = past_due_subscription!()
      decline()
      dun(subscription)
      Repo.delete_all(Oban.Job)
      dun(reload(subscription))

      assert [{_first, one}, {_second, other}] = flush_charges()
      assert one != other
    end

    test "that is the last one still ends in a cancelled subscription and a void invoice" do
      subscription = past_due_subscription!()
      decline()

      # Default of three attempts: the renewal and two retries.
      dun(reload(subscription))
      Repo.delete_all(Oban.Job)
      dun(reload(subscription))

      assert %Subscription{status: "past_due", renewal_attempts: 3} = reload(subscription)
      assert [_final_run] = dunning_jobs()
      Repo.delete_all(Oban.Job)

      assert {:ok, _} = dun(reload(subscription))

      assert %Subscription{status: "cancelled"} = reload(subscription)
      assert [%Invoice{status: "void"}] = invoices(subscription)
      assert dunning_jobs() == []
    end

    test "at the last attempt, a period paid by bank transfer moves on instead of ending" do
      subscription = past_due_subscription!()
      [invoice] = invoices(subscription)
      assert {:ok, _} = Billing.mark_invoice_paid(invoice)
      Repo.delete_all(Oban.Job)

      subscription
      |> reload()
      |> Ecto.Changeset.change(renewal_attempts: 3)
      |> Repo.update!()

      assert {:ok, %Subscription{status: "active"}} = dun(subscription)
      assert flush_charges() == []
      assert [%Invoice{status: "paid"}] = invoices(subscription)
    end

    test "paying an invoice of another period queues no retry off the schedule" do
      subscription = past_due_subscription!()
      [invoice] = invoices(subscription)

      # not the current period's any more: the run it queued would find the period
      # unpaid and charge the card a second time that day
      Repo.update_all(from(i in Invoice, where: i.uuid == ^invoice.uuid),
        set: [metadata: %{"period_end" => "2020-01-01T00:00:00Z"}]
      )

      assert {:ok, _} = Billing.mark_invoice_paid(Repo.get!(Invoice, invoice.uuid))
      assert dunning_jobs() == []
    end

    test "a queued paid-period retry does not charge a later unpaid period" do
      subscription = past_due_subscription!()
      [invoice] = invoices(subscription)
      assert {:ok, _} = Billing.mark_invoice_paid(invoice)
      assert [paid_period_job] = dunning_jobs()

      # Another retry moves the paid period on before this job runs. The next
      # renewal fails too, so the subscription is past due again, for a new period.
      assert {:ok, %Subscription{status: "active"}} = dun(subscription)
      decline()
      assert {:ok, %Subscription{status: "past_due"} = later} = renew(reload(subscription))
      flush_charges()
      approve()

      assert :ok = SubscriptionDunningWorker.perform(paid_period_job)
      assert flush_charges() == []
      assert reload(subscription).current_period_end == later.current_period_end
      assert reload(subscription).renewal_attempts == later.renewal_attempts
      assert Enum.count(invoices(subscription), &(&1.status == "paid")) == 1

      assert Enum.any?(dunning_jobs(), fn job ->
               job.state == "scheduled" and
                 job.args["period_end"] == DateTime.to_iso8601(later.current_period_end)
             end)
    end

    test "does not charge a period that changed after the initial dunning read" do
      subscription = past_due_subscription!()
      [invoice] = invoices(subscription)
      assert {:ok, _} = Billing.mark_invoice_paid(invoice)
      later_period_end = DateTime.add(subscription.current_period_end, 30, :day)

      after_dunning_read(fn ->
        Repo.update_all(from(s in Subscription, where: s.uuid == ^subscription.uuid),
          set: [current_period_end: later_period_end]
        )
      end)

      approve()
      assert {:ok, :skipped} = dun(subscription)
      assert flush_charges() == []
      assert reload(subscription).current_period_end == later_period_end
      assert [%Invoice{status: "paid"}] = invoices(subscription)
    end

    test "a paid period that cannot move on is retried without counting an attempt" do
      subscription = past_due_subscription!()
      [invoice] = invoices(subscription)
      assert {:ok, _} = Billing.mark_invoice_paid(invoice)
      Repo.delete_all(Oban.Job)

      # what `SubscriptionCharge` declines under the locks after the paid check; a
      # refund landing in between takes the same callback
      Repo.update_all(from(s in Subscription, where: s.uuid == ^subscription.uuid),
        set: [subscription_type_uuid: nil]
      )

      before = reload(subscription)
      assert {:ok, {:declined, :no_plan}} = dun(before)
      assert %Subscription{status: "past_due", renewal_attempts: attempts} = reload(subscription)
      assert attempts == before.renewal_attempts
      assert [%Oban.Job{state: "scheduled"}] = dunning_jobs()
    end

    # `dun/1` calls the worker directly, so the row Oban would be running is not in
    # the table. The payment queues that row and Oban marks it executing before
    # `perform/1`; uniqueness that counts `:executing` then drops the next day.
    test "a paid period that cannot move on still queues the next day while that retry is running" do
      subscription = past_due_subscription!()
      [invoice] = invoices(subscription)
      assert {:ok, _} = Billing.mark_invoice_paid(invoice)
      assert [%Oban.Job{state: "available"} = running] = dunning_jobs()

      {1, _} =
        Repo.update_all(from(j in Oban.Job, where: j.id == ^running.id),
          set: [state: "executing"]
        )

      Repo.update_all(from(s in Subscription, where: s.uuid == ^subscription.uuid),
        set: [subscription_type_uuid: nil]
      )

      before = reload(subscription)
      assert {:ok, {:declined, :no_plan}} = dun(before)
      assert reload(subscription).renewal_attempts == before.renewal_attempts

      # `all_enqueued/1` hides an executing job, which is the row this has to keep.
      states =
        Oban.Job
        |> where([j], j.worker == ^inspect(SubscriptionDunningWorker))
        |> Repo.all()
        |> Enum.map(& &1.state)
        |> Enum.sort()

      assert states == ["executing", "scheduled"]
    end

    test "a decline does not queue a second retry while one is already scheduled" do
      subscription = past_due_subscription!()
      decline()

      assert {:ok, _} = dun(subscription)
      assert [_scheduled] = dunning_jobs()

      assert {:ok, _} = dun(reload(subscription))
      assert [%Oban.Job{state: "scheduled"}] = dunning_jobs()
    end

    test "giving up leaves an invoice with money on it for an operator" do
      subscription = past_due_subscription!()
      [invoice] = invoices(subscription)

      assert {:ok, _} =
               Billing.record_payment(invoice, %{amount: "2.00", payment_method: "bank"}, nil)

      subscription
      |> reload()
      |> Ecto.Changeset.change(renewal_attempts: 3)
      |> Repo.update!()

      log = capture_log(fn -> assert {:ok, _} = dun(subscription) end)

      assert log =~ "left open"
      assert %Subscription{status: "cancelled"} = reload(subscription)
      assert [%Invoice{status: "sent"}] = invoices(subscription)
    end

    test "after a charge that could not be recorded, does not charge again" do
      subscription = past_due_subscription!()

      approve(fn ->
        Repo.update_all(from(i in Invoice, where: i.user_uuid == ^subscription.user_uuid),
          set: [status: "void"]
        )
      end)

      log =
        capture_log(fn ->
          result = dun(subscription)
          refute match?({:error, _}, result)
        end)

      assert log =~ "failed to record it"
      assert %Subscription{status: "past_due"} = reload(subscription)
      assert dunning_jobs() == []
    end

    # Attach the card after dunning reads the subscription, before the charge
    # reloads it under its lock. The initial struct still has no payment method.
    defp attach_card_after_dunning_read(subscription) do
      Repo.update_all(from(s in Subscription, where: s.uuid == ^subscription.uuid),
        set: [payment_method_uuid: nil]
      )

      after_dunning_read(fn ->
        Repo.update_all(from(s in Subscription, where: s.uuid == ^subscription.uuid),
          set: [payment_method_uuid: subscription.payment_method_uuid]
        )

        send(self(), :card_attached)
      end)
    end

    defp after_dunning_read(fun) do
      handler_id = {__MODULE__, make_ref()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:phoenix_kit_billing, :test, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if self() == test_pid and query =~ ~s(FROM "phoenix_kit_subscriptions") do
            :telemetry.detach(handler_id)
            fun.()
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "counts a card decline when the card was attached after the initial read" do
      subscription = past_due_subscription!()
      attach_card_after_dunning_read(subscription)
      decline()

      assert {:ok, {:declined, _reason}} = dun(subscription)
      assert_received :card_attached
      assert [_charge] = flush_charges()
      assert reload(subscription).renewal_attempts == subscription.renewal_attempts + 1
      assert [%Oban.Job{state: "scheduled"}] = dunning_jobs()
    end

    test "does not retry an unrecorded charge on a card attached after the initial read" do
      subscription = past_due_subscription!()
      attach_card_after_dunning_read(subscription)

      approve(fn ->
        Repo.update_all(from(i in Invoice, where: i.user_uuid == ^subscription.user_uuid),
          set: [status: "void"]
        )
      end)

      capture_log(fn ->
        assert {:ok, {:charged_not_recorded, _reason}} = dun(subscription)
      end)

      assert_received :card_attached
      assert [_charge] = flush_charges()
      assert reload(subscription).status == "past_due"
      assert dunning_jobs() == []
    end

    test "without a usable card does not fail the job, and comes back" do
      subscription = past_due_subscription!()

      Repo.update_all(from(p in PaymentMethod, where: p.user_uuid == ^subscription.user_uuid),
        set: [status: "removed"]
      )

      result = dun(subscription)

      refute match?({:error, _}, result)
      assert flush_charges() == []
      assert [_next] = dunning_jobs()
    end
  end

  describe "a subscription paid by invoice, without a card" do
    # bank transfer: the renewal makes the period's invoice, nothing can be charged,
    # and the subscriber pays the invoice, which an operator marks paid
    defp invoiced_subscription! do
      subscription = renewed_without_card!()
      Repo.delete_all(Oban.Job)
      subscription
    end

    # with the retry the renewal scheduled for tomorrow still queued
    defp renewed_without_card! do
      subscription = subscription!()

      Repo.update_all(from(s in Subscription, where: s.uuid == ^subscription.uuid),
        set: [payment_method_uuid: nil]
      )

      {:ok, _} = renew(subscription)
      reload(subscription)
    end

    defp job_states, do: dunning_jobs() |> Enum.map(& &1.state) |> Enum.sort()

    test "is past due with the period's invoice open after the renewal" do
      subscription = invoiced_subscription!()
      assert %Subscription{status: "past_due"} = subscription
      assert [%Invoice{status: status}] = invoices(subscription)
      assert status in ["draft", "sent"]
    end

    test "marking the invoice paid queues a retry, which starts the next period without a charge" do
      subscription = invoiced_subscription!()
      [open] = invoices(subscription)
      assert {:ok, _} = Billing.mark_invoice_paid(open)
      assert [_job] = dunning_jobs()

      assert {:ok, %Subscription{status: "active"}} = dun(subscription)
      assert flush_charges() == []
      renewed = reload(subscription)
      assert renewed.status == "active"
      assert DateTime.compare(renewed.current_period_end, subscription.current_period_end) == :gt
    end

    test "marking the invoice paid queues a retry now, beside the one scheduled for tomorrow" do
      subscription = renewed_without_card!()
      assert job_states() == ["scheduled"]
      [open] = invoices(subscription)
      assert {:ok, _} = Billing.mark_invoice_paid(open)
      assert job_states() == ["available", "scheduled"]
    end

    test "a second mark-paid is refused and queues nothing more" do
      subscription = renewed_without_card!()
      [open] = invoices(subscription)
      assert {:ok, _} = Billing.mark_invoice_paid(open)
      assert {:error, :invoice_not_payable} = Billing.mark_invoice_paid(open)
      assert job_states() == ["available", "scheduled"]
    end

    test "a payment recorded for the whole amount queues a retry" do
      subscription = invoiced_subscription!()
      [open] = invoices(subscription)

      assert {:ok, _} =
               Billing.record_payment(
                 open,
                 %{amount: Decimal.to_string(open.total), payment_method: "bank"},
                 nil
               )

      assert [%Oban.Job{state: "available"}] = dunning_jobs()
      assert {:ok, %Subscription{status: "active"}} = dun(subscription)
      assert flush_charges() == []
    end

    test "a part payment queues nothing" do
      subscription = invoiced_subscription!()
      [open] = invoices(subscription)

      assert {:ok, _} =
               Billing.record_payment(open, %{amount: "1.00", payment_method: "bank"}, nil)

      assert dunning_jobs() == []
    end

    test "marking it paid inside a transaction queues nothing" do
      subscription = invoiced_subscription!()
      [open] = invoices(subscription)
      assert {:ok, {:ok, _}} = Repo.transaction(fn -> Billing.mark_invoice_paid(open) end)
      assert dunning_jobs() == []
    end

    test "after a void of the invoice, a retry issues another and counts no attempt" do
      subscription = invoiced_subscription!()
      [voided] = invoices(subscription)
      assert {:ok, _} = Billing.void_invoice(voided)

      assert {:ok, :no_payment_method} = dun(subscription)

      assert [%Invoice{status: "sent"}] =
               Enum.reject(invoices(subscription), &(&1.uuid == voided.uuid))

      assert reload(subscription).renewal_attempts == subscription.renewal_attempts
      assert flush_charges() == []
    end

    test "unpaid, a retry waits for the next day and counts no attempt" do
      subscription = invoiced_subscription!()
      assert {:ok, :no_payment_method} = dun(subscription)
      assert %Subscription{status: "past_due", renewal_attempts: attempts} = reload(subscription)
      assert attempts == subscription.renewal_attempts
      assert [_next] = dunning_jobs()
      assert flush_charges() == []
    end

    test "a card renewal that pays its invoice queues no extra retry" do
      subscription = subscription!()
      approve()
      assert {:ok, %Subscription{status: "active"}} = renew(subscription)
      assert dunning_jobs() == []
    end
  end

  describe "SubscriptionCharge.run/2 between its two transactions" do
    # Asked once per transaction. Whatever happens in between, as a second worker
    # would, is what the second answer has to catch before the card is touched.
    defp due_then(subscription, then) do
      calls = :counters.new(1, [])

      fn _locked ->
        :counters.add(calls, 1, 1)
        if :counters.get(calls, 1) == 1, do: true, else: then.(subscription)
      end
    end

    defp run(subscription, due?) do
      SubscriptionCharge.run(reload(subscription),
        description: "Test",
        due?: due?,
        declined: fn _locked, reason -> {:declined, reason} end
      )
    end

    test "asks again under the lock, and charges nothing when it is no longer due" do
      subscription = subscription!()
      approve()

      assert {:ok, :skipped} = run(subscription, due_then(subscription, fn _ -> false end))

      assert flush_charges() == []
      assert [%Invoice{status: "sent"}] = invoices(subscription)
    end

    test "does not charge an invoice voided since it was found" do
      subscription = subscription!()
      approve()

      due? =
        due_then(subscription, fn subscription ->
          Repo.update_all(from(i in Invoice, where: i.user_uuid == ^subscription.user_uuid),
            set: [status: "void"]
          )

          true
        end)

      assert {:declined, :invoice_not_payable} = run(subscription, due?)
      assert flush_charges() == []
    end
  end

  describe "pause_subscription/1" do
    test "pauses an active and a trialing subscription" do
      assert {:ok, %Subscription{status: "paused"}} =
               Billing.pause_subscription(subscription!())

      assert {:ok, %Subscription{status: "paused"}} =
               Billing.pause_subscription(subscription!(%{status: "trialing"}))
    end

    test "refuses anything else, so dunning is not switched off by a pause" do
      for status <- ~w(past_due cancelled paused) do
        subscription = subscription!(%{status: status})

        assert {:error, :subscription_not_pausable} = Billing.pause_subscription(subscription)
        assert reload(subscription).status == status
      end
    end

    test "decides on the stored row, not the caller's struct" do
      subscription = subscription!()
      stale = subscription

      Repo.update_all(from(s in Subscription, where: s.uuid == ^subscription.uuid),
        set: [status: "cancelled"]
      )

      assert {:error, :subscription_not_pausable} = Billing.pause_subscription(stale)
      assert reload(subscription).status == "cancelled"
    end
  end

  describe "resume_subscription/1" do
    test "resumes a paused subscription" do
      assert {:ok, %Subscription{status: "active"}} =
               Billing.resume_subscription(subscription!(%{status: "paused"}))
    end

    test "takes back a pending cancellation, which is what the detail page's button offers" do
      subscription = subscription!(%{cancel_at_period_end: true})

      assert {:ok, %Subscription{status: "active", cancel_at_period_end: false}} =
               Billing.resume_subscription(subscription)
    end

    test "taking back a cancellation leaves a trial a trial" do
      subscription = subscription!(%{status: "trialing", cancel_at_period_end: true})

      assert {:ok, %Subscription{status: "trialing", cancel_at_period_end: false}} =
               Billing.resume_subscription(subscription)
    end

    test "does not bring back a cancelled subscription without a payment" do
      subscription = subscription!(%{status: "cancelled"})

      assert {:error, :subscription_not_resumable} = Billing.resume_subscription(subscription)
      assert reload(subscription).status == "cancelled"
    end

    test "refuses an active or past due subscription with nothing to resume" do
      for status <- ~w(active past_due) do
        subscription = subscription!(%{status: status})

        assert {:error, :subscription_not_resumable} = Billing.resume_subscription(subscription)
      end
    end

    test "decides on the stored row, not the caller's struct" do
      subscription = subscription!(%{status: "paused"})

      Repo.update_all(from(s in Subscription, where: s.uuid == ^subscription.uuid),
        set: [status: "cancelled"]
      )

      assert {:error, :subscription_not_resumable} = Billing.resume_subscription(subscription)
      assert reload(subscription).status == "cancelled"
    end
  end
end
