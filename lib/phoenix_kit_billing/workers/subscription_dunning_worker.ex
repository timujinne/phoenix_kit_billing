defmodule PhoenixKitBilling.Workers.SubscriptionDunningWorker do
  @moduledoc """
  Oban worker for dunning (failed payment recovery).

  When a subscription payment fails, the subscription enters `past_due` status
  and this worker handles retry attempts during the grace period.

  ## Dunning Process

  1. Initial payment fails → subscription status = `past_due`
  2. Grace period starts (configurable, default 3 days)
  3. This worker retries payment at intervals, on the invoice of the period
     (see `SubscriptionCharge`), so the money reaches the ledger
  4. If payment succeeds → status = `active`
  5. If max attempts reached or grace period ends → status = `cancelled`, and the
     invoice is voided: nothing is owed for a period that was not given — unless the
     period's invoice was paid some other way (*Mark paid*): that is looked at first,
     and moves the period on while it stays paid. Refunded meanwhile, the run retries
     without counting an attempt

  A declined retry is a handled outcome, not a failed job. Returned as an error, Oban
  would retry it within seconds: each try counts, so one decline would use up every
  attempt and cancel the subscription in about a minute.

  ## Retry Schedule

  Default retry schedule (can be configured):
  - Attempt 1: Immediate (handled by RenewalWorker)
  - Attempt 2: 24 hours later
  - Attempt 3: 48 hours later (2 days)
  - Attempt 4: 72 hours later (3 days, grace period ends)

  ## Configuration

  ```elixir
  # Settings (stored in database)
  billing_subscription_grace_days: 3
  billing_dunning_max_attempts: 3
  ```

  ## Manual Trigger

  ```elixir
  %{subscription_uuid: "019145a1-0000-7000-8000-000000000001"}
  |> SubscriptionDunningWorker.new()
  |> Oban.insert()
  ```
  """

  use Oban.Worker,
    queue: :billing,
    max_attempts: 5,
    unique: [period: 3600, keys: [:subscription_uuid, :period_end]]

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitBilling.{PaymentMethod, Subscription}
  alias PhoenixKitBilling.Workers.SubscriptionCharge

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    subscription_uuid = Map.get(args, "subscription_uuid") || Map.get(args, "subscription_id")

    case get_subscription_with_preloads(subscription_uuid) do
      nil ->
        Logger.warning("Subscription #{subscription_uuid} not found for dunning")
        :ok

      subscription ->
        # Automatic retries belong to one period. Another retry may have settled
        # it already, and this job must not charge a later period.
        if is_nil(args["period_end"]) or
             args["period_end"] == DateTime.to_iso8601(subscription.current_period_end) do
          process_dunning(subscription)
        else
          :ok
        end
    end
  end

  # ============================================
  # Dunning Processing
  # ============================================

  defp process_dunning(%Subscription{status: "cancelled"}) do
    # Already cancelled, nothing to do
    :ok
  end

  defp process_dunning(%Subscription{status: status}) when status not in ["past_due"] do
    # Not in past_due status, skip
    :ok
  end

  defp process_dunning(%Subscription{} = subscription) do
    max_attempts = get_max_attempts()

    cond do
      # Paid some other way (bank transfer marked paid): the period moves on, whatever
      # the attempts or the grace period say. Nothing is charged for a paid invoice.
      SubscriptionCharge.period_paid?(subscription) ->
        settle_paid_period(subscription)

      # Cancel BEFORE attempting if this attempt would push us past the
      # configured cap. `renewal_attempts` is the number of completed
      # failed attempts so far; the next try would be attempt N+1.
      subscription.renewal_attempts + 1 > max_attempts ->
        Logger.info("Subscription #{subscription.uuid} exceeded max dunning attempts, cancelling")
        cancel_subscription(subscription, "Max payment retry attempts exceeded")

      Subscription.grace_period_expired?(subscription) ->
        Logger.info("Subscription #{subscription.uuid} grace period expired, cancelling")
        cancel_subscription(subscription, "Grace period expired")

      true ->
        attempt_payment_retry(subscription)
    end
  end

  # No card to charge, but the period may be paid already: an invoice paid by bank
  # transfer and marked paid. `SubscriptionCharge.run/2` finds that invoice paid and
  # moves the subscription on without a charge. Unpaid, it asks for a charge, gets
  # `:no_payment_method`, and this waits for the next day as before: no attempt is
  # counted, so a subscriber paying by invoice has the whole grace period.
  # A card added since the initial read is charged under the lock; its outcome must
  # use the normal decline accounting and charged-not-recorded handling.
  defp attempt_payment_retry(%Subscription{payment_method: nil} = subscription) do
    retry_charge(subscription, fn
      locked, :no_payment_method ->
        Logger.warning("Subscription #{locked.uuid} has no payment method for retry")
        # Still schedule next retry in case user adds payment method
        schedule_next_retry(locked)
        {:ok, :no_payment_method}

      locked, reason ->
        handle_decline(locked, reason)
    end)
  end

  defp attempt_payment_retry(%Subscription{} = subscription) do
    pm = subscription.payment_method

    if PaymentMethod.usable?(pm) do
      Logger.info(
        "Attempting payment retry ##{subscription.renewal_attempts + 1} for subscription #{subscription.uuid}"
      )

      retry_charge(subscription)
    else
      Logger.warning(
        "Payment method not usable for subscription #{subscription.uuid}: #{inspect(pm.status)}"
      )

      schedule_next_retry(subscription)
      {:ok, :payment_method_not_usable}
    end
  end

  # Paid when looked at, so under the locks `SubscriptionCharge` finds it paid and moves
  # the period on without a charge. Refunded in between, it is a retry like any other,
  # except that a decline is not counted: the attempts cap is for a card that keeps
  # being refused, and this subscriber had paid.
  defp settle_paid_period(%Subscription{} = subscription) do
    retry_charge(subscription, fn locked, reason ->
      Logger.warning("Subscription #{locked.uuid} period is no longer paid: #{inspect(reason)}")

      schedule_next_retry(locked)
      {:ok, {:declined, reason}}
    end)
  end

  defp retry_charge(%Subscription{} = subscription, declined \\ &handle_decline/2) do
    result =
      SubscriptionCharge.run(subscription,
        description: "Subscription renewal (dunning retry)",
        due?: fn locked ->
          Subscription.past_due?(locked) and
            DateTime.compare(locked.current_period_end, subscription.current_period_end) == :eq
        end,
        declined: declined
      )

    case result do
      {:ok, %Subscription{status: "active"}} = paid ->
        Logger.info("Dunning payment successful for subscription #{subscription.uuid}")
        paid

      # The money was taken: nothing more is scheduled, and the job is not failed, or
      # either would charge it again.
      {:error, {:charged_not_recorded, _reason} = outcome} ->
        {:ok, outcome}

      other ->
        other
    end
  end

  defp handle_decline(%Subscription{} = subscription, reason) do
    Logger.warning(
      "Dunning payment failed for subscription #{subscription.uuid}: #{inspect(reason)}"
    )

    update_retry_count(subscription)
    schedule_next_retry(subscription)
    {:ok, {:declined, reason}}
  end

  defp update_retry_count(%Subscription{} = subscription) do
    subscription
    |> Ecto.Changeset.change(%{
      renewal_attempts: subscription.renewal_attempts + 1,
      last_renewal_attempt_at: UtilsDate.utc_now()
    })
    |> RepoHelper.repo().update()
  end

  defp cancel_subscription(%Subscription{} = subscription, reason) do
    Logger.info("Cancelling subscription #{subscription.uuid}: #{reason}")
    SubscriptionCharge.end_subscription(subscription, reason)
  end

  # Unconditional: `process_dunning/1` decides at the next run whether that is another
  # try or the end. Stopping here on the last attempt left the subscription past due
  # for good, and `active?/1` counts that as in service.
  #
  # States are the worker's default (`:successful`) without `:executing`. The retry
  # queued when the period's invoice is paid is inserted and runs at once, and this
  # schedules the next day while that job is still executing. Counting `:executing`
  # drops the insert: the running job conflicts with itself, and when it was the only
  # one queued the subscription stays past due. A job that is waiting, held or already
  # finished still keeps the slot, so a second retry is not queued beside it.
  defp schedule_next_retry(%Subscription{} = subscription) do
    states = Oban.Job.unique_states(:successful) -- [:executing]

    %{
      subscription_uuid: subscription.uuid,
      period_end: DateTime.to_iso8601(subscription.current_period_end)
    }
    |> __MODULE__.new(schedule_in: 86_400, unique: [states: states])
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Subscription #{subscription.uuid} has no dunning retry queued: #{inspect(reason)}"
        )
    end
  end

  # ============================================
  # Queries & Helpers
  # ============================================

  defp get_subscription_with_preloads(uuid) when is_binary(uuid) do
    import Ecto.Query

    from(s in Subscription,
      where: s.uuid == ^uuid,
      preload: [:subscription_type, :payment_method]
    )
    |> RepoHelper.repo().one()
  end

  defp get_max_attempts do
    Settings.get_setting("billing_dunning_max_attempts", "3")
    |> String.to_integer()
  end
end
