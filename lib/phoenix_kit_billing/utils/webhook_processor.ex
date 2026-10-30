defmodule PhoenixKitBilling.WebhookProcessor do
  @moduledoc """
  Processes normalized webhook events from payment providers.

  This module handles the business logic for webhook events after they've
  been verified and normalized by the provider modules. It ensures:

  - **Idempotency**: Events are tracked by event_id to prevent double-processing
  - **Error handling**: Failed events are logged with retry counts
  - **Business logic**: Invoices are marked paid, receipts generated, etc.

  ## Event Types

  - `checkout.completed` - Checkout session completed (payment succeeded)
  - `checkout.expired` - Checkout session expired
  - `payment.succeeded` - Direct payment succeeded (for saved cards)
  - `payment.failed` - Payment failed
  - `refund.created` - Refund was processed
  - `setup.completed` - Setup session completed (card saved)

  ## Usage

      # Called by BillingWebhookController
      WebhookProcessor.process(normalized_event)
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, Notifications, PaymentMethod, Transaction, WebhookEvent}
  alias PhoenixKitBilling.Providers.MinorUnits

  require Logger

  @doc """
  Processes a normalized webhook event.

  Checks for idempotency, processes the event, and logs the result.

  ## Returns

  - `{:ok, result}` - Event processed successfully
  - `{:error, :duplicate_event}` - Event already processed
  - `{:error, reason}` - Processing failed
  """
  @spec process(map()) :: {:ok, any()} | {:error, atom() | term()}
  def process(%{event_id: _event_id, provider: _provider, type: _type} = event) do
    case upsert_webhook_event(event) do
      {:new, webhook_event} ->
        run_and_mark(webhook_event, event)

      {:retry, webhook_event} ->
        Logger.info(
          "Retrying previously-failed webhook event " <>
            "#{webhook_event.provider}/#{webhook_event.event_id} " <>
            "(prior attempts: #{webhook_event.retry_count})"
        )

        run_and_mark(webhook_event, event)

      {:already_processed, _webhook_event} ->
        {:error, :duplicate_event}

      {:max_retries, webhook_event} ->
        Logger.error(
          "Webhook event #{webhook_event.provider}/#{webhook_event.event_id} " <>
            "exceeded the retry limit (#{webhook_event.retry_count} attempts); not reprocessing."
        )

        {:error, :max_retries_exceeded}

      {:error, reason} ->
        Logger.error("Failed to log webhook event before processing: #{inspect(reason)}")
        {:error, :event_log_failed}
    end
  rescue
    e ->
      Logger.error("Webhook processing error: #{Exception.format(:error, e, __STACKTRACE__)}")
      {:error, :processing_error}
  end

  defp run_and_mark(webhook_event, event) do
    result = process_event(event)
    mark_event_processed(webhook_event, result)
    result
  end

  # ===========================================
  # Event Handlers
  # ===========================================

  defp process_event(%{type: "checkout.completed", provider: provider, data: data} = event) do
    Logger.info("Processing checkout.completed: #{inspect(data)}")

    case data do
      %{mode: "payment", invoice_uuid: invoice_uuid} when not is_nil(invoice_uuid) ->
        # One-time payment for invoice
        process_invoice_payment(invoice_uuid, Map.put(data, :provider, provider), event.event_id)

      %{mode: "setup", user_uuid: user_uuid} when not is_nil(user_uuid) ->
        # Setup session - card saved
        process_setup_completed(data)

      _ ->
        Logger.warning("Unhandled checkout.completed mode: #{inspect(data)}")
        {:ok, :ignored}
    end
  end

  defp process_event(%{type: "checkout.expired", data: data}) do
    Logger.info("Checkout session expired: #{inspect(data[:session_id])}")
    # Clear checkout session from order if needed
    {:ok, :expired}
  end

  defp process_event(%{type: "payment.succeeded", provider: provider, data: data} = event) do
    Logger.info("Processing payment.succeeded: #{inspect(data)}")

    case data do
      %{invoice_uuid: invoice_uuid} when not is_nil(invoice_uuid) ->
        # Payment for invoice (e.g., subscription renewal)
        process_invoice_payment(invoice_uuid, Map.put(data, :provider, provider), event.event_id)

      _ ->
        Logger.warning("Payment succeeded without invoice_uuid: #{inspect(data)}")
        {:ok, :ignored}
    end
  end

  defp process_event(%{type: "payment.failed", data: data}) do
    Logger.warning("Payment failed: #{inspect(data)}")

    case data do
      %{invoice_uuid: invoice_uuid} when not is_nil(invoice_uuid) ->
        # Update invoice/subscription status
        process_payment_failure(invoice_uuid, data)

      _ ->
        {:ok, :ignored}
    end
  end

  defp process_event(%{type: "refund.created", provider: provider, data: data}) do
    Logger.info("Processing refund.created: #{inspect(data)}")
    # Record refund transaction
    process_refund(Map.put(data, :provider, to_string(provider)))
  end

  defp process_event(%{type: "setup.completed", data: data}) do
    Logger.info("Processing setup.completed: #{inspect(data)}")
    # Save payment method for user
    process_setup_completed(data)
  end

  defp process_event(%{type: type}) do
    Logger.debug("Unhandled webhook event type: #{type}")
    {:ok, :unhandled}
  end

  # ===========================================
  # Business Logic
  # ===========================================

  defp process_invoice_payment(invoice_uuid, data, event_id) do
    invoice_uuid = parse_id(invoice_uuid)

    with {:ok, invoice} <- get_invoice(invoice_uuid),
         :ok <- validate_invoice_status(invoice) do
      # Determine amount from event data
      amount = calculate_payment_amount(invoice, data)

      # Record the payment
      payment_attrs = %{
        amount: amount,
        payment_method: to_string(data[:provider] || "stripe"),
        description: "Online payment via #{data[:provider] || "Stripe"}",
        provider_transaction_id: data[:charge_id] || data[:payment_intent_id],
        provider_data: data
      }

      # Pass nil for admin_user - system/webhook initiated payment
      #
      # `record_payment/3` returns the recorded `%Transaction{}`, NOT the
      # invoice - and a transaction has no `:status`, so reading one raised
      # KeyError on the success path. Until provider payments started
      # inserting at all this branch was never reached, which is why the
      # mismatch went unnoticed: the payment committed, the webhook 500'd,
      # and the provider retried a charge that had already been recorded.
      case Billing.record_payment(invoice, payment_attrs, nil) do
        {:ok, %Transaction{}} ->
          updated_invoice = Billing.get_invoice!(invoice.uuid)
          Logger.info("Payment recorded for invoice #{updated_invoice.invoice_number}")

          # Generate receipt if fully paid
          if updated_invoice.status == "paid" do
            maybe_generate_and_send_receipt(updated_invoice)
          end

          _ = Notifications.payment_received(updated_invoice, amount)

          {:ok, updated_invoice}

        # A void committed between the status check above and the lock
        # `record_payment/3` takes: the same case as a void seen up front.
        {:error, :not_payable} ->
          case Billing.get_invoice(invoice.uuid) do
            %Invoice{status: "void"} = voided ->
              payment_on_void_invoice(voided, data, amount, event_id)

            _ ->
              payment_not_recorded(invoice, invoice_uuid, :not_payable)
          end

        {:error, reason} ->
          payment_not_recorded(invoice, invoice_uuid, reason)
      end
    else
      {:error, :invoice_not_found} ->
        Logger.warning("Invoice not found for webhook: #{invoice_uuid}")
        {:error, :invoice_not_found}

      {:error, :already_paid} ->
        Logger.debug("Invoice #{invoice_uuid} already paid")
        {:ok, :already_paid}

      # The customer was charged for an invoice that was voided meanwhile.
      # Recording it would put money on a void document, and failing the event
      # would have the provider retry it to the limit with the charge visible
      # only in a log line. So: nothing is booked, the charge is kept on the
      # invoice's void trail, the event is answered as handled, and the
      # operators get the one thing only they can act on - the charge needs
      # refunding at the provider.
      {:error, {:invoice_void, invoice}} ->
        payment_on_void_invoice(invoice, data, calculate_payment_amount(invoice, data), event_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp payment_not_recorded(invoice, invoice_uuid, reason) do
    Logger.error("Failed to record payment for invoice #{invoice_uuid}: #{inspect(reason)}")
    _ = Notifications.payment_failed(invoice, reason)
    {:error, reason}
  end

  # Ids only in the log and on the trail: the provider payload can carry the
  # customer's email.
  defp payment_on_void_invoice(invoice, data, amount, event_id) do
    charge = %{
      provider: data[:provider] || "stripe",
      charge_id: data[:charge_id] || data[:payment_intent_id],
      amount: amount,
      # The webhook's own currency when it names one: it is what was charged.
      currency: data[:currency] || invoice.currency,
      event_id: event_id
    }

    Logger.error(
      "Payment received for void invoice #{invoice.invoice_number} (#{invoice.uuid}); " <>
        "not recorded - refund it at the provider: charge #{inspect(charge.charge_id)}, " <>
        "event #{inspect(event_id)}"
    )

    case Billing.record_payment_after_void(invoice, charge) do
      # The notification is at-most-once: it goes out after the trail commit and
      # is not queued with it (`InvoiceEvents` only carries paid/refunded/voided
      # to other modules' handlers, and `Notifications` has no durable queue). If
      # the process dies between the two, the retry finds the charge on the trail
      # (`:duplicate`) and does not notify. The charge is not lost: it is on the
      # trail, in the error log above and in the warning on the invoice page.
      {:ok, _invoice, :added} ->
        _ = Notifications.payment_failed(invoice, :invoice_void)
        {:ok, :invoice_void}

      # The trail had the charge already, and so the operators have been told.
      {:ok, _invoice, :duplicate} ->
        {:ok, :invoice_void}

      {:error, reason} ->
        # Not marked handled: the retry gets another go at keeping the trace.
        Logger.error(
          "Could not keep the charge on void invoice #{invoice.uuid}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Receipt generation/sending is best-effort after a successful payment:
  # the payment itself already succeeded, so a receipt failure must not fail
  # the webhook. We log non-`:ok` results rather than discarding them.
  #
  # `generate_receipt/1` stamps `receipt_number` onto the *returned* struct, so
  # we must send from that struct — `send_receipt/2` rejects an invoice whose
  # `receipt_number` is still nil with `{:error, :receipt_not_generated}`.
  defp maybe_generate_and_send_receipt(invoice) do
    case Billing.generate_receipt(invoice) do
      {:ok, invoice_with_receipt} ->
        send_receipt(invoice_with_receipt)

      other ->
        Logger.warning(
          "Receipt generation skipped for #{invoice.invoice_number}: #{inspect(other)}"
        )
    end
  end

  defp send_receipt(invoice) do
    case Billing.send_receipt(invoice, []) do
      {:ok, _updated_invoice, {:error, email_reason}} ->
        Logger.warning(
          "Receipt saved for #{invoice.invoice_number} but its email was not sent: " <>
            "#{inspect(email_reason)}"
        )

      {:ok, _updated_invoice, _email_result} ->
        :ok

      other ->
        Logger.warning("Receipt send skipped for #{invoice.invoice_number}: #{inspect(other)}")
    end
  end

  defp process_payment_failure(invoice_uuid, data) do
    invoice_uuid = parse_id(invoice_uuid)

    # Log the failure for dunning/retry logic
    Logger.warning(
      "Payment failed for invoice #{invoice_uuid}: #{data[:error_code]} - #{data[:error_message]}"
    )

    # If this invoice is tied to a subscription, update subscription status
    # This will be handled by the subscription renewal worker

    {:ok, :logged}
  end

  defp process_refund(data) do
    with {:ok, payment_ids} <- refund_payment_ids(data),
         {:ok, original_tx} <- find_payment_transaction(payment_ids, data.provider),
         {:ok, invoice} <- get_invoice(original_tx.invoice_uuid) do
      refund_attrs = %{
        payment_method: original_tx.payment_method,
        description: refund_description(data),
        provider_transaction_id: refund_id(data),
        provider_data: data
      }

      result =
        Billing.record_provider_refund(invoice, refund_attrs, fn locked ->
          with :ok <- ensure_refund_not_recorded(locked, data) do
            refund_amount(data, locked, original_tx, payment_ids)
          end
        end)

      case result do
        {:ok, transaction} ->
          Logger.info(
            "Refund recorded for invoice #{invoice.invoice_number}: " <>
              "#{Decimal.to_string(transaction.amount)} #{transaction.currency}"
          )

          {:ok, transaction}

        {:error, :exceeds_paid_amount} ->
          refund_exceeds_paid_amount(invoice, data)

        {:error, reason} when reason in [:already_recorded, :already_refunded] ->
          {:ok, reason}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :no_charge_id} ->
        Logger.warning("Refund webhook missing charge_id: #{inspect(data)}")
        {:ok, :ignored}

      # Acknowledged, not retried: on a Stripe account shared with other sites
      # most of these are their refunds, and failing the event would only
      # turn each one into failed deliveries and error logs for a payment that
      # is not ours. The `:unmatched_refund` result leaves a note on the
      # stored event (see `mark_event_processed/2`) so the miss can be found
      # later.
      {:error, :transaction_not_found} ->
        Logger.error(
          "Refund webhook matches no recorded payment, so it was NOT applied: " <>
            "charge #{inspect(data[:charge_id])}, " <>
            "payment intent #{inspect(data[:payment_intent_id])}, " <>
            "refund #{inspect(data[:refund_id])}. If the payment belongs to this " <>
            "shop, reconcile it by hand; a payment taken by another site on the " <>
            "same account lands here too."
        )

        {:ok, :unmatched_refund}

      {:error, :invoice_not_found} ->
        Logger.warning("Refund webhook's original transaction has no matching invoice")
        {:ok, :ignored}
    end
  end

  # A running total is cut down to what the ledger lacks (`unrecorded_refund/4`),
  # so a duplicate never reaches `record_refund/3`: exceeding what the invoice
  # has been paid means the ledger and Stripe disagree (a refund booked against
  # another payment, an amount edited by hand). Fail the event so a redelivery
  # can reconcile it once the ledger is corrected.
  #
  # A provider that reports one refund at a time has no running total to
  # reconcile: a refund that does not fit there is a duplicate or one already
  # applied, as it always was.
  defp refund_exceeds_paid_amount(invoice, %{amount_refunded_total: total} = data)
       when is_integer(total) do
    Logger.error(
      "Refund webhook cannot be applied to invoice #{invoice.invoice_number}: Stripe reports " <>
        "#{total} (minor units) refunded on charge #{inspect(data[:charge_id])} " <>
        "(payment intent #{inspect(data[:payment_intent_id])}), more than the " <>
        "#{Decimal.to_string(invoice.paid_amount)} #{invoice.currency} the invoice still " <>
        "holds after the refunds already in the ledger. The ledger and Stripe disagree; " <>
        "the event is failed so Stripe " <>
        "redelivers it."
    )

    {:error, :refund_exceeds_paid_amount}
  end

  defp refund_exceeds_paid_amount(invoice, _data) do
    Logger.warning(
      "Refund webhook amount exceeds paid_amount for invoice #{invoice.invoice_number}; " <>
        "ignoring as a duplicate or partial-already-applied refund."
    )

    {:ok, :already_refunded}
  end

  defp process_setup_completed(data) do
    user_uuid = data[:user_uuid]
    pm_id = data[:provider_payment_method_id]

    cond do
      is_nil(user_uuid) or is_nil(pm_id) ->
        Logger.debug("setup.completed missing user_uuid or provider_payment_method_id")
        {:ok, :ignored}

      payment_method_exists?(data[:provider] || "stripe", pm_id) ->
        {:ok, :already_saved}

      true ->
        attrs = %{
          provider: to_string(data[:provider] || "stripe"),
          provider_payment_method_id: pm_id,
          provider_customer_id: data[:customer_id],
          user_uuid: user_uuid,
          type: data[:type] || "card",
          brand: data[:brand],
          last4: data[:last4],
          exp_month: data[:exp_month],
          exp_year: data[:exp_year],
          status: "active",
          metadata: data[:metadata] || %{}
        }

        case %PaymentMethod{} |> PaymentMethod.changeset(attrs) |> repo().insert() do
          {:ok, pm} ->
            Logger.info("Payment method saved for user #{user_uuid}: #{pm.uuid}")
            {:ok, pm}

          {:error, changeset} ->
            Logger.error(
              "Failed to save payment method from setup.completed: #{inspect(changeset.errors)}"
            )

            {:error, changeset}
        end
    end
  end

  # The ids a refund event names its payment by. Stripe sends a charge and,
  # for anything paid through a PaymentIntent, that too.
  defp refund_payment_ids(data) do
    case [data[:charge_id], data[:payment_intent_id]] |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> {:error, :no_charge_id}
      ids -> {:ok, ids}
    end
  end

  # A payment is recorded under whichever id the event that created it
  # carried: a Checkout payment under its PaymentIntent (`pi_...`, with no
  # charge id anywhere), a saved-card charge under the charge, and the other
  # id may sit in `provider_data`. Only payments (positive amounts) match - a
  # refund recorded without a refund id once reused the charge id, and
  # matched itself on the next refund.
  defp find_payment_transaction(provider_ids, provider) do
    Transaction
    |> where([t], t.amount > 0 and t.payment_method == ^provider)
    |> where(
      [t],
      t.provider_transaction_id in ^provider_ids or
        fragment("?->>'payment_intent_id'", t.provider_data) in ^provider_ids or
        fragment("?->>'charge_id'", t.provider_data) in ^provider_ids
    )
    |> order_by([t], asc: t.inserted_at, asc: t.uuid)
    |> limit(1)
    |> repo().one()
    |> case do
      nil -> {:error, :transaction_not_found}
      tx -> {:ok, tx}
    end
  end

  # The provider's id for THIS refund, when the event has one. EveryPay names
  # a payment and its refund by one reference, which says nothing about which
  # refund this is.
  defp refund_id(data) do
    id = data[:refund_id]
    if id in [data[:charge_id], data[:payment_intent_id]], do: nil, else: id
  end

  # A cumulative total can include earlier refunds missing from the ledger,
  # even when its latest refund id is already recorded. Reconcile the total.
  defp ensure_refund_not_recorded(_invoice, %{amount_refunded_total: total})
       when is_integer(total),
       do: :ok

  defp ensure_refund_not_recorded(invoice, data) do
    ensure_refund_id_not_recorded(invoice, refund_id(data))
  end

  defp ensure_refund_id_not_recorded(_invoice, nil), do: :ok

  defp ensure_refund_id_not_recorded(invoice, refund_id) do
    recorded? =
      repo().exists?(
        from(t in Transaction,
          where:
            t.invoice_uuid == ^invoice.uuid and t.amount < 0 and
              t.provider_transaction_id == ^refund_id
        )
      )

    if recorded?, do: {:error, :already_recorded}, else: :ok
  end

  # §7/E5: the webhook's own reported amount is a provider minor unit,
  # never a bare "cents" - dividing by a hard-coded 100 was correct only
  # by coincidence, for exactly the currencies that happen to have two
  # decimal places. `webhook_amount/3` below reads the currency the
  # provider's own normalizer already carries alongside the amount
  # (Stripe, Razorpay's payment side, PayPal, and EveryPay all include
  # it) and converts via `MinorUnits.from_minor_units/2` instead.
  #
  # `:indeterminate` here is NOT a currency guess: it is the SAME
  # fallback this function already used whenever the webhook carried no
  # amount at all, now also reached when the webhook's currency is
  # missing or not one this shop recognizes. A provider that genuinely
  # cannot supply a
  # currency (or reports one this shop's `phoenix_kit_currencies` has
  # never heard of) keeps working through this explicit, logged,
  # already-existing path rather than through a guessed conversion
  # factor - it trusts what THIS shop already knows about the invoice
  # instead of a webhook figure it cannot safely interpret.
  defp refund_amount(%{amount_refunded_total: total} = data, invoice, original_tx, payment_ids)
       when is_integer(total) do
    case running_total(data) do
      {:ok, running_total} ->
        unrecorded_refund(running_total, invoice, original_tx, payment_ids)

      # Unlike the fallback below, a running total is never answered with "the
      # whole payment": it is a partial refund as often as not. The event
      # fails, so it is redelivered once the currency is known to the shop.
      :error ->
        Logger.error(
          "Refund webhook for charge #{inspect(data[:charge_id])} (payment intent " <>
            "#{inspect(data[:payment_intent_id])}) reports #{total} in " <>
            "#{inspect(data[:currency])}, which this shop's currency table cannot convert; " <>
            "nothing was recorded and the event is failed so Stripe redelivers it."
        )

        {:error, :refund_total_indeterminate}
    end
  end

  defp refund_amount(data, invoice, original_tx, _payment_ids) do
    per_refund_amount(data, invoice, original_tx)
  end

  defp running_total(%{amount_refunded_total: total, currency: currency})
       when is_integer(total) and is_binary(currency) do
    case MinorUnits.from_minor_units(total, currency) do
      {:ok, amount} -> {:ok, amount}
      {:error, _reason} -> :error
    end
  end

  defp running_total(_data), do: :error

  defp per_refund_amount(data, invoice, original_tx) do
    case webhook_amount(data, :amount_refunded, :amount) do
      {:ok, amount} ->
        {:ok, amount}

      :indeterminate ->
        # Default to refunding the full original transaction, capped at
        # the invoice's currently paid_amount (record_refund will reject
        # anything larger).
        original = Decimal.abs(original_tx.amount)
        cap = invoice.paid_amount || Decimal.new(0)
        {:ok, if(Decimal.compare(original, cap) == :gt, do: cap, else: original)}
    end
  end

  # Stripe reports a charge's refunds as one running total that grows with
  # every refund. What is new is that total less what the ledger already
  # holds for the payment - which also covers a redelivered event, events
  # arriving out of order, and a refund the host recorded itself after
  # creating it at Stripe.
  #
  # Called inside `record_provider_refund/3`, with the invoice row locked
  # until the ledger insert commits, including when another event reports the
  # same total under a different event id.
  defp unrecorded_refund(total, invoice, original_tx, payment_ids) do
    delta = Decimal.sub(total, recorded_refund_total(invoice, original_tx, payment_ids))

    if Decimal.positive?(delta), do: {:ok, delta}, else: {:error, :already_refunded}
  end

  defp recorded_refund_total(invoice, original_tx, payment_ids) do
    from(t in Transaction,
      where:
        t.invoice_uuid == ^invoice.uuid and t.amount < 0 and
          t.payment_method == ^original_tx.payment_method,
      select: {t.amount, t.provider_data}
    )
    |> repo().all()
    |> Enum.reject(fn {_amount, provider_data} ->
      refund_of_other_payment?(provider_data, payment_ids)
    end)
    |> Enum.reduce(Decimal.new(0), fn {amount, _provider_data}, sum ->
      Decimal.add(sum, Decimal.abs(amount))
    end)
  end

  # A refund this processor recorded names the payment it reversed. One
  # recorded by hand or by the host names none, and counts toward whichever
  # payment of the invoice asks.
  defp refund_of_other_payment?(provider_data, payment_ids) do
    named =
      [provider_data["charge_id"], provider_data["payment_intent_id"]]
      |> Enum.reject(&is_nil/1)

    named != [] and not Enum.any?(named, &(&1 in payment_ids))
  end

  defp refund_description(data) do
    data[:reason] || data[:description] || "Provider refund webhook"
  end

  defp payment_method_exists?(provider, provider_pm_id) do
    repo().exists?(
      from(pm in PaymentMethod,
        where:
          pm.provider == ^to_string(provider) and
            pm.provider_payment_method_id == ^provider_pm_id
      )
    )
  end

  # ===========================================
  # Idempotency & Event Logging
  # ===========================================

  defp upsert_webhook_event(%{event_id: event_id, provider: provider, type: type} = event) do
    attrs = %{
      provider: to_string(provider),
      event_id: event_id,
      event_type: type,
      # `event` is a %Providers.Types.WebhookEventData{} struct, which does not
      # implement Access — bracket syntax (`event[:raw_payload]`) raises. Use
      # Map.get/2 to read the struct field safely.
      payload: Map.get(event, :raw_payload) || %{},
      processed: false,
      retry_count: 0
    }

    %WebhookEvent{}
    |> WebhookEvent.changeset(attrs)
    |> repo().insert()
    |> case do
      {:ok, webhook_event} ->
        {:new, webhook_event}

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :provider) or Keyword.has_key?(errors, :event_id) do
          existing =
            repo().one(
              from(we in WebhookEvent,
                where: we.provider == ^to_string(provider) and we.event_id == ^event_id
              )
            )

          cond do
            is_nil(existing) -> {:error, :event_log_failed}
            existing.processed -> {:already_processed, existing}
            WebhookEvent.max_retries_exceeded?(existing) -> {:max_retries, existing}
            true -> {:retry, existing}
          end
        else
          {:error, {:invalid_event, errors}}
        end
    end
  end

  # Processed, but with a note: a refund that matched no payment was
  # acknowledged, not applied.
  defp mark_event_processed(%WebhookEvent{} = webhook_event, {:ok, :unmatched_refund}) do
    mark_processed(webhook_event, "refund matches no recorded payment; not applied")
  end

  defp mark_event_processed(%WebhookEvent{} = webhook_event, {:ok, _}) do
    mark_processed(webhook_event, nil)
  end

  defp mark_event_processed(%WebhookEvent{} = webhook_event, {:error, reason}) do
    webhook_event
    |> WebhookEvent.failed_changeset(inspect(reason))
    |> repo().update()
    |> case do
      {:ok, _} ->
        :ok

      {:error, fail_reason} ->
        Logger.warning("Could not mark webhook event failed: #{inspect(fail_reason)}")
        :ok
    end
  end

  defp mark_processed(%WebhookEvent{} = webhook_event, note) do
    webhook_event
    |> WebhookEvent.processed_changeset(note)
    |> repo().update()
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not mark webhook event processed: #{inspect(reason)}")
        :ok
    end
  end

  # ===========================================
  # Helpers
  # ===========================================

  defp repo, do: RepoHelper.repo()

  defp get_invoice(invoice_id) do
    case Billing.get_invoice(invoice_id) do
      nil -> {:error, :invoice_not_found}
      invoice -> {:ok, invoice}
    end
  end

  defp validate_invoice_status(%{status: "paid"}) do
    {:error, :already_paid}
  end

  defp validate_invoice_status(%Invoice{status: "void"} = invoice) do
    {:error, {:invoice_void, invoice}}
  end

  # Delegates to `Invoice.payable?/1` rather than repeating the status list.
  # The two drifted: this gate admitted "draft", which `record_payment/3` now
  # rejects as `:not_payable` - so a draft invoice passed here only to have
  # its payment dropped downstream and the webhook retried forever. One
  # authority on what may take money, not two.
  defp validate_invoice_status(%Invoice{} = invoice) do
    if Invoice.payable?(invoice),
      do: :ok,
      else: {:error, {:invalid_status, invoice.status}}
  end

  defp validate_invoice_status(%{status: status}) do
    {:error, {:invalid_status, status}}
  end

  defp calculate_payment_amount(invoice, data) do
    case webhook_amount(data, :amount_total, :amount) do
      {:ok, amount} -> amount
      # Same "explicit, documented, already-existing path" as
      # refund_amount/4 above — see its comment for why this is not a
      # guess. Use the remaining balance on the invoice instead.
      :indeterminate -> Decimal.sub(invoice.total, invoice.paid_amount || Decimal.new(0))
    end
  end

  # Reads a provider-minor-unit amount out of normalized webhook `data`
  # under `preferred_key` (falling back to `fallback_key` — providers
  # disagree on which one they populate for a given event) together with
  # the currency the SAME normalizer already attaches, and converts via
  # `MinorUnits.from_minor_units/2`. `:indeterminate` covers every case
  # this must not guess through: no usable amount field, no currency
  # alongside it, or a currency this shop's `phoenix_kit_currencies`
  # table does not recognize.
  defp webhook_amount(data, preferred_key, fallback_key) do
    with :error <- webhook_amount_for_key(data, preferred_key),
         :error <- webhook_amount_for_key(data, fallback_key) do
      :indeterminate
    end
  end

  defp webhook_amount_for_key(data, key) do
    case {Map.get(data, key), Map.get(data, :currency)} do
      {amount_cents, currency} when is_integer(amount_cents) and is_binary(currency) ->
        case MinorUnits.from_minor_units(amount_cents, currency) do
          {:ok, amount} ->
            {:ok, amount}

          {:error, :unknown_currency} ->
            Logger.warning(
              "[Billing] webhook amount currency #{currency} is not in this shop's " <>
                "currency table; using the invoice's own balance instead of the " <>
                "webhook's reported amount"
            )

            :error
        end

      {amount_cents, _no_currency} when is_integer(amount_cents) ->
        # An amount with NO currency at all is a normalizer bug, not the
        # ordinary "this event carries no amount under this key" case
        # below - every provider's own normalizer already attaches the
        # currency it read alongside the amount (§7/E5), so this should
        # not happen on a real webhook. Worth surfacing; falls back the
        # same way.
        Logger.warning(
          "[Billing] webhook amount #{amount_cents} under #{inspect(key)} arrived with no " <>
            "currency; using the invoice's own balance instead of the webhook's reported amount"
        )

        :error

      _ ->
        # No amount field at all under this key - the ordinary case for
        # most event types and most providers (a webhook rarely carries
        # BOTH :amount_total and :amount, and plenty carry neither).
        # Stays quiet.
        :error
    end
  end

  defp parse_id(id) when is_binary(id), do: id
  defp parse_id(id) when is_integer(id), do: id
  defp parse_id(_), do: nil
end
