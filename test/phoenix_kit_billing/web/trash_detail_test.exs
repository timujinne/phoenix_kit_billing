defmodule PhoenixKitBilling.Web.TrashDetailTest do
  @moduledoc """
  "Move to trash" and "Restore" on the order and invoice pages: offered only
  where the context would allow them, behind a confirmation, behind the
  capability the page's other actions need, and logged to Activity.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, Order}
  alias PhoenixKitBilling.Test.Repo

  setup %{conn: conn} do
    Settings.update_setting("billing_enabled", "true")
    user = fixture_user()
    scope = fake_scope(user_uuid: user.uuid, email: user.email)
    {:ok, conn: put_test_scope(conn, scope), user: user}
  end

  defp order(user, attrs \\ %{}) do
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

    order
  end

  defp draft_invoice(user, attrs \\ %{}) do
    {:ok, invoice} =
      Billing.create_invoice(
        user.uuid,
        Map.merge(%{total: Decimal.new("100.00"), currency: "EUR"}, attrs)
      )

    invoice
  end

  defp with_status(invoice, status) do
    invoice |> Ecto.Changeset.change(status: status) |> Repo.update!()
  end

  defp denied_conn(conn, permissions) do
    put_test_scope(conn, fake_scope(roles: ["Employee"], permissions: permissions))
  end

  describe "order detail: Move to trash" do
    test "opens a confirmation, and confirming trashes the order", %{conn: conn, user: user} do
      order = order(user)
      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")

      refute has_element?(view, "#trash-order-modal")
      refute has_element?(view, "#order-trashed-badge")
      refute has_element?(view, "#trash-order-button[data-confirm]")

      view |> element("#trash-order-button") |> render_click()
      assert has_element?(view, "#trash-order-modal")
      assert has_element?(view, "#trash-order-form")

      view |> form("#trash-order-form") |> render_submit()

      refute has_element?(view, "#trash-order-modal")
      assert has_element?(view, "#order-trashed-badge")
      assert has_element?(view, "#order-trashed-mark")
      assert has_element?(view, "#restore-order-button")
      refute has_element?(view, "#trash-order-button")

      stored = Billing.get_order!(order.uuid)
      assert Order.trashed?(stored)
      assert stored.trashed_by_uuid == user.uuid
      assert stored.status == "draft"

      assert_activity_logged("billing.order_trashed",
        resource_uuid: order.uuid,
        actor_uuid: user.uuid,
        metadata_has: %{"status" => "draft", "order_number" => order.order_number}
      )
    end

    test "closing the confirmation trashes nothing", %{conn: conn, user: user} do
      order = order(user)
      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")

      view |> element("#trash-order-button") |> render_click()
      view |> element("#trash-order-modal .modal-backdrop") |> render_click()

      refute has_element?(view, "#trash-order-modal")
      refute Order.trashed?(Billing.get_order!(order.uuid))
    end

    test "is offered for a draft or a cancelled order only", %{conn: conn, user: user} do
      {:ok, cancelled} = Billing.cancel_order(order(user))
      {:ok, confirmed} = Billing.confirm_order(order(user))
      {:ok, to_pay} = Billing.confirm_order(order(user))
      {:ok, paid} = Billing.mark_order_paid(to_pay)
      pending = order(user, %{"status" => "pending"})

      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{cancelled.uuid}")
      assert has_element?(view, "#trash-order-button")

      for order <- [confirmed, paid, pending] do
        {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")
        refute has_element?(view, "#trash-order-button"), order.status
      end
    end

    test "is not offered while an invoice of the order is open", %{conn: conn, user: user} do
      order = order(user)
      {:ok, invoice} = Billing.create_invoice_from_order(order)

      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")
      refute has_element?(view, "#trash-order-button")

      {:ok, _} = Billing.void_invoice(invoice)
      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")
      assert has_element?(view, "#trash-order-button")
    end

    test "an order that got an invoice meanwhile is refused, and the page says why", %{
      conn: conn,
      user: user
    } do
      order = order(user)
      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")
      view |> element("#trash-order-button") |> render_click()

      {:ok, _} = Billing.create_invoice_from_order(Billing.get_order!(order.uuid))

      view |> form("#trash-order-form") |> render_submit()

      assert has_element?(view, "#flash-error", "neither void nor in the trash")
      refute has_element?(view, "#trash-order-modal")
      refute Order.trashed?(Billing.get_order!(order.uuid))
    end

    test "is not offered without manage_orders, and a forged event is denied", %{
      conn: conn,
      user: user
    } do
      order = order(user)
      conn = denied_conn(conn, ["billing", "billing.manage_invoices"])
      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")

      refute has_element?(view, "#trash-order-button")

      render_hook(view, "trash_order", %{})

      assert has_element?(view, "#flash-error", "permission")
      refute Order.trashed?(Billing.get_order!(order.uuid))
    end
  end

  describe "order detail: a trashed order" do
    setup %{user: user} do
      order = order(user)
      {:ok, trashed} = Billing.trash_order(order, actor_uuid: user.uuid)
      {:ok, order: trashed}
    end

    test "says it is in the trash, and hides what it cannot do", %{conn: conn, order: order} do
      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")

      assert has_element?(view, "#order-trashed-badge")
      assert has_element?(view, "#order-trashed-mark")
      assert has_element?(view, "#restore-order-button")

      for button <- ["#trash-order-button", "#cancel-order-button"] do
        refute has_element?(view, button)
      end

      refute has_element?(view, "button[phx-click=confirm_order]")
      refute has_element?(view, "button[phx-click=mark_paid]")
      refute has_element?(view, "button[phx-click=generate_invoice]")
      refute has_element?(view, ~s|a[href$="/edit"]|)
    end

    test "Restore asks first, then brings the order back", %{
      conn: conn,
      order: order,
      user: user
    } do
      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")

      view |> element("#restore-order-button") |> render_click()
      assert has_element?(view, "#restore-order-modal")

      view |> form("#restore-order-form") |> render_submit()

      refute has_element?(view, "#restore-order-modal")
      refute has_element?(view, "#order-trashed-badge")
      refute has_element?(view, "#order-trashed-mark")
      assert has_element?(view, "#trash-order-button")
      assert has_element?(view, "button[phx-click=confirm_order]")

      refute Order.trashed?(Billing.get_order!(order.uuid))

      assert_activity_logged("billing.order_restored",
        resource_uuid: order.uuid,
        actor_uuid: user.uuid,
        metadata_has: %{"status" => "draft"}
      )
    end

    test "closing the restore confirmation restores nothing", %{conn: conn, order: order} do
      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")

      view |> element("#restore-order-button") |> render_click()
      view |> element("#restore-order-modal .modal-backdrop") |> render_click()

      refute has_element?(view, "#restore-order-modal")
      assert Order.trashed?(Billing.get_order!(order.uuid))
    end

    test "a forged action on the trashed page is refused with a message, not a crash", %{
      conn: conn,
      order: order
    } do
      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")

      render_hook(view, "confirm_order", %{})
      assert has_element?(view, "#flash-error", "in the trash")

      render_hook(view, "generate_invoice", %{})
      assert has_element?(view, "#flash-error", "in the trash")

      assert Billing.get_order!(order.uuid).status == "draft"
    end

    test "restore is not offered without manage_orders", %{conn: conn, order: order} do
      conn = denied_conn(conn, ["billing", "billing.manage_invoices"])
      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")

      assert has_element?(view, "#order-trashed-badge")
      refute has_element?(view, "#restore-order-button")

      render_hook(view, "restore_order", %{})

      assert has_element?(view, "#flash-error", "permission")
      assert Order.trashed?(Billing.get_order!(order.uuid))
    end

    test "trashing it from another session updates an open page", %{conn: conn, user: user} do
      fresh = order(user)
      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{fresh.uuid}")
      refute has_element?(view, "#order-trashed-badge")

      {:ok, _} = Billing.trash_order(fresh)
      render(view)

      assert has_element?(view, "#order-trashed-badge")
    end

    test "the edit page sends you back to the order, with a message", %{
      conn: conn,
      order: order
    } do
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, "/en/admin/billing/orders/#{order.uuid}/edit")

      assert to =~ "/admin/billing/orders/#{order.uuid}"
      refute to =~ "/edit"
      assert flash["error"] =~ "in the trash"
    end

    test "an order trashed while its edit page was open refuses the save, with a message", %{
      conn: conn,
      user: user
    } do
      fresh = order(user)
      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{fresh.uuid}/edit")
      {:ok, _} = Billing.trash_order(fresh)

      render_hook(view, "save", %{"order" => %{"notes" => "late"}})

      assert has_element?(view, "#flash-error", "in the trash")
      assert Billing.get_order!(fresh.uuid).notes == nil
    end
  end

  describe "in the admin's language" do
    test "the order page says it in Ukrainian and in Russian", %{conn: conn, user: user} do
      order = order(user)

      {:ok, view, _html} =
        conn |> put_test_locale("uk") |> live("/en/admin/billing/orders/#{order.uuid}")

      assert has_element?(view, "#trash-order-button", "Перемістити в кошик")

      {:ok, trashed} = Billing.trash_order(order)

      {:ok, view, _html} =
        conn |> put_test_locale("uk") |> live("/en/admin/billing/orders/#{trashed.uuid}")

      assert has_element?(view, "#order-trashed-badge", "У кошику")
      assert has_element?(view, "#restore-order-button", "Відновити")

      {:ok, view, _html} =
        conn |> put_test_locale("ru") |> live("/en/admin/billing/orders/#{trashed.uuid}")

      assert has_element?(view, "#order-trashed-badge", "В корзине")
      assert has_element?(view, "#restore-order-button", "Восстановить")
    end

    test "the lists name the tab", %{conn: conn} do
      {:ok, view, _html} =
        conn |> put_test_locale("uk") |> live("/admin/billing/invoices")

      assert has_element?(view, "#invoices-tab-trash", "Кошик")

      {:ok, view, _html} =
        conn |> put_test_locale("ru") |> live("/admin/billing/orders")

      assert has_element?(view, "#orders-tab-trash", "Корзина")
    end
  end

  describe "a forged form submit" do
    test "cannot trash an order through the order form", %{conn: conn, user: user} do
      order = order(user)
      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}/edit")

      render_hook(view, "save", %{
        "order" => %{
          "notes" => "edited",
          "trashed_at" => "2026-01-01T00:00:00Z",
          "trashed_by_uuid" => user.uuid
        }
      })

      stored = Billing.get_order!(order.uuid)
      assert stored.notes == "edited"
      refute Order.trashed?(stored)
      assert stored.trashed_by_uuid == nil
    end

    test "cannot lift a trashed order out of the trash through the order form", %{
      conn: conn,
      user: user
    } do
      fresh = order(user)
      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{fresh.uuid}/edit")
      {:ok, _} = Billing.trash_order(fresh)

      render_hook(view, "save", %{"order" => %{"trashed_at" => nil, "trashed_by_uuid" => nil}})

      assert Order.trashed?(Billing.get_order!(fresh.uuid))
    end
  end

  describe "order detail: the invoices shown" do
    test "an invoice in the trash is not listed on its order", %{conn: conn, user: user} do
      order = order(user)
      {:ok, shown} = Billing.create_invoice_from_order(order)
      {:ok, hidden} = Billing.create_invoice_from_order(order)
      {:ok, _} = Billing.trash_invoice(hidden)

      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")

      assert has_element?(view, "td", shown.invoice_number)
      refute has_element?(view, "td", hidden.invoice_number)
    end
  end

  describe "order detail: an invoice of the order goes to the trash" do
    test "an open page learns that the order can be trashed now", %{conn: conn, user: user} do
      order = order(user)
      {:ok, invoice} = Billing.create_invoice_from_order(order)

      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")
      refute has_element?(view, "#trash-order-button")
      assert has_element?(view, "td", invoice.invoice_number)

      {:ok, _} = Billing.trash_invoice(invoice)
      render(view)

      refute has_element?(view, "td", invoice.invoice_number)
      assert has_element?(view, "#trash-order-button")
    end
  end

  describe "invoice detail: Move to trash" do
    test "opens a confirmation that says the number stays used, and trashes the draft", %{
      conn: conn,
      user: user
    } do
      invoice = draft_invoice(user)
      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

      refute has_element?(view, "#trash-invoice-modal")
      view |> element("#trash-invoice-button") |> render_click()

      assert has_element?(view, "#trash-invoice-modal", "number")
      assert has_element?(view, "#trash-invoice-modal", invoice.invoice_number)

      view |> form("#trash-invoice-form") |> render_submit()

      refute has_element?(view, "#trash-invoice-modal")
      assert has_element?(view, "#invoice-trashed-badge")
      assert has_element?(view, "#invoice-trashed-mark")
      assert has_element?(view, "#restore-invoice-button")

      stored = Billing.get_invoice!(invoice.uuid)
      assert Invoice.trashed?(stored)
      assert stored.trashed_by_uuid == user.uuid
      assert stored.status == "draft"

      assert_activity_logged("billing.invoice_trashed",
        resource_uuid: invoice.uuid,
        actor_uuid: user.uuid,
        metadata_has: %{"status" => "draft", "invoice_number" => invoice.invoice_number}
      )
    end

    test "closing the confirmation trashes nothing", %{conn: conn, user: user} do
      invoice = draft_invoice(user)
      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

      view |> element("#trash-invoice-button") |> render_click()
      view |> element("#trash-invoice-modal .modal-backdrop") |> render_click()

      refute has_element?(view, "#trash-invoice-modal")
      refute Invoice.trashed?(Billing.get_invoice!(invoice.uuid))
    end

    test "is never offered for an issued invoice", %{conn: conn, user: user} do
      for status <- ~w(sent overdue paid void) do
        invoice = draft_invoice(user) |> with_status(status)
        {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

        refute has_element?(view, "#trash-invoice-button"), status
      end
    end

    test "is not offered without manage_invoices, and a forged event is denied", %{
      conn: conn,
      user: user
    } do
      invoice = draft_invoice(user)
      conn = denied_conn(conn, ["billing", "billing.manage_orders"])
      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

      refute has_element?(view, "#trash-invoice-button")

      render_hook(view, "trash_invoice", %{})

      assert has_element?(view, "#flash-error", "permission")
      refute Invoice.trashed?(Billing.get_invoice!(invoice.uuid))
    end

    test "an invoice sent meanwhile is refused, and the page says why", %{
      conn: conn,
      user: user
    } do
      invoice = draft_invoice(user)
      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")
      view |> element("#trash-invoice-button") |> render_click()

      {:ok, _, _} =
        Billing.send_invoice(invoice, to_email: "c@example.com", send_email: false)

      view |> form("#trash-invoice-form") |> render_submit()

      assert has_element?(view, "#flash-error", "never sent")
      refute Invoice.trashed?(Billing.get_invoice!(invoice.uuid))
    end
  end

  describe "invoice detail: a trashed invoice" do
    setup %{user: user} do
      {:ok, trashed} = Billing.trash_invoice(draft_invoice(user), actor_uuid: user.uuid)
      {:ok, invoice: trashed}
    end

    test "says it is in the trash, and hides what it cannot do", %{conn: conn, invoice: invoice} do
      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

      assert has_element?(view, "#invoice-trashed-badge")
      assert has_element?(view, "#invoice-trashed-mark")
      assert has_element?(view, "#restore-invoice-button")

      for button <- ~w(#trash-invoice-button #void-invoice-button) do
        refute has_element?(view, button)
      end

      refute has_element?(view, "button[phx-click=open_send_modal]")
      refute has_element?(view, "button[phx-click=open_payment_modal]")
    end

    test "Restore asks first, then brings the invoice back", %{
      conn: conn,
      invoice: invoice,
      user: user
    } do
      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

      view |> element("#restore-invoice-button") |> render_click()
      assert has_element?(view, "#restore-invoice-modal")
      view |> form("#restore-invoice-form") |> render_submit()

      refute has_element?(view, "#restore-invoice-modal")
      refute has_element?(view, "#invoice-trashed-badge")
      assert has_element?(view, "#trash-invoice-button")
      assert has_element?(view, "button[phx-click=open_send_modal]")

      refute Invoice.trashed?(Billing.get_invoice!(invoice.uuid))

      assert_activity_logged("billing.invoice_restored",
        resource_uuid: invoice.uuid,
        actor_uuid: user.uuid
      )
    end

    test "a forged send or void is refused with a message, not a crash", %{
      conn: conn,
      invoice: invoice
    } do
      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

      render_hook(view, "void_invoice", %{"reason" => "x"})
      assert has_element?(view, "#flash-error", "in the trash")

      render_hook(view, "send_invoice", %{})
      assert has_element?(view, "#flash-error", "in the trash")

      stored = Billing.get_invoice!(invoice.uuid)
      assert stored.status == "draft"
      assert stored.sent_at == nil
    end

    test "restore is not offered without manage_invoices", %{conn: conn, invoice: invoice} do
      conn = denied_conn(conn, ["billing", "billing.manage_orders"])
      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

      assert has_element?(view, "#invoice-trashed-badge")
      refute has_element?(view, "#restore-invoice-button")

      render_hook(view, "restore_invoice", %{})

      assert has_element?(view, "#flash-error", "permission")
      assert Invoice.trashed?(Billing.get_invoice!(invoice.uuid))
    end

    test "restoring it onto a cancelled order is refused with a message", %{
      conn: conn,
      user: user
    } do
      order = order(user)
      {:ok, invoice} = Billing.create_invoice_from_order(order)
      {:ok, _} = Billing.trash_invoice(invoice)
      {:ok, _} = Billing.cancel_order(order)

      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")
      view |> element("#restore-invoice-button") |> render_click()
      view |> form("#restore-invoice-form") |> render_submit()

      assert has_element?(view, "#flash-error", "cancelled")
      assert Invoice.trashed?(Billing.get_invoice!(invoice.uuid))
    end

    test "restoring it onto an order in the trash is refused with a message", %{
      conn: conn,
      user: user
    } do
      order = order(user)
      {:ok, invoice} = Billing.create_invoice_from_order(order)
      {:ok, _} = Billing.trash_invoice(invoice)
      {:ok, _} = Billing.trash_order(order)

      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")
      view |> element("#restore-invoice-button") |> render_click()
      view |> form("#restore-invoice-form") |> render_submit()

      assert has_element?(view, "#flash-error", "in the trash")
      assert Invoice.trashed?(Billing.get_invoice!(invoice.uuid))
    end
  end
end
