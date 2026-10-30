defmodule PhoenixKitBilling.Providers.StripeRefundEventsTest do
  @moduledoc """
  How `Stripe.handle_webhook_event/1` normalizes `charge.refunded`.

  A `charge.refunded` object carries `payment_intent` - the only id that ties
  it to a Checkout payment, which is recorded under the PaymentIntent and has
  no charge id - and the charge's CUMULATIVE `amount_refunded`. It lists its
  `refunds` only on API versions that still embed them ("not returned by
  default" in Stripe's Charge reference).
  """

  use ExUnit.Case, async: true

  alias PhoenixKitBilling.Providers.Stripe
  alias PhoenixKitBilling.Providers.Types.WebhookEventData

  defp charge_refunded(object_overrides) do
    object =
      Map.merge(
        %{
          "id" => "ch_test_refund_1",
          "object" => "charge",
          "amount" => 3000,
          "amount_refunded" => 1500,
          "currency" => "eur",
          "payment_intent" => "pi_test_refund_1",
          "refunded" => false
        },
        object_overrides
      )

    %{"id" => "evt_refund", "type" => "charge.refunded", "data" => %{"object" => object}}
  end

  test "carries both ids and the charge's running total, and no refund id when no refunds are listed" do
    assert {:ok, %WebhookEventData{type: "refund.created", provider: :stripe, data: data}} =
             Stripe.handle_webhook_event(charge_refunded(%{}))

    assert data.charge_id == "ch_test_refund_1"
    assert data.payment_intent_id == "pi_test_refund_1"
    assert data.amount_refunded_total == 1500
    assert data.currency == "eur"
    assert data.refund_id == nil
  end

  test "names the newest refund when the API version lists them" do
    refunds = %{"data" => [%{"id" => "re_newest"}, %{"id" => "re_older"}]}

    assert {:ok, %WebhookEventData{data: data}} =
             Stripe.handle_webhook_event(charge_refunded(%{"refunds" => refunds}))

    assert data.refund_id == "re_newest"
  end

  test "a charge made outside a PaymentIntent has no payment_intent_id" do
    assert {:ok, %WebhookEventData{data: data}} =
             Stripe.handle_webhook_event(charge_refunded(%{"payment_intent" => nil}))

    assert data.charge_id == "ch_test_refund_1"
    assert data.payment_intent_id == nil
  end

  # They describe the refunds `charge.refunded` already reports, and the two
  # streams cannot be matched against each other.
  test "the refund.created and refund.updated events are not consumed" do
    refund = %{
      "id" => "re_test_refund_1",
      "object" => "refund",
      "amount" => 1500,
      "charge" => "ch_test_refund_1",
      "currency" => "eur",
      "payment_intent" => "pi_test_refund_1",
      "status" => "succeeded"
    }

    for type <- ["refund.created", "refund.updated"] do
      assert {:error, :unknown_event} =
               Stripe.handle_webhook_event(%{
                 "id" => "evt_refund",
                 "type" => type,
                 "data" => %{"object" => refund}
               })
    end
  end

  test "a refunds list that is empty leaves the refund id unknown" do
    assert {:ok, %WebhookEventData{data: data}} =
             Stripe.handle_webhook_event(charge_refunded(%{"refunds" => %{"data" => []}}))

    assert data.refund_id == nil
  end
end
