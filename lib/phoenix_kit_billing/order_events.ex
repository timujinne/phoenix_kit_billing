defmodule PhoenixKitBilling.OrderEvents do
  @moduledoc """
  A durable way for OTHER modules to learn that an order was paid, refunded,
  cancelled or reinstated.

  `PhoenixKitBilling.InvoiceEvents` only fires for invoices, and an order can be
  paid without one. The `{:order_paid, order}` PubSub broadcast is a
  notification, not a delivery: a listener that was restarting never hears it,
  and whatever the order was for (stock to write off, an email to send) never
  happens.

  An order paid through its invoice fires this `:paid` as well as the invoice's
  own, so a module listening to both must not act twice.

  ## Events

  - `:paid` - the order became `"paid"`, directly or through its invoice.
  - `:refunded` - the order became `"refunded"`. That takes a full refund: a
    partial one leaves the order `"paid"` and fires no order event (the invoice's
    `:refunded` fires for every refund).
  - `:cancelled` - the order became `"cancelled"`.
  - `:reinstated` - a cancelled order went back to the status it was cancelled
    from (`reinstate_order/3`). When an invoice paid meanwhile settles the order
    in the same transaction, `:paid` follows. A handler that undid something on
    `:cancelled` (released stock) takes it up again here.

  A refused transition fires nothing. Neither does moving an order to the trash
  or restoring it, which change no status.

  ## For a module that wants to hear

  Export `billing_order_event_handlers/0` from your `PhoenixKit.Module`,
  returning handler modules. Each implements:

      @spec handle_order_event(
              :paid | :refunded | :cancelled | :reinstated,
              PhoenixKitBilling.Order.t()
            ) :: :ok | {:error, term()}

  End the handler with a catch-all clause (`def handle_order_event(_event,
  _order), do: :ok`): events are added over time (`:reinstated` was), and a
  handler with no clause for one fails its job and is retried.

  Duck-typed - no compile-time dependency on billing - the same pattern as
  `InvoiceEvents`, so an optional billing integration costs nothing when billing
  is absent. A host app can also list handlers:

      config :phoenix_kit_billing, order_event_handlers: [MyApp.OrderHandler]

  ## Guarantees

  - The event is enqueued in the **same database transaction** that changed the
    order's status: it is committed with the status or not at all.
  - **One Oban job per (event, handler)**: a failing handler retries alone and
    never holds up another module.
  - **At-least-once.** A handler must be idempotent. Each job carries an
    `event_uuid`, which Oban uses so an event reaches a handler through one job;
    it does not cover a retry of that job, and it is not passed to the handler.
    The order's uuid and the event do not identify an occurrence either: an
    order cancelled, reinstated and cancelled again fires `:cancelled` twice
    (and `:reinstated` once in between). So do not remember "done for (order,
    event)"; make the effect idempotent against the order's status as the
    handler reads it (release the stock if the order is cancelled and it is not
    released yet).
  - The handler receives the order **as it is now** - re-read when the job runs,
    with `:billing_profile` loaded - not a snapshot from when it was enqueued. A
    `:paid` delivered late can find the order already `"refunded"`, a
    `:cancelled` the order already reinstated.
  - A job may only call a handler that is registered *when it runs*: job
    arguments are data, never a license to invoke an arbitrary module.

  The jobs run on the `:billing` queue, which billing declares through
  `oban_queues/0`. A node that does not run it delivers nothing: the jobs wait.

  PubSub still fires for live screens, after the commit.
  """

  require Logger

  alias PhoenixKitBilling.Order
  alias PhoenixKitBilling.Workers.OrderEventWorker

  @events [:paid, :refunded, :cancelled, :reinstated]

  @doc "The events handlers can receive."
  def events, do: @events

  @doc """
  Every registered handler: the host's configured ones plus those declared by
  installed PhoenixKit modules via `billing_order_event_handlers/0`.
  """
  def handlers do
    configured = Application.get_env(:phoenix_kit_billing, :order_event_handlers, [])

    (configured ++ discovered())
    |> Enum.uniq()
    |> Enum.filter(&handler?/1)
  end

  # The registry, not `ModuleDiscovery.discover_external_modules/0`: that one
  # walks every dependency's ebin directory on disk, and this runs on every
  # transition - inside the transaction holding the order's row lock - and again
  # on every job. The registry is a `:persistent_term` read of the same set,
  # built once at boot.
  defp discovered do
    PhoenixKit.ModuleRegistry.all_modules()
    |> Enum.filter(fn mod ->
      Code.ensure_loaded?(mod) and function_exported?(mod, :billing_order_event_handlers, 0)
    end)
    |> Enum.flat_map(fn mod ->
      try do
        List.wrap(mod.billing_order_event_handlers())
      rescue
        e ->
          Logger.warning(
            "[Billing] #{inspect(mod)}.billing_order_event_handlers/0 failed: #{Exception.message(e)}"
          )

          []
      end
    end)
  rescue
    _ -> []
  end

  defp handler?(mod) when is_atom(mod),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, :handle_order_event, 2)

  defp handler?(_), do: false

  @doc """
  Enqueues one job per handler for `event` on `order`. Call it INSIDE the
  transaction that changed the order, so the event commits with it.

  If Oban is not running (a host misconfiguration, or a bare test), this logs and
  returns `:not_enqueued` rather than raising: a payment must never be rolled back
  because a notification could not be queued.
  """
  def enqueue(event, %Order{uuid: uuid}) when event in @events do
    event_uuid = Ecto.UUID.generate()

    Enum.each(handlers(), fn handler ->
      %{
        "event" => Atom.to_string(event),
        "order_uuid" => uuid,
        "event_uuid" => event_uuid,
        "handler" => inspect(handler)
      }
      |> OrderEventWorker.new()
      |> Oban.insert!()
    end)
  rescue
    e in [ArgumentError, RuntimeError] ->
      Logger.error(
        "[Billing] order #{event} event for #{uuid} NOT enqueued (is Oban running?): " <>
          Exception.message(e)
      )

      :not_enqueued
  end

  @doc false
  # Resolves a handler named in a job's arguments against the handlers
  # registered NOW. Never `String.to_existing_atom` + call: that would let any
  # string in a job row invoke any loaded module.
  def resolve_handler(name) when is_binary(name) do
    case Enum.find(handlers(), &(inspect(&1) == name)) do
      nil -> :error
      handler -> {:ok, handler}
    end
  end
end
