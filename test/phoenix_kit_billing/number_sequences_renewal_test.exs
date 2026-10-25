defmodule PhoenixKitBilling.NumberSequencesRenewalTest do
  @moduledoc """
  The renewal worker creates its invoice inside the transaction that holds the
  subscription's row lock. An invoice that fails validation must come back as
  an ordinary `{:error, changeset}` there, so `handle_payment_failure` can still
  mark the subscription past due - an aborted transaction would make that
  update raise.
  """

  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Subscription
  alias PhoenixKitBilling.SubscriptionType
  alias PhoenixKitBilling.Workers.SubscriptionRenewalWorker

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual})
    :ok
  end

  test "an invoice that fails validation leaves the subscription past due" do
    user = fixture_user()

    {:ok, type} =
      Billing.create_subscription_type(%{
        name: "Plan",
        slug: "plan-#{System.unique_integer([:positive])}",
        price: Decimal.new("5.00"),
        currency: "EUR"
      })

    {:ok, subscription} =
      Billing.create_subscription(user.uuid, %{subscription_type_uuid: type.uuid})

    # A plan whose currency is not a code the invoice accepts, written around
    # its changeset: the renewal invoice then fails validation.
    Repo.update_all(from(t in SubscriptionType, where: t.uuid == ^type.uuid),
      set: [currency: "XX"]
    )

    job = %Oban.Job{args: %{"subscription_uuid" => subscription.uuid}}
    assert {:ok, _} = SubscriptionRenewalWorker.perform(job)

    assert %Subscription{status: "past_due", renewal_attempts: 1} =
             Repo.get!(Subscription, subscription.uuid)
  end
end
