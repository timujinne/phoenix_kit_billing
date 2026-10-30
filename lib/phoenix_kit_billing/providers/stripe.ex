defmodule PhoenixKitBilling.Providers.Stripe do
  @moduledoc """
  Stripe payment provider implementation.

  This module implements the `PhoenixKitBilling.Providers.Provider` behaviour
  for Stripe payments. It supports:

  - Hosted Checkout for one-time payments
  - Setup sessions for saving payment methods
  - Charging saved payment methods (for subscription renewals)
  - Webhook signature verification
  - Refunds

  ## Configuration

  Configure Stripe via the admin UI (`/admin/settings/billing/providers`)
  or by writing the underlying `PhoenixKit.Settings` keys directly:

      PhoenixKit.Settings.update_setting("billing_stripe_enabled", "true")
      PhoenixKit.Settings.update_setting("billing_stripe_secret_key", "sk_test_...")
      PhoenixKit.Settings.update_setting("billing_stripe_webhook_secret", "whsec_...")

  The secret key is read from `billing_stripe_secret_key` (falling back to
  the legacy `billing_stripe_api_key`); see `stripe_secret_key/0`.

  ## Webhook Events

  Configure your Stripe webhook to send these events:
  - `checkout.session.completed` - Payment completed
  - `checkout.session.expired` - Session expired
  - `payment_intent.succeeded` - Payment succeeded (for saved cards)
  - `payment_intent.payment_failed` - Payment failed
  - `charge.refunded` - Refund processed
  - `setup_intent.succeeded` - Card saved successfully

  `charge.refunded` is the one refund event this provider consumes. Its
  Charge object carries the running total refunded on the charge, so a
  refund is recorded as the part of that total the ledger does not hold yet
  and a redelivery or a refund the host already recorded adds nothing. The
  `refund.created` / `refund.updated` events describe the same refunds one
  by one and are deliberately not consumed: the two streams cannot be
  matched against each other (a Charge does not list its refunds by
  default), so reading both would record a partial refund twice.

  ## Dependencies

  Talks to the Stripe REST API directly over `Req` — no `stripe` hex
  package is required.
  """

  @behaviour PhoenixKitBilling.Providers.Provider

  alias PhoenixKitBilling.Providers.Types.{
    ChargeResult,
    CheckoutSession,
    PaymentMethodInfo,
    RefundResult,
    SetupSession,
    WebhookEventData
  }

  alias PhoenixKit.Settings
  alias PhoenixKitBilling.Providers.MinorUnits

  require Logger

  @stripe_api_version "2023-10-16"

  # Provider identification
  @impl true
  def provider_name, do: :stripe

  @impl true
  def available? do
    config = get_config()
    config[:enabled] and is_binary(config[:api_key]) and config[:api_key] != ""
  end

  @doc """
  Creates a Stripe Checkout Session for one-time payment.

  ## Options

  - `:success_url` - URL to redirect after successful payment (required)
  - `:cancel_url` - URL to redirect if user cancels (required)
  - `:save_payment_method` - Whether to save card for future use (default: false)
  - `:customer_email` - Pre-fill customer email
  - `:metadata` - Additional metadata to attach

  ## Amount

  Stripe is asked for the amount due, `total - paid_amount`. The invoice's line
  items are sent as they are when they add up to it; otherwise (tax, a
  discount, a part payment) one line "Invoice <number>" for the amount due is
  sent. An invoice with nothing left to pay answers `{:error, :nothing_to_pay}`
  and no session is opened.

  ## Examples

      iex> create_checkout_session(invoice, success_url: "https://...", cancel_url: "https://...")
      {:ok, %{id: "cs_test_...", url: "https://checkout.stripe.com/..."}}
  """
  @impl true
  def create_checkout_session(invoice, opts) do
    with {:ok, config} <- ensure_configured(),
         {:ok, line_items} <- build_line_items(invoice) do
      params = %{
        mode: "payment",
        line_items: line_items,
        success_url: Keyword.fetch!(opts, :success_url),
        cancel_url: Keyword.fetch!(opts, :cancel_url),
        client_reference_id: to_string(invoice.uuid),
        metadata: %{
          invoice_uuid: to_string(invoice.uuid),
          invoice_number: invoice.invoice_number
        }
      }

      params =
        params
        |> maybe_add_customer_email(invoice, opts)
        |> maybe_add_save_payment_method(opts)
        |> maybe_add_custom_metadata(opts)

      case stripe_request(:post, "/checkout/sessions", params, config) do
        {:ok, %{"id" => id, "url" => url, "expires_at" => expires_at}} ->
          {:ok,
           %CheckoutSession{
             id: id,
             url: url,
             provider: :stripe,
             expires_at: DateTime.from_unix!(expires_at),
             metadata: %{invoice_uuid: invoice.uuid}
           }}

        {:error, reason} ->
          Logger.error("Stripe checkout session creation failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Creates a Stripe Setup Session to save a payment method.

  ## Options

  - `:success_url` - URL to redirect after success (required)
  - `:cancel_url` - URL to redirect if user cancels (required)
  - `:customer_email` - Customer email

  ## Examples

      iex> create_setup_session(user, success_url: "https://...", cancel_url: "https://...")
      {:ok, %{id: "seti_...", url: "https://checkout.stripe.com/..."}}
  """
  @impl true
  def create_setup_session(user, opts) do
    with {:ok, config} <- ensure_configured(),
         {:ok, customer_id} <- ensure_customer(user, config) do
      params = %{
        mode: "setup",
        customer: customer_id,
        success_url: Keyword.fetch!(opts, :success_url),
        cancel_url: Keyword.fetch!(opts, :cancel_url),
        payment_method_types: ["card"],
        metadata: %{
          user_uuid: to_string(user.uuid)
        }
      }

      case stripe_request(:post, "/checkout/sessions", params, config) do
        {:ok, %{"id" => id, "url" => url}} ->
          {:ok,
           %SetupSession{
             id: id,
             url: url,
             provider: :stripe,
             metadata: %{user_uuid: user.uuid, customer_id: customer_id}
           }}

        {:error, reason} ->
          Logger.error("Stripe setup session creation failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Charges a saved payment method.

  Used for subscription renewals where the payment method was previously saved.

  ## Options

  - `:currency` - Currency code (default: EUR)
  - `:description` - Description for the charge
  - `:invoice_uuid` - Associated invoice UUID
  - `:metadata` - Additional metadata

  ## Examples

      iex> charge_payment_method(payment_method, Decimal.new("99.00"), currency: "EUR")
      {:ok, %{id: "pi_...", provider_transaction_id: "ch_...", status: "succeeded"}}
  """
  @impl true
  def charge_payment_method(payment_method, amount, opts) do
    # Read BEFORE ensure_configured/0 so a missing :currency fails even on a
    # host with no Stripe config at all — a caller must never see a silent
    # "EUR" fallback just because the provider isn't set up yet (§7.1).
    currency = opts |> Keyword.fetch!(:currency) |> String.downcase()

    with {:ok, config} <- ensure_configured(),
         {:ok, amount_cents} <- MinorUnits.to_minor_units(amount, currency) do
      params = %{
        amount: amount_cents,
        currency: currency,
        customer: payment_method.provider_customer_id,
        payment_method: payment_method.provider_payment_method_id,
        off_session: true,
        confirm: true,
        description: Keyword.get(opts, :description, "PhoenixKit subscription payment"),
        metadata:
          %{
            payment_method_uuid: to_string(payment_method.uuid)
          }
          |> maybe_merge_invoice_metadata(opts)
      }

      case stripe_request(:post, "/payment_intents", params, config) do
        {:ok, %{"id" => id, "status" => "succeeded", "latest_charge" => charge_id}} ->
          {:ok,
           %ChargeResult{
             id: id,
             provider_transaction_id: charge_id,
             amount: amount,
             currency: String.upcase(currency),
             status: "succeeded",
             metadata: %{payment_intent_id: id}
           }}

        {:ok, %{"status" => "requires_action"}} ->
          {:error, :requires_action}

        {:ok, %{"status" => "requires_payment_method"}} ->
          {:error, :card_declined}

        {:error, %{"code" => "card_declined"}} ->
          {:error, :card_declined}

        {:error, %{"code" => "expired_card"}} ->
          {:error, :payment_method_expired}

        {:error, reason} ->
          Logger.error("Stripe charge failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Verifies Stripe webhook signature.

  Uses Stripe's signature verification to ensure the webhook came from Stripe.

  ## Examples

      iex> verify_webhook_signature(raw_body, signature_header, webhook_secret)
      :ok

      iex> verify_webhook_signature(raw_body, "invalid", webhook_secret)
      {:error, :invalid_signature}
  """
  @impl true
  def verify_webhook_signature(payload, signature, secret) do
    # Stripe signature format: t=timestamp,v1=signature
    with {:ok, parts} <- parse_signature(signature),
         {:ok, timestamp} <- Map.fetch(parts, "t"),
         {:ok, expected_sig} <- Map.fetch(parts, "v1"),
         :ok <- verify_timestamp(timestamp),
         :ok <- verify_signature(payload, timestamp, expected_sig, secret) do
      :ok
    else
      _ -> {:error, :invalid_signature}
    end
  end

  @doc """
  Handles and normalizes Stripe webhook events.

  ## Supported Events

  - `checkout.session.completed` - Checkout payment completed
  - `checkout.session.expired` - Checkout session expired
  - `payment_intent.succeeded` - Payment intent succeeded
  - `payment_intent.payment_failed` - Payment failed
  - `charge.refunded` - Charge refunded
  - `setup_intent.succeeded` - Setup intent completed (card saved)

  ## Examples

      iex> handle_webhook_event(%{"type" => "checkout.session.completed", ...})
      {:ok, %{type: "checkout.completed", event_id: "evt_...", data: %{...}}}
  """
  @impl true
  def handle_webhook_event(%{"type" => type, "id" => event_id, "data" => %{"object" => object}}) do
    case normalize_event(type, object) do
      {:ok, normalized} ->
        {:ok,
         %WebhookEventData{
           type: normalized.type,
           event_id: event_id,
           data: normalized.data,
           provider: :stripe,
           raw_payload: object
         }}

      {:error, :unknown_event} ->
        Logger.debug("Unknown Stripe event type: #{type}")
        {:error, :unknown_event}
    end
  end

  def handle_webhook_event(_payload) do
    {:error, :invalid_payload}
  end

  @doc """
  Creates a refund for a Stripe payment.

  `provider_transaction_id` is the id the payment was recorded under: a
  charge (`ch_…`, as saved-card charges are recorded) or a PaymentIntent
  (`pi_…`, as Checkout payments are recorded). Stripe takes the two as
  different parameters, so the id decides which one is sent.

  This only creates the refund at Stripe. Record it in the ledger with
  `PhoenixKitBilling.record_refund/3`, passing `payment_method: "stripe"` and
  the returned `provider_refund_id` as `provider_transaction_id`: the webhook
  that follows counts only refunds of the same payment method toward what the
  ledger already holds, and `record_refund/3` defaults to `"bank"` - a refund
  recorded under that default is recorded a second time when Stripe reports it.

  ## Options

  - `:currency` - Currency code, required only when `amount` is given (a
    full refund needs none) — used to convert `amount` to Stripe's minor
    unit; never sent to Stripe itself, since a refund's currency is fixed
    by the charge it reverses
  - `:reason` - Reason for refund ("duplicate", "fraudulent", "requested_by_customer")
  - `:metadata` - Additional metadata

  ## Examples

      iex> create_refund("ch_xxx", Decimal.new("50.00"), currency: "EUR", reason: "requested_by_customer")
      {:ok, %{id: "re_...", provider_refund_id: "re_...", amount: #Decimal<50.00>}}
  """
  @impl true
  def create_refund(provider_transaction_id, amount, opts) do
    with {:ok, config} <- ensure_configured(),
         {:ok, params} <- build_refund_params(provider_transaction_id, amount, opts) do
      case stripe_request(:post, "/refunds", params, config) do
        {:ok, %{"id" => id, "amount" => amount_cents, "currency" => currency, "status" => status}} ->
          with {:ok, refunded_amount} <- MinorUnits.from_minor_units(amount_cents, currency) do
            {:ok,
             %RefundResult{
               id: id,
               provider_refund_id: id,
               amount: refunded_amount,
               status: status,
               metadata: %{}
             }}
          end

        {:ok, unexpected} ->
          Logger.error("Stripe refund response missing an expected field: #{inspect(unexpected)}")
          {:error, :unexpected_response}

        {:error, %{"code" => "charge_already_refunded"}} ->
          {:error, :already_refunded}

        {:error, reason} ->
          Logger.error("Stripe refund failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp build_refund_params(provider_transaction_id, amount, opts) do
    with {:ok, params} <-
           maybe_put_refund_amount(refund_target(provider_transaction_id), amount, opts) do
      {:ok, maybe_put_refund_reason(params, opts)}
    end
  end

  # A PaymentIntent id sent as `charge` is answered with "No such charge".
  defp refund_target("pi_" <> _ = payment_intent_id), do: %{payment_intent: payment_intent_id}
  defp refund_target(charge_id), do: %{charge: charge_id}

  defp maybe_put_refund_amount(params, nil, _opts), do: {:ok, params}

  defp maybe_put_refund_amount(params, amount, opts) do
    currency = Keyword.fetch!(opts, :currency)

    with {:ok, amount_cents} <- MinorUnits.to_minor_units(amount, currency) do
      {:ok, Map.put(params, :amount, amount_cents)}
    end
  end

  defp maybe_put_refund_reason(params, opts) do
    case Keyword.get(opts, :reason) do
      nil -> params
      reason -> Map.put(params, :reason, reason)
    end
  end

  @doc """
  Gets details of a saved payment method from Stripe.

  ## Examples

      iex> get_payment_method_details("pm_xxx")
      {:ok, %{id: "pm_xxx", type: "card", brand: "visa", last4: "4242", ...}}
  """
  @impl true
  def get_payment_method_details(provider_payment_method_id) do
    with {:ok, config} <- ensure_configured() do
      case stripe_request(:get, "/payment_methods/#{provider_payment_method_id}", nil, config) do
        {:ok,
         %{
           "id" => id,
           "type" => type,
           "card" => %{
             "brand" => brand,
             "last4" => last4,
             "exp_month" => exp_month,
             "exp_year" => exp_year
           }
         }} ->
          {:ok,
           %PaymentMethodInfo{
             id: id,
             provider: :stripe,
             provider_payment_method_id: id,
             provider_customer_id: nil,
             type: type,
             brand: brand,
             last4: last4,
             exp_month: exp_month,
             exp_year: exp_year,
             metadata: %{}
           }}

        {:ok, %{"id" => id, "type" => type}} ->
          {:ok,
           %PaymentMethodInfo{
             id: id,
             provider: :stripe,
             provider_payment_method_id: id,
             provider_customer_id: nil,
             type: type,
             brand: nil,
             last4: nil,
             exp_month: nil,
             exp_year: nil,
             metadata: %{}
           }}

        {:error, %{"code" => "resource_missing"}} ->
          {:error, :not_found}

        {:error, reason} ->
          Logger.error("Stripe get payment method failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Detaches a payment method from its customer.

  ## Examples

      iex> detach_payment_method("pm_xxx")
      :ok
  """
  @impl true
  def detach_payment_method(provider_payment_method_id) do
    with {:ok, config} <- ensure_configured() do
      case stripe_request(
             :post,
             "/payment_methods/#{provider_payment_method_id}/detach",
             %{},
             config
           ) do
        {:ok, _} -> :ok
        {:error, %{"code" => "resource_missing"}} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ===========================================
  # Private Helpers
  # ===========================================

  defp get_config do
    %{
      enabled: Settings.get_setting("billing_stripe_enabled", "false") == "true",
      api_key: stripe_secret_key(),
      webhook_secret: Settings.get_setting("billing_stripe_webhook_secret", "")
    }
  end

  # The admin UI persists the Stripe secret under `billing_stripe_secret_key`
  # (matching Stripe's own naming). Older/hand-rolled configs may have used
  # `billing_stripe_api_key`; fall back to it so those hosts keep working
  # without a manual data migration.
  defp stripe_secret_key do
    case Settings.get_setting("billing_stripe_secret_key", "") do
      "" -> Settings.get_setting("billing_stripe_api_key", "")
      key -> key
    end
  end

  defp ensure_configured do
    config = get_config()

    if config[:enabled] and is_binary(config[:api_key]) and config[:api_key] != "" do
      {:ok, config}
    else
      {:error, :not_configured}
    end
  end

  defp stripe_request(method, path, body, config) do
    url = "https://api.stripe.com/v1#{path}"

    headers = [
      {"Authorization", "Bearer #{config[:api_key]}"},
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Stripe-Version", @stripe_api_version}
    ]

    body_encoded = if body, do: encode_body(body), else: ""

    # TEST-ONLY seam: `:stripe_req_options` is never set in any shipped
    # config - this merge is a no-op in production. It lets tests point the
    # request at a `Req.Test` stub and read the form body Stripe would get.
    # Whoever can write Application env for this node already controls far
    # bigger levers, so the key does not widen what such an attacker can do.
    # Same shape as `:paypal_req_options`.
    extra_opts = Application.get_env(:phoenix_kit_billing, :stripe_req_options, [])

    request_opts =
      case method do
        :get -> [method: :get, url: url, headers: headers]
        :post -> [method: :post, url: url, headers: headers, body: body_encoded]
      end

    request = request_opts |> Keyword.merge(extra_opts) |> Req.new()

    case Req.request(request) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: _status, body: %{"error" => error}}} ->
        {:error, error}

      {:ok, %{status: status, body: body}} ->
        {:error, %{"status" => status, "body" => body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp encode_body(map) when is_map(map) do
    map
    |> flatten_map()
    |> URI.encode_query()
  end

  defp flatten_map(map, prefix \\ "") do
    Enum.flat_map(map, fn {key, value} ->
      new_key = if prefix == "", do: to_string(key), else: "#{prefix}[#{key}]"
      flatten_value(new_key, value)
    end)
  end

  defp flatten_value(key, %{} = nested), do: flatten_map(nested, key)

  defp flatten_value(key, list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, idx} -> flatten_list_item(key, item, idx) end)
  end

  defp flatten_value(key, value), do: [{key, to_string(value)}]

  defp flatten_list_item(key, item, idx) when is_map(item) do
    flatten_map(item, "#{key}[#{idx}]")
  end

  defp flatten_list_item(key, item, idx) do
    [{"#{key}[#{idx}]", to_string(item)}]
  end

  # Stripe charges the sum of the line items, while the invoice is paid by
  # `total - paid_amount`, which also carries tax, discount and shipping that
  # are not line items. When the two differ (tax, a discount, a part payment)
  # the session is one line for the amount due, so Stripe takes exactly what
  # the webhook will book.
  defp build_line_items(invoice) do
    currency =
      invoice.currency || raise(ArgumentError, "invoice #{invoice.uuid} has no currency")

    with {:ok, items} <- item_lines(invoice, currency),
         {:ok, due} <- amount_due(invoice, currency),
         :ok <- ensure_positive(due) do
      if line_items_total(items) == due,
        do: {:ok, items},
        else: {:ok, [amount_due_line(invoice, currency, due)]}
    end
  end

  defp ensure_positive(due) when due > 0, do: :ok
  defp ensure_positive(_due), do: {:error, :nothing_to_pay}

  defp item_lines(invoice, currency) do
    (invoice.line_items || [])
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case MinorUnits.to_minor_units(parse_decimal_amount(item["unit_price"]), currency) do
        {:ok, unit_amount} ->
          line_item = %{
            price_data: %{
              currency: String.downcase(currency),
              product_data: %{
                name: item["name"] || "Item"
              },
              unit_amount: unit_amount
            },
            quantity: item["quantity"] || 1
          }

          {:cont, {:ok, [line_item | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, _reason} = error -> error
    end
  end

  defp amount_due(invoice, currency) do
    paid = parse_decimal_amount(Map.get(invoice, :paid_amount))
    due = Decimal.sub(parse_decimal_amount(Map.get(invoice, :total)), paid)
    MinorUnits.to_minor_units(due, currency)
  end

  # A non-integer quantity cannot be summed in minor units; it counts as "the
  # lines do not add up", so the amount due is charged as one line.
  defp line_items_total(items) do
    Enum.reduce_while(items, 0, fn item, sum ->
      case item.quantity do
        quantity when is_integer(quantity) ->
          {:cont, sum + item.price_data.unit_amount * quantity}

        _ ->
          {:halt, :unknown}
      end
    end)
  end

  defp amount_due_line(invoice, currency, due) do
    %{
      price_data: %{
        currency: String.downcase(currency),
        product_data: %{name: "Invoice #{invoice.invoice_number}"},
        unit_amount: due
      },
      quantity: 1
    }
  end

  defp parse_decimal_amount(nil), do: Decimal.new(0)
  defp parse_decimal_amount(%Decimal{} = amount), do: amount
  defp parse_decimal_amount(amount) when is_binary(amount), do: Decimal.new(amount)
  defp parse_decimal_amount(amount) when is_number(amount), do: Decimal.from_float(amount * 1.0)

  defp maybe_add_customer_email(params, invoice, opts) do
    email = Keyword.get(opts, :customer_email) || get_invoice_email(invoice)

    if email do
      Map.put(params, :customer_email, email)
    else
      params
    end
  end

  defp get_invoice_email(invoice) do
    case invoice do
      %{billing_details: %{"email" => email}} when is_binary(email) -> email
      %{user: %{email: email}} when is_binary(email) -> email
      _ -> nil
    end
  end

  defp maybe_add_save_payment_method(params, opts) do
    if Keyword.get(opts, :save_payment_method, false) do
      Map.merge(params, %{
        payment_intent_data: %{
          setup_future_usage: "off_session"
        }
      })
    else
      params
    end
  end

  defp maybe_add_custom_metadata(params, opts) do
    case Keyword.get(opts, :metadata) do
      nil -> params
      custom -> Map.update!(params, :metadata, &Map.merge(&1, custom))
    end
  end

  defp maybe_merge_invoice_metadata(metadata, opts) do
    case Keyword.get(opts, :invoice_uuid) do
      nil -> metadata
      invoice_uuid -> Map.put(metadata, :invoice_uuid, to_string(invoice_uuid))
    end
  end

  defp ensure_customer(user, config) do
    # Check if user already has a Stripe customer ID from saved payment methods
    case get_stripe_customer_id_for_user(user.uuid) do
      nil ->
        # Create new customer
        params = %{
          email: user.email,
          metadata: %{
            user_uuid: to_string(user.uuid)
          }
        }

        case stripe_request(:post, "/customers", params, config) do
          {:ok, %{"id" => customer_id}} ->
            {:ok, customer_id}

          {:error, reason} ->
            {:error, reason}
        end

      customer_id ->
        {:ok, customer_id}
    end
  end

  defp get_stripe_customer_id_for_user(user_uuid) do
    import Ecto.Query

    query =
      from(pm in PhoenixKitBilling.PaymentMethod,
        where: pm.user_uuid == ^user_uuid,
        where: pm.provider == "stripe",
        where: not is_nil(pm.provider_customer_id),
        where: pm.status == "active",
        select: pm.provider_customer_id,
        limit: 1
      )

    PhoenixKit.RepoHelper.repo().one(query)
  end

  defp parse_signature(signature) do
    parts =
      signature
      |> String.split(",")
      |> Enum.map(fn part ->
        case String.split(part, "=", parts: 2) do
          [key, value] -> {key, value}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    {:ok, parts}
  rescue
    _ -> {:error, :invalid_format}
  end

  defp verify_timestamp(timestamp) do
    # Stripe recommends rejecting webhooks older than 5 minutes
    timestamp_int = String.to_integer(timestamp)
    now = System.system_time(:second)
    tolerance = 300

    if abs(now - timestamp_int) <= tolerance do
      :ok
    else
      {:error, :timestamp_too_old}
    end
  rescue
    _ -> {:error, :invalid_timestamp}
  end

  defp verify_signature(payload, timestamp, expected_sig, secret) do
    signed_payload = "#{timestamp}.#{payload}"

    computed_sig =
      :crypto.mac(:hmac, :sha256, secret, signed_payload) |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(computed_sig, expected_sig) do
      :ok
    else
      {:error, :signature_mismatch}
    end
  end

  # `amount_total` / `amount` / `amount_refunded_total` below are Stripe's OWN
  # raw minor-unit integers, passed through unconverted — Stripe already
  # reports these at ITS OWN currency-correct scale (a JPY charge comes
  # back as "1000", not "100000"), so no conversion belongs here. The
  # `currency` carried alongside each one is what lets
  # `utils/webhook_processor.ex` convert them back to a shop-side Decimal
  # correctly for any currency, not just two-decimal ones (§7/E5).
  defp normalize_event("checkout.session.completed", object) do
    {:ok,
     %{
       type: "checkout.completed",
       data: %{
         session_id: object["id"],
         payment_status: object["payment_status"],
         customer_id: object["customer"],
         customer_email: object["customer_email"],
         payment_intent_id: object["payment_intent"],
         setup_intent_id: object["setup_intent"],
         invoice_uuid:
           get_in(object, ["metadata", "invoice_uuid"]) ||
             get_in(object, ["metadata", "invoice_id"]),
         mode: object["mode"],
         amount_total: object["amount_total"],
         currency: object["currency"]
       }
     }}
  end

  defp normalize_event("checkout.session.expired", object) do
    {:ok,
     %{
       type: "checkout.expired",
       data: %{
         session_id: object["id"],
         invoice_uuid:
           get_in(object, ["metadata", "invoice_uuid"]) ||
             get_in(object, ["metadata", "invoice_id"])
       }
     }}
  end

  defp normalize_event("payment_intent.succeeded", object) do
    {:ok,
     %{
       type: "payment.succeeded",
       data: %{
         payment_intent_id: object["id"],
         charge_id: object["latest_charge"],
         amount: object["amount"],
         currency: object["currency"],
         customer_id: object["customer"],
         provider_payment_method_id: object["payment_method"],
         invoice_uuid:
           get_in(object, ["metadata", "invoice_uuid"]) ||
             get_in(object, ["metadata", "invoice_id"])
       }
     }}
  end

  defp normalize_event("payment_intent.payment_failed", object) do
    {:ok,
     %{
       type: "payment.failed",
       data: %{
         payment_intent_id: object["id"],
         error_code: get_in(object, ["last_payment_error", "code"]),
         error_message: get_in(object, ["last_payment_error", "message"]),
         customer_id: object["customer"],
         invoice_uuid:
           get_in(object, ["metadata", "invoice_uuid"]) ||
             get_in(object, ["metadata", "invoice_id"])
       }
     }}
  end

  # A Charge's `amount_refunded` is the running total refunded on it, not
  # the amount of the refund that raised this event - hence
  # `amount_refunded_total`, which the processor reduces to the part not yet
  # in the ledger. `payment_intent` is what ties the charge to a Checkout
  # payment, which is recorded under the PaymentIntent id and has no charge id.
  defp normalize_event("charge.refunded", object) do
    {:ok,
     %{
       type: "refund.created",
       data: %{
         charge_id: object["id"],
         payment_intent_id: object["payment_intent"],
         amount_refunded_total: object["amount_refunded"],
         currency: object["currency"],
         refund_id: latest_refund_id(object)
       }
     }}
  end

  defp normalize_event("setup_intent.succeeded", object) do
    {:ok,
     %{
       type: "setup.completed",
       data: %{
         setup_intent_id: object["id"],
         provider_payment_method_id: object["payment_method"],
         customer_id: object["customer"],
         user_uuid:
           get_in(object, ["metadata", "user_uuid"]) ||
             get_in(object, ["metadata", "user_id"])
       }
     }}
  end

  defp normalize_event(_type, _object) do
    {:error, :unknown_event}
  end

  # Stripe's Charge reference lists `refunds` as "not returned by default"
  # (newest first when present), so this is usually nil: the refund id is
  # then unknown.
  defp latest_refund_id(%{"refunds" => %{"data" => [%{"id" => id} | _]}}), do: id
  defp latest_refund_id(_charge), do: nil
end
