defmodule PhoenixKitBilling.Providers.StripeCurrencyAmountsTest do
  @moduledoc """
  §7 (E5) of the per-domain-currency design: `PhoenixKitBilling.Providers.Stripe`
  used to convert every amount to Stripe's minor unit with a hard-coded
  ×100, which is wrong for a zero-decimal currency (JPY: charges 100x) or a
  three-decimal one (BHD: truncates). The actual conversion arithmetic is
  covered exhaustively in `minor_units_test.exs`; this file only proves
  that Stripe's three call sites (charge, refund, checkout-session line
  items) actually route through it and refuse — rather than guess — an
  unrecognized code or an over-precise amount, and do so BEFORE any
  network call (Stripe is "configured" with a fake key below precisely so
  the code reaches the currency check instead of short-circuiting on
  `{:error, :not_configured}` first; no test here exercises a currency
  Stripe would actually accept, since that would require a real API call
  this suite has no way to stub).
  """

  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling.Currency
  alias PhoenixKitBilling.PaymentMethod
  alias PhoenixKitBilling.Providers.Stripe

  setup do
    Settings.update_setting("billing_stripe_enabled", "true")
    Settings.update_setting("billing_stripe_secret_key", "sk_test_fake_not_a_real_key")

    Repo.delete_all(Currency)

    {:ok, _usd} =
      PhoenixKitBilling.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, _jpy} =
      PhoenixKitBilling.create_currency(%{
        code: "JPY",
        name: "Yen",
        symbol: "¥",
        decimal_places: 0,
        exchange_rate: "150.0"
      })

    on_exit(fn ->
      Settings.update_setting("billing_stripe_enabled", "false")
      Settings.update_setting("billing_stripe_secret_key", "")
    end)

    :ok
  end

  @pm %PaymentMethod{
    provider_customer_id: "cus_x",
    provider_payment_method_id: "pm_x"
  }

  describe "charge_payment_method/3" do
    test "refuses an unrecognized currency code before any network call" do
      assert {:error, :unknown_currency} =
               Stripe.charge_payment_method(@pm, Decimal.new("10.00"), currency: "XXX")
    end

    test "refuses a JPY amount with a fraction — JPY has zero decimal places" do
      assert {:error, :fractional_amount} =
               Stripe.charge_payment_method(@pm, Decimal.new("10.50"), currency: "JPY")
    end
  end

  describe "create_refund/3" do
    test "a partial refund refuses an unrecognized currency code before any network call" do
      assert {:error, :unknown_currency} =
               Stripe.create_refund("ch_x", Decimal.new("10.00"), currency: "XXX")
    end

    test "a partial refund still raises KeyError without :currency (§7.1 unchanged)" do
      assert_raise KeyError, fn ->
        Stripe.create_refund("ch_x", Decimal.new("10.00"), [])
      end
    end
  end

  describe "create_checkout_session/2 — line items" do
    test "refuses an unrecognized invoice currency before any network call" do
      invoice = %{
        uuid: Ecto.UUID.generate(),
        currency: "XXX",
        line_items: [%{"name" => "Widget", "quantity" => 1, "unit_price" => "10.00"}]
      }

      assert {:error, :unknown_currency} =
               Stripe.create_checkout_session(invoice,
                 success_url: "https://example.com/ok",
                 cancel_url: "https://example.com/cancel"
               )
    end

    test "refuses a JPY line item with a fraction" do
      invoice = %{
        uuid: Ecto.UUID.generate(),
        currency: "JPY",
        line_items: [%{"name" => "Widget", "quantity" => 1, "unit_price" => "10.50"}]
      }

      assert {:error, :fractional_amount} =
               Stripe.create_checkout_session(invoice,
                 success_url: "https://example.com/ok",
                 cancel_url: "https://example.com/cancel"
               )
    end

    test "an invoice with nothing left to pay is refused before any network call" do
      for {total, paid} <- [{"25.00", "25.00"}, {"0", "0"}] do
        invoice = %{
          uuid: Ecto.UUID.generate(),
          currency: "USD",
          total: Decimal.new(total),
          paid_amount: Decimal.new(paid),
          line_items: [%{"name" => "Widget", "quantity" => 1, "unit_price" => total}]
        }

        assert {:error, :nothing_to_pay} =
                 Stripe.create_checkout_session(invoice,
                   success_url: "https://example.com/ok",
                   cancel_url: "https://example.com/cancel"
                 )
      end
    end

    test "an invoice with no currency at all still raises ArgumentError (§7.1 unchanged)" do
      invoice = %{
        uuid: Ecto.UUID.generate(),
        currency: nil,
        line_items: [%{"name" => "Widget", "quantity" => 1, "unit_price" => "10.00"}]
      }

      assert_raise ArgumentError, ~r/has no currency/, fn ->
        Stripe.create_checkout_session(invoice,
          success_url: "https://example.com/ok",
          cancel_url: "https://example.com/cancel"
        )
      end
    end
  end
end
