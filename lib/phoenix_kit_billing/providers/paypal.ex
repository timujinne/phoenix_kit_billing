defmodule PhoenixKitBilling.Providers.PayPal do
  @moduledoc """
  PayPal payment provider implementation.

  Uses PayPal REST API v2 for:
  - Checkout sessions (Orders API)
  - Saved payment methods (Vault API)
  - Refunds

  ## Configuration

  Required settings in database:
  - `billing_paypal_enabled` - "true" to enable
  - `billing_paypal_client_id` - PayPal Client ID
  - `billing_paypal_client_secret` - PayPal Client Secret
  - `billing_paypal_mode` - "sandbox" or "live"
  - `billing_paypal_webhook_id` - Webhook ID for signature verification

  ## PayPal API Flow

  1. Get OAuth2 access token (cached)
  2. Create Order with intent: "CAPTURE"
  3. Redirect user to PayPal approval URL
  4. User approves payment on PayPal
  5. PayPal redirects to success_url with token
  6. Capture payment via webhook or on return

  ## Webhook Events

  - `CHECKOUT.ORDER.APPROVED` - User approved the payment
  - `PAYMENT.CAPTURE.COMPLETED` - Payment captured successfully
  - `PAYMENT.CAPTURE.DENIED` - Payment capture failed
  - `PAYMENT.CAPTURE.REFUNDED` - Refund completed
  """

  @behaviour PhoenixKitBilling.Providers.Provider

  alias PhoenixKitBilling.Providers.Types.{
    ChargeResult,
    CheckoutSession,
    RefundResult,
    SetupSession,
    WebhookEventData
  }

  alias PhoenixKit.Settings
  alias PhoenixKitBilling.Providers.MinorUnits

  require Logger

  @sandbox_url "https://api-m.sandbox.paypal.com"
  @live_url "https://api-m.paypal.com"

  # ============================================
  # Provider Behaviour Implementation
  # ============================================

  @impl true
  def provider_name, do: :paypal

  @impl true
  def available? do
    Settings.get_setting("billing_paypal_enabled", "false") == "true" &&
      has_credentials?()
  end

  @impl true
  def create_checkout_session(invoice, opts) do
    # Merge invoice data with opts
    merged_opts = Keyword.merge(opts, invoice_to_opts(invoice))

    with {:ok, amount_str} <- format_amount(merged_opts[:amount], merged_opts[:currency]),
         :ok <- ensure_positive_amount(merged_opts[:amount]),
         {:ok, token} <- get_access_token(),
         {:ok, order} <- create_order(token, amount_str, merged_opts) do
      # Find the approval URL
      approve_link =
        order["links"]
        |> Enum.find(fn link -> link["rel"] == "approve" end)

      {:ok,
       %CheckoutSession{
         id: order["id"],
         url: approve_link["href"],
         provider: :paypal,
         expires_at: nil
       }}
    end
  end

  @impl true
  def create_setup_session(user, opts) do
    # Add user_id to opts
    merged_opts =
      Keyword.put(opts, :user_uuid, user[:uuid] || user["uuid"] || user[:id] || user["id"])

    with {:ok, token} <- get_access_token(),
         {:ok, setup_token} <- create_setup_token(token, merged_opts) do
      # Find the approval URL
      approve_link =
        setup_token["links"]
        |> Enum.find(fn link -> link["rel"] == "approve" end)

      {:ok,
       %SetupSession{
         id: setup_token["id"],
         url: approve_link["href"],
         provider: :paypal
       }}
    end
  end

  @impl true
  def charge_payment_method(payment_method, amount, opts) do
    # Read BEFORE get_access_token/0 so a missing :currency fails even
    # without configured PayPal credentials — otherwise the with-chain
    # below short-circuits on {:error, :not_configured} and the caller
    # never learns :currency was missing at all (§7.1). format_amount/2
    # (which needs the currency too) runs before the token exchange for
    # the same reason: a locally-knowable failure — an unrecognized
    # currency code, or more precision than the currency allows — must
    # not cost a network round trip before it is reported.
    currency = Keyword.fetch!(opts, :currency)

    with {:ok, amount_str} <- format_amount(amount, currency),
         {:ok, token} <- get_access_token(),
         {:ok, order} <-
           create_order_with_vault(token, payment_method, amount_str, currency, opts),
         {:ok, capture} <- capture_order(token, order["id"]) do
      {:ok,
       %ChargeResult{
         id: capture["id"],
         status: capture["status"],
         amount: amount
       }}
    end
  end

  @impl true
  def verify_webhook_signature(payload, signature, _secret) do
    # PayPal requires verifying via API call
    with {:ok, token} <- get_access_token() do
      verify_webhook_via_api(token, payload, signature)
    end
  end

  @impl true
  def handle_webhook_event(payload) do
    event_type = payload["event_type"]
    resource = payload["resource"]

    case event_type do
      "CHECKOUT.ORDER.APPROVED" ->
        handle_order_approved(resource, payload)

      "PAYMENT.CAPTURE.COMPLETED" ->
        handle_capture_completed(resource, payload)

      "PAYMENT.CAPTURE.DENIED" ->
        handle_capture_denied(resource, payload)

      "PAYMENT.CAPTURE.REFUNDED" ->
        handle_capture_refunded(resource, payload)

      _ ->
        {:error, :unknown_event}
    end
  end

  @impl true
  def create_refund(provider_transaction_id, amount, opts) do
    with {:ok, refund_amount} <- maybe_format_refund_amount(amount, opts),
         {:ok, token} <- get_access_token(),
         {:ok, refund} <- do_create_refund(token, provider_transaction_id, refund_amount, opts) do
      {:ok,
       %RefundResult{
         id: refund["id"],
         provider_refund_id: refund["id"],
         status: refund["status"],
         amount: amount
       }}
    end
  end

  @impl true
  def get_payment_method_details(provider_payment_method_id) do
    with {:ok, token} <- get_access_token(),
         {:ok, vault_token} <- get_vault_payment_token(token, provider_payment_method_id) do
      source = vault_token["payment_source"]

      details =
        cond do
          card = source["card"] ->
            %{
              type: "card",
              brand: card["brand"],
              last4: card["last_digits"],
              exp_month:
                card["expiry"] |> String.split("-") |> List.last() |> String.to_integer(),
              exp_year: card["expiry"] |> String.split("-") |> List.first() |> String.to_integer()
            }

          _paypal = source["paypal"] ->
            %{
              type: "paypal",
              brand: "paypal",
              last4: nil
            }

          true ->
            %{type: "unknown"}
        end

      {:ok, details}
    end
  end

  # ============================================
  # PayPal API Calls
  # ============================================

  defp create_order(token, amount_str, opts) do
    currency =
      opts[:currency] || opts["currency"] ||
        raise(ArgumentError, "PayPal create_order: :currency is required")

    description = opts[:description] || opts["description"] || "Payment"
    success_url = opts[:success_url] || opts["success_url"]
    cancel_url = opts[:cancel_url] || opts["cancel_url"]
    metadata = opts[:metadata] || opts["metadata"] || %{}

    body = %{
      intent: "CAPTURE",
      purchase_units: [
        %{
          amount: %{
            currency_code: String.upcase(currency),
            value: amount_str
          },
          description: description,
          custom_id: Jason.encode!(metadata)
        }
      ],
      payment_source: %{
        paypal: %{
          experience_context: %{
            payment_method_preference: "IMMEDIATE_PAYMENT_REQUIRED",
            brand_name: Settings.get_setting("billing_company_name", ""),
            locale: "en-US",
            landing_page: "LOGIN",
            user_action: "PAY_NOW",
            return_url: success_url,
            cancel_url: cancel_url
          }
        }
      }
    }

    request(:post, "/v2/checkout/orders", token, body)
  end

  defp create_order_with_vault(token, payment_method, amount_str, currency, opts) do
    description = Keyword.get(opts, :description, "Payment")
    metadata = Keyword.get(opts, :metadata, %{})

    body = %{
      intent: "CAPTURE",
      purchase_units: [
        %{
          amount: %{
            currency_code: String.upcase(currency),
            value: amount_str
          },
          description: description,
          custom_id: Jason.encode!(metadata)
        }
      ],
      payment_source: %{
        token: %{
          id: payment_method.provider_payment_method_id,
          type: "PAYMENT_METHOD_TOKEN"
        }
      }
    }

    request(:post, "/v2/checkout/orders", token, body)
  end

  defp capture_order(token, order_id) do
    request(:post, "/v2/checkout/orders/#{order_id}/capture", token, %{})
  end

  defp create_setup_token(token, opts) do
    success_url = opts[:success_url] || opts["success_url"]
    cancel_url = opts[:cancel_url] || opts["cancel_url"]
    user_uuid = opts[:user_uuid] || opts["user_uuid"]

    body = %{
      payment_source: %{
        paypal: %{
          description: "Save payment method",
          usage_type: "MERCHANT",
          customer_type: "CONSUMER",
          experience_context: %{
            return_url: success_url,
            cancel_url: cancel_url
          }
        }
      },
      customer: %{
        id: "user_#{user_uuid}"
      }
    }

    request(:post, "/v3/vault/setup-tokens", token, body)
  end

  defp get_vault_payment_token(token, vault_id) do
    request(:get, "/v3/vault/payment-tokens/#{vault_id}", token)
  end

  # :currency is only required for a partial refund — a full refund
  # (amount: nil) sends no currency_code at all, so requiring it
  # unconditionally would raise for nothing (§7.1: the invariant is
  # "never silently default where it's used", not "require everywhere").
  # `refund_amount` is `nil` (full refund) or `{amount_str, currency}`,
  # already formatted by `maybe_format_refund_amount/2` in the caller —
  # this function only builds the request body, so a currency-code or
  # precision failure is reported before the token exchange, not here.
  defp do_create_refund(token, capture_id, refund_amount, opts) do
    note = Keyword.get(opts, :note, "Refund")

    body =
      case refund_amount do
        {amount_str, currency} ->
          %{
            amount: %{
              currency_code: String.upcase(currency),
              value: amount_str
            },
            note_to_payer: note
          }

        nil ->
          %{note_to_payer: note}
      end

    request(:post, "/v2/payments/captures/#{capture_id}/refund", token, body)
  end

  defp verify_webhook_via_api(token, payload, headers) when is_map(headers) do
    webhook_id = Settings.get_setting("billing_paypal_webhook_id", "")

    body = %{
      auth_algo: headers["paypal-auth-algo"],
      cert_url: headers["paypal-cert-url"],
      transmission_id: headers["paypal-transmission-id"],
      transmission_sig: headers["paypal-transmission-sig"],
      transmission_time: headers["paypal-transmission-time"],
      webhook_id: webhook_id,
      webhook_event: payload
    }

    case request(:post, "/v1/notifications/verify-webhook-signature", token, body) do
      {:ok, %{"verification_status" => "SUCCESS"}} -> :ok
      {:ok, _} -> {:error, :invalid_signature}
      error -> error
    end
  end

  defp verify_webhook_via_api(_token, _payload, _signature) do
    # If signature is just a string, we can't verify properly
    # In production, headers should be passed
    Logger.warning("PayPal webhook verification requires full headers map")
    {:error, :invalid_signature}
  end

  # ============================================
  # Webhook Event Handlers
  # ============================================

  defp handle_order_approved(resource, payload) do
    order_id = resource["id"]
    custom_id = get_custom_id(resource)

    {:ok,
     %WebhookEventData{
       event_id: payload["id"],
       type: "checkout.completed",
       provider: :paypal,
       data: %{
         session_id: order_id,
         mode: "payment",
         invoice_uuid: custom_id["invoice_uuid"] || custom_id["invoice_id"],
         payment_intent_id: order_id
       },
       raw_payload: payload
     }}
  end

  defp handle_capture_completed(resource, payload) do
    capture_id = resource["id"]
    amount = resource["amount"]
    custom_id = get_custom_id_from_capture(resource)

    {:ok,
     %WebhookEventData{
       event_id: payload["id"],
       type: "payment.succeeded",
       provider: :paypal,
       data: %{
         charge_id: capture_id,
         invoice_uuid: custom_id["invoice_uuid"] || custom_id["invoice_id"],
         amount: parse_amount(amount["value"], amount["currency_code"]),
         currency: amount["currency_code"]
       },
       raw_payload: payload
     }}
  end

  defp handle_capture_denied(resource, payload) do
    custom_id = get_custom_id_from_capture(resource)

    {:ok,
     %WebhookEventData{
       event_id: payload["id"],
       type: "payment.failed",
       provider: :paypal,
       data: %{
         invoice_uuid: custom_id["invoice_uuid"] || custom_id["invoice_id"],
         error_code: "CAPTURE_DENIED",
         error_message: "Payment capture was denied"
       },
       raw_payload: payload
     }}
  end

  defp handle_capture_refunded(resource, payload) do
    refund_id = resource["id"]
    amount = resource["amount"]

    {:ok,
     %WebhookEventData{
       event_id: payload["id"],
       type: "refund.created",
       provider: :paypal,
       data: %{
         refund_id: refund_id,
         charge_id: resource["links"] |> find_capture_id(),
         amount_refunded: parse_amount(amount["value"], amount["currency_code"]),
         currency: amount["currency_code"]
       },
       raw_payload: payload
     }}
  end

  # ============================================
  # OAuth2 Token Management
  # ============================================

  defp get_access_token do
    # In production, this should be cached
    client_id = Settings.get_setting("billing_paypal_client_id", "")
    client_secret = Settings.get_setting("billing_paypal_client_secret", "")

    if client_id == "" or client_secret == "" do
      {:error, :not_configured}
    else
      auth = Base.encode64("#{client_id}:#{client_secret}")

      # TEST-ONLY seam: `:paypal_req_options` is never set in any shipped
      # config (config.exs / runtime.exs) — this merge is a no-op in
      # production. It exists so tests can point this one Req call at a
      # `Req.Test` stub instead of PayPal's real OAuth endpoint, without a
      # real network call or real credentials. Whoever can write
      # Application env for this node already controls far bigger levers
      # (the Repo URL, the endpoint's secret_key_base, ...), so this key
      # does not expand what such an attacker can already do.
      opts =
        Keyword.merge(
          [
            headers: [
              {"Authorization", "Basic #{auth}"},
              {"Content-Type", "application/x-www-form-urlencoded"}
            ],
            body: "grant_type=client_credentials"
          ],
          Application.get_env(:phoenix_kit_billing, :paypal_req_options, [])
        )

      case Req.post("#{base_url()}/v1/oauth2/token", opts) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, body["access_token"]}

        {:ok, %{status: status, body: body}} ->
          Logger.error("PayPal OAuth error: #{status} - #{inspect(body)}")
          {:error, :authentication_failed}

        {:error, reason} ->
          Logger.error("PayPal OAuth request failed: #{inspect(reason)}")
          {:error, :request_failed}
      end
    end
  end

  # ============================================
  # HTTP Helpers
  # ============================================

  defp request(method, path, token, body \\ nil) do
    url = "#{base_url()}#{path}"

    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"},
      {"PayPal-Request-Id", generate_request_id()}
    ]

    opts =
      case method do
        :get -> [headers: headers]
        _ -> [headers: headers, json: body]
      end
      |> Keyword.merge(Application.get_env(:phoenix_kit_billing, :paypal_req_options, []))

    result =
      case method do
        :get -> Req.get(url, opts)
        :post -> Req.post(url, opts)
      end

    case result do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("PayPal API error: #{status} - #{inspect(body)}")
        error_message = get_in(body, ["details", Access.at(0), "description"]) || "API error"
        {:error, error_message}

      {:error, reason} ->
        Logger.error("PayPal request failed: #{inspect(reason)}")
        {:error, :request_failed}
    end
  end

  # ============================================
  # Helpers
  # ============================================

  defp base_url do
    case Settings.get_setting("billing_paypal_mode", "sandbox") do
      "live" -> @live_url
      _ -> @sandbox_url
    end
  end

  defp has_credentials? do
    Settings.get_setting("billing_paypal_client_id", "") != "" &&
      Settings.get_setting("billing_paypal_client_secret", "") != ""
  end

  # PayPal's Orders/Payments APIs take `amount.value` as a decimal STRING
  # at the currency's own precision — not an integer minor unit the way
  # Stripe does. A zero-decimal currency (JPY, ...) must be sent with no
  # decimal point at all ("1000", not "1000.00"); a three-decimal one
  # (BHD, ...) needs all three digits. The old code always formatted to
  # exactly 2 decimals, which is wrong in both directions — spec §2.6/§7
  # (E5). Routed through `MinorUnits.to_minor_units_and_places/2` for the
  # same refuse-rather-than-guess unknown-currency and no-silent-rounding
  # behavior Stripe gets (one currency lookup, not two), then rendered
  # back to a string at the exact digit count it reports — never via a
  # float, so a large amount cannot lose precision in the round trip.
  defp format_amount(%Decimal{} = amount, currency_code) do
    with {:ok, minor_units, places} <- MinorUnits.to_minor_units_and_places(amount, currency_code) do
      {:ok, minor_units_to_decimal_string(minor_units, places)}
    end
  end

  defp minor_units_to_decimal_string(minor_units, 0), do: Integer.to_string(minor_units)

  defp minor_units_to_decimal_string(minor_units, places) do
    sign = if minor_units < 0, do: "-", else: ""

    digits =
      minor_units
      |> abs()
      |> Integer.to_string()
      |> String.pad_leading(places + 1, "0")

    {whole, fraction} = String.split_at(digits, byte_size(digits) - places)
    sign <> whole <> "." <> fraction
  end

  # PayPal's own wire format never uses this integer — it is a purely
  # internal minor-unit encoding this module produces so a webhook's
  # amount can travel through `WebhookEventData.data[:amount]` /
  # `[:amount_refunded]` the same shape Stripe's raw minor units already
  # do, for `utils/webhook_processor.ex` to convert back with
  # `MinorUnits.from_minor_units/2` (§7/E5). It USED to be a fixed ×100
  # regardless of currency, which only round-tripped correctly because
  # the processor divided by the same fixed 100 on the other end; now
  # that the processor is currency-aware, this must be too, or the pair
  # would decode a currency-aware charge with a currency-blind confirmation
  # (see `utils/webhook_processor.ex`'s `webhook_amount_for_key/2`).
  #
  # `nil` on an unrecognized currency or an over-precise amount — never a
  # guessed factor — so the processor's `is_integer(...)` guard misses it
  # and falls back to the invoice's own balance instead of a wrong number.
  defp parse_amount(amount_str, currency_code)
       when is_binary(amount_str) and is_binary(currency_code) do
    case MinorUnits.to_minor_units(Decimal.new(amount_str), currency_code) do
      {:ok, minor_units} -> minor_units
      {:error, _reason} -> nil
    end
  end

  defp parse_amount(amount, _currency_code), do: amount

  defp get_custom_id(resource) do
    custom_id_json =
      resource["purchase_units"]
      |> List.first()
      |> Map.get("custom_id", "{}")

    case Jason.decode(custom_id_json) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp get_custom_id_from_capture(resource) do
    # Try to get from supplementary_data or links
    custom_id_json = resource["custom_id"] || "{}"

    case Jason.decode(custom_id_json) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp find_capture_id(links) when is_list(links) do
    case Enum.find(links, fn link -> link["rel"] == "up" end) do
      %{"href" => href} -> href |> String.split("/") |> List.last()
      _ -> nil
    end
  end

  defp find_capture_id(_), do: nil

  defp generate_request_id do
    "req_" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
  end

  # Fetches/validates :currency (fetch! only when a partial amount is
  # given — a full refund needs none, same rule as `do_create_refund/4`
  # documents) and pre-formats the decimal string BEFORE the token
  # exchange, mirroring `charge_payment_method/3` (§7.1 + E5: a locally
  # knowable failure must not cost a network round trip first).
  defp maybe_format_refund_amount(nil, _opts), do: {:ok, nil}

  defp maybe_format_refund_amount(amount, opts) do
    currency = Keyword.fetch!(opts, :currency)

    with {:ok, amount_str} <- format_amount(amount, currency) do
      {:ok, {amount_str, currency}}
    end
  end

  defp invoice_to_opts(%_{} = invoice), do: invoice |> Map.from_struct() |> invoice_to_opts()

  defp invoice_to_opts(invoice) when is_map(invoice) do
    total = invoice[:total] || invoice["total"] || Decimal.new(0)
    paid = invoice[:paid_amount] || invoice["paid_amount"] || Decimal.new(0)
    amount = Decimal.sub(total, paid)

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
