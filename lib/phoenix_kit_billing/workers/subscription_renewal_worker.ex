defmodule PhoenixKitBilling.Workers.SubscriptionRenewalWorker do
  @moduledoc """
  Oban worker for processing subscription renewals.

  This worker runs daily and handles:
  - Finding subscriptions due for renewal (within 24 hours of period end, and a trial
    once it is over)
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

  1. Query subscriptions where `current_period_end` is within 24 hours, trials that are
     over, and those set to cancel at the period end whose period is over
  2. For each subscription:
     a. End it if it is set to cancel and its period is over
     b. Find or create the invoice of the period
     c. Charge saved payment method (see `SubscriptionCharge`)
     d. On success: extend period_end, update invoice as paid
     e. On failure: set past_due, schedule dunning, leave the invoice open for it

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
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitBilling.Subscription
  alias PhoenixKitBilling.Workers.{SubscriptionCharge, SubscriptionDunningWorker}

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
    end_cancelled_subscription(subscription)
  end

  defp process_subscription_renewal(%Subscription{} = subscription) do
    # Read before any lock, so a second worker that got here first shows as a period
    # that moved on.
    period_end = subscription.current_period_end

    due? = fn locked ->
      locked.status in ["active", "trialing"] and not locked.cancel_at_period_end and
        DateTime.compare(locked.current_period_end, period_end) == :eq
    end

    result =
      SubscriptionCharge.run(subscription,
        description: "Subscription renewal",
        due?: due?,
        declined: &handle_payment_failure/2
      )

    case result do
      # Past due, so no renewal charges it again, and no dunning for the same reason.
      {:error, {:charged_not_recorded, _reason}} ->
        SubscriptionCharge.mark_past_due(subscription)

      other ->
        other
    end
  end

  # The job may have been queued before the flag was set, with the period still
  # running: the customer has paid for it.
  defp end_cancelled_subscription(%Subscription{} = subscription) do
    if Subscription.renewal_due?(subscription) do
      Logger.info("Subscription #{subscription.uuid} marked for cancellation, cancelling now")
      SubscriptionCharge.end_subscription(subscription, "Cancelled at the end of its period")
    else
      {:ok, :period_not_over}
    end
  end

  defp handle_payment_failure(%Subscription{} = subscription, reason) do
    {:ok, past_due} = SubscriptionCharge.mark_past_due(subscription)

    Logger.warning(
      "Subscription #{subscription.uuid} renewal failed: #{failure_message(reason)}. " <>
        "Grace period until #{past_due.grace_period_end}"
    )

    schedule_dunning(subscription)

    {:ok, past_due}
  end

  defp failure_message(:no_payment_method), do: "No payment method configured"
  defp failure_message(reason), do: inspect(reason)

  defp schedule_dunning(%Subscription{} = subscription) do
    # Schedule dunning worker to retry in 24 hours
    %{
      subscription_uuid: subscription.uuid,
      period_end: DateTime.to_iso8601(subscription.current_period_end)
    }
    |> SubscriptionDunningWorker.new(schedule_in: 86_400)
    |> Oban.insert()
  end

  # ============================================
  # Queries
  # ============================================

  defp find_subscriptions_due_for_renewal do
    now = UtilsDate.utc_now()
    cutoff = DateTime.add(now, 24, :hour)

    # Find subscriptions where:
    # - Status is active, and the period ends within the next 24 hours
    # - Status is trialing, and the trial is over: it was promised up to its last day
    # - Or it is set to cancel and the period is over: nothing else ends those, and
    #   `active?/1` would say they are in service for good
    from(s in Subscription,
      where:
        (s.cancel_at_period_end == false and s.status == "active" and
           s.current_period_end <= ^cutoff) or
          (s.cancel_at_period_end == false and s.status == "trialing" and
             s.current_period_end <= ^now) or
          (s.cancel_at_period_end == true and s.status != "cancelled" and
             s.current_period_end <= ^now)
    )
    |> RepoHelper.repo().all()
  end

  defp get_subscription(uuid) when is_binary(uuid) do
    RepoHelper.repo().get_by(Subscription, uuid: uuid)
  end
end
