defmodule PhoenixKitBilling.Web.TrashListsTest do
  @moduledoc """
  The orders and invoices lists leave the trash out and have a Trash tab that
  shows only what is in it, with when and by whom.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing

  setup %{conn: conn} do
    Settings.update_setting("billing_enabled", "true")
    user = fixture_user()
    actor = fixture_user()
    scope = fake_scope(user_uuid: actor.uuid, email: actor.email)
    {:ok, conn: put_test_scope(conn, scope), user: user, actor: actor}
  end

  defp order(user) do
    {:ok, order} =
      Billing.create_order(user, %{
        "total" => Decimal.new("10.00"),
        "currency" => "EUR",
        "billing_snapshot" => %{"email" => "g@example.com"}
      })

    order
  end

  defp invoice(user) do
    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("10.00"), currency: "EUR"})

    invoice
  end

  describe "orders" do
    setup %{user: user, actor: actor} do
      kept = order(user)
      gone = order(user)
      {:ok, _} = Billing.trash_order(gone, actor_uuid: actor.uuid)
      {:ok, kept: kept, gone: gone}
    end

    test "the default list leaves the trash out and offers the Trash tab", %{
      conn: conn,
      kept: kept,
      gone: gone
    } do
      {:ok, view, _html} = live(conn, "/admin/billing/orders")

      assert has_element?(view, "#orders-table", kept.order_number)
      refute has_element?(view, "#orders-table", gone.order_number)
      assert has_element?(view, "#orders-tab-active.tab-active")
      assert has_element?(view, "#orders-tab-trash:not(.tab-active)")
      refute has_element?(view, "#orders-table th", "Trashed")
    end

    test "the Trash tab shows only the trash, with when and by whom", %{
      conn: conn,
      kept: kept,
      gone: gone,
      actor: actor
    } do
      {:ok, view, _html} = live(conn, "/admin/billing/orders")

      view |> element("#orders-tab-trash") |> render_click()
      assert_patch(view, "/admin/billing/orders?trash=1")

      assert has_element?(view, "#orders-tab-trash.tab-active")
      assert has_element?(view, "#orders-table", gone.order_number)
      refute has_element?(view, "#orders-table", kept.order_number)
      assert has_element?(view, "#orders-table th", "Trashed")
      assert has_element?(view, "#order-trashed-by-#{gone.uuid}", actor.email)
      assert has_element?(view, "#order-trashed-at-#{gone.uuid}")
    end

    test "back to the list leaves the trash again", %{conn: conn, gone: gone} do
      {:ok, view, _html} = live(conn, "/admin/billing/orders?trash=1")

      view |> element("#orders-tab-active") |> render_click()
      assert_patch(view, "/admin/billing/orders")

      refute has_element?(view, "#orders-table", gone.order_number)
    end

    test "an empty trash says so", %{conn: conn, gone: gone} do
      {:ok, _} = Billing.restore_order(gone)
      {:ok, view, _html} = live(conn, "/admin/billing/orders?trash=1")

      assert has_element?(view, "#orders-trash-empty")
    end

    test "the status filter works inside the trash", %{conn: conn, gone: gone} do
      {:ok, view, _html} = live(conn, "/admin/billing/orders?trash=1&status=paid")
      refute has_element?(view, "#orders-table", gone.order_number)

      {:ok, view, _html} = live(conn, "/admin/billing/orders?trash=1&status=draft")
      assert has_element?(view, "#orders-table", gone.order_number)
    end

    test "trashing and restoring elsewhere refreshes an open list", %{
      conn: conn,
      kept: kept
    } do
      {:ok, view, _html} = live(conn, "/admin/billing/orders")
      assert has_element?(view, "#orders-table", kept.order_number)

      {:ok, _} = Billing.trash_order(kept)
      render(view)
      refute has_element?(view, "#orders-table", kept.order_number)

      {:ok, _} = Billing.restore_order(kept)
      render(view)
      assert has_element?(view, "#orders-table", kept.order_number)
    end
  end

  describe "invoices" do
    setup %{user: user, actor: actor} do
      kept = invoice(user)
      gone = invoice(user)
      {:ok, _} = Billing.trash_invoice(gone, actor_uuid: actor.uuid)
      {:ok, kept: kept, gone: gone}
    end

    test "the default list leaves the trash out and offers the Trash tab", %{
      conn: conn,
      kept: kept,
      gone: gone
    } do
      {:ok, view, _html} = live(conn, "/admin/billing/invoices")

      assert has_element?(view, "#invoices-table", kept.invoice_number)
      refute has_element?(view, "#invoices-table", gone.invoice_number)
      assert has_element?(view, "#invoices-tab-active.tab-active")
      assert has_element?(view, "#invoices-tab-trash:not(.tab-active)")
    end

    test "the Trash tab shows only the trash, with when and by whom", %{
      conn: conn,
      kept: kept,
      gone: gone,
      actor: actor
    } do
      {:ok, view, _html} = live(conn, "/admin/billing/invoices")

      view |> element("#invoices-tab-trash") |> render_click()
      assert_patch(view, "/admin/billing/invoices?trash=1")

      assert has_element?(view, "#invoices-table", gone.invoice_number)
      refute has_element?(view, "#invoices-table", kept.invoice_number)
      assert has_element?(view, "#invoices-table th", "Trashed")
      assert has_element?(view, "#invoice-trashed-by-#{gone.uuid}", actor.email)
      assert has_element?(view, "#invoice-trashed-at-#{gone.uuid}")
    end

    test "an empty trash says so", %{conn: conn, gone: gone} do
      {:ok, _} = Billing.restore_invoice(gone)
      {:ok, view, _html} = live(conn, "/admin/billing/invoices?trash=1")

      assert has_element?(view, "#invoices-trash-empty")
    end

    test "trashing elsewhere refreshes an open list", %{conn: conn, kept: kept} do
      {:ok, view, _html} = live(conn, "/admin/billing/invoices")

      {:ok, _} = Billing.trash_invoice(kept)
      render(view)

      refute has_element?(view, "#invoices-table", kept.invoice_number)
    end
  end
end
