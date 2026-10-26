defmodule PhoenixKitBilling.Web.OrderFormCancelForgeryTest do
  @moduledoc """
  The order form must not be a way round `cancel_order/3`: a crafted submit
  with `status: cancelled` and a forged `cancelled_from` is refused.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing

  setup %{conn: conn} do
    Settings.update_setting("billing_enabled", "true")
    user = fixture_user()
    scope = fake_scope(user_uuid: user.uuid, email: user.email)
    {:ok, conn: put_test_scope(conn, scope), user: user}
  end

  defp pending_order(user) do
    {:ok, order} =
      Billing.create_order(user, %{
        "total" => Decimal.new("99.00"),
        "currency" => "EUR",
        "status" => "pending",
        "billing_snapshot" => %{"email" => "g@example.com"},
        "line_items" => [%{"name" => "Item", "total" => "99.00"}]
      })

    order
  end

  test "a crafted submit cannot cancel an order or forge cancelled_from", %{
    conn: conn,
    user: user
  } do
    order = pending_order(user)
    {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}/edit")

    render_submit(view, "save", %{
      "order" => %{
        "currency" => "EUR",
        "status" => "cancelled",
        "metadata" => %{"cancelled_from" => "draft"}
      }
    })

    stored = Billing.get_order!(order.uuid)
    assert stored.status == "pending"
    assert stored.cancelled_at == nil
    refute Map.has_key?(stored.metadata, "cancelled_from")
  end

  test "the form still saves its legitimate status choices", %{conn: conn, user: user} do
    order = pending_order(user)
    {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}/edit")

    render_submit(view, "save", %{"order" => %{"currency" => "EUR", "status" => "confirmed"}})

    assert Billing.get_order!(order.uuid).status == "confirmed"
  end

  test "a crafted submit cannot move a pending order back to draft", %{conn: conn, user: user} do
    order = pending_order(user)
    {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}/edit")

    render_submit(view, "save", %{"order" => %{"currency" => "EUR", "status" => "draft"}})

    assert Billing.get_order!(order.uuid).status == "pending"
  end

  test "the status select offers only the statuses reachable from the current one", %{
    conn: conn,
    user: user
  } do
    order = pending_order(user)
    {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}/edit")

    refute has_element?(view, "select[name='order[status]'] option[value=draft]")
    assert has_element?(view, "select[name='order[status]'] option[value=pending]")
    assert has_element?(view, "select[name='order[status]'] option[value=confirmed]")
  end
end
