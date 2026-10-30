defmodule PhoenixKitBilling.Providers.CheckoutBalanceTest do
  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling.Invoice
  alias PhoenixKitBilling.Providers

  @providers [:paypal, :razorpay, :everypay]
  @opts [success_url: "https://shop.test/done", cancel_url: "https://shop.test/cancel"]

  setup do
    for {key, value} <- [
          {"billing_paypal_enabled", "true"},
          {"billing_paypal_client_id", "test"},
          {"billing_paypal_client_secret", "test"},
          {"billing_razorpay_enabled", "true"},
          {"billing_razorpay_key_id", "test"},
          {"billing_razorpay_key_secret", "test"},
          {"billing_everypay_enabled", "true"},
          {"billing_everypay_api_username", "test"},
          {"billing_everypay_api_secret", "test"},
          {"billing_everypay_account_name", "EUR3D1"}
        ] do
      Settings.update_setting(key, value)
    end

    for provider <- @providers do
      key = String.to_atom("#{provider}_req_options")
      previous = Application.fetch_env(:phoenix_kit_billing, key)
      Application.put_env(:phoenix_kit_billing, key, plug: {Req.Test, __MODULE__})

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phoenix_kit_billing, key, value)
          :error -> Application.delete_env(:phoenix_kit_billing, key)
        end
      end)
    end

    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:http_request, conn.request_path})
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case conn.request_path do
        "/v1/oauth2/token" ->
          Req.Test.json(conn, %{"access_token" => "test-token"})

        "/v2/checkout/orders" ->
          send(parent, {:paypal, Jason.decode!(body)})

          Req.Test.json(conn, %{
            "id" => "paypal-order",
            "links" => [%{"rel" => "approve", "href" => "https://paypal.test/pay"}]
          })

        "/v1/orders" ->
          send(parent, {:razorpay, Jason.decode!(body)})
          Req.Test.json(conn, %{"id" => "razorpay-order", "amount" => 1500, "currency" => "EUR"})

        "/v1/payment_links" ->
          Req.Test.json(conn, %{"short_url" => "https://razorpay.test/pay"})

        "/api/v4/payments/oneoff" ->
          send(parent, {:everypay, Jason.decode!(body)})

          Req.Test.json(conn, %{
            "payment_reference" => "everypay-ref",
            "payment_link" => "https://everypay.test/pay"
          })
      end
    end)

    :ok
  end

  defp invoice do
    %Invoice{
      uuid: Ecto.UUID.generate(),
      invoice_number: "INV-REVIEW",
      currency: "EUR",
      total: Decimal.new("25.00"),
      paid_amount: Decimal.new("10.00")
    }
  end

  for provider <- @providers do
    test "#{provider} accepts a real invoice and charges only its remaining balance" do
      provider = unquote(provider)
      assert {:ok, %{url: url}} = Providers.create_checkout_session(provider, invoice(), @opts)
      assert is_binary(url)
      assert_received {^provider, body}

      case provider do
        :paypal ->
          assert [%{"amount" => %{"value" => "15.00"}}] = body["purchase_units"]

        :razorpay ->
          assert body["amount"] == 1500

        :everypay ->
          assert body["amount"] == 15
      end
    end

    test "#{provider} refuses a settled invoice without making an HTTP request" do
      provider = unquote(provider)
      settled = %{invoice() | paid_amount: Decimal.new("25.00")}

      assert {:error, :nothing_to_pay} =
               Providers.create_checkout_session(provider, settled, @opts)

      refute_received {^provider, _}
      refute_received {:http_request, _}
    end
  end
end
