defmodule PhoenixKitBilling.Web.InvoiceDetail do
  @moduledoc """
  Invoice detail LiveView for the billing module.

  Displays complete invoice information and provides actions for invoice management.
  Complex business logic is delegated to `Actions`, and template helpers live in `Helpers`.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext
  import PhoenixKitWeb.Components.Core.AdminPageHeader
  import PhoenixKitWeb.Components.Core.DecimalInput
  import PhoenixKitWeb.Components.Core.UserInfo
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling.Web.Authz
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu
  import PhoenixKitWeb.Components.Core.TimeDisplay
  import PhoenixKitBilling.Web.Components.CurrencyDisplay
  import PhoenixKitBilling.Web.Components.InvoiceStatusBadge
  import PhoenixKitBilling.Web.Components.TransactionTypeBadge
  import PhoenixKitBilling.Web.Components.OrderStatusBadge
  import PhoenixKitBilling.Web.Components.TrashMark

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Events
  alias PhoenixKitBilling.Invoice
  alias PhoenixKitBilling.Providers
  alias PhoenixKitBilling.Web.InvoiceDetail.Actions
  alias PhoenixKitBilling.Web.Trail

  import PhoenixKitBilling.Web.InvoiceDetail.Helpers

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      if connected?(socket) do
        Events.subscribe_invoices()
        Events.subscribe_transactions()
      end

      {:ok, assign(socket, loaded?: false)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Billing module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    case Billing.get_invoice(id, preload: [:order, :transactions, :user]) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Invoice not found"))
         |> push_navigate(to: Routes.path("/admin/billing/invoices"))}

      invoice ->
        project_title = Settings.get_project_title()
        available_providers = Providers.list_available_providers()

        socket =
          if socket.assigns[:loaded?] do
            assign_invoice(socket, invoice)
          else
            socket
            |> assign(:loaded?, true)
            |> Trail.billing(invoice.invoice_number, [Trail.invoices()])
            |> assign(:project_title, project_title)
            |> assign_invoice(invoice)
            |> assign(:available_providers, available_providers)
            |> assign(:checkout_loading, nil)
            |> assign(:show_payment_modal, false)
            |> assign(:show_refund_modal, false)
            |> assign(:show_void_modal, false)
            |> assign(:show_send_modal, false)
            |> assign(:show_send_receipt_modal, false)
            |> assign(:show_send_credit_note_modal, false)
            |> assign(:show_send_payment_confirmation_modal, false)
            |> assign(:show_trash_modal, false)
            |> assign(:show_restore_modal, false)
            |> assign(:payment_amount, Invoice.remaining_amount(invoice) |> Decimal.to_string())
            |> assign(:refund_amount, "")
            |> assign(:payment_description, "")
            |> assign(:refund_description, "")
            |> assign(:available_payment_methods, Billing.available_payment_methods())
            |> assign(:selected_payment_method, "bank")
            |> assign(:selected_refund_payment_method, "bank")
            |> assign(:send_email, get_default_email(invoice))
            |> assign(:send_receipt_email, get_default_email(invoice))
            |> assign(:send_credit_note_email, get_default_email(invoice))
            |> assign(:send_credit_note_transaction_uuid, nil)
            |> assign(:send_payment_confirmation_email, get_default_email(invoice))
            |> assign(:send_payment_confirmation_transaction_uuid, nil)
          end

        {:noreply, socket}
    end
  end

  # PubSub: refresh invoice + transactions when a related event fires.
  @impl true
  def handle_info({event, %{uuid: uuid}}, %{assigns: %{invoice: %{uuid: uuid}}} = socket)
      when event in [
             :invoice_paid,
             :invoice_voided,
             :invoice_sent,
             :invoice_trashed,
             :invoice_restored
           ] do
    {:noreply, refresh_invoice(socket)}
  end

  def handle_info({:transaction_created, %{invoice_uuid: invoice_uuid}}, socket)
      when not is_nil(invoice_uuid) do
    if socket.assigns[:invoice] && socket.assigns.invoice.uuid == invoice_uuid do
      {:noreply, refresh_invoice(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:transaction_refunded, %{invoice_uuid: invoice_uuid}}, socket)
      when not is_nil(invoice_uuid) do
    if socket.assigns[:invoice] && socket.assigns.invoice.uuid == invoice_uuid do
      {:noreply, refresh_invoice(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh_invoice(%{assigns: %{invoice: %{uuid: uuid}}} = socket) do
    case Billing.get_invoice(uuid, preload: [:order, :transactions, :user]) do
      nil -> socket
      invoice -> assign_invoice(socket, invoice)
    end
  end

  defp refresh_invoice(socket), do: socket

  # The invoice and what the page derives from it: its transactions, who trashed
  # it, and whether the viewer may change it.
  defp assign_invoice(socket, invoice) do
    socket
    |> assign(:invoice, invoice)
    |> assign(:transactions, invoice.transactions)
    |> assign(:trashed_by, trashed_by_email(invoice))
    |> assign(:can_manage_invoices, Authz.can?(socket, :manage_invoices))
  end

  # Modal Controls

  @impl true
  def handle_event("open_payment_modal", _params, socket) do
    remaining = Invoice.remaining_amount(socket.assigns.invoice)

    {:noreply,
     socket
     |> assign(:show_payment_modal, true)
     |> assign(:payment_amount, Decimal.to_string(remaining))
     |> assign(:payment_description, "")}
  end

  @impl true
  def handle_event("close_payment_modal", _params, socket) do
    {:noreply, assign(socket, :show_payment_modal, false)}
  end

  @impl true
  def handle_event("open_refund_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_refund_modal, true)
     |> assign(:refund_amount, "")
     |> assign(:refund_description, "")}
  end

  @impl true
  def handle_event("close_refund_modal", _params, socket) do
    {:noreply, assign(socket, :show_refund_modal, false)}
  end

  @impl true
  def handle_event("open_void_modal", _params, socket) do
    {:noreply, assign(socket, :show_void_modal, true)}
  end

  @impl true
  def handle_event("close_void_modal", _params, socket) do
    {:noreply, assign(socket, :show_void_modal, false)}
  end

  @impl true
  def handle_event("open_trash_modal", _params, socket) do
    {:noreply, assign(socket, :show_trash_modal, true)}
  end

  @impl true
  def handle_event("close_trash_modal", _params, socket) do
    {:noreply, assign(socket, :show_trash_modal, false)}
  end

  @impl true
  def handle_event("open_restore_modal", _params, socket) do
    {:noreply, assign(socket, :show_restore_modal, true)}
  end

  @impl true
  def handle_event("close_restore_modal", _params, socket) do
    {:noreply, assign(socket, :show_restore_modal, false)}
  end

  @impl true
  def handle_event("open_send_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_send_modal, true)
     |> assign(:send_email, get_default_email(socket.assigns.invoice))}
  end

  @impl true
  def handle_event("close_send_modal", _params, socket) do
    {:noreply, assign(socket, :show_send_modal, false)}
  end

  @impl true
  def handle_event("open_send_receipt_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_send_receipt_modal, true)
     |> assign(:send_receipt_email, get_default_email(socket.assigns.invoice))}
  end

  @impl true
  def handle_event("close_send_receipt_modal", _params, socket) do
    {:noreply, assign(socket, :show_send_receipt_modal, false)}
  end

  @impl true
  def handle_event(
        "open_send_credit_note_modal",
        %{"transaction-uuid" => transaction_uuid},
        socket
      ) do
    {:noreply,
     socket
     |> assign(:show_send_credit_note_modal, true)
     |> assign(:send_credit_note_email, get_default_email(socket.assigns.invoice))
     |> assign(:send_credit_note_transaction_uuid, transaction_uuid)}
  end

  @impl true
  def handle_event("close_send_credit_note_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_send_credit_note_modal, false)
     |> assign(:send_credit_note_transaction_uuid, nil)}
  end

  @impl true
  def handle_event(
        "open_send_payment_confirmation_modal",
        %{"transaction-uuid" => transaction_uuid},
        socket
      ) do
    {:noreply,
     socket
     |> assign(:show_send_payment_confirmation_modal, true)
     |> assign(:send_payment_confirmation_email, get_default_email(socket.assigns.invoice))
     |> assign(:send_payment_confirmation_transaction_uuid, transaction_uuid)}
  end

  @impl true
  def handle_event("close_send_payment_confirmation_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_send_payment_confirmation_modal, false)
     |> assign(:send_payment_confirmation_transaction_uuid, nil)}
  end

  # Form Updates

  @impl true
  def handle_event("update_payment_form", params, socket) do
    socket =
      socket
      |> assign(:payment_amount, params["amount"] || socket.assigns.payment_amount)
      |> assign(:payment_description, params["description"] || socket.assigns.payment_description)

    socket =
      if params["payment_method"] do
        assign(socket, :selected_payment_method, params["payment_method"])
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_refund_form", params, socket) do
    socket =
      socket
      |> assign(:refund_amount, params["amount"] || socket.assigns.refund_amount)
      |> assign(:refund_description, params["description"] || socket.assigns.refund_description)

    socket =
      if params["payment_method"] do
        assign(socket, :selected_refund_payment_method, params["payment_method"])
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_send_form", %{"email" => email}, socket) do
    {:noreply, assign(socket, :send_email, email)}
  end

  @impl true
  def handle_event("update_send_receipt_form", %{"email" => email}, socket) do
    {:noreply, assign(socket, :send_receipt_email, email)}
  end

  @impl true
  def handle_event("update_send_credit_note_form", %{"email" => email}, socket) do
    {:noreply, assign(socket, :send_credit_note_email, email)}
  end

  @impl true
  def handle_event("update_send_payment_confirmation_form", %{"email" => email}, socket) do
    {:noreply, assign(socket, :send_payment_confirmation_email, email)}
  end

  # Action Delegators

  # Every money action re-checks the capability: these send emails,
  # record payments and void invoices.

  @impl true
  def handle_event("record_payment", params, socket) do
    Authz.authorize(socket, :manage_invoices, fn ->
      gated_event("record_payment", params, socket)
    end)
  end

  @impl true
  def handle_event("pay_with_provider", params, socket) do
    Authz.authorize(socket, :manage_invoices, fn ->
      gated_event("pay_with_provider", params, socket)
    end)
  end

  @impl true
  def handle_event("record_refund", params, socket) do
    Authz.authorize(socket, :manage_invoices, fn ->
      gated_event("record_refund", params, socket)
    end)
  end

  @impl true
  def handle_event("send_invoice", params, socket) do
    Authz.authorize(socket, :manage_invoices, fn ->
      gated_event("send_invoice", params, socket)
    end)
  end

  @impl true
  def handle_event("send_receipt", params, socket) do
    Authz.authorize(socket, :manage_invoices, fn ->
      gated_event("send_receipt", params, socket)
    end)
  end

  @impl true
  def handle_event("send_credit_note", params, socket) do
    Authz.authorize(socket, :manage_invoices, fn ->
      gated_event("send_credit_note", params, socket)
    end)
  end

  @impl true
  def handle_event("send_payment_confirmation", params, socket) do
    Authz.authorize(socket, :manage_invoices, fn ->
      gated_event("send_payment_confirmation", params, socket)
    end)
  end

  @impl true
  def handle_event("void_invoice", params, socket) do
    Authz.authorize(socket, :manage_invoices, fn ->
      gated_event("void_invoice", params, socket)
    end)
  end

  @impl true
  def handle_event("generate_receipt", params, socket) do
    Authz.authorize(socket, :manage_invoices, fn ->
      gated_event("generate_receipt", params, socket)
    end)
  end

  @impl true
  def handle_event("trash_invoice", params, socket) do
    Authz.authorize(socket, :manage_invoices, fn ->
      gated_event("trash_invoice", params, socket)
    end)
  end

  @impl true
  def handle_event("restore_invoice", params, socket) do
    Authz.authorize(socket, :manage_invoices, fn ->
      gated_event("restore_invoice", params, socket)
    end)
  end

  defp gated_event("record_payment", _params, socket), do: Actions.record_payment(socket)

  defp gated_event("pay_with_provider", %{"provider" => provider}, socket),
    do: Actions.pay_with_provider(socket, provider)

  defp gated_event("record_refund", _params, socket), do: Actions.record_refund(socket)

  defp gated_event("send_invoice", _params, socket), do: Actions.send_invoice(socket)

  defp gated_event("send_receipt", _params, socket), do: Actions.send_receipt(socket)

  defp gated_event("send_credit_note", _params, socket), do: Actions.send_credit_note(socket)

  defp gated_event("send_payment_confirmation", _params, socket),
    do: Actions.send_payment_confirmation(socket)

  defp gated_event("void_invoice", params, socket),
    do: Actions.void_invoice(socket, params["reason"])

  defp gated_event("generate_receipt", _params, socket), do: Actions.generate_receipt(socket)

  defp gated_event("trash_invoice", _params, socket), do: Actions.trash_invoice(socket)

  defp gated_event("restore_invoice", _params, socket), do: Actions.restore_invoice(socket)
end
