defmodule PhoenixKitBilling.Events do
  @moduledoc """
  PubSub events for PhoenixKit Billing system.

  Broadcasts billing-related events for real-time updates in LiveViews.
  Uses `PhoenixKit.PubSub.Manager` for self-contained PubSub operations.

  ## Topics

  - `phoenix_kit:billing:orders` - Order events (created, updated, confirmed, paid, refunded, cancelled, reinstated, trashed, restored)
  - `phoenix_kit:billing:invoices` - Invoice events (created, sent, paid, voided, trashed, restored)
  - `phoenix_kit:billing:profiles` - Billing profile events (created, updated, deleted)
  - `phoenix_kit:billing:transactions` - Transaction events (created, refunded)
  - `phoenix_kit:billing:credit_notes` - Credit note events (sent, applied)
  - `phoenix_kit:billing:currencies` - Currency table events (rate, enabled, rounding rule, base changed)

  ## Usage Examples

      # Subscribe to order events
      PhoenixKitBilling.Events.subscribe_orders()

      # Handle in LiveView
      def handle_info({:order_created, order}, socket) do
        # Update UI
        {:noreply, socket}
      end

      # Broadcast order created
      PhoenixKitBilling.Events.broadcast_order_created(order)
  """

  alias PhoenixKit.PubSub.Manager

  @orders_topic "phoenix_kit:billing:orders"
  @invoices_topic "phoenix_kit:billing:invoices"
  @profiles_topic "phoenix_kit:billing:profiles"
  @transactions_topic "phoenix_kit:billing:transactions"
  @credit_notes_topic "phoenix_kit:billing:credit_notes"
  @subscriptions_topic "phoenix_kit:billing:subscriptions"
  @currencies_topic "phoenix_kit:billing:currencies"

  # ============================================
  # SUBSCRIPTIONS
  # ============================================

  @doc """
  Subscribes to order events.
  """
  def subscribe_orders do
    Manager.subscribe(@orders_topic)
  end

  @doc """
  Subscribes to invoice events.
  """
  def subscribe_invoices do
    Manager.subscribe(@invoices_topic)
  end

  @doc """
  Subscribes to billing profile events.
  """
  def subscribe_profiles do
    Manager.subscribe(@profiles_topic)
  end

  @doc """
  Subscribes to transaction events.
  """
  def subscribe_transactions do
    Manager.subscribe(@transactions_topic)
  end

  @doc """
  Subscribes to credit note events.
  """
  def subscribe_credit_notes do
    Manager.subscribe(@credit_notes_topic)
  end

  @doc """
  Subscribes to subscription events.
  """
  def subscribe_subscriptions do
    Manager.subscribe(@subscriptions_topic)
  end

  @doc """
  Subscribes to subscription events for a specific user.
  """
  def subscribe_user_subscriptions(user_uuid) do
    Manager.subscribe("#{@subscriptions_topic}:user:#{user_uuid}")
  end

  @doc """
  Subscribes to order events for a specific user.
  """
  def subscribe_user_orders(user_uuid) do
    Manager.subscribe("#{@orders_topic}:user:#{user_uuid}")
  end

  @doc """
  Subscribes to invoice events for a specific user.
  """
  def subscribe_user_invoices(user_uuid) do
    Manager.subscribe("#{@invoices_topic}:user:#{user_uuid}")
  end

  @doc """
  Subscribes to transaction events for a specific user.
  """
  def subscribe_user_transactions(user_uuid) do
    Manager.subscribe("#{@transactions_topic}:user:#{user_uuid}")
  end

  # ============================================
  # ORDER BROADCASTS
  # ============================================

  @doc """
  Broadcasts order created event.
  """
  def broadcast_order_created(order) do
    broadcast(@orders_topic, {:order_created, order})
    broadcast("#{@orders_topic}:user:#{order.user_uuid}", {:order_created, order})
  end

  @doc """
  Broadcasts order updated event.
  """
  def broadcast_order_updated(order) do
    broadcast(@orders_topic, {:order_updated, order})
    broadcast("#{@orders_topic}:user:#{order.user_uuid}", {:order_updated, order})
  end

  @doc """
  Broadcasts order confirmed event.
  """
  def broadcast_order_confirmed(order) do
    broadcast(@orders_topic, {:order_confirmed, order})
    broadcast("#{@orders_topic}:user:#{order.user_uuid}", {:order_confirmed, order})
  end

  @doc """
  Broadcasts order paid event.
  """
  def broadcast_order_paid(order) do
    broadcast(@orders_topic, {:order_paid, order})
    broadcast("#{@orders_topic}:user:#{order.user_uuid}", {:order_paid, order})
  end

  @doc """
  Broadcasts order refunded event.
  """
  def broadcast_order_refunded(order) do
    broadcast(@orders_topic, {:order_refunded, order})
    broadcast("#{@orders_topic}:user:#{order.user_uuid}", {:order_refunded, order})
  end

  @doc """
  Broadcasts order cancelled event.
  """
  def broadcast_order_cancelled(order) do
    broadcast(@orders_topic, {:order_cancelled, order})
    broadcast("#{@orders_topic}:user:#{order.user_uuid}", {:order_cancelled, order})
  end

  @doc """
  Broadcasts order reinstated event (a cancelled order went back to the status
  it was cancelled from).
  """
  def broadcast_order_reinstated(order) do
    broadcast(@orders_topic, {:order_reinstated, order})
    broadcast("#{@orders_topic}:user:#{order.user_uuid}", {:order_reinstated, order})
  end

  @doc """
  Broadcasts order trashed event. Trashing changes nothing else about the
  order, so it is announced on its own: no `:order_updated` or
  `:order_cancelled` goes with it.
  """
  def broadcast_order_trashed(order) do
    broadcast(@orders_topic, {:order_trashed, order})
    broadcast("#{@orders_topic}:user:#{order.user_uuid}", {:order_trashed, order})
  end

  @doc """
  Broadcasts order restored event (the order left the trash).
  """
  def broadcast_order_restored(order) do
    broadcast(@orders_topic, {:order_restored, order})
    broadcast("#{@orders_topic}:user:#{order.user_uuid}", {:order_restored, order})
  end

  # ============================================
  # INVOICE BROADCASTS
  # ============================================

  @doc """
  Broadcasts invoice created event.
  """
  def broadcast_invoice_created(invoice) do
    broadcast(@invoices_topic, {:invoice_created, invoice})
    broadcast("#{@invoices_topic}:user:#{invoice.user_uuid}", {:invoice_created, invoice})
  end

  @doc """
  Broadcasts invoice sent event.
  """
  def broadcast_invoice_sent(invoice) do
    broadcast(@invoices_topic, {:invoice_sent, invoice})
    broadcast("#{@invoices_topic}:user:#{invoice.user_uuid}", {:invoice_sent, invoice})
  end

  @doc """
  Broadcasts invoice paid event.
  """
  def broadcast_invoice_paid(invoice) do
    broadcast(@invoices_topic, {:invoice_paid, invoice})
    broadcast("#{@invoices_topic}:user:#{invoice.user_uuid}", {:invoice_paid, invoice})
  end

  @doc """
  Broadcasts invoice voided event.
  """
  def broadcast_invoice_voided(invoice) do
    broadcast(@invoices_topic, {:invoice_voided, invoice})
    broadcast("#{@invoices_topic}:user:#{invoice.user_uuid}", {:invoice_voided, invoice})
  end

  @doc """
  Broadcasts invoice trashed event. Like `broadcast_order_trashed/1`, it goes
  alone: no `:invoice_voided` or other event comes with it, and the durable
  `PhoenixKitBilling.InvoiceEvents` are not involved.
  """
  def broadcast_invoice_trashed(invoice) do
    broadcast(@invoices_topic, {:invoice_trashed, invoice})
    broadcast("#{@invoices_topic}:user:#{invoice.user_uuid}", {:invoice_trashed, invoice})
  end

  @doc """
  Broadcasts invoice restored event (the invoice left the trash).
  """
  def broadcast_invoice_restored(invoice) do
    broadcast(@invoices_topic, {:invoice_restored, invoice})
    broadcast("#{@invoices_topic}:user:#{invoice.user_uuid}", {:invoice_restored, invoice})
  end

  # ============================================
  # BILLING PROFILE BROADCASTS
  # ============================================

  @doc """
  Broadcasts billing profile created event.
  """
  def broadcast_profile_created(profile) do
    broadcast(@profiles_topic, {:profile_created, profile})
  end

  @doc """
  Broadcasts billing profile updated event.
  """
  def broadcast_profile_updated(profile) do
    broadcast(@profiles_topic, {:profile_updated, profile})
  end

  @doc """
  Broadcasts billing profile deleted event.
  """
  def broadcast_profile_deleted(profile) do
    broadcast(@profiles_topic, {:profile_deleted, profile})
  end

  # ============================================
  # TRANSACTION BROADCASTS
  # ============================================

  @doc """
  Broadcasts transaction created event.
  """
  def broadcast_transaction_created(transaction) do
    broadcast(@transactions_topic, {:transaction_created, transaction})

    broadcast(
      "#{@transactions_topic}:user:#{transaction.user_uuid}",
      {:transaction_created, transaction}
    )
  end

  @doc """
  Broadcasts transaction refunded event.
  """
  def broadcast_transaction_refunded(transaction) do
    broadcast(@transactions_topic, {:transaction_refunded, transaction})

    broadcast(
      "#{@transactions_topic}:user:#{transaction.user_uuid}",
      {:transaction_refunded, transaction}
    )
  end

  # ============================================
  # CREDIT NOTE BROADCASTS
  # ============================================

  @doc """
  Broadcasts credit note sent event.
  """
  def broadcast_credit_note_sent(invoice, transaction) do
    broadcast(@credit_notes_topic, {:credit_note_sent, invoice, transaction})
  end

  @doc """
  Broadcasts credit note applied event.
  """
  def broadcast_credit_note_applied(invoice, transaction, amount) do
    broadcast(@credit_notes_topic, {:credit_note_applied, invoice, transaction, amount})
  end

  # ============================================
  # SUBSCRIPTION BROADCASTS
  # ============================================

  @doc """
  Broadcasts subscription created event.
  """
  def broadcast_subscription_created(subscription) do
    broadcast(@subscriptions_topic, {:subscription_created, subscription})

    broadcast(
      "#{@subscriptions_topic}:user:#{subscription.user_uuid}",
      {:subscription_created, subscription}
    )
  end

  @doc """
  Broadcasts subscription cancelled event.
  """
  def broadcast_subscription_cancelled(subscription) do
    broadcast(@subscriptions_topic, {:subscription_cancelled, subscription})

    broadcast(
      "#{@subscriptions_topic}:user:#{subscription.user_uuid}",
      {:subscription_cancelled, subscription}
    )
  end

  @doc """
  Broadcasts subscription renewed event.
  """
  def broadcast_subscription_renewed(subscription) do
    broadcast(@subscriptions_topic, {:subscription_renewed, subscription})

    broadcast(
      "#{@subscriptions_topic}:user:#{subscription.user_uuid}",
      {:subscription_renewed, subscription}
    )
  end

  @doc """
  Broadcasts subscription type changed event.
  """
  def broadcast_subscription_type_changed(subscription, old_type_uuid, new_type_uuid) do
    broadcast(
      @subscriptions_topic,
      {:subscription_type_changed, subscription, old_type_uuid, new_type_uuid}
    )

    broadcast(
      "#{@subscriptions_topic}:user:#{subscription.user_uuid}",
      {:subscription_type_changed, subscription, old_type_uuid, new_type_uuid}
    )
  end

  @doc """
  Broadcasts subscription status changed event.
  """
  def broadcast_subscription_status_changed(subscription, old_status, new_status) do
    broadcast(
      @subscriptions_topic,
      {:subscription_status_changed, subscription, old_status, new_status}
    )

    broadcast(
      "#{@subscriptions_topic}:user:#{subscription.user_uuid}",
      {:subscription_status_changed, subscription, old_status, new_status}
    )
  end

  # ============================================
  # CURRENCIES
  # ============================================

  @doc "Topic for currency-table changes."
  def currencies_topic, do: @currencies_topic

  @doc """
  Subscribes to currency-table changes. Storefront LiveViews use this to
  re-render converted prices the moment a rate, a rounding rule, an
  `enabled` flag or the base changes (per-domain-currency spec §4.2.1 item 5).
  """
  def subscribe_currencies, do: Manager.subscribe(@currencies_topic)

  @doc """
  Broadcasts `{:currencies_changed, code}` — sent by the context AFTER its
  currency cache is cleared, so a subscriber that re-reads on receipt sees
  the new table. `code` is the currency that was written (for
  `set_default_currency/1`, the new base — every rate was renormalized).

  The clear itself is a `GenServer.cast` (fire-and-forget), so the context
  follows it with a same-process `GenServer.call` to the cache (a barrier —
  Erlang orders messages from one sender to one receiver, so the call
  cannot return until the cast has been applied) before ever reaching this
  function. That is what makes the "sees the new table" promise above
  true, not just usual.
  """
  def broadcast_currencies_changed(%PhoenixKitBilling.Currency{code: code}) do
    broadcast(@currencies_topic, {:currencies_changed, code})
  end

  # ============================================
  # HELPERS
  # ============================================

  defp broadcast(topic, message) do
    Manager.broadcast(topic, message)
  end
end
