defmodule PhoenixKitBilling.StripeRefundWebhooksTest do
  @moduledoc """
  A refund made in the Stripe dashboard for a payment taken through Checkout
  was acknowledged with 200 and never applied: the payment is recorded from
  `checkout.session.completed` under the PaymentIntent id (`pi_…`), while the
  `charge.refunded` event names the charge (`ch_…`), and the processor looked
  the payment up by that id alone.

  These feed Stripe-shaped event payloads through the provider's normalizer
  and the webhook processor, so the shapes asserted are the ones Stripe sends:
  a `charge.refunded` object carries `payment_intent` and the charge's
  CUMULATIVE `amount_refunded`, and no `refunds` list (it is "not returned by
  default" on current API versions).
  """

  use PhoenixKitBilling.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKitBilling, as: Billing

  alias PhoenixKitBilling.{
    Currency,
    Events,
    Providers,
    Transaction,
    WebhookEvent,
    WebhookProcessor
  }

  setup do
    Repo.delete_all(Currency)

    {:ok, _eur} =
      Billing.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        is_default: true,
        exchange_rate: "1.0"
      })

    :ok
  end

  defp user_fixture do
    {:ok, user} =
      Auth.register_user(
        %{
          email: "refund-#{System.unique_integer([:positive])}@example.com",
          password: "hello world!123"
        },
        nil
      )

    user
  end

  # An issued invoice (EUR 30.00 unless told otherwise) with a linked order,
  # as a Checkout Session would be created for it.
  defp invoice_fixture(user, currency \\ "EUR", total \\ "30.00") do
    {:ok, order} =
      Billing.create_order(user, %{
        "line_items" => [
          %{"name" => "Item", "quantity" => 1, "unit_price" => total, "total" => total}
        ],
        "subtotal" => Decimal.new(total),
        "total" => Decimal.new(total),
        "currency" => currency,
        "status" => "pending",
        "billing_snapshot" => %{"email" => user.email}
      })

    {:ok, invoice} = Billing.create_invoice_from_order(order)

    {:ok, sent} =
      invoice
      |> Ecto.Changeset.change(%{status: "sent"})
      |> RepoHelper.repo().update()

    {sent, order}
  end

  defp event_id, do: "evt_#{System.unique_integer([:positive])}"

  defp checkout_completed(invoice, payment_intent, cents, currency) do
    %{
      "id" => event_id(),
      "type" => "checkout.session.completed",
      "data" => %{
        "object" => %{
          "id" => "cs_test_#{System.unique_integer([:positive])}",
          "object" => "checkout.session",
          "mode" => "payment",
          "payment_status" => "paid",
          "payment_intent" => payment_intent,
          "amount_total" => cents,
          "currency" => currency,
          "metadata" => %{"invoice_uuid" => invoice.uuid}
        }
      }
    }
  end

  # `charge.refunded` as current API versions deliver it: no `refunds` list.
  defp charge_refunded(charge, payment_intent, refunded_total, opts \\ []) do
    amount = Keyword.get(opts, :amount, 3000)

    object =
      %{
        "id" => charge,
        "object" => "charge",
        "amount" => amount,
        "amount_refunded" => refunded_total,
        "currency" => Keyword.get(opts, :currency, "eur"),
        "payment_intent" => payment_intent,
        "refunded" => refunded_total >= amount
      }

    object =
      case Keyword.get(opts, :refunds) do
        nil -> object
        ids -> Map.put(object, "refunds", %{"data" => Enum.map(ids, &%{"id" => &1})})
      end

    %{
      "id" => Keyword.get(opts, :event_id, event_id()),
      "type" => "charge.refunded",
      "data" => %{"object" => object}
    }
  end

  defp deliver(payload) do
    {:ok, event} = Providers.handle_webhook_event(:stripe, payload)
    WebhookProcessor.process(event)
  end

  defp refund_rows(invoice) do
    Repo.all(
      from(t in Transaction,
        where: t.invoice_uuid == ^invoice.uuid and t.amount < 0,
        order_by: [asc: t.inserted_at, asc: t.transaction_number]
      )
    )
  end

  defp refunded_cents(invoice) do
    invoice
    |> refund_rows()
    |> Enum.map(&Decimal.mult(Decimal.abs(&1.amount), 100))
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
    |> Decimal.to_integer()
  end

  # Pays the invoice the way a Checkout Session does: `checkout.session.completed`.
  defp pay_by_checkout(invoice, payment_intent, cents \\ 3000, currency \\ "eur") do
    assert {:ok, %{status: "paid"}} =
             deliver(checkout_completed(invoice, payment_intent, cents, currency))
  end

  describe "a payment taken through Checkout (stored under the PaymentIntent id)" do
    test "a full refund reported by charge id is applied to the invoice and its order" do
      {invoice, order} = invoice_fixture(user_fixture())
      pay_by_checkout(invoice, "pi_checkout_1")

      Events.subscribe_orders()

      assert {:ok, %Transaction{} = refund} =
               deliver(charge_refunded("ch_checkout_1", "pi_checkout_1", 3000))

      assert Decimal.equal?(refund.amount, Decimal.new("-30.00"))
      assert refund.payment_method == "stripe"
      # What a later refund on the invoice reads back: the ids of the payment
      # this one reversed.
      stored = Repo.get!(Transaction, refund.uuid)
      assert stored.provider_data["charge_id"] == "ch_checkout_1"
      assert stored.provider_data["payment_intent_id"] == "pi_checkout_1"

      refunded = Billing.get_invoice!(invoice.uuid)
      assert Decimal.equal?(refunded.paid_amount, Decimal.new("0"))
      assert refunded.status == "void"

      assert Billing.get_order!(order.uuid).status == "refunded"
      assert_receive {:order_refunded, %{uuid: uuid, status: "refunded"}}
      assert uuid == order.uuid
    end

    test "a partial refund leaves the invoice and the order paid" do
      {invoice, order} = invoice_fixture(user_fixture())
      pay_by_checkout(invoice, "pi_checkout_2")

      Events.subscribe_orders()

      assert {:ok, %Transaction{amount: amount}} =
               deliver(charge_refunded("ch_checkout_2", "pi_checkout_2", 1000))

      assert Decimal.equal?(amount, Decimal.new("-10.00"))

      partly = Billing.get_invoice!(invoice.uuid)
      assert Decimal.equal?(partly.paid_amount, Decimal.new("20.00"))
      assert partly.status == "paid"

      assert Billing.get_order!(order.uuid).status == "paid"
      refute_receive {:order_refunded, _}
    end

    test "several partial refunds on one charge are recorded one by one, not as repeated running totals" do
      {invoice, order} = invoice_fixture(user_fixture())
      pay_by_checkout(invoice, "pi_checkout_3")

      # Stripe's `amount_refunded` is the running total: 10, then 20, then 30.
      assert {:ok, %Transaction{}} =
               deliver(charge_refunded("ch_checkout_3", "pi_checkout_3", 1000))

      assert {:ok, %Transaction{}} =
               deliver(charge_refunded("ch_checkout_3", "pi_checkout_3", 2000))

      assert [-1000, -1000] =
               invoice
               |> refund_rows()
               |> Enum.map(&(&1.amount |> Decimal.mult(100) |> Decimal.to_integer()))

      assert Decimal.equal?(Billing.get_invoice!(invoice.uuid).paid_amount, Decimal.new("10.00"))

      assert {:ok, %Transaction{}} =
               deliver(charge_refunded("ch_checkout_3", "pi_checkout_3", 3000))

      assert refunded_cents(invoice) == 3000
      assert Billing.get_order!(order.uuid).status == "refunded"
    end

    test "the same refund redelivered under a new event id records nothing more" do
      {invoice, _order} = invoice_fixture(user_fixture())
      pay_by_checkout(invoice, "pi_checkout_4")

      assert {:ok, %Transaction{}} =
               deliver(charge_refunded("ch_checkout_4", "pi_checkout_4", 1000))

      assert {:ok, :already_refunded} =
               deliver(charge_refunded("ch_checkout_4", "pi_checkout_4", 1000))

      assert refunded_cents(invoice) == 1000
    end

    test "the very same event redelivered is a duplicate" do
      {invoice, _order} = invoice_fixture(user_fixture())
      pay_by_checkout(invoice, "pi_checkout_5")

      payload =
        charge_refunded("ch_checkout_5", "pi_checkout_5", 1000, event_id: "evt_refund_dup")

      assert {:ok, %Transaction{}} = deliver(payload)
      assert {:error, :duplicate_event} = deliver(payload)
      assert refunded_cents(invoice) == 1000
    end

    test "events arriving out of order never record more than Stripe says was refunded" do
      {invoice, _order} = invoice_fixture(user_fixture())
      pay_by_checkout(invoice, "pi_checkout_6")

      assert {:ok, %Transaction{}} =
               deliver(charge_refunded("ch_checkout_6", "pi_checkout_6", 2000))

      assert {:ok, :already_refunded} =
               deliver(charge_refunded("ch_checkout_6", "pi_checkout_6", 1000))

      assert refunded_cents(invoice) == 2000
    end

    test "an API version that lists the refunds names the refund and reconciles a replay by total" do
      {invoice, _order} = invoice_fixture(user_fixture())
      pay_by_checkout(invoice, "pi_checkout_7")

      assert {:ok, %Transaction{} = refund} =
               deliver(
                 charge_refunded("ch_checkout_7", "pi_checkout_7", 1000,
                   refunds: ["re_2", "re_1"]
                 )
               )

      assert refund.provider_transaction_id == "re_2"

      # A different event that reports the same refund, with a total this
      # ledger has already passed.
      assert {:ok, :already_refunded} =
               deliver(
                 charge_refunded("ch_checkout_7", "pi_checkout_7", 1000,
                   refunds: ["re_2", "re_1"]
                 )
               )

      assert refunded_cents(invoice) == 1000
    end

    test "a refund with no refund id does not reuse the charge id as its own id" do
      {invoice, _order} = invoice_fixture(user_fixture())
      pay_by_checkout(invoice, "pi_checkout_8")

      assert {:ok, %Transaction{provider_transaction_id: nil}} =
               deliver(charge_refunded("ch_checkout_8", "pi_checkout_8", 1000))
    end
  end

  describe "finding the payment a refund belongs to" do
    test "a row recorded by charge id (a saved-card charge) is found by the charge id" do
      {invoice, _order} = invoice_fixture(user_fixture())

      {:ok, _payment} =
        Billing.record_payment(
          invoice,
          %{
            amount: Decimal.new("30.00"),
            payment_method: "stripe",
            provider_transaction_id: "ch_saved_1",
            provider_data: %{"metadata" => %{"payment_intent_id" => "pi_saved_1"}}
          },
          nil
        )

      assert {:ok, %Transaction{} = refund} =
               deliver(charge_refunded("ch_saved_1", "pi_saved_1", 3000))

      assert Decimal.equal?(refund.amount, Decimal.new("-30.00"))
    end

    test "an existing row that holds only the PaymentIntent id is found without a data migration" do
      {invoice, _order} = invoice_fixture(user_fixture())

      # Exactly what 0.22 wrote for a Checkout payment: the PaymentIntent id
      # and no charge id anywhere.
      {:ok, _payment} =
        Billing.record_payment(
          invoice,
          %{
            amount: Decimal.new("30.00"),
            payment_method: "stripe",
            provider_transaction_id: "pi_old_1",
            provider_data: %{"payment_intent_id" => "pi_old_1", "session_id" => "cs_old_1"}
          },
          nil
        )

      assert {:ok, %Transaction{} = refund} =
               deliver(charge_refunded("ch_old_1", "pi_old_1", 1000))

      assert Decimal.equal?(refund.amount, Decimal.new("-10.00"))
    end

    test "a payment that only names the PaymentIntent in its data is found by it" do
      {invoice, _order} = invoice_fixture(user_fixture())

      {:ok, _payment} =
        Billing.record_payment(
          invoice,
          %{
            amount: Decimal.new("30.00"),
            payment_method: "stripe",
            provider_transaction_id: "txn_host_recorded",
            provider_data: %{"payment_intent_id" => "pi_data_1"}
          },
          nil
        )

      assert {:ok, %Transaction{}} = deliver(charge_refunded("ch_data_1", "pi_data_1", 1000))
    end

    test "a second refund on a charge-id payment still finds the payment, not its own earlier refund" do
      {invoice, _order} = invoice_fixture(user_fixture())

      {:ok, _payment} =
        Billing.record_payment(
          invoice,
          %{
            amount: Decimal.new("30.00"),
            payment_method: "stripe",
            provider_transaction_id: "ch_saved_2"
          },
          nil
        )

      assert {:ok, %Transaction{}} = deliver(charge_refunded("ch_saved_2", "pi_saved_2", 1000))
      assert {:ok, %Transaction{}} = deliver(charge_refunded("ch_saved_2", "pi_saved_2", 2000))

      assert refunded_cents(invoice) == 2000
    end

    test "the refund goes to the invoice that took that payment, not another one" do
      user = user_fixture()
      {invoice_a, _} = invoice_fixture(user)
      {invoice_b, _} = invoice_fixture(user)
      pay_by_checkout(invoice_a, "pi_multi_a")
      pay_by_checkout(invoice_b, "pi_multi_b")

      assert {:ok, %Transaction{}} = deliver(charge_refunded("ch_multi_b", "pi_multi_b", 3000))

      assert refunded_cents(invoice_a) == 0
      assert refunded_cents(invoice_b) == 3000
    end
  end

  describe "refunds this ledger already knows about" do
    test "a recorded latest refund does not hide an earlier refund in the running total" do
      {invoice, _order} = invoice_fixture(user_fixture())
      pay_by_checkout(invoice, "pi_host_latest")

      {:ok, _refund} =
        Billing.record_refund(
          Billing.get_invoice!(invoice.uuid),
          %{amount: "10.00", payment_method: "stripe", provider_transaction_id: "re_latest"},
          nil
        )

      assert {:ok, %Transaction{amount: amount}} =
               deliver(
                 charge_refunded("ch_host_latest", "pi_host_latest", 2000,
                   refunds: ["re_latest", "re_earlier"]
                 )
               )

      assert Decimal.equal?(amount, Decimal.new("-10.00"))
      assert refunded_cents(invoice) == 2000
    end

    test "a payment id belonging to another provider is not matched" do
      {invoice, _order} = invoice_fixture(user_fixture())

      {:ok, _payment} =
        Billing.record_payment(
          invoice,
          %{amount: "30.00", payment_method: "paypal", provider_transaction_id: "pi_foreign"},
          nil
        )

      capture_log(fn ->
        assert {:ok, :unmatched_refund} =
                 deliver(charge_refunded("ch_foreign", "pi_foreign", 1000))
      end)

      assert refund_rows(invoice) == []
    end

    test "a refund the host recorded after creating it at Stripe is not recorded again by the webhook" do
      {invoice, _order} = invoice_fixture(user_fixture())
      pay_by_checkout(invoice, "pi_host_1")

      # What a host does after `Providers.create_refund/4`: record the refund
      # under Stripe's refund id.
      {:ok, _host_refund} =
        Billing.record_refund(
          Billing.get_invoice!(invoice.uuid),
          %{
            amount: Decimal.new("10.00"),
            payment_method: "stripe",
            provider_transaction_id: "re_host_1"
          },
          nil
        )

      assert {:ok, :already_refunded} = deliver(charge_refunded("ch_host_1", "pi_host_1", 1000))
      assert refunded_cents(invoice) == 1000

      # A later refund made in the dashboard adds only its own amount.
      assert {:ok, %Transaction{amount: amount}} =
               deliver(charge_refunded("ch_host_1", "pi_host_1", 2500))

      assert Decimal.equal?(amount, Decimal.new("-15.00"))
    end

    test "a refund of one payment is not counted against another payment of the same invoice" do
      {invoice, _order} = invoice_fixture(user_fixture())

      for {amount, payment_intent} <- [{"10.00", "pi_two_a"}, {"20.00", "pi_two_b"}] do
        {:ok, _payment} =
          Billing.record_payment(
            Billing.get_invoice!(invoice.uuid),
            %{
              amount: Decimal.new(amount),
              payment_method: "stripe",
              provider_transaction_id: payment_intent,
              provider_data: %{"payment_intent_id" => payment_intent}
            },
            nil
          )
      end

      assert {:ok, %Transaction{amount: first}} =
               deliver(charge_refunded("ch_two_a", "pi_two_a", 500, amount: 1000))

      # 5.00 of the other payment is already in the ledger; this charge has
      # had none of its own refunded yet.
      assert {:ok, %Transaction{amount: second}} =
               deliver(charge_refunded("ch_two_b", "pi_two_b", 500, amount: 2000))

      assert Decimal.equal?(first, Decimal.new("-5.00"))
      assert Decimal.equal?(second, Decimal.new("-5.00"))
    end

    test "a refund of another payment method on the invoice is not counted against the charge" do
      {invoice, _order} = invoice_fixture(user_fixture())
      pay_by_checkout(invoice, "pi_mixed_1")

      {:ok, _bank_refund} =
        Billing.record_refund(
          Billing.get_invoice!(invoice.uuid),
          %{amount: Decimal.new("5.00"), payment_method: "bank"},
          nil
        )

      assert {:ok, %Transaction{amount: amount}} =
               deliver(charge_refunded("ch_mixed_1", "pi_mixed_1", 1000))

      assert Decimal.equal?(amount, Decimal.new("-10.00"))
    end
  end

  describe "a refund that matches no recorded payment" do
    test "is reported at error level with the provider ids, and acknowledged" do
      log =
        capture_log([level: :error], fn ->
          assert {:ok, :unmatched_refund} =
                   deliver(
                     charge_refunded("ch_foreign_1", "pi_foreign_1", 1000,
                       event_id: "evt_foreign_1"
                     )
                   )
        end)

      assert log =~ "ch_foreign_1"
      assert log =~ "pi_foreign_1"
    end

    test "records no transaction and leaves a trace on the stored event" do
      {invoice, _order} = invoice_fixture(user_fixture())
      pay_by_checkout(invoice, "pi_mine_1")

      capture_log([level: :error], fn ->
        assert {:ok, :unmatched_refund} =
                 deliver(
                   charge_refunded("ch_foreign_2", "pi_foreign_2", 1000,
                     event_id: "evt_foreign_2"
                   )
                 )
      end)

      assert refunded_cents(invoice) == 0

      stored = Repo.get_by!(WebhookEvent, provider: "stripe", event_id: "evt_foreign_2")
      assert stored.processed
      assert stored.error_message =~ "refund"
    end

    test "an ordinary processed event carries no such trace" do
      {invoice, _order} = invoice_fixture(user_fixture())
      pay_by_checkout(invoice, "pi_mine_2")

      payload = charge_refunded("ch_mine_2", "pi_mine_2", 1000, event_id: "evt_mine_2")
      assert {:ok, %Transaction{}} = deliver(payload)

      stored = Repo.get_by!(WebhookEvent, provider: "stripe", event_id: "evt_mine_2")
      assert stored.processed
      assert is_nil(stored.error_message)
    end
  end

  describe "a running total the ledger cannot take in" do
    # 25.00 of the invoice is already refunded, against another payment; the
    # total Stripe reports for THIS payment is the whole 30.00. Nothing this
    # processor can record reconciles the two.
    defp ledger_ahead_of_stripe(payment_intent) do
      {invoice, _order} = invoice_fixture(user_fixture())
      pay_by_checkout(invoice, payment_intent)

      {:ok, _other} =
        Billing.record_refund(
          Billing.get_invoice!(invoice.uuid),
          %{
            amount: Decimal.new("25.00"),
            payment_method: "stripe",
            provider_transaction_id: "re_other_#{payment_intent}",
            provider_data: %{"payment_intent_id" => "pi_other_#{payment_intent}"}
          },
          nil
        )

      invoice
    end

    test "fails the event instead of acknowledging it as a duplicate" do
      invoice = ledger_ahead_of_stripe("pi_gap_1")

      log =
        capture_log([level: :error], fn ->
          assert {:error, :refund_exceeds_paid_amount} =
                   deliver(charge_refunded("ch_gap_1", "pi_gap_1", 3000, event_id: "evt_gap_1"))
        end)

      assert log =~ "ch_gap_1"
      assert log =~ "pi_gap_1"

      # Nothing was recorded, and the invoice is not mistaken for refunded.
      assert refunded_cents(invoice) == 2500
      assert Decimal.equal?(Billing.get_invoice!(invoice.uuid).paid_amount, Decimal.new("5.00"))

      # The stored event is failed, so Stripe redelivers it and the processor
      # counts the attempt.
      stored = Repo.get_by!(WebhookEvent, provider: "stripe", event_id: "evt_gap_1")
      refute stored.processed
      assert stored.retry_count == 1
      assert stored.error_message =~ "refund_exceeds_paid_amount"
    end

    test "a redelivery reads the ledger as it is by then and records the remainder" do
      invoice = ledger_ahead_of_stripe("pi_gap_2")
      payload = charge_refunded("ch_gap_2", "pi_gap_2", 3000, event_id: "evt_gap_2")

      capture_log([level: :error], fn ->
        assert {:error, :refund_exceeds_paid_amount} = deliver(payload)
      end)

      # The row turns out to be this payment's own (what a concurrent event
      # that had not committed yet looks like a moment later).
      from(t in Transaction, where: t.provider_transaction_id == "re_other_pi_gap_2")
      |> Repo.update_all(set: [provider_data: %{"payment_intent_id" => "pi_gap_2"}])

      assert {:ok, %Transaction{amount: amount}} = deliver(payload)
      assert Decimal.equal?(amount, Decimal.new("-5.00"))
      assert refunded_cents(invoice) == 3000

      stored = Repo.get_by!(WebhookEvent, provider: "stripe", event_id: "evt_gap_2")
      assert stored.processed
    end

    test "an event in a currency the shop does not know is not guessed at" do
      {invoice, _order} = invoice_fixture(user_fixture())
      pay_by_checkout(invoice, "pi_gbp_1")

      log =
        capture_log([level: :error], fn ->
          assert {:error, :refund_total_indeterminate} =
                   deliver(
                     charge_refunded("ch_gbp_1", "pi_gbp_1", 1000,
                       currency: "gbp",
                       event_id: "evt_gbp_1"
                     )
                   )
        end)

      assert log =~ "ch_gbp_1"

      # Not "the whole payment" and not anything else.
      assert refunded_cents(invoice) == 0
      assert Decimal.equal?(Billing.get_invoice!(invoice.uuid).paid_amount, Decimal.new("30.00"))

      stored = Repo.get_by!(WebhookEvent, provider: "stripe", event_id: "evt_gbp_1")
      refute stored.processed
      assert stored.retry_count == 1
    end

    test "a zero-decimal currency reconciles the running total in whole units" do
      {:ok, _jpy} =
        Billing.create_currency(%{
          code: "JPY",
          name: "Yen",
          symbol: "¥",
          decimal_places: 0,
          exchange_rate: "150.0"
        })

      {invoice, _order} = invoice_fixture(user_fixture(), "JPY", "1000")
      pay_by_checkout(invoice, "pi_jpy_1", 1000, "jpy")

      opts = [amount: 1000, currency: "jpy"]

      assert {:ok, %Transaction{amount: first}} =
               deliver(charge_refunded("ch_jpy_1", "pi_jpy_1", 300, opts))

      assert {:ok, %Transaction{amount: second}} =
               deliver(charge_refunded("ch_jpy_1", "pi_jpy_1", 1000, opts))

      assert Decimal.equal?(first, Decimal.new("-300"))
      assert Decimal.equal?(second, Decimal.new("-700"))
    end
  end

  describe "a provider that reports one refund at a time" do
    for provider <- [:paypal, :razorpay, :everypay] do
      test "#{provider} payments retain their provider and can be refunded" do
        provider = unquote(provider)
        {invoice, _order} = invoice_fixture(user_fixture())
        payment_id = "#{provider}_payment"

        assert {:ok, _invoice} =
                 WebhookProcessor.process(%{
                   event_id: event_id(),
                   provider: provider,
                   type: "payment.succeeded",
                   data: %{
                     invoice_uuid: invoice.uuid,
                     charge_id: payment_id,
                     amount: 3000,
                     currency: "EUR"
                   }
                 })

        assert {:ok, %Transaction{payment_method: method, amount: amount}} =
                 WebhookProcessor.process(%{
                   event_id: event_id(),
                   provider: provider,
                   type: "refund.created",
                   data: %{
                     charge_id: payment_id,
                     refund_id: "refund_#{provider}",
                     amount: 1000,
                     currency: "EUR"
                   }
                 })

        assert method == to_string(provider)
        assert Decimal.equal?(amount, Decimal.new("-10.00"))
      end
    end

    test "a refund larger than what was paid is still dropped as already applied" do
      {invoice, _order} = invoice_fixture(user_fixture())

      {:ok, _payment} =
        Billing.record_payment(
          invoice,
          %{
            amount: Decimal.new("30.00"),
            payment_method: "razorpay",
            provider_transaction_id: "pay_rz_1"
          },
          nil
        )

      assert {:ok, %Transaction{}} =
               WebhookProcessor.process(%{
                 event_id: "evt_rz_1",
                 provider: :razorpay,
                 type: "refund.created",
                 data: %{
                   charge_id: "pay_rz_1",
                   refund_id: "rfnd_1",
                   amount_refunded: 3000,
                   currency: "EUR"
                 }
               })

      # The same refund again under another event id: the id is in the ledger.
      assert {:ok, :already_recorded} =
               WebhookProcessor.process(%{
                 event_id: "evt_rz_2",
                 provider: :razorpay,
                 type: "refund.created",
                 data: %{
                   charge_id: "pay_rz_1",
                   refund_id: "rfnd_1",
                   amount_refunded: 3000,
                   currency: "EUR"
                 }
               })

      # A different refund of an amount nothing is left to refund.
      assert {:ok, :already_refunded} =
               WebhookProcessor.process(%{
                 event_id: "evt_rz_3",
                 provider: :razorpay,
                 type: "refund.created",
                 data: %{
                   charge_id: "pay_rz_1",
                   refund_id: "rfnd_2",
                   amount_refunded: 1000,
                   currency: "EUR"
                 }
               })
    end
  end
end
