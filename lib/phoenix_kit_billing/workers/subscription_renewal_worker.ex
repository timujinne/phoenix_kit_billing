defmodule PhoenixKitBilling.Workers.SubscriptionRenewalWorker do
  @moduledoc """
  Oban worker for processing subscription renewals.

  This worker runs daily and handles:
  - Finding subscriptions due for renewal (within 24 hours of period end)
  - Creating invoices for the renewal
  - Charging saved payment methods via providers
  - Updating subscription periods on success
  - Moving to past_due status on failure

  ## Scheduling

  The worker should be scheduled to run daily via Oban crontab:

  ```elixir
  config :my_app, Oban,
    queues: [default: 10, billing: 5],
    plugins: [
      {Oban.Plugins.Cron,
       crontab: [
         {"0 6 * * *", PhoenixKitBilling.Workers.SubscriptionRenewalWorker}
       ]}
    ]
  ```

  ## Process Flow

  1. Query subscriptions where `current_period_end` is within 24 hours
  2. For each subscription:
     a. Skip if cancel_at_period_end is true
     b. Create renewal invoice
     c. Charge saved payment method
     d. On success: extend period_end, update invoice as paid
     e. On failure: set past_due, schedule dunning

  ## Manual Trigger

  Can be triggered manually for a specific subscription:

  ```elixir
  %{subscription_uuid: "019145a1-0000-7000-8000-000000000001"}
  |> SubscriptionRenewalWorker.new()
  |> Oban.insert()
  ```
  """

  use Oban.Worker,
    queue: :billing,
    max_attempts: 3,
    unique: [period: 3600, keys: [:subscription_uuid]]

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitBilling, as: Billing

  alias PhoenixKitBilling.{
    Notifications,
    PaymentMethod,
    Providers,
    Subscription,
    SubscriptionType
  }

  alias PhoenixKitBilling.Workers.SubscriptionDunningWorker

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_uuid" => subscription_uuid}})
      when is_binary(subscription_uuid) do
    process_one(subscription_uuid)
  end

  def perform(%Oban.Job{args: %{"subscription_id" => subscription_uuid}})
      when is_binary(subscription_uuid) do
    # Backward compat for in-flight jobs
    process_one(subscription_uuid)
  end

  def perform(%Oban.Job{args: _args}) do
    # Process all due subscriptions (daily batch). Fan out into one job
    # per subscription so the per-subscription unique key + row lock
    # apply correctly and a single bad subscription cannot poison the
    # entire batch run.
    subscriptions = find_subscriptions_due_for_renewal()
    Logger.info("Found #{length(subscriptions)} subscriptions due for renewal")

    Enum.each(subscriptions, fn subscription ->
      %{subscription_uuid: subscription.uuid}
      |> __MODULE__.new()
      |> Oban.insert()
    end)

    :ok
  end

  defp process_one(subscription_uuid) do
    case get_subscription(subscription_uuid) do
      nil ->
        Logger.warning("Subscription #{subscription_uuid} not found for renewal")
        :ok

      subscription ->
        process_subscription_renewal(subscription)
    end
  end

  # ============================================
  # Renewal Processing
  # ============================================

  defp process_subscription_renewal(%Subscription{cancel_at_period_end: true} = subscription) do
    # Subscription marked for cancellation - don't renew, cancel now
    Logger.info("Subscription #{subscription.uuid} marked for cancellation, cancelling now")

    subscription
    |> Subscription.cancel_changeset(true)
    |> RepoHelper.repo().update()
  end

  defp process_subscription_renewal(%Subscription{uuid: uuid}) do
    repo = RepoHelper.repo()

    # Take a row lock on the subscription so a concurrent webhook
    # (`payment.succeeded` for the renewal invoice) or another worker
    # instance cannot double-extend the period or double-charge.
    repo.transaction(fn ->
      case lock_and_load(uuid, repo) do
        nil ->
          Logger.warning("Subscription #{uuid} not found inside renewal transaction")
          :ok

        %Subscription{cancel_at_period_end: true} = subscription ->
          subscription
          |> Subscription.cancel_changeset(true)
          |> repo.update!()

        %Subscription{} = locked ->
          period_end_at_dispatch = locked.current_period_end
          do_renew(locked, period_end_at_dispatch, repo)
      end
    end)
    |> unwrap_transaction()
  end

  defp lock_and_load(uuid, repo) do
    from(s in Subscription,
      where: s.uuid == ^uuid,
      lock: "FOR UPDATE",
      preload: [:subscription_type, :payment_method]
    )
    |> repo.one()
  end

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp do_renew(%Subscription{} = subscription, period_end_at_dispatch, repo) do
    cond do
      subscription.status == "cancelled" ->
        Logger.info("Subscription #{subscription.uuid} already cancelled — skipping renewal")
        {:ok, :cancelled}

      DateTime.compare(subscription.current_period_end, period_end_at_dispatch) != :eq ->
        # Another process (likely a webhook for the same renewal) already
        # advanced the period. Idempotent skip.
        Logger.info(
          "Subscription #{subscription.uuid} already renewed by another path — skipping"
        )

        {:ok, :already_renewed}

      true ->
        attempt_renewal(subscription, repo)
    end
  end

  defp attempt_renewal(%Subscription{} = subscription, repo) do
    with {:ok, invoice} <- create_renewal_invoice(subscription),
         {:ok, _txn} <- charge_payment_method(subscription, invoice) do
      plan = subscription.subscription_type

      new_period_end =
        SubscriptionType.next_billing_date(
          plan,
          DateTime.to_date(subscription.current_period_end)
        )

      subscription
      |> Subscription.activate_changeset(datetime_from_date(new_period_end))
      |> repo.update()
    else
      {:error, :no_payment_method} ->
        Logger.warning("Subscription #{subscription.uuid} has no payment method")
        handle_payment_failure(subscription, "No payment method configured")

      {:error, reason} ->
        handle_payment_failure(subscription, inspect(reason))
    end
  end

  defp create_renewal_invoice(%Subscription{subscription_type: nil}) do
    {:error, :no_plan}
  end

  defp create_renewal_invoice(%Subscription{} = subscription) do
    plan = subscription.subscription_type

    line_items = [
      %{
        "name" => "#{plan.name} subscription",
        "description" => "#{SubscriptionType.interval_description(plan)}",
        "quantity" => 1,
        "unit_price" => plan.price,
        "total" => plan.price
      }
    ]

    invoice_attrs = %{
      billing_profile_uuid: subscription.billing_profile_uuid,
      currency: plan.currency,
      status: "sent",
      due_date: Date.utc_today(),
      notes: "Subscription renewal: #{plan.name}",
      line_items: line_items,
      subtotal: plan.price,
      total: plan.price
    }

    case Billing.create_invoice(subscription.user_uuid, invoice_attrs) do
      {:ok, invoice} -> {:ok, invoice}
      error -> error
    end
  end

  defp charge_payment_method(%Subscription{payment_method: nil}, _invoice) do
    {:error, :no_payment_method}
  end

  # No void handling: the invoice is created in the transaction that charges, so nobody can void it first.
  defp charge_payment_method(%Subscription{payment_method: pm} = subscription, invoice) do
    if PaymentMethod.usable?(pm) do
      # Providers.charge_payment_method expects the payment_method map with :provider key
      case Providers.charge_payment_method(pm, invoice.total,
             currency: invoice.currency,
             description: "Subscription renewal",
             metadata: %{
               invoice_uuid: invoice.uuid,
               subscription_uuid: subscription.uuid
             }
           ) do
        {:ok, charge_result} ->
          # Record payment on invoice. `charge_result` is a `%ChargeResult{}`
          # struct and `provider_data` is a `:map` column - the context
          # sanitizes it, because a struct survives Ecto's cast and dump and
          # only blows up in the JSON encoder, i.e. after the card is charged.
          payment_attrs = %{
            amount: invoice.total,
            payment_method: pm.provider,
            description: "Subscription renewal payment",
            provider_transaction_id: charge_result.provider_transaction_id,
            provider_data: charge_result
          }

          case Billing.record_payment(invoice, payment_attrs, nil) do
            {:ok, txn} ->
              _ = Notifications.payment_received(invoice, invoice.total)
              {:ok, txn}

            {:error, reason} ->
              # The money LEFT the customer's account and we could not write
              # the ledger row: an operator has to reconcile this by hand.
              Logger.error(
                "Charged #{invoice.total} #{invoice.currency} for invoice " <>
                  "#{invoice.invoice_number} but failed to record it: #{inspect(reason)}"
              )

              _ = Notifications.payment_failed(invoice, reason)
              {:error, reason}
          end

        {:error, reason} ->
          _ = Notifications.payment_failed(invoice, reason)
          {:error, reason}
      end
    else
      {:error, :payment_method_not_usable}
    end
  end

  defp handle_payment_failure(%Subscription{} = subscription, error_message) do
    grace_days =
      Settings.get_setting("billing_subscription_grace_days", "3") |> String.to_integer()

    grace_period_end = DateTime.add(UtilsDate.utc_now(), grace_days, :day)

    Logger.warning(
      "Subscription #{subscription.uuid} renewal failed: #{error_message}. Grace period until #{grace_period_end}"
    )

    result =
      subscription
      |> Subscription.past_due_changeset(grace_period_end)
      |> RepoHelper.repo().update()

    # Schedule dunning job
    schedule_dunning(subscription.uuid)

    result
  end

  defp schedule_dunning(subscription_uuid) do
    # Schedule dunning worker to retry in 24 hours
    %{subscription_uuid: subscription_uuid}
    |> SubscriptionDunningWorker.new(schedule_in: 86_400)
    |> Oban.insert()
  end

  # ============================================
  # Queries
  # ============================================

  defp find_subscriptions_due_for_renewal do
    import Ecto.Query

    # Find subscriptions where:
    # - Status is active or trialing
    # - Period end is within next 24 hours
    # - Not already marked for cancellation
    cutoff = DateTime.add(UtilsDate.utc_now(), 24, :hour)

    from(s in Subscription,
      where: s.status in ["active", "trialing"],
      where: s.current_period_end <= ^cutoff,
      where: s.cancel_at_period_end == false
    )
    |> RepoHelper.repo().all()
  end

  defp get_subscription(uuid) when is_binary(uuid) do
    RepoHelper.repo().get_by(Subscription, uuid: uuid)
  end

  defp datetime_from_date(date) do
    DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  end
end
