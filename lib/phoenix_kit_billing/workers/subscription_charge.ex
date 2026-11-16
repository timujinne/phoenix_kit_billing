defmodule PhoenixKitBilling.Workers.SubscriptionCharge do
  @moduledoc """
  Charging a subscription for its period: what signup and the renewal and dunning
  workers share.

  A subscription pays in advance, at the price it stored, so a charge pays for the
  period that starts with it. A period has one invoice, found by the subscription and
  the moment the charge falls due (stored under `metadata["period_end"]`), and that
  invoice is what gets charged. So a retry finds the invoice a decline left open, and
  a period paid some other way (*Mark paid*, or the webhook of a charge whose worker
  crashed) is not charged again.

  It takes two transactions:

    1. Under the subscription's row lock, find or create the invoice, and commit. The
       invoice counter is released here, so no other invoice waits on a provider.
    2. Under the subscription's and the invoice's row locks, charge, record and move
       the subscription to its next period.

  What the locks hold off: a second worker, which finds the period moved on, and a
  void or a payment of the invoice, which wait for the charge to be recorded.

  A subscription with nothing to pay (a free plan) moves to its next period with no
  invoice and no call to a provider, which would refuse the amount.

  ## The price and the tax

  The invoice bills `subscription.price`, in `subscription.currency`: what the plan
  cost when the subscriber took it, not what it costs now.
  `PhoenixKitBilling.change_subscription_type/3` and
  `PhoenixKitBilling.apply_plan_price/1` are what change them.

  That price has the tax inside it, so the card is charged the same with tax on or
  off. The invoice shows the net and the tax at `PhoenixKitBilling.tax_rate_for/1`.

  ## A crash past the charge

  The second transaction rolls back and the invoice survives, so the retry charges
  that invoice again. Two things keep that from reaching the card twice:

    * the provider is told the invoice (`:invoice_uuid`), so the webhook of the first
      charge pays it, and the retry finds it paid. PayPal's events do not carry it;
    * the charge carries an `:idempotency_key` made from the invoice and the attempt:
      a retry of the same attempt repeats the key, and a decline, which commits a new
      attempt, moves it on, or the provider would replay the decline.

  Only Stripe honours the key: PayPal charges in two calls that one key cannot cover,
  and Razorpay and EveryPay have none. So with those, a retry that gets there before
  the webhook can still charge twice, as it always could.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitBilling, as: Billing

  alias PhoenixKitBilling.{
    BillingProfile,
    Invoice,
    Notifications,
    PaymentMethod,
    Providers,
    Subscription,
    SubscriptionType
  }

  require Logger

  @typedoc """
  `:description` is sent to the provider and put on the ledger row. `:due?` is asked
  on the locked subscription, before each transaction: `false` leaves everything
  alone. `:declined` runs under the lock when the invoice could not be made or the
  card was refused, and its return value is returned.
  """
  @type opts :: [
          description: String.t(),
          due?: (Subscription.t() -> boolean()),
          declined: (Subscription.t(), term() -> term())
        ]

  @doc """
  Charges the subscription for its current period.

  Returns `{:ok, subscription}` for a paid period, `{:ok, :skipped}` when it is not
  due, what `:declined` returns, or `{:error, {:charged_not_recorded, reason}}` when
  the money was taken and the ledger refused it. **That last one must not be retried:**
  an operator has to reconcile it, and has been told to.
  """
  @spec run(Subscription.t(), opts()) :: term()
  def run(%Subscription{} = subscription, opts) do
    due? = Keyword.fetch!(opts, :due?)
    declined = Keyword.fetch!(opts, :declined)

    result =
      under_lock(subscription, fn locked ->
        if due?.(locked), do: period_invoice(locked), else: :skipped
      end)

    case result do
      {:ok, %Invoice{} = invoice} -> settle(subscription, invoice, opts)
      {:ok, %Subscription{}} = nothing_to_pay -> nothing_to_pay
      {:error, reason} -> under_lock(subscription, &declined.(&1, reason))
      :skipped -> {:ok, :skipped}
    end
  end

  @doc """
  Whether the subscription's current period has a paid invoice: `run/2` would move it
  to the next period without a charge.
  """
  @spec period_paid?(Subscription.t()) :: boolean()
  def period_paid?(%Subscription{} = subscription) do
    match?(%Invoice{status: "paid"}, find_period_invoice(subscription))
  end

  @doc """
  Takes the first payment of a subscription just created, which has a period of no
  length until it is paid.

  Declined, the subscription ends here and its invoice is voided, and the reason is
  returned: it never started. A crash leaves it `active` with that empty period, so
  the daily renewal run takes it from there, on the same invoice.

  Returns `{:ok, subscription}` or `{:error, reason}`. Like `run/2`, that can be
  `{:error, {:charged_not_recorded, reason}}`: the subscription is left past due, with
  no retry, for an operator.
  """
  @spec first_charge(Subscription.t()) :: {:ok, Subscription.t()} | {:error, term()}
  def first_charge(%Subscription{current_period_end: period_end} = subscription) do
    result =
      run(subscription,
        description: "Subscription first payment",
        due?: &first_charge_due?(&1, period_end),
        declined: fn _locked, reason -> {:declined, reason} end
      )

    case result do
      {:ok, %Subscription{}} = paid ->
        paid

      # The daily run got to it first, and what it did stands.
      {:ok, :skipped} ->
        {:ok, RepoHelper.repo().get!(Subscription, subscription.uuid)}

      {:declined, reason} ->
        {:ok, _ended} = end_subscription(subscription, "First payment declined")
        {:error, reason}

      {:error, {:charged_not_recorded, _reason}} = error ->
        {:ok, _past_due} = mark_past_due(subscription)
        error
    end
  end

  defp first_charge_due?(%Subscription{} = locked, period_end) do
    locked.status == "active" and DateTime.compare(locked.current_period_end, period_end) == :eq
  end

  @doc """
  Ends the subscription now and voids what it still has open: nothing is owed for a
  period that was not given. An invoice with money on it is left for an operator
  (`:invoice_has_payments`).
  """
  @spec end_subscription(Subscription.t(), String.t()) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def end_subscription(%Subscription{} = subscription, reason) do
    with {:ok, cancelled} <- Billing.cancel_subscription(subscription, immediately: true) do
      void_open_invoices(cancelled, reason)
      {:ok, cancelled}
    end
  end

  @doc """
  Moves the subscription to `past_due`, with the grace period starting now, which also
  keeps the daily renewal run from charging it.
  """
  @spec mark_past_due(Subscription.t()) :: {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def mark_past_due(%Subscription{} = subscription) do
    grace_days =
      Settings.get_setting("billing_subscription_grace_days", "3") |> String.to_integer()

    subscription
    |> Subscription.past_due_changeset(DateTime.add(UtilsDate.utc_now(), grace_days, :day))
    |> RepoHelper.repo().update()
  end

  defp void_open_invoices(%Subscription{uuid: uuid}, reason) do
    from(i in Invoice,
      where:
        i.subscription_uuid == ^uuid and i.status in ["sent", "overdue"] and
          is_nil(i.trashed_at)
    )
    |> RepoHelper.repo().all()
    |> Enum.each(fn invoice ->
      with {:error, refusal} <- Billing.void_invoice(invoice, reason) do
        Logger.warning(
          "Invoice #{invoice.invoice_number} left open on ended subscription #{uuid}: " <>
            inspect(refusal)
        )
      end
    end)
  end

  defp under_lock(%Subscription{} = subscription, fun) do
    repo = RepoHelper.repo()

    {:ok, result} =
      repo.transaction(fn ->
        case lock_subscription(subscription, repo) do
          nil -> :skipped
          locked -> fun.(locked)
        end
      end)

    result
  end

  defp lock_subscription(%Subscription{uuid: uuid}, repo) do
    from(s in Subscription,
      where: s.uuid == ^uuid,
      lock: "FOR UPDATE",
      preload: [:subscription_type, :payment_method, :billing_profile]
    )
    |> repo.one()
  end

  defp period_invoice(%Subscription{} = subscription) do
    case find_period_invoice(subscription) do
      nil -> bill_period(subscription)
      invoice -> {:ok, invoice}
    end
  end

  # A void or trashed invoice is no longer the period's: dunning goes on, and makes
  # another.
  defp find_period_invoice(%Subscription{uuid: uuid} = subscription) do
    period_end = period_key(subscription)

    from(i in Invoice,
      where: i.subscription_uuid == ^uuid and i.status != "void" and is_nil(i.trashed_at),
      where: fragment("?->>'period_end' = ?", i.metadata, ^period_end),
      order_by: [desc: i.inserted_at, desc: i.uuid],
      limit: 1
    )
    |> RepoHelper.repo().one()
  end

  defp period_key(%Subscription{current_period_end: period_end}) do
    DateTime.to_iso8601(period_end)
  end

  defp bill_period(%Subscription{subscription_type: nil}), do: {:error, :no_plan}

  defp bill_period(%Subscription{price: price} = subscription) do
    if Decimal.positive?(price),
      do: create_period_invoice(subscription),
      else: next_period(subscription, RepoHelper.repo())
  end

  defp create_period_invoice(%Subscription{billing_profile: profile} = subscription) do
    tax_rate = Billing.tax_rate_for(profile)
    {net, tax} = Invoice.split_included_tax(subscription.price, tax_rate)

    line_items = [
      %{
        "name" => "#{subscription.plan_name} subscription",
        "description" =>
          "#{SubscriptionType.interval_description(subscription.subscription_type)}",
        "quantity" => 1,
        "unit_price" => net,
        "total" => net
      }
    ]

    Billing.create_invoice(subscription.user_uuid, %{
      subscription_uuid: subscription.uuid,
      billing_details: billing_details(profile),
      currency: subscription.currency,
      status: "sent",
      due_date: Date.utc_today(),
      notes: "Subscription: #{subscription.plan_name}",
      line_items: line_items,
      subtotal: net,
      tax_rate: tax_rate,
      tax_amount: tax,
      total: subscription.price,
      metadata: %{"period_end" => period_key(subscription)}
    })
  end

  defp billing_details(nil), do: %{}
  defp billing_details(%BillingProfile{} = profile), do: BillingProfile.to_snapshot(profile)

  defp settle(%Subscription{} = subscription, %Invoice{} = invoice, opts) do
    repo = RepoHelper.repo()

    result =
      repo.transaction(fn ->
        with %Subscription{} = locked <- lock_subscription(subscription, repo),
             true <- opts[:due?].(locked),
             %Invoice{} = locked_invoice <- lock_invoice(invoice, repo) do
          pay(locked, locked_invoice, opts, repo)
        else
          _gone_or_no_longer_due -> :skipped
        end
      end)

    # After the commit: a notification reports a committed fact, and in a transaction
    # the ledger aborted its write would be lost.
    case result do
      {:ok, {:paid, renewed, amount}} ->
        _ = Notifications.payment_received(invoice, amount)
        {:ok, renewed}

      {:ok, :skipped} ->
        {:ok, :skipped}

      {:ok, other} ->
        other

      {:error, {:charged_not_recorded, reason}} = error ->
        _ = Notifications.payment_failed(invoice, reason)
        error
    end
  end

  defp lock_invoice(%Invoice{uuid: uuid}, repo) do
    from(i in Invoice, where: i.uuid == ^uuid, lock: "FOR UPDATE")
    |> repo.one()
  end

  # Before any charge: moving to the next period needs the plan, and that comes after.
  defp pay(%Subscription{subscription_type: nil} = locked, _invoice, opts, _repo) do
    opts[:declined].(locked, :no_plan)
  end

  # Paid since the invoice was found, or before: the money is in, nothing is charged.
  defp pay(%Subscription{} = locked, %Invoice{status: "paid"}, _opts, repo) do
    next_period(locked, repo)
  end

  defp pay(%Subscription{} = locked, %Invoice{} = invoice, opts, repo) do
    amount = Invoice.remaining_amount(invoice)

    case charge(locked, invoice, amount, opts[:description]) do
      {:ok, charge_result} ->
        record(locked, invoice, amount, charge_result, opts[:description], repo)

      {:error, reason} ->
        opts[:declined].(locked, reason)
    end
  end

  defp charge(%Subscription{payment_method: nil}, _invoice, _amount, _description) do
    {:error, :no_payment_method}
  end

  defp charge(%Subscription{payment_method: method} = subscription, invoice, amount, description) do
    with :ok <- ensure_chargeable(method, invoice) do
      method
      |> Providers.charge_payment_method(amount,
        currency: invoice.currency,
        description: description,
        invoice_uuid: invoice.uuid,
        idempotency_key: "#{invoice.uuid}-#{subscription.renewal_attempts}",
        metadata: %{invoice_uuid: invoice.uuid, subscription_uuid: subscription.uuid}
      )
      |> notify_refusal(invoice)
    end
  end

  defp notify_refusal({:error, reason} = refusal, invoice) do
    _ = Notifications.payment_failed(invoice, reason)
    refusal
  end

  defp notify_refusal(charged, _invoice), do: charged

  defp ensure_chargeable(%PaymentMethod{} = method, %Invoice{} = invoice) do
    cond do
      not PaymentMethod.usable?(method) -> {:error, :payment_method_not_usable}
      not Invoice.payable?(invoice) -> {:error, :invoice_not_payable}
      true -> :ok
    end
  end

  defp record(locked, invoice, amount, charge_result, description, repo) do
    # `charge_result` is a `%ChargeResult{}` struct and `provider_data` is a `:map`
    # column - the context sanitizes it, because a struct survives Ecto's cast and
    # dump and only blows up in the JSON encoder, i.e. after the card is charged.
    attrs = %{
      amount: amount,
      payment_method: locked.payment_method.provider,
      description: description,
      provider_transaction_id: charge_result.provider_transaction_id,
      provider_data: charge_result
    }

    case Billing.record_payment(invoice, attrs, nil) do
      {:ok, _transaction} ->
        with {:ok, renewed} <- next_period(locked, repo) do
          {:paid, renewed, amount}
        end

      {:error, reason} ->
        # The money LEFT the customer's account and the ledger has no row for it. The
        # refusal aborted this transaction, so only a rollback is left from here.
        Logger.error(
          "Charged #{amount} #{invoice.currency} for invoice #{invoice.invoice_number} " <>
            "but failed to record it: #{inspect(reason)}. Reconcile it by hand; it will " <>
            "not be retried."
        )

        repo.rollback({:charged_not_recorded, reason})
    end
  end

  defp next_period(%Subscription{subscription_type: plan} = subscription, repo) do
    next =
      SubscriptionType.next_billing_date(plan, DateTime.to_date(subscription.current_period_end))

    subscription
    |> Subscription.activate_changeset(DateTime.new!(next, ~T[00:00:00], "Etc/UTC"))
    |> repo.update()
  end
end
