defmodule PhoenixKitBilling.Providers.EveryPay do
  @moduledoc """
  EveryPay payment provider implementation.

  Implements the `PhoenixKitBilling.Providers.Provider` behaviour for the
  EveryPay (EveryPay AS, Estonia/Baltics) Payment Gateway, API v4. It supports:

  - Hosted payment page for one-time payments (`/payments/oneoff`)
  - Charging saved card tokens for subscription renewals (`/payments/mit`)
  - Refunds (`/payments/:reference/refund`)
  - Server-side payment-status verification of callbacks

  ## Configuration

  Configure EveryPay in your provider settings:

      # Via Admin UI: /admin/settings/billing/providers
      # Or via Settings API:
      PhoenixKit.Settings.update_setting("billing_everypay_enabled", "true")
      PhoenixKit.Settings.update_setting("billing_everypay_api_username", "...")
      PhoenixKit.Settings.update_setting("billing_everypay_api_secret", "...")
      PhoenixKit.Settings.update_setting("billing_everypay_account_name", "EUR3D1")
      PhoenixKit.Settings.update_setting("billing_everypay_mode", "test")

  - `mode` is `"test"` (demo gateway) or `"live"` (production gateway).
  - `account_name` is the EveryPay processing account; it also fixes the
    currency, so EveryPay one-off requests do not send a currency.

  ## Webhook / Callback Verification

  EveryPay v4 callbacks are **not** HMAC-signed. Instead of trusting the
  callback payload, this provider re-fetches the authoritative payment record
  from the API (`GET /payments/:reference`) using HTTP Basic auth and
  normalizes that. See `PhoenixKitBilling.Web.WebhookController.everypay/2`.

  Configure the callback URL in the EveryPay merchant portal
  (E-shop settings -> Callback URL):

      https://yourdomain.com/phoenix_kit/webhooks/billing/everypay

  ## Dependencies

  Uses `Req` for HTTP requests (already a dependency of this package).
  """

  @behaviour PhoenixKitBilling.Providers.Provider

  alias PhoenixKitBilling.Providers.Types.{
    ChargeResult,
    CheckoutSession,
    RefundResult,
    WebhookEventData
  }

  alias PhoenixKit.Settings
  alias PhoenixKitBilling.Providers.MinorUnits

  require Logger

  @live_base_url "https://pay.every-pay.eu"
  @demo_base_url "https://igw-demo.every-pay.com"
  @api_path "/api/v4"

  # EveryPay payment_state values, grouped by how they are normalized.
  @success_states ~w(settled authorized)
  @failure_states ~w(failed abandoned voided)
  @refund_states ~w(refunded partially_refunded)

  # Provider identification
  @impl true
  def provider_name, do: :everypay

  @impl true
  def available?, do: configured?(get_config())

  @doc """
  Creates an EveryPay one-off payment and returns the hosted payment page URL.

  The invoice's remaining balance is charged in the currency fixed by the
  configured processing account.

  ## Options

  - `:success_url` - URL EveryPay redirects the customer back to (required).
    EveryPay uses a single `customer_url` for both success and cancel; the
    return page must verify the payment state.
  - `:customer_ip` - Customer IP address (recommended for fraud scoring)
  - `:customer_email` - Pre-fill / attach customer email
  - `:locale` - Payment page locale (e.g. `"en"`, `"et"`)
  - `:save_payment_method` - Request a reusable card token (default: false)

  ## Examples

      iex> create_checkout_session(invoice, success_url: "https://...")
      {:ok, %CheckoutSession{id: "abc-123", url: "https://.../payment?..."}}
  """
  @impl true
  def create_checkout_session(invoice, opts) do
    due = Decimal.sub(invoice.total, Map.get(invoice, :paid_amount) || Decimal.new(0))

    with {:ok, config} <- ensure_configured(),
         :ok <- ensure_positive_amount(due),
         {:ok, amount} <- decimal_to_amount(due, invoice.currency) do
      params =
        %{
          api_username: config[:api_username],
          account_name: config[:account_name],
          amount: amount,
          order_reference: to_string(invoice.uuid),
          nonce: generate_nonce(),
          timestamp: timestamp(),
          customer_url: Keyword.fetch!(opts, :success_url)
        }
        |> maybe_put(:customer_ip, Keyword.get(opts, :customer_ip))
        |> maybe_put(:email, Keyword.get(opts, :customer_email) || invoice_email(invoice))
        |> maybe_put(:locale, Keyword.get(opts, :locale))
        |> maybe_request_token(opts)

      case everypay_request(:post, "/payments/oneoff", params, config) do
        {:ok, %{"payment_link" => url, "payment_reference" => reference} = body} ->
          {:ok,
           %CheckoutSession{
             id: reference,
             url: url,
             provider: :everypay,
             expires_at: nil,
             metadata: %{invoice_uuid: invoice.uuid, payment_state: body["payment_state"]}
           }}

        {:ok, body} ->
          Logger.error("EveryPay oneoff response missing payment_link: #{inspect(body)}")
          {:error, :invalid_response}

        {:error, reason} ->
          Logger.error("EveryPay checkout session creation failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Not supported by EveryPay.

  EveryPay has no zero-amount "save card" flow; a card token is obtained as a
  side effect of a one-off payment when `:save_payment_method` is set. Returns
  `{:error, :not_supported}`.
  """
  @impl true
  def create_setup_session(_user, _opts), do: {:error, :not_supported}

  @doc """
  Charges a saved EveryPay card token (merchant-initiated transaction).

  Used for subscription renewals. The token is stored on the payment method as
  `provider_payment_method_id` during a one-off payment with
  `:save_payment_method` enabled.

  ## Options

  - `:description` - Description for the charge
  - `:invoice_uuid` - Associated invoice UUID (used as `order_reference`)

  ## Examples

      iex> charge_payment_method(payment_method, Decimal.new("99.00"), invoice_uuid: uuid)
      {:ok, %ChargeResult{provider_transaction_id: "abc-123", status: "succeeded"}}
  """
  @impl true
  def charge_payment_method(payment_method, amount, opts) do
    with {:ok, config} <- ensure_configured() do
      order_reference =
        case Keyword.get(opts, :invoice_uuid) do
          nil -> to_string(payment_method.uuid)
          invoice_uuid -> to_string(invoice_uuid)
        end

      params = %{
        api_username: config[:api_username],
        account_name: config[:account_name],
        amount: decimal_to_amount(amount),
        order_reference: order_reference,
        nonce: generate_nonce(),
        timestamp: timestamp(),
        token: payment_method.provider_payment_method_id,
        token_agreement: "recurring"
      }

      case everypay_request(:post, "/payments/mit", params, config) do
        {:ok, %{"payment_state" => state, "payment_reference" => reference} = body}
        when state in @success_states ->
          {:ok,
           %ChargeResult{
             id: reference,
             provider_transaction_id: reference,
             amount: amount,
             currency: body["currency"],
             status: "succeeded",
             metadata: %{payment_state: state}
           }}

        {:ok, %{"payment_state" => "failed"}} ->
          {:error, :card_declined}

        {:ok, %{"payment_state" => state}} ->
          Logger.error("EveryPay MIT charge returned unexpected state: #{state}")
          {:error, {:unexpected_state, state}}

        {:error, reason} ->
          Logger.error("EveryPay MIT charge failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  EveryPay v4 callbacks are not signed; verification is done by re-fetching the
  payment status server-side. Always returns `:ok`.

  See `fetch_payment/1` and `PhoenixKitBilling.Web.WebhookController.everypay/2`.
  """
  @impl true
  def verify_webhook_signature(_payload, _signature, _secret), do: :ok

  @doc """
  Normalizes an EveryPay payment record (as returned by `fetch_payment/1`) into
  a `WebhookEventData` struct for `PhoenixKitBilling.WebhookProcessor`.

  The payment `payment_state` drives the normalized event type:

  - `settled` -> `checkout.completed`
  - `failed` / `abandoned` / `voided` -> `payment.failed`
  - `refunded` / `partially_refunded` -> `refund.created`
  - any other state -> `{:error, :unknown_event}` (ignored)
  """
  @impl true
  def handle_webhook_event(
        %{"payment_reference" => reference, "payment_state" => state} = payment
      ) do
    case normalize_payment(state, payment) do
      {:ok, normalized} ->
        {:ok,
         %WebhookEventData{
           type: normalized.type,
           event_id: "#{reference}:#{state}",
           data: normalized.data,
           provider: :everypay,
           raw_payload: payment
         }}

      {:error, :unknown_event} ->
        Logger.debug("EveryPay payment in non-final state: #{state}")
        {:error, :unknown_event}
    end
  end

  def handle_webhook_event(_payload), do: {:error, :invalid_payload}

  @doc """
  Creates a refund for an EveryPay payment.

  `provider_transaction_id` is the EveryPay `payment_reference`. Pass `nil` as
  `amount` for a full refund.

  ## Examples

      iex> create_refund("abc-123", Decimal.new("10.00"), [])
      {:ok, %RefundResult{provider_refund_id: "abc-123", status: "refunded"}}
  """
  @impl true
  def create_refund(provider_transaction_id, amount, _opts) do
    with {:ok, config} <- ensure_configured() do
      params =
        %{
          api_username: config[:api_username],
          nonce: generate_nonce(),
          timestamp: timestamp()
        }
        |> maybe_put(:amount, amount && decimal_to_amount(amount))

      path = "/payments/#{provider_transaction_id}/refund"

      case everypay_request(:post, path, params, config) do
        {:ok, %{"payment_state" => state, "payment_reference" => reference} = body}
        when state in @refund_states ->
          {:ok,
           %RefundResult{
             id: reference,
             provider_refund_id: reference,
             amount: amount || to_decimal(refunded_amount(body)),
             status: "refunded",
             metadata: %{payment_state: state}
           }}

        {:ok, %{"payment_state" => state}} ->
          Logger.error("EveryPay refund returned unexpected state: #{state}")
          {:error, {:unexpected_state, state}}

        {:error, reason} ->
          Logger.error("EveryPay refund failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Not supported by EveryPay.

  EveryPay exposes no standalone payment-method API; card tokens are only
  available on the originating payment. Returns `{:error, :not_supported}`.
  """
  @impl true
  def get_payment_method_details(_provider_payment_method_id), do: {:error, :not_supported}

  @doc """
  Fetches the authoritative payment record from EveryPay.

  Used by the webhook controller to verify callbacks server-side. Returns the
  raw decoded payment map (string keys) on success.

  ## Examples

      iex> fetch_payment("abc-123")
      {:ok, %{"payment_reference" => "abc-123", "payment_state" => "settled", ...}}
  """
  @spec fetch_payment(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_payment(payment_reference) do
    with {:ok, config} <- ensure_configured() do
      query = URI.encode_query(%{"api_username" => config[:api_username]})

      case everypay_request(:get, "/payments/#{payment_reference}?#{query}", nil, config) do
        {:ok, %{"payment_reference" => _} = payment} -> {:ok, payment}
        {:ok, body} -> {:error, {:invalid_response, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ===========================================
  # Private Helpers
  # ===========================================

  defp get_config do
    %{
      enabled: Settings.get_setting("billing_everypay_enabled", "false") == "true",
      api_username: Settings.get_setting("billing_everypay_api_username", ""),
      api_secret: Settings.get_setting("billing_everypay_api_secret", ""),
      account_name: Settings.get_setting("billing_everypay_account_name", ""),
      mode: Settings.get_setting("billing_everypay_mode", "test")
    }
  end

  defp ensure_configured do
    config = get_config()
    if configured?(config), do: {:ok, config}, else: {:error, :not_configured}
  end

  defp configured?(config) do
    config[:enabled] && present?(config[:api_username]) && present?(config[:api_secret]) &&
      present?(config[:account_name])
  end

  defp base_url(%{mode: "live"}), do: @live_base_url
  defp base_url(_config), do: @demo_base_url

  defp everypay_request(method, path, body, config) do
    url = base_url(config) <> @api_path <> path

    options =
      [
        method: method,
        url: url,
        auth: {:basic, "#{config[:api_username]}:#{config[:api_secret]}"},
        decode_json: [keys: :strings],
        receive_timeout: 30_000,
        # Charges and refunds are not idempotent — never let Req silently retry.
        retry: false
      ]
      |> maybe_put_json(body)
      # Same test transport seam as Stripe and PayPal; unset in production.
      |> Keyword.merge(Application.get_env(:phoenix_kit_billing, :everypay_req_options, []))

    case Req.request(options) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        {:error, %{"status" => status, "body" => response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_json(options, nil), do: options
  defp maybe_put_json(options, body), do: Keyword.put(options, :json, body)

  defp ensure_positive_amount(amount) do
    if Decimal.positive?(amount), do: :ok, else: {:error, :nothing_to_pay}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_request_token(params, opts) do
    if Keyword.get(opts, :save_payment_method, false) do
      params
      |> Map.put(:request_token, true)
      |> Map.put(:token_consent_agreement, "recurring")
    else
      params
    end
  end

  defp generate_nonce do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp present?(value), do: is_binary(value) and value != ""

  # `create_checkout_session/2` has the invoice's own currency on hand, so
  # this rounds/validates against ITS `decimal_places` the way
  # `MinorUnits` does for every other provider (§2.6/§7, E5) — a
  # hard-coded 2 here silently padded a zero-decimal currency and
  # silently dropped a three-decimal one's third digit. Refuses rather
  # than drops: `to_minor_units_and_places/2` already errors on a
  # fraction the currency cannot represent.
  defp decimal_to_amount(%Decimal{} = amount, currency_code) when is_binary(currency_code) do
    with {:ok, _minor_units, places} <-
           MinorUnits.to_minor_units_and_places(amount, currency_code) do
      {:ok, amount |> Decimal.round(places) |> Decimal.to_float()}
    end
  end

  # `charge_payment_method/3` and `create_refund/3` have NO currency to
  # check against here: EveryPay's account fixes the currency
  # server-side, and neither a saved payment method nor a bare refund
  # amount carries one at these call sites — inventing one (the shop's
  # base currency, say) would be exactly the kind of guess §7/E5 forbids,
  # since nothing here confirms it matches the account's actual currency.
  # Rounding to a hard-coded 2 before this fix silently dropped a
  # three-decimal currency's third digit; sending the caller's own
  # `Decimal` precision unrounded is the honest alternative — a caller
  # with a legitimately different precision must decide its own
  # rounding, not have one guessed here.
  defp decimal_to_amount(%Decimal{} = amount) do
    Decimal.to_float(amount)
  end

  defp decimal_to_amount(amount) when is_number(amount), do: amount

  defp invoice_email(invoice) do
    case invoice do
      %{billing_details: %{"email" => email}} when is_binary(email) -> email
      %{user: %{email: email}} when is_binary(email) -> email
      _ -> nil
    end
  end

  defp normalize_payment(state, payment) when state in @success_states do
    {:ok,
     %{
       type: "checkout.completed",
       data: %{
         mode: "payment",
         provider: :everypay,
         session_id: payment["payment_reference"],
         charge_id: payment["payment_reference"],
         invoice_uuid: payment["order_reference"],
         payment_state: state,
         amount: amount_cents(payment["amount"], payment["currency"]),
         currency: payment["currency"]
       }
     }}
  end

  defp normalize_payment(state, payment) when state in @failure_states do
    {:ok,
     %{
       type: "payment.failed",
       data: %{
         provider: :everypay,
         invoice_uuid: payment["order_reference"],
         error_code: state,
         error_message: payment["processing_errors"] || payment["error"]
       }
     }}
  end

  defp normalize_payment(state, payment) when state in @refund_states do
    {:ok,
     %{
       type: "refund.created",
       data: %{
         provider: :everypay,
         charge_id: payment["payment_reference"],
         refund_id: payment["payment_reference"],
         amount: amount_cents(refunded_amount(payment), payment["currency"]),
         currency: payment["currency"]
       }
     }}
  end

  defp normalize_payment(_state, _payment), do: {:error, :unknown_event}

  # The processor expects an integer provider minor unit, converted via
  # `currency`'s own `decimal_places` (§7/E5) — a fixed ×100 here would
  # silently mismatch `utils/webhook_processor.ex`'s currency-aware
  # `MinorUnits.from_minor_units/2` on the other end. `nil` on a missing
  # amount, a missing currency, an unrecognized currency code, or more
  # precision than the currency allows — never a guessed factor — so the
  # processor's `is_integer(...)` guard misses it and falls back to the
  # invoice's own balance instead of a wrong number.
  defp amount_cents(nil, _currency), do: nil
  defp amount_cents(_amount, nil), do: nil

  defp amount_cents(amount, currency) when is_number(amount) do
    amount |> Decimal.from_float() |> amount_cents(currency)
  end

  defp amount_cents(amount, currency) when is_binary(amount) do
    amount |> Decimal.new() |> amount_cents(currency)
  end

  defp amount_cents(%Decimal{} = amount, currency) when is_binary(currency) do
    case MinorUnits.to_minor_units(amount, currency) do
      {:ok, minor_units} -> minor_units
      {:error, _reason} -> nil
    end
  end

  defp refunded_amount(payment) do
    case payment["refunds"] do
      refunds when is_list(refunds) and refunds != [] ->
        refunds
        |> Enum.map(&to_decimal(&1["amount"]))
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

      _ ->
        payment["refunded_amount"] || payment["amount"]
    end
  end

  defp to_decimal(nil), do: Decimal.new(0)
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)
  defp to_decimal(%Decimal{} = value), do: value
end
