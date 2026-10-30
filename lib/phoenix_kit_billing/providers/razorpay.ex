defmodule PhoenixKitBilling.Providers.Razorpay do
  @moduledoc """
  Razorpay payment provider implementation.

  Razorpay is a popular payment gateway in India. Uses their REST API for:
  - Payment Links (hosted checkout)
  - Orders API
  - Customers and Tokens (saved payment methods)
  - Refunds

  ## Configuration

  Required settings in database:
  - `billing_razorpay_enabled` - "true" to enable
  - `billing_razorpay_key_id` - Razorpay Key ID
  - `billing_razorpay_key_secret` - Razorpay Key Secret
  - `billing_razorpay_webhook_secret` - Webhook secret for signature verification

  ## Razorpay Flow

  1. Create Order with amount and currency
  2. Create Payment Link or use Checkout.js
  3. User completes payment on Razorpay
  4. Razorpay sends webhook on payment success
  5. Verify signature and process payment

  ## Webhook Events

  - `payment.authorized` - Payment authorized (for 2-step payments)
  - `payment.captured` - Payment captured successfully
  - `payment.failed` - Payment failed
  - `refund.created` - Refund initiated
  - `refund.processed` - Refund completed

  ## Currency Support

  Primary currency is INR. International payments supported with:
  USD, EUR, GBP, SGD, AED, CAD, CNY, SEK, NZD, MXN, etc.
  """

  @behaviour PhoenixKitBilling.Providers.Provider

  alias PhoenixKitBilling.Providers.Types.{
    ChargeResult,
    CheckoutSession,
    PaymentMethodInfo,
    RefundResult,
    WebhookEventData
  }

  alias PhoenixKit.Settings
  alias PhoenixKitBilling.Providers.MinorUnits

  require Logger

  @base_url "https://api.razorpay.com"

  # ============================================
  # Provider Behaviour Implementation
  # ============================================

  @impl true
  def provider_name, do: :razorpay

  @impl true
  def available? do
    Settings.get_setting("billing_razorpay_enabled", "false") == "true" &&
      has_credentials?()
  end

  @impl true
  def create_checkout_session(invoice, opts) do
    # Merge invoice data with opts
    merged_opts = Keyword.merge(opts, invoice_to_opts(invoice))

    with :ok <- ensure_positive_amount(merged_opts[:amount]),
         {:ok, order} <- create_order(merged_opts),
         {:ok, payment_link} <- create_payment_link(order, merged_opts) do
      {:ok,
       %CheckoutSession{
         id: order["id"],
         url: payment_link["short_url"],
         provider: :razorpay,
         expires_at: payment_link["expire_by"] |> datetime_from_unix()
       }}
    end
  end

  @impl true
  def create_setup_session(_user, _opts) do
    # Razorpay doesn't have direct setup sessions like Stripe
    # We create a zero-amount authorization to save the card
    # Or use their emandate/subscription API

    # For now, return an error - implement with emandate if needed
    {:error, :not_supported}
  end

  @impl true
  def charge_payment_method(payment_method, amount, opts) do
    # Read BEFORE the request chain so a missing :currency fails even on a
    # host with no Razorpay config at all — same rule as Stripe/PayPal, and
    # a silent "INR" here would charge in a currency the invoice never
    # named (§7.1).
    _currency = Keyword.fetch!(opts, :currency)

    # Razorpay recurring payments use tokens
    token_id = payment_method.provider_payment_method_id
    customer_id = payment_method.provider_customer_id

    with {:ok, order} <- create_order_for_recurring(amount, opts),
         {:ok, payment} <- create_recurring_payment(order, token_id, customer_id, opts) do
      {:ok,
       %ChargeResult{
         id: payment["id"],
         status: payment["status"],
         amount: amount
       }}
    end
  end

  @impl true
  def verify_webhook_signature(payload, signature, secret) do
    # Razorpay uses HMAC SHA256
    expected_signature =
      :crypto.mac(:hmac, :sha256, secret, payload)
      |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(expected_signature, signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  @impl true
  def handle_webhook_event(payload) do
    event = payload["event"]
    event_payload = payload["payload"]

    case event do
      "payment.captured" ->
        handle_payment_captured(event_payload, payload)

      "payment.authorized" ->
        handle_payment_authorized(event_payload, payload)

      "payment.failed" ->
        handle_payment_failed(event_payload, payload)

      "refund.created" ->
        handle_refund_created(event_payload, payload)

      "refund.processed" ->
        handle_refund_processed(event_payload, payload)

      "order.paid" ->
        handle_order_paid(event_payload, payload)

      _ ->
        {:error, :unknown_event}
    end
  end

  @impl true
  def create_refund(provider_transaction_id, amount, opts) do
    with {:ok, refund} <- do_create_refund(provider_transaction_id, amount, opts) do
      {:ok,
       %RefundResult{
         id: refund["id"],
         provider_refund_id: refund["id"],
         status: refund["status"],
         amount: refund["amount"]
       }}
    end
  end

  @impl true
  def get_payment_method_details(token_id) do
    # Razorpay tokens don't expose card details easily
    # Return minimal structure matching the payment_method type
    {:ok,
     %PaymentMethodInfo{
       id: token_id,
       provider: :razorpay,
       provider_payment_method_id: token_id,
       provider_customer_id: nil,
       type: "card",
       brand: nil,
       last4: nil,
       exp_month: nil,
       exp_year: nil,
       metadata: %{}
     }}
  end

  # ============================================
  # Razorpay API Calls
  # ============================================

  defp create_order(opts) do
    amount = opts[:amount] || opts["amount"]

    currency =
      opts[:currency] || opts["currency"] ||
        raise(ArgumentError, "Razorpay create_order: :currency is required")

    metadata = opts[:metadata] || opts["metadata"] || %{}

    # Razorpay expects amount in the smallest currency unit (paise for
    # INR) — via decimal_places, not a hard-coded 100 (§2.6/§7, E5): a
    # zero-decimal currency sent through a fixed 100 is charged ONE
    # HUNDRED TIMES its intended amount.
    with {:ok, amount_paise} <- MinorUnits.to_minor_units(amount, currency) do
      body = %{
        amount: amount_paise,
        currency: String.upcase(currency),
        notes: metadata,
        receipt: "receipt_#{System.system_time(:millisecond)}"
      }

      request(:post, "/v1/orders", body)
    end
  end

  defp create_order_for_recurring(amount, opts) do
    currency = Keyword.fetch!(opts, :currency)
    metadata = Keyword.get(opts, :metadata, %{})

    # Same currency-aware conversion as create_order/1 above (§2.6/§7,
    # E5): `amount` here is always the public API's Decimal directly
    # (charge_payment_method/3's caller), so the old hard-coded ×100 was
    # live on every recurring charge, not just a dormant fallback branch.
    with {:ok, amount_paise} <- MinorUnits.to_minor_units(amount, currency) do
      body = %{
        amount: amount_paise,
        currency: String.upcase(currency),
        notes: metadata,
        receipt: "recurring_#{System.system_time(:millisecond)}"
      }

      request(:post, "/v1/orders", body)
    end
  end

  defp create_payment_link(order, opts) do
    description = opts[:description] || opts["description"] || "Payment"
    success_url = opts[:success_url] || opts["success_url"]
    # cancel_url not used in Razorpay payment links - they use callback_url only
    metadata = opts[:metadata] || opts["metadata"] || %{}

    body = %{
      amount: order["amount"],
      currency: order["currency"],
      description: description,
      callback_url: success_url,
      callback_method: "get",
      notes: Map.merge(metadata, %{order_id: order["id"]}),
      # Expire in 30 minutes
      expire_by: System.system_time(:second) + 1800
    }

    request(:post, "/v1/payment_links", body)
  end

  defp create_recurring_payment(order, token_id, customer_id, opts) do
    description = Keyword.get(opts, :description, "Recurring payment")

    body = %{
      email: Keyword.get(opts, :email, "customer@example.com"),
      contact: Keyword.get(opts, :phone, "9999999999"),
      amount: order["amount"],
      currency: order["currency"],
      order_id: order["id"],
      customer_id: customer_id,
      token: token_id,
      recurring: "1",
      description: description
    }

    request(:post, "/v1/payments/create/recurring", body)
  end

  # :currency is only required for a partial refund (amount: nil sends no
  # amount at all, so Razorpay refunds the full payment in whatever
  # currency it was captured in) — same rule §7.1 already established for
  # Stripe/PayPal. It was silently unused here before this fix, because
  # the old `is_integer(amount)` branch never needed it; now it drives
  # the same currency-aware conversion as create_order/1 above (§2.6/§7,
  # E5) instead of a hard-coded 100.
  defp do_create_refund(payment_id, amount, opts) do
    notes = Keyword.get(opts, :notes, %{})

    with {:ok, body} <- build_refund_body(amount, opts, notes) do
      request(:post, "/v1/payments/#{payment_id}/refund", body)
    end
  end

  defp build_refund_body(nil, _opts, notes), do: {:ok, %{notes: notes}}

  defp build_refund_body(amount, opts, notes) do
    currency = Keyword.fetch!(opts, :currency)

    with {:ok, amount_paise} <- MinorUnits.to_minor_units(amount, currency) do
      {:ok, %{amount: amount_paise, notes: notes}}
    end
  end

  # ============================================
  # Webhook Event Handlers
  # ============================================

  defp handle_payment_captured(event_payload, raw_payload) do
    payment = event_payload["payment"]["entity"]
    order_id = payment["order_id"]
    notes = payment["notes"] || %{}

    {:ok,
     %WebhookEventData{
       event_id: raw_payload["event_id"] || payment["id"],
       type: "payment.succeeded",
       provider: :razorpay,
       data: %{
         charge_id: payment["id"],
         order_id: order_id,
         invoice_uuid: notes["invoice_uuid"] || notes["invoice_id"],
         amount: payment["amount"],
         currency: payment["currency"]
       },
       raw_payload: raw_payload
     }}
  end

  defp handle_payment_authorized(event_payload, raw_payload) do
    payment = event_payload["payment"]["entity"]

    # For 2-step payments, we may need to capture manually
    # Auto-capture is usually enabled, so this is informational
    {:ok,
     %WebhookEventData{
       event_id: raw_payload["event_id"] || payment["id"],
       type: "payment.authorized",
       provider: :razorpay,
       data: %{
         payment_id: payment["id"],
         order_id: payment["order_id"],
         amount: payment["amount"]
       },
       raw_payload: raw_payload
     }}
  end

  defp handle_payment_failed(event_payload, raw_payload) do
    payment = event_payload["payment"]["entity"]
    error = payment["error_code"] || "unknown"
    error_desc = payment["error_description"] || "Payment failed"
    notes = payment["notes"] || %{}

    {:ok,
     %WebhookEventData{
       event_id: raw_payload["event_id"] || payment["id"],
       type: "payment.failed",
       provider: :razorpay,
       data: %{
         payment_id: payment["id"],
         order_id: payment["order_id"],
         invoice_uuid: notes["invoice_uuid"] || notes["invoice_id"],
         error_code: error,
         error_message: error_desc
       },
       raw_payload: raw_payload
     }}
  end

  defp handle_order_paid(event_payload, raw_payload) do
    order = event_payload["order"]["entity"]
    payment = event_payload["payment"]["entity"]
    notes = order["notes"] || %{}

    {:ok,
     %WebhookEventData{
       event_id: raw_payload["event_id"] || order["id"],
       type: "checkout.completed",
       provider: :razorpay,
       data: %{
         mode: "payment",
         session_id: order["id"],
         payment_intent_id: payment["id"],
         invoice_uuid: notes["invoice_uuid"] || notes["invoice_id"],
         amount_total: order["amount_paid"],
         currency: order["currency"]
       },
       raw_payload: raw_payload
     }}
  end

  defp handle_refund_created(event_payload, raw_payload) do
    refund = event_payload["refund"]["entity"]

    {:ok,
     %WebhookEventData{
       event_id: raw_payload["event_id"] || refund["id"],
       type: "refund.created",
       provider: :razorpay,
       data: %{
         refund_id: refund["id"],
         charge_id: refund["payment_id"],
         amount_refunded: refund["amount"],
         # Added alongside amount_refunded (§7/E5): the payment-side
         # handlers above already carry this from the same Razorpay
         # entity shape; utils/webhook_processor.ex needs it to convert
         # amount_refunded for any currency, not just two-decimal ones.
         currency: refund["currency"],
         status: refund["status"]
       },
       raw_payload: raw_payload
     }}
  end

  defp handle_refund_processed(event_payload, raw_payload) do
    refund = event_payload["refund"]["entity"]

    {:ok,
     %WebhookEventData{
       event_id: raw_payload["event_id"] || refund["id"],
       type: "refund.completed",
       provider: :razorpay,
       data: %{
         refund_id: refund["id"],
         charge_id: refund["payment_id"],
         amount_refunded: refund["amount"],
         currency: refund["currency"],
         status: "succeeded"
       },
       raw_payload: raw_payload
     }}
  end

  # ============================================
  # HTTP Helpers
  # ============================================

  defp request(method, path, body) do
    with {:ok, credentials} <- get_credentials() do
      execute_request(method, path, body, credentials)
    end
  end

  defp get_credentials do
    key_id = Settings.get_setting("billing_razorpay_key_id", "")
    key_secret = Settings.get_setting("billing_razorpay_key_secret", "")

    if key_id == "" or key_secret == "" do
      {:error, :not_configured}
    else
      {:ok, {key_id, key_secret}}
    end
  end

  defp execute_request(method, path, body, {key_id, key_secret}) do
    url = "#{@base_url}#{path}"
    auth = Base.encode64("#{key_id}:#{key_secret}")

    headers = [
      {"Authorization", "Basic #{auth}"},
      {"Content-Type", "application/json"}
    ]

    # Same test transport seam as Stripe and PayPal; unset in production.
    opts =
      build_request_opts(method, headers, body)
      |> Keyword.merge(Application.get_env(:phoenix_kit_billing, :razorpay_req_options, []))

    method
    |> do_http_request(url, opts)
    |> handle_response()
  end

  defp build_request_opts(_method, headers, body), do: [headers: headers, json: body]

  defp do_http_request(:post, url, opts), do: Req.post(url, opts)

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    {:ok, body}
  end

  defp handle_response({:ok, %{status: status, body: body}}) do
    Logger.error("Razorpay API error: #{status} - #{inspect(body)}")
    error_message = body["error"]["description"] || "API error"
    {:error, error_message}
  end

  defp handle_response({:error, reason}) do
    Logger.error("Razorpay request failed: #{inspect(reason)}")
    {:error, :request_failed}
  end

  # ============================================
  # Helpers
  # ============================================

  defp has_credentials? do
    Settings.get_setting("billing_razorpay_key_id", "") != "" &&
      Settings.get_setting("billing_razorpay_key_secret", "") != ""
  end

  defp datetime_from_unix(nil), do: nil

  defp datetime_from_unix(unix_timestamp) when is_integer(unix_timestamp) do
    DateTime.from_unix!(unix_timestamp)
  end

  defp datetime_from_unix(_), do: nil

  defp invoice_to_opts(%_{} = invoice), do: invoice |> Map.from_struct() |> invoice_to_opts()

  defp invoice_to_opts(invoice) when is_map(invoice) do
    total = invoice[:total] || invoice["total"] || Decimal.new(0)
    paid = invoice[:paid_amount] || invoice["paid_amount"] || Decimal.new(0)
    amount = Decimal.sub(total, paid)

    # Was: an unconditional Decimal.mult(amount, 100) here, so create_order/1
    # received an already-scaled integer and its own is_integer(amount)
    # branch skipped conversion entirely — for a zero-decimal currency
    # that meant charging 100x with no currency-aware step anywhere in
    # the chain (§2.6/§7, E5). Passing the Decimal straight through and
    # letting create_order/1 do the ONE currency-aware conversion removes
    # that duplicate, silently-wrong scaling step rather than just fixing
    # its factor.
    [
      amount: amount,
      currency:
        invoice[:currency] || invoice["currency"] ||
          raise(ArgumentError, "invoice has no currency"),
      description: "Invoice #{invoice[:invoice_number] || invoice["invoice_number"]}",
      metadata: %{
        invoice_uuid: invoice[:uuid] || invoice["uuid"] || invoice[:id] || invoice["id"],
        invoice_number: invoice[:invoice_number] || invoice["invoice_number"]
      }
    ]
  end

  defp invoice_to_opts(_), do: []

  defp ensure_positive_amount(amount) do
    if Decimal.positive?(amount), do: :ok, else: {:error, :nothing_to_pay}
  end
end
