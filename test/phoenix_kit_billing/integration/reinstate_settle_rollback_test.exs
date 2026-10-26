defmodule PhoenixKitBilling.Integration.ReinstateSettleRollbackTest do
  @moduledoc """
  A reinstate whose settlement fails after the order was written is taken back
  whole: the order stays cancelled, with its notes and metadata as they were.

  The failure is forced with a CHECK constraint on the orders table, added in
  the test's own sandbox transaction (and gone with it). `async: false`: the
  ALTER TABLE locks the table for the length of the test.
  """

  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, Order}
  alias PhoenixKitBilling.Test.Repo

  test "a payment that cannot be written takes the reinstate back with it" do
    user = fixture_user()

    {:ok, order} =
      Billing.create_order(user, %{
        "total" => Decimal.new("99.00"),
        "currency" => "EUR",
        "billing_snapshot" => %{"email" => "g@example.com"},
        "line_items" => [%{"name" => "Item", "total" => "99.00"}]
      })

    {:ok, confirmed} = Billing.confirm_order(order)
    {:ok, invoice} = Billing.create_invoice_from_order(confirmed)
    {:ok, sent} = invoice |> Invoice.status_changeset("sent") |> Repo.update()
    {:ok, cancelled} = Billing.cancel_order(confirmed, "first")
    {:ok, _} = Billing.mark_invoice_paid(sent)

    table = Order.__schema__(:source)

    Repo.query!(
      "ALTER TABLE #{table} ADD CONSTRAINT reinstate_test_no_paid CHECK (status <> 'paid')"
    )

    assert_raise Ecto.ConstraintError, ~r/reinstate_test_no_paid/, fn ->
      Billing.reinstate_order(cancelled, "back")
    end

    stored = Billing.get_order!(cancelled.uuid)
    assert stored.status == "cancelled"
    assert stored.internal_notes == cancelled.internal_notes
    assert stored.metadata["reinstated"] == nil
    assert Order.revision(stored) == Order.revision(cancelled)
  end
end
