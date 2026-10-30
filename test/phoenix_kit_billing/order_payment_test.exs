defmodule PhoenixKitBilling.OrderPaymentTest do
  @moduledoc """
  `PhoenixKitBilling.start_order_payment/2`: from an order with an online
  payment option to a provider checkout URL, over a stubbed Stripe
  (`:stripe_req_options` + `Req.Test`).
  """

  use PhoenixKitBilling.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Modules.Billing, as: LegacyBilling
  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, Order, WebhookProcessor}

  @urls [success_url: "https://shop.test/done", cancel_url: "https://shop.test/cancel"]

  setup do
    Settings.update_setting("billing_stripe_enabled", "true")
    Settings.update_setting("billing_stripe_secret_key", "sk_test_123")
    Application.put_env(:phoenix_kit_billing, :stripe_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_billing, :stripe_req_options)
      Settings.update_setting("billing_stripe_enabled", "false")
      Settings.update_setting("billing_stripe_secret_key", "")
    end)

    counter = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)

      Req.Test.json(conn, %{
        "id" => "cs_test_#{n}",
        "url" => "https://checkout.stripe.test/#{n}",
        "expires_at" => System.os_time(:second) + 86_400
      })
    end)

    stripe = option!("stripe", %{type: "online", provider: "stripe", active: true})
    cod = option!("cod", %{type: "offline", provider: nil, active: true})

    {:ok, stripe: stripe, cod: cod, counter: counter}
  end

  # The codes are seeded by the migrations; make the two this test needs known.
  defp option!(code, attrs) do
    case Billing.get_payment_option_by_code(code) do
      nil ->
        {:ok, o} = Billing.create_payment_option(Map.merge(%{name: code, code: code}, attrs))
        o

      o ->
        {:ok, o} = Billing.update_payment_option(o, attrs)
        o
    end
  end

  defp order!(option, attrs \\ %{}) do
    {:ok, order} =
      Billing.create_order(
        fixture_user(),
        Map.merge(
          %{
            "total" => Decimal.new("25.00"),
            "currency" => "EUR",
            "status" => "pending",
            "payment_option_uuid" => option.uuid,
            "billing_snapshot" => %{"email" => "buyer@example.com"},
            "line_items" => [
              %{"name" => "Vase", "quantity" => 1, "unit_price" => "25.00", "total" => "25.00"}
            ]
          },
          attrs
        )
      )

    order
  end

  setup do
    {:ok, currency: ensure_currency()}
  end

  defp ensure_currency do
    case Billing.get_currency_by_code("EUR") do
      nil ->
        {:ok, c} =
          Billing.create_currency(%{
            code: "EUR",
            name: "Euro",
            symbol: "€",
            is_default: true,
            enabled: true
          })

        c

      c ->
        c
    end
  end

  test "creates a sent invoice and returns the provider URL", %{stripe: stripe} do
    order = order!(stripe)

    assert {:ok, %{invoice: invoice, url: "https://checkout.stripe.test/1"}} =
             Billing.start_order_payment(order, @urls)

    assert invoice.order_uuid == order.uuid
    assert invoice.status == "sent"
    assert Invoice.payable?(invoice)
    assert invoice.metadata["checkout"]["provider"] == "stripe"
    assert invoice.metadata["checkout"]["provider_session_id"] == "cs_test_1"
  end

  test "addresses the invoice to the buyer", %{stripe: stripe} do
    order = order!(stripe)
    {:ok, %{invoice: invoice}} = Billing.start_order_payment(order, @urls)

    [entry] = invoice.metadata["send_history"]
    assert entry["email"] == Repo.preload(order, :user).user.email
  end

  test "is idempotent: the same invoice and the live session come back", %{
    stripe: stripe,
    counter: counter
  } do
    order = order!(stripe)

    {:ok, first} = Billing.start_order_payment(order, @urls)
    {:ok, second} = Billing.start_order_payment(order, @urls)

    assert first.invoice.uuid == second.invoice.uuid
    assert first.url == second.url
    assert :counters.get(counter, 1) == 1
    assert length(Billing.list_invoices_for_order(order.uuid)) == 1
  end

  test "an old session is replaced on the same invoice", %{stripe: stripe} do
    order = order!(stripe)
    {:ok, first} = Billing.start_order_payment(order, @urls)

    stale = DateTime.utc_now() |> DateTime.add(-2 * 86_400) |> DateTime.to_iso8601()

    meta = put_in(first.invoice.metadata, ["checkout", "created_at"], stale)
    first.invoice |> Ecto.Changeset.change(%{metadata: meta}) |> Repo.update!()

    {:ok, second} = Billing.start_order_payment(order, @urls)

    assert second.invoice.uuid == first.invoice.uuid
    assert second.url == "https://checkout.stripe.test/2"
  end

  test "a session is replaced when its return URLs or customer email change", %{stripe: stripe} do
    order = order!(stripe)
    {:ok, first} = Billing.start_order_payment(order, @urls)

    opts = Keyword.put(@urls, :success_url, "https://shop.test/another-order")
    {:ok, second} = Billing.start_order_payment(order, opts)
    assert second.url != first.url

    opts = Keyword.put(opts, :cancel_url, "https://shop.test/another-cancel")
    {:ok, third} = Billing.start_order_payment(order, opts)
    assert third.url != second.url

    opts = Keyword.put(opts, :customer_email, "other@example.com")
    {:ok, fourth} = Billing.start_order_payment(order, opts)
    assert fourth.url != third.url
  end

  test "a session in another currency is not reused for the same numeric amount", %{
    stripe: stripe
  } do
    order = order!(stripe)
    {:ok, first} = Billing.start_order_payment(order, @urls)

    Repo.update_all(from(i in Invoice, where: i.uuid == ^first.invoice.uuid),
      set: [currency: "USD"]
    )

    {:ok, second} = Billing.start_order_payment(order, @urls)
    assert second.url != first.url
  end

  test "the legacy billing namespace exposes order payments", %{stripe: stripe} do
    assert {:ok, %{invoice: %Invoice{}, url: _url}} =
             LegacyBilling.start_order_payment(order!(stripe), @urls)
  end

  test "sends Stripe the invoice, the amount and both return URLs", %{stripe: stripe} do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:stripe_body, URI.decode_query(body)})

      Req.Test.json(conn, %{
        "id" => "cs_x",
        "url" => "https://x.test/",
        "expires_at" => 4_102_444_800
      })
    end)

    {:ok, %{invoice: invoice}} = Billing.start_order_payment(order!(stripe), @urls)

    assert_received {:stripe_body, params}
    assert params["success_url"] == "https://shop.test/done"
    assert params["cancel_url"] == "https://shop.test/cancel"
    assert params["metadata[invoice_uuid]"] == invoice.uuid

    assert Enum.any?(params, fn {k, v} -> k =~ "unit_amount" and v == "2500" end)
  end

  test "the provider's webhook then pays the invoice and the order", %{stripe: stripe} do
    order = order!(stripe)
    {:ok, %{invoice: invoice}} = Billing.start_order_payment(order, @urls)

    assert {:ok, paid} =
             WebhookProcessor.process(%{
               event_id: "evt_order_payment_#{System.unique_integer([:positive])}",
               provider: :stripe,
               type: "checkout.completed",
               data: %{
                 mode: "payment",
                 invoice_uuid: invoice.uuid,
                 amount_total: 2500,
                 currency: "EUR",
                 payment_intent_id: "pi_order_1"
               }
             })

    assert paid.status == "paid"
    assert Repo.get!(Order, order.uuid).status == "paid"
    assert {:error, :already_paid} = Billing.start_order_payment(order, @urls)
  end

  test "accepts the order uuid", %{stripe: stripe} do
    order = order!(stripe)

    assert {:ok, %{url: _}} = Billing.start_order_payment(order.uuid, @urls)
  end

  test "the customer_email option is the recipient on the send history", %{stripe: stripe} do
    order = order!(stripe)

    assert {:ok, %{invoice: invoice}} =
             Billing.start_order_payment(order, [{:customer_email, "x@example.com"} | @urls])

    assert hd(invoice.metadata["send_history"])["email"] == "x@example.com"
  end

  test "an offline option is not payable online", %{cod: cod} do
    assert {:error, :order_not_payable} = Billing.start_order_payment(order!(cod), @urls)
  end

  test "an order without an option is not payable online" do
    {:ok, order} =
      Billing.create_order(fixture_user(), %{
        "total" => Decimal.new("5.00"),
        "currency" => "EUR",
        "billing_snapshot" => %{"email" => "b@example.com"}
      })

    assert {:error, :order_not_payable} = Billing.start_order_payment(order, @urls)
  end

  test "an unknown order", %{} do
    assert {:error, :order_not_found} =
             Billing.start_order_payment(Ecto.UUID.generate(), @urls)
  end

  test "a paid or cancelled order is refused", %{stripe: stripe} do
    paid = order!(stripe, %{"status" => "paid"})
    cancelled = order!(stripe, %{"status" => "cancelled"})

    assert {:error, :already_paid} = Billing.start_order_payment(paid, @urls)
    assert {:error, :order_not_payable} = Billing.start_order_payment(cancelled, @urls)
  end

  test "a provider that is not configured", %{stripe: stripe} do
    Settings.update_setting("billing_stripe_enabled", "false")

    assert {:error, :provider_not_available} =
             Billing.start_order_payment(order!(stripe), @urls)
  end

  test "a provider failure keeps the order and its sent invoice, and a retry works", %{
    stripe: stripe
  } do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => %{"message" => "boom"}})
    end)

    order = order!(stripe)
    assert {:error, _} = Billing.start_order_payment(order, @urls)

    assert %Order{status: "pending"} = Repo.get!(Order, order.uuid)
    assert [%Invoice{status: "sent"} = invoice] = Billing.list_invoices_for_order(order.uuid)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "id" => "cs_ok",
        "url" => "https://ok.test/",
        "expires_at" => 4_102_444_800
      })
    end)

    assert {:ok, %{invoice: again, url: "https://ok.test/"}} =
             Billing.start_order_payment(order, @urls)

    assert again.uuid == invoice.uuid
  end

  test "an already paid invoice answers :already_paid", %{stripe: stripe} do
    order = order!(stripe)
    {:ok, %{invoice: invoice}} = Billing.start_order_payment(order, @urls)

    Repo.update_all(from(i in Invoice, where: i.uuid == ^invoice.uuid), set: [status: "paid"])

    assert {:error, :already_paid} = Billing.start_order_payment(order, @urls)
  end

  test "concurrent starts open one invoice and one session", %{stripe: stripe, counter: counter} do
    order = order!(stripe)
    parent = self()

    results =
      1..4
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          Req.Test.allow(__MODULE__, parent, self())
          Billing.start_order_payment(order, @urls)
        end)
      end)
      |> Task.await_many(15_000)

    assert Enum.all?(results, &match?({:ok, %{url: "https://checkout.stripe.test/1"}}, &1))
    assert :counters.get(counter, 1) == 1
    assert length(Billing.list_invoices_for_order(order.uuid)) == 1
  end

  test "an existing draft invoice is sent and reused, and an overdue one is reused", %{
    stripe: stripe
  } do
    order = order!(stripe)
    {:ok, draft} = Billing.create_invoice_from_order(order)

    {:ok, %{invoice: sent}} = Billing.start_order_payment(order, @urls)
    assert sent.uuid == draft.uuid and sent.status == "sent"

    Repo.update_all(from(i in Invoice, where: i.uuid == ^sent.uuid), set: [status: "overdue"])
    {:ok, %{invoice: overdue}} = Billing.start_order_payment(order, @urls)
    assert overdue.uuid == sent.uuid and overdue.status == "overdue"
  end

  test "the :provider option overrides the option's provider", %{cod: cod} do
    assert {:ok, %{url: _}} =
             Billing.start_order_payment(order!(cod), [{:provider, :stripe} | @urls])
  end

  test "success_url is required", %{stripe: stripe} do
    assert_raise KeyError, fn -> Billing.start_order_payment(order!(stripe), []) end
  end

  describe "the amount Stripe is asked for" do
    defp capture_stripe_body do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:stripe_body, URI.decode_query(body)})

        Req.Test.json(conn, %{
          "id" => "cs_amount",
          "url" => "https://x.test/",
          "expires_at" => 4_102_444_800
        })
      end)
    end

    # What Stripe would charge: the sum of unit_amount * quantity.
    defp stripe_charge(params) do
      amounts =
        for {k, v} <- params, String.ends_with?(k, "[unit_amount]"), into: %{} do
          {String.replace(k, "[price_data][unit_amount]", ""), String.to_integer(v)}
        end

      Enum.reduce(amounts, 0, fn {prefix, amount}, sum ->
        sum + amount * String.to_integer(Map.get(params, prefix <> "[quantity]", "1"))
      end)
    end

    defp pay!(invoice, amount_minor) do
      assert {:ok, paid} =
               WebhookProcessor.process(%{
                 event_id: "evt_amount_#{System.unique_integer([:positive])}",
                 provider: :stripe,
                 type: "checkout.completed",
                 data: %{
                   mode: "payment",
                   invoice_uuid: invoice.uuid,
                   amount_total: amount_minor,
                   currency: "EUR",
                   payment_intent_id: "pi_#{System.unique_integer([:positive])}"
                 }
               })

      paid
    end

    test "an order with tax is charged its total, and the webhook pays it", %{stripe: stripe} do
      capture_stripe_body()

      order =
        order!(stripe, %{
          "subtotal" => Decimal.new("25.00"),
          "tax_amount" => Decimal.new("5.00"),
          "tax_rate" => Decimal.new("0.20"),
          "total" => Decimal.new("30.00")
        })

      {:ok, %{invoice: invoice}} = Billing.start_order_payment(order, @urls)

      assert_received {:stripe_body, params}
      assert stripe_charge(params) == 3000
      assert params["line_items[0][price_data][product_data][name]"] =~ invoice.invoice_number

      assert pay!(invoice, 3000).status == "paid"
      assert Repo.get!(Order, order.uuid).status == "paid"
    end

    test "an order with a discount is charged its total, and the webhook pays it", %{
      stripe: stripe
    } do
      capture_stripe_body()

      order =
        order!(stripe, %{
          "subtotal" => Decimal.new("25.00"),
          "discount_amount" => Decimal.new("5.00"),
          "total" => Decimal.new("20.00")
        })

      {:ok, %{invoice: invoice}} = Billing.start_order_payment(order, @urls)

      assert_received {:stripe_body, params}
      assert stripe_charge(params) == 2000

      assert pay!(invoice, 2000).status == "paid"
      assert Repo.get!(Order, order.uuid).status == "paid"
    end

    test "a partly paid invoice is charged what is left", %{stripe: stripe} do
      capture_stripe_body()
      order = order!(stripe)

      {:ok, %{invoice: invoice}} = Billing.start_order_payment(order, @urls)
      assert_received {:stripe_body, first}
      assert stripe_charge(first) == 2500

      {:ok, _} = Billing.record_payment(invoice, %{amount: Decimal.new("10.00")}, nil)

      {:ok, _} = Billing.start_order_payment(order, @urls)

      assert_received {:stripe_body, params}
      assert stripe_charge(params) == 1500

      assert pay!(invoice, 1500).status == "paid"
      assert Repo.get!(Order, order.uuid).status == "paid"
    end

    test "an order whose lines add up to the total keeps its own lines", %{stripe: stripe} do
      capture_stripe_body()
      {:ok, _} = Billing.start_order_payment(order!(stripe), @urls)

      assert_received {:stripe_body, params}
      assert params["line_items[0][price_data][product_data][name]"] == "Vase"
    end
  end

  test "a session opened for another amount is not reused", %{stripe: stripe} do
    order = order!(stripe)
    {:ok, %{invoice: invoice, url: first}} = Billing.start_order_payment(order, @urls)

    {:ok, _} = Billing.record_payment(invoice, %{amount: Decimal.new("10.00")}, nil)
    {:ok, %{url: second}} = Billing.start_order_payment(order, @urls)

    assert first != second
  end

  test "a string quantity is charged as the amount due, not a crash", %{stripe: stripe} do
    capture_stripe_body()

    order =
      order!(stripe, %{
        "line_items" => [
          %{"name" => "Vase", "quantity" => "1", "unit_price" => "25.00", "total" => "25.00"}
        ]
      })

    assert {:ok, _} = Billing.start_order_payment(order, @urls)
    assert_received {:stripe_body, params}
    assert Enum.any?(params, fn {k, v} -> k =~ "unit_amount" and v == "2500" end)
  end

  test "an order with a zero total is not payable online", %{stripe: stripe} do
    order = order!(stripe, %{"total" => Decimal.new("0")})

    assert {:error, :order_not_payable} = Billing.start_order_payment(order, @urls)
    assert Billing.list_invoices_for_order(order.uuid) == []
  end

  test "a call made inside a transaction is refused and does nothing", %{stripe: stripe} do
    order = order!(stripe)

    assert {:error, :in_transaction} =
             Repo.transaction(fn -> Billing.start_order_payment(order, @urls) end)
             |> elem(1)

    assert Billing.list_invoices_for_order(order.uuid) == []
  end

  describe "the per-order lock" do
    setup do
      config = Application.fetch_env!(:phoenix_kit_billing, Repo)

      {:ok, conn} =
        Postgrex.start_link(
          Keyword.take(config, [:hostname, :port, :username, :password, :database])
        )

      {:ok, conn: conn}
    end

    defp try_lock(conn, order) do
      key = PhoenixKitBilling.OrderPayment.lock_key(order.uuid)

      %{rows: [[locked?]]} =
        Postgrex.query!(conn, "SELECT pg_try_advisory_lock(hashtext($1))", [key])

      locked?
    end

    test "is held on another connection while the provider is called, and released after", %{
      stripe: stripe,
      conn: conn
    } do
      order = order!(stripe)
      parent = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, {:in_stripe, self()})

        receive do
          :go -> :ok
        after
          10_000 -> :timeout
        end

        Req.Test.json(conn, %{
          "id" => "cs_lock",
          "url" => "https://x.test/",
          "expires_at" => 4_102_444_800
        })
      end)

      task = Task.async(fn -> Billing.start_order_payment(order, @urls) end)

      assert_receive {:in_stripe, stripe_pid}, 5_000
      refute try_lock(conn, order)

      send(stripe_pid, :go)
      assert {:ok, %{url: "https://x.test/"}} = Task.await(task, 15_000)

      assert try_lock(conn, order)
    end

    test "a start that cannot get the lock answers :lock_timeout and leaves no invoice", %{
      stripe: stripe,
      conn: conn
    } do
      order = order!(stripe)
      key = PhoenixKitBilling.OrderPayment.lock_key(order.uuid)
      Postgrex.query!(conn, "SELECT pg_advisory_lock(hashtext($1))", [key])

      Application.put_env(:phoenix_kit_billing, :order_payment_lock_wait_ms, 300)
      on_exit(fn -> Application.delete_env(:phoenix_kit_billing, :order_payment_lock_wait_ms) end)

      assert {:error, :lock_timeout} = Billing.start_order_payment(order, @urls)
      assert Billing.list_invoices_for_order(order.uuid) == []
    end

    test "is released when the provider fails", %{stripe: stripe, conn: conn} do
      order = order!(stripe)
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "{}") end)

      assert {:error, _} = Billing.start_order_payment(order, @urls)
      assert try_lock(conn, order)
    end
  end
end
