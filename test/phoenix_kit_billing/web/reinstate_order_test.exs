defmodule PhoenixKitBilling.Web.ReinstateOrderTest do
  @moduledoc """
  A cancelled order's detail page offers Reinstate to an operator who may
  manage orders. It asks first, with an optional reason, then takes the order
  back to the status it was cancelled from and logs it in Activity.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing

  setup %{conn: conn} do
    Settings.update_setting("billing_enabled", "true")
    user = fixture_user()
    scope = fake_scope(user_uuid: user.uuid, email: user.email)
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, user: user}
  end

  defp cancelled_order(user, attrs \\ %{}) do
    {:ok, order} =
      Billing.create_order(
        user,
        Map.merge(
          %{
            "total" => Decimal.new("99.00"),
            "currency" => "EUR",
            "billing_snapshot" => %{"email" => "g@example.com"},
            "line_items" => [%{"name" => "Item", "total" => "99.00"}]
          },
          attrs
        )
      )

    {:ok, confirmed} = Billing.confirm_order(order)
    {:ok, cancelled} = Billing.cancel_order(confirmed, "Changed mind")
    cancelled
  end

  defp denied_conn(conn, permissions) do
    put_test_scope(conn, fake_scope(roles: ["Employee"], permissions: permissions))
  end

  test "asks first, then reinstates the order with the reason in its trail", %{
    conn: conn,
    user: user
  } do
    order = cancelled_order(user, %{"internal_notes" => "Called the customer"})
    {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")

    refute has_element?(view, "#reinstate-order-modal")
    view |> element("#reinstate-order-button") |> render_click()
    assert has_element?(view, "#reinstate-order-form textarea[name=reason][maxlength='500']")

    view
    |> form("#reinstate-order-form", %{"reason" => "Customer called back"})
    |> render_submit()

    refute has_element?(view, "#reinstate-order-modal")
    refute has_element?(view, "#reinstate-order-button")
    assert has_element?(view, "#flash-info", "Order reinstated")
    assert has_element?(view, "button[phx-click=mark_paid]")

    stored = Billing.get_order!(order.uuid)
    assert stored.status == "confirmed"
    assert stored.metadata["reinstated"]["reason"] == "Customer called back"
    assert stored.metadata["reinstated"]["by_uuid"] == user.uuid

    assert stored.internal_notes =~
             ~r/\ACalled the customer\n\nCancelled .*\n\nReinstated .* UTC: Customer called back\z/

    assert_activity_logged("billing.order_reinstated",
      resource_uuid: order.uuid,
      actor_uuid: user.uuid,
      metadata_has: %{"status" => "confirmed", "reason" => "Customer called back"}
    )
  end

  test "closing the confirmation reinstates nothing", %{conn: conn, user: user} do
    order = cancelled_order(user)
    {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")

    view |> element("#reinstate-order-button") |> render_click()
    view |> element("#reinstate-order-modal .modal-backdrop") |> render_click()

    refute has_element?(view, "#reinstate-order-modal")
    assert Billing.get_order!(order.uuid).status == "cancelled"
  end

  test "is offered only for a cancelled order", %{conn: conn, user: user} do
    {:ok, draft} =
      Billing.create_order(user, %{
        "total" => Decimal.new("9.00"),
        "currency" => "EUR",
        "billing_snapshot" => %{"email" => "g@example.com"}
      })

    {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{draft.uuid}")
    refute has_element?(view, "#reinstate-order-button")
  end

  test "is not offered for a cancelled order in the trash", %{conn: conn, user: user} do
    {:ok, trashed} = Billing.trash_order(cancelled_order(user))
    {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{trashed.uuid}")

    assert has_element?(view, "#restore-order-button")
    refute has_element?(view, "#reinstate-order-button")

    render_hook(view, "reinstate_order", %{"reason" => "x"})
    assert has_element?(view, "#flash-error", "in the trash")
    assert Billing.get_order!(trashed.uuid).status == "cancelled"
  end

  test "is not offered without manage_orders, and a forged event is denied", %{
    conn: conn,
    user: user
  } do
    order = cancelled_order(user)
    conn = denied_conn(conn, ["billing", "billing.manage_invoices"])

    # The order page itself needs manage_orders, so neither the button nor the
    # event is reachable.
    assert {:error, {:live_redirect, %{flash: %{"error" => error}}}} =
             live(conn, "/en/admin/billing/orders/#{order.uuid}")

    assert error =~ "permission"
    assert Billing.get_order!(order.uuid).status == "cancelled"
  end

  test "reinstated from another session meanwhile: refused with a message", %{
    conn: conn,
    user: user
  } do
    order = cancelled_order(user)
    {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")
    view |> element("#reinstate-order-button") |> render_click()

    {:ok, _} = Billing.reinstate_order(Billing.get_order!(order.uuid), "first")

    view |> form("#reinstate-order-form", %{"reason" => "second"}) |> render_submit()

    assert has_element?(view, "#flash-error", "Only a cancelled order")
    refute has_element?(view, "#reinstate-order-modal")
    assert Billing.get_order!(order.uuid).metadata["reinstated"]["reason"] == "first"
  end

  test "an open page follows a reinstate made elsewhere", %{conn: conn, user: user} do
    order = cancelled_order(user)
    {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")
    assert has_element?(view, "#reinstate-order-button")

    {:ok, _} = Billing.reinstate_order(order)
    render(view)

    refute has_element?(view, "#reinstate-order-button")
    assert has_element?(view, "button[phx-click=mark_paid]")
  end

  test "the button reads in the admin's language", %{conn: conn, user: user} do
    order = cancelled_order(user)

    {:ok, view, _html} =
      conn
      |> put_test_locale("uk")
      |> live("/en/admin/billing/orders/#{order.uuid}")

    assert has_element?(view, "#reinstate-order-button", "Повернути замовлення")
  end
end
