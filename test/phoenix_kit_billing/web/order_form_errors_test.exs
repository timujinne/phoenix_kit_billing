defmodule PhoenixKitBilling.Web.OrderFormErrorsTest do
  @moduledoc """
  An order that fails validation comes back from `create_order/1` with its
  action set, which is what makes a form show the errors.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing

  setup %{conn: conn} do
    Settings.update_setting("billing_enabled", "true")
    user = fixture_user()

    {:ok, _profile} =
      Billing.create_billing_profile(user, %{
        "type" => "individual",
        "first_name" => "Ada",
        "last_name" => "Lovelace"
      })

    %{conn: put_test_scope(conn, fake_scope()), user: user}
  end

  test "the admin order form shows the error of an invalid create", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, "/en/admin/billing/orders/new")

    view
    |> element("select[name='user_uuid']")
    |> render_change(%{"user_uuid" => user.uuid})

    refute has_element?(view, "label.select-error")

    # A currency code that is not three letters fails the order's validation.
    render_hook(view, "save", %{"order" => %{"currency" => "EURO"}})

    assert has_element?(view, "label.select-error")
    assert Billing.list_user_orders(user.uuid) == []
  end
end
