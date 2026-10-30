defmodule PhoenixKitBilling.OrderPayment do
  @moduledoc """
  Starts the online payment of an order: finds or creates the order's open
  invoice, makes it payable and opens a checkout session at the provider of
  the order's payment option.

  The public entry point is `PhoenixKitBilling.start_order_payment/2`. This
  module composes billing's public functions (`create_invoice_from_order/2`,
  `send_invoice/2`, `create_checkout_session/3`), so their errors reach the
  caller as they are; it also reads `Invoice` and `Order` with its own queries
  and calls `Providers.*` for the provider lookup.

  Whether the caller may pay this order at all (that it is the buyer's own) is
  the caller's concern: the order is found by its uuid alone.

  ## Steps

    1. The order must be unpaid and carry an online payment option whose
       provider is configured.
    2. The order's open invoice (`draft`, `sent` or `overdue`, newest first)
       is reused, or one is created from the order. Steps 2 to 4 run under a
       per-order advisory lock (held on one connection, outside any
       transaction, so billing's invoice events still follow their commits),
       so two clicks cannot create two invoices or two live sessions. The lock
       is a *session* lock: the repo must use session pooling (PgBouncer in
       transaction mode does not keep it on one connection).
    3. A `draft` invoice is sent **without an email** (`send_email: false`):
       only a `sent` or `overdue` invoice is payable, and the buyer is
       emailed when the payment lands, not when the checkout opens.
    4. A checkout session recorded on the invoice (`metadata["checkout"]`)
       for the same provider, amount, currency, return URLs and customer email
       is reused while it is younger than 20 minutes; otherwise a new one is
       opened and recorded. The payment itself is
       confirmed by the provider's webhook, never by the return URL.

  ## Options

    * `:success_url` (required) - where the provider sends the buyer after paying
    * `:cancel_url` - defaults to `:success_url`
    * `:customer_email` - the invoice recipient (when it differs from the
      order's buyer) and the address prefilled at the provider
    * `:provider` - overrides the provider of the order's payment option

  Returns `{:ok, %{invoice: invoice, url: url}}` or `{:error, reason}`, where
  the reason is one of `:order_not_found`, `:order_not_payable` (cancelled,
  refunded, no online payment option), `:already_paid`,
  `:provider_not_available`, `:lock_timeout` (another start for the same
  order held the lock for too long), `:in_transaction` (see below), or whatever
  billing's own functions return.

  ## The order lock

  The lock is a Postgres *session* advisory lock on one pinned connection, so
  the repo needs session pooling (PgBouncer in transaction mode does not keep
  it on one connection). Its holder keeps that connection for the whole call,
  provider request included: up to 60 s (the checkout timeout) if the provider
  is slow. A second start for the same order polls for the lock, one short
  checkout per try, up to 30 s by default; set
  `config :phoenix_kit_billing, :order_payment_lock_wait_ms, ms` to change it.

  Call it **outside a transaction**. Inside one, an aborted transaction would
  make the unlock fail and leave the lock on the connection, and the invoice
  events billing broadcasts would go out before your commit; so a call made in
  a transaction answers `{:error, :in_transaction}` and does nothing.
  """

  import Ecto.Query

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, Order, PaymentOption, Providers}

  # A session is reused only while it is surely still live. Stripe keeps a
  # Checkout session for at least 30 minutes, but Razorpay's payment link
  # expires after 30 minutes (PayPal and EveryPay record no expiry), so the
  # window is 20 minutes, inside the shortest we know of.
  @session_reuse_seconds 1200

  # The connection is held while the lock is waited for and the provider is
  # called (Req waits 15 s itself), so its checkout timeout is well above both.
  @checkout_timeout 60_000
  @lock_wait_ms 30_000
  @lock_poll_ms 50

  @spec start(Order.t() | String.t(), keyword()) ::
          {:ok, %{invoice: Invoice.t(), url: String.t()}} | {:error, term()}
  def start(order_or_uuid, opts) do
    success_url = Keyword.fetch!(opts, :success_url)
    opts = Keyword.put_new(opts, :cancel_url, success_url)

    with :ok <- ensure_not_in_transaction(),
         {:ok, uuid} <- order_uuid(order_or_uuid) do
      # Everything from "which invoice" to "the session is recorded" runs under
      # the order's lock, so two clicks cannot open two sessions for one
      # invoice. It is a session-level lock on one pinned connection and no
      # transaction: the invoice events billing broadcasts while creating and
      # sending the invoice must go out after their own commits.
      with_order_lock(uuid, fn -> start_locked(uuid, opts) end)
    end
  end

  defp start_locked(uuid, opts) do
    # Read under the lock: the order may have been paid while we waited.
    with {:ok, order} <- load_order(uuid),
         :ok <- ensure_payable(order),
         {:ok, provider} <- resolve_provider(order, opts),
         {:ok, invoice} <- find_or_create_invoice(order),
         {:ok, invoice} <- make_payable(invoice, opts),
         {:ok, url} <- session_url(invoice, provider, opts) do
      {:ok, %{invoice: repo().get!(Invoice, invoice.uuid), url: url}}
    end
  end

  defp ensure_not_in_transaction do
    if repo().in_transaction?(), do: {:error, :in_transaction}, else: :ok
  end

  defp order_uuid(%Order{uuid: uuid}), do: order_uuid(uuid)

  defp order_uuid(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :order_not_found}
    end
  end

  defp load_order(uuid) do
    case repo().get(Order, uuid) do
      nil -> {:error, :order_not_found}
      order -> {:ok, repo().preload(order, :payment_option)}
    end
  end

  defp ensure_payable(%Order{status: "paid"}), do: {:error, :already_paid}

  defp ensure_payable(%Order{status: status, total: total})
       when status in ~w(draft pending confirmed) do
    if payable_amount?(total), do: :ok, else: {:error, :order_not_payable}
  end

  defp ensure_payable(_order), do: {:error, :order_not_payable}

  defp payable_amount?(%Decimal{} = total), do: Decimal.compare(total, 0) == :gt
  defp payable_amount?(_total), do: false

  defp resolve_provider(%Order{payment_option: option}, opts) do
    case {opts[:provider], option} do
      {provider, _} when not is_nil(provider) -> known_provider(provider)
      {nil, %PaymentOption{type: "online", provider: provider}} -> known_provider(provider)
      _ -> {:error, :order_not_payable}
    end
  end

  # A name that is not one of the providers billing knows must not create an
  # atom, and one that is not configured must not open an invoice.
  defp known_provider(name) do
    provider = Enum.find(Providers.all_providers(), &(to_string(&1) == to_string(name)))

    if provider && Providers.provider_enabled?(provider),
      do: {:ok, provider},
      else: {:error, :provider_not_available}
  end

  # The lock is polled with `pg_try_advisory_lock`, one short checkout per
  # try, so a waiter holds no pool connection while it sleeps and a start that
  # cannot get the lock answers `{:error, :lock_timeout}`. Only the holder
  # keeps its connection (the lock lives on it) while the provider is called.
  defp with_order_lock(uuid, fun) do
    key = lock_key(uuid)
    deadline = System.monotonic_time(:millisecond) + lock_wait_ms()
    lock_loop(key, deadline, fun)
  end

  defp lock_loop(key, deadline, fun) do
    attempt =
      repo().checkout(
        fn ->
          %{rows: [[locked?]]} =
            repo().query!("SELECT pg_try_advisory_lock(hashtext($1))", [key])

          if locked? do
            try do
              {:locked, fun.()}
            after
              repo().query!("SELECT pg_advisory_unlock(hashtext($1))", [key])
            end
          else
            :busy
          end
        end,
        timeout: @checkout_timeout
      )

    case attempt do
      {:locked, result} ->
        result

      :busy ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :lock_timeout}
        else
          Process.sleep(@lock_poll_ms)
          lock_loop(key, deadline, fun)
        end
    end
  end

  defp lock_wait_ms,
    do: Application.get_env(:phoenix_kit_billing, :order_payment_lock_wait_ms, @lock_wait_ms)

  @doc false
  @spec lock_key(String.t()) :: String.t()
  def lock_key(uuid), do: "billing_order_payment:" <> uuid

  defp find_or_create_invoice(order) do
    open =
      from(i in Invoice,
        where: i.order_uuid == ^order.uuid and i.status in ~w(draft sent overdue paid),
        order_by: [desc: i.inserted_at, desc: i.uuid],
        limit: 1
      )

    case repo().one(open) do
      %Invoice{status: "paid"} -> {:error, :already_paid}
      %Invoice{} = invoice -> {:ok, invoice}
      nil -> Billing.create_invoice_from_order(order)
    end
  end

  defp make_payable(%Invoice{status: "draft"} = invoice, opts) do
    send_opts = ([send_email: false] ++ Keyword.take(opts, [:customer_email])) |> to_email()

    case Billing.send_invoice(invoice, send_opts) do
      {:ok, sent, _email_result} -> {:ok, sent}
      {:error, _} = error -> error
    end
  end

  defp make_payable(invoice, _opts), do: {:ok, invoice}

  defp to_email(opts) do
    case Keyword.pop(opts, :customer_email) do
      {nil, opts} -> opts
      {email, opts} -> Keyword.put(opts, :to_email, email)
    end
  end

  defp session_url(invoice, provider, opts) do
    case reusable_url(invoice, provider, opts) do
      url when is_binary(url) ->
        {:ok, url}

      nil ->
        checkout_opts = Keyword.take(opts, [:success_url, :cancel_url, :customer_email])

        with {:ok, url} <- Billing.create_checkout_session(invoice, provider, checkout_opts) do
          record_checkout_context(invoice, url, opts)
          {:ok, url}
        end
    end
  end

  # Billing records the session under `metadata["checkout"]` without the amount
  # it was opened for; this adds the amount and request context so a session
  # cannot be reused with a different currency, recipient or return route.
  # Only the record of the session just opened (its URL) is touched. Best
  # effort, like billing's own record: without it the session is simply not
  # reused.
  defp record_checkout_context(%Invoice{uuid: uuid} = invoice, url, opts) do
    with %Invoice{metadata: %{"checkout" => %{"url" => ^url} = checkout} = metadata} = stored <-
           repo().get(Invoice, uuid),
         {:ok, _} <-
           stored
           |> Ecto.Changeset.change(%{
             metadata:
               Map.put(metadata, "checkout", Map.merge(checkout, checkout_context(invoice, opts)))
           })
           |> repo().update() do
      :ok
    else
      _ -> :ok
    end
  end

  # A session is reused only for the amount it was opened for: a part payment
  # or a changed total in between makes it stale. A session recorded without
  # its amount (by an older billing) is never reused.
  defp reusable_url(
         %Invoice{metadata: %{"checkout" => %{"url" => url} = checkout}} = invoice,
         provider,
         opts
       )
       when is_binary(url) do
    context = checkout_context(invoice, opts)

    with true <- checkout["provider"] == to_string(provider),
         true <- Map.take(checkout, Map.keys(context)) == context,
         {:ok, created_at, _} <- DateTime.from_iso8601(checkout["created_at"] || ""),
         age = DateTime.diff(DateTime.utc_now(), created_at),
         true <- age >= 0 and age < @session_reuse_seconds do
      url
    else
      _ -> nil
    end
  end

  defp reusable_url(_invoice, _provider, _opts), do: nil

  defp checkout_context(invoice, opts) do
    %{
      "amount_due" => amount_due(invoice),
      "currency" => invoice.currency,
      "success_url" => opts[:success_url],
      "cancel_url" => opts[:cancel_url],
      "customer_email" => opts[:customer_email]
    }
  end

  defp amount_due(invoice), do: invoice |> Invoice.remaining_amount() |> Decimal.to_string()

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
