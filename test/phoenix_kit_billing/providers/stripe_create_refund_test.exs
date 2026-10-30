defmodule PhoenixKitBilling.Providers.StripeCreateRefundTest do
  @moduledoc """
  Which Stripe object `Stripe.create_refund/3` addresses.

  A Checkout payment is stored under its PaymentIntent id (`pi_…`), and
  `POST /v1/refunds` takes that as `payment_intent`, not `charge` - sending it
  as `charge` is answered with "No such charge".

  Exercised against a `Req.Test` stub wired through the `:stripe_req_options`
  application env (a test-only seam, unset in every shipped config), so the
  form body Stripe would receive is what is asserted.
  """

  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling.Currency
  alias PhoenixKitBilling.Providers.Stripe
  alias PhoenixKitBilling.Providers.Types.RefundResult

  setup do
    Settings.update_setting("billing_stripe_enabled", "true")
    Settings.update_setting("billing_stripe_secret_key", "sk_test_fake_not_a_real_key")

    Repo.delete_all(Currency)

    {:ok, _eur} =
      PhoenixKitBilling.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        is_default: true,
        exchange_rate: "1.0"
      })

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:stripe_request, conn.method, conn.request_path, URI.decode_query(body)})

      Req.Test.json(conn, %{
        "id" => "re_test_1",
        "object" => "refund",
        "amount" => 1000,
        "currency" => "eur",
        "status" => "succeeded"
      })
    end)

    Application.put_env(:phoenix_kit_billing, :stripe_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_billing, :stripe_req_options)
      Settings.update_setting("billing_stripe_enabled", "false")
      Settings.update_setting("billing_stripe_secret_key", "")
    end)

    :ok
  end

  test "a PaymentIntent id (a Checkout payment) is sent as payment_intent" do
    assert {:ok, %RefundResult{provider_refund_id: "re_test_1"}} =
             Stripe.create_refund("pi_3Checkout", Decimal.new("10.00"), currency: "EUR")

    assert_received {:stripe_request, "POST", "/v1/refunds", params}
    assert params["payment_intent"] == "pi_3Checkout"
    refute Map.has_key?(params, "charge")
    assert params["amount"] == "1000"
  end

  test "a charge id (a saved-card charge) is still sent as charge" do
    assert {:ok, %RefundResult{}} =
             Stripe.create_refund("ch_3Saved", Decimal.new("10.00"), currency: "EUR")

    assert_received {:stripe_request, "POST", "/v1/refunds", params}
    assert params["charge"] == "ch_3Saved"
    refute Map.has_key?(params, "payment_intent")
  end

  test "a full refund by PaymentIntent id sends no amount, and the reason rides along" do
    assert {:ok, %RefundResult{}} =
             Stripe.create_refund("pi_3Checkout", nil, reason: "requested_by_customer")

    assert_received {:stripe_request, "POST", "/v1/refunds", params}
    assert params["payment_intent"] == "pi_3Checkout"
    assert params["reason"] == "requested_by_customer"
    refute Map.has_key?(params, "amount")
  end
end
