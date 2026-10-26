defmodule PhoenixKitBilling.Web.VoidCancelModalsTest do
  @moduledoc """
  The Void button on an invoice and the Cancel button on an order open a modal
  with an optional reason instead of a bare browser confirm. The reason lands
  in the document's trail and in the Activity entry; a void invoice carries a
  VOID mark on its detail page and on its printout.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Invoice
  alias PhoenixKitBilling.Test.Repo

  setup %{conn: conn} do
    Settings.update_setting("billing_enabled", "true")
    user = fixture_user()
    scope = fake_scope(user_uuid: user.uuid, email: user.email)
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, user: user}
  end

  defp sent_invoice(user, attrs \\ %{}) do
    {:ok, invoice} =
      Billing.create_invoice(
        user.uuid,
        Map.merge(%{total: Decimal.new("100.00"), currency: "EUR"}, attrs)
      )

    {:ok, sent} = invoice |> Invoice.status_changeset("sent") |> Repo.update()
    sent
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

  describe "invoice detail: Void" do
    test "opens a modal, and submitting it with a reason voids the invoice with a trail", %{
      conn: conn,
      user: user
    } do
      invoice = sent_invoice(user, %{notes: "Thanks for your order"})
      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

      refute has_element?(view, "#void-invoice-modal")
      refute has_element?(view, "#void-invoice-button[data-confirm]")

      view |> element("#void-invoice-button") |> render_click()
      assert has_element?(view, "#void-invoice-form textarea[name=reason][maxlength='500']")

      view |> form("#void-invoice-form", %{"reason" => "Booking cancelled"}) |> render_submit()

      refute has_element?(view, "#void-invoice-modal")
      assert has_element?(view, "#invoice-void-mark")
      assert has_element?(view, "#invoice-void-reason", "Booking cancelled")
      refute has_element?(view, "#void-invoice-button")

      stored = Billing.get_invoice!(invoice.uuid)
      assert stored.status == "void"
      assert stored.notes == "Thanks for your order"
      assert stored.metadata["void"]["reason"] == "Booking cancelled"
      assert stored.metadata["void"]["by_uuid"] == user.uuid

      assert_activity_logged("billing.invoice_voided",
        resource_uuid: invoice.uuid,
        actor_uuid: user.uuid,
        metadata_has: %{"status" => "void", "reason" => "Booking cancelled"}
      )
    end

    test "the reason is optional", %{conn: conn, user: user} do
      invoice = sent_invoice(user)
      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

      view |> element("#void-invoice-button") |> render_click()
      view |> form("#void-invoice-form", %{"reason" => ""}) |> render_submit()

      assert has_element?(view, "#invoice-void-mark")
      refute has_element?(view, "#invoice-void-reason")

      stored = Billing.get_invoice!(invoice.uuid)
      assert stored.status == "void"
      assert stored.metadata["void"]["reason"] == nil
    end

    test "closing the modal voids nothing", %{conn: conn, user: user} do
      invoice = sent_invoice(user)
      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

      view |> element("#void-invoice-button") |> render_click()
      view |> element("#void-invoice-modal .modal-backdrop") |> render_click()

      refute has_element?(view, "#void-invoice-modal")
      assert Billing.get_invoice!(invoice.uuid).status == "sent"
    end

    test "an invoice paid meanwhile is not voided, and the page says so", %{
      conn: conn,
      user: user
    } do
      invoice = sent_invoice(user)
      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")
      view |> element("#void-invoice-button") |> render_click()

      {:ok, _paid} = Billing.mark_invoice_paid(Billing.get_invoice!(invoice.uuid))

      view |> form("#void-invoice-form", %{"reason" => "Too late"}) |> render_submit()

      assert has_element?(view, "#flash-error", "cannot be voided")
      refute has_element?(view, "#void-invoice-modal")
      assert Billing.get_invoice!(invoice.uuid).status == "paid"
      refute has_element?(view, "#invoice-void-mark")
    end

    test "a partly paid invoice has no Void button, and the page says why", %{
      conn: conn,
      user: user
    } do
      invoice = sent_invoice(user)

      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")
      assert has_element?(view, "#void-invoice-button")
      refute has_element?(view, "#void-invoice-unavailable")

      {:ok, _tx} =
        Billing.record_payment(invoice, %{amount: "40.00", payment_method: "bank"}, nil)

      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")
      refute has_element?(view, "#void-invoice-button")
      assert has_element?(view, "#void-invoice-unavailable")
      assert has_element?(view, "button", "Issue Refund")
    end

    test "a payment recorded while the modal is open: the void is refused, the page says so", %{
      conn: conn,
      user: user
    } do
      invoice = sent_invoice(user)
      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")
      view |> element("#void-invoice-button") |> render_click()

      {:ok, _tx} =
        Billing.record_payment(
          Billing.get_invoice!(invoice.uuid),
          %{amount: "40.00", payment_method: "bank"},
          nil
        )

      view |> form("#void-invoice-form", %{"reason" => "Too late"}) |> render_submit()

      assert has_element?(view, "#flash-error", "cannot be voided")
      assert Billing.get_invoice!(invoice.uuid).status == "sent"
      refute has_element?(view, "#void-invoice-button")
      assert has_element?(view, "#void-invoice-unavailable")
    end

    test "an old void invoice without a trail shows the mark and no reason", %{
      conn: conn,
      user: user
    } do
      invoice = sent_invoice(user)
      {:ok, _} = invoice |> Invoice.status_changeset("void") |> Repo.update()

      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

      assert has_element?(view, "#invoice-void-mark")
      refute has_element?(view, "#invoice-void-reason")
    end
  end

  describe "invoice print" do
    test "a void invoice shows the VOID mark but keeps the reason off the printout", %{
      conn: conn,
      user: user
    } do
      invoice = sent_invoice(user)
      {:ok, _} = Billing.void_invoice(invoice, "Issued twice by mistake")

      {:ok, view, html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}/print")

      assert has_element?(view, "#invoice-void-mark")
      refute has_element?(view, "#invoice-void-reason")
      refute html =~ "Issued twice by mistake"

      # The admin detail page, which the customer does not see, keeps it.
      {:ok, detail, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")
      assert has_element?(detail, "#invoice-void-reason", "Issued twice by mistake")
    end

    test "an old void invoice shows the mark without a reason", %{conn: conn, user: user} do
      invoice = sent_invoice(user)
      {:ok, _} = invoice |> Invoice.status_changeset("void") |> Repo.update()

      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}/print")

      assert has_element?(view, "#invoice-void-mark")
      refute has_element?(view, "#invoice-void-reason")
    end

    test "a live invoice has no mark", %{conn: conn, user: user} do
      invoice = sent_invoice(user)

      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}/print")

      refute has_element?(view, "#invoice-void-mark")
    end
  end

  describe "order detail: Cancel" do
    test "opens a modal, and submitting it with a reason cancels the order", %{
      conn: conn,
      user: user
    } do
      order = order(user, %{"internal_notes" => "Called the customer"})
      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")

      refute has_element?(view, "#cancel-order-modal")
      refute has_element?(view, "#cancel-order-button[data-confirm]")

      view |> element("#cancel-order-button") |> render_click()
      assert has_element?(view, "#cancel-order-form textarea[name=reason][maxlength='500']")

      view |> form("#cancel-order-form", %{"reason" => "Changed mind"}) |> render_submit()

      refute has_element?(view, "#cancel-order-modal")
      refute has_element?(view, "#cancel-order-button")

      stored = Billing.get_order!(order.uuid)
      assert stored.status == "cancelled"
      assert stored.metadata["cancelled_from"] == "draft"
      assert stored.metadata["cancelled_by_uuid"] == user.uuid

      assert stored.internal_notes =~
               ~r/\ACalled the customer\n\nCancelled .* UTC: Changed mind\z/

      assert_activity_logged("billing.order_cancelled",
        resource_uuid: order.uuid,
        actor_uuid: user.uuid,
        metadata_has: %{"status" => "cancelled", "reason" => "Changed mind"}
      )
    end

    test "the reason is optional, and closing the modal cancels nothing", %{
      conn: conn,
      user: user
    } do
      order = order(user)
      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")

      view |> element("#cancel-order-button") |> render_click()
      view |> element("#cancel-order-modal .modal-backdrop") |> render_click()
      assert Billing.get_order!(order.uuid).status == "draft"

      view |> element("#cancel-order-button") |> render_click()
      view |> form("#cancel-order-form", %{"reason" => ""}) |> render_submit()

      stored = Billing.get_order!(order.uuid)
      assert stored.status == "cancelled"
      assert stored.internal_notes == nil
    end
  end

  describe "invoice detail: a void invoice" do
    test "the mark is the noun, not the verb, in the admin's language", %{conn: conn, user: user} do
      {:ok, voided} = Billing.void_invoice(sent_invoice(user))

      {:ok, view, _html} =
        conn
        |> put_test_locale("uk")
        |> live("/en/admin/billing/invoices/#{voided.uuid}")

      assert has_element?(view, "#invoice-void-mark h3", "АНУЛЬОВАНО")
    end

    test "warns about a payment that arrived after the void", %{conn: conn, user: user} do
      {:ok, voided} = Billing.void_invoice(sent_invoice(user), "Duplicate")
      {:ok, _, :added} = Billing.record_payment_after_void(voided, charge())

      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{voided.uuid}")

      assert has_element?(view, "#invoice-payments-after-void", "ch_1")
      assert has_element?(view, "#invoice-payments-after-void", "100.00 EUR")
    end

    test "has no warning without one", %{conn: conn, user: user} do
      {:ok, voided} = Billing.void_invoice(sent_invoice(user), "Duplicate")

      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{voided.uuid}")

      refute has_element?(view, "#invoice-payments-after-void")
    end
  end

  defp charge do
    %{
      provider: :stripe,
      charge_id: "ch_1",
      amount: Decimal.new("100.00"),
      currency: "EUR",
      event_id: "evt_1"
    }
  end
end
