defmodule PhoenixKitBilling.Web.CreditNotePrint do
  @moduledoc """
  Printable credit note view - displays refund/credit note in a print-friendly format.

  This page is designed to be printed or saved as PDF directly from the browser.
  Credit notes are generated for refund transactions.

  IMPORTANT: In a credit note, the roles are reversed compared to invoice:
  - The company (seller) is now the PAYER (issuing the refund)
  - The customer is now the PAYEE (receiving the refund)
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext
  import PhoenixKitBilling.Web.Components.PrintDocument
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.DocumentBranding
  alias PhoenixKitBilling.Paths
  alias PhoenixKitBilling.Transaction
  alias PhoenixKitBilling.Web.Authz

  @impl true
  def mount(_params, _session, socket) do
    Authz.authorize_mount(socket, :manage_invoices, fn ->
      {:ok, socket, layout: false}
    end)
  end

  @impl true
  def handle_params(
        %{"invoice_uuid" => invoice_uuid, "transaction_uuid" => transaction_uuid},
        _url,
        socket
      ) do
    if Billing.enabled?() do
      load_document(socket, invoice_uuid, transaction_uuid)
    else
      {:noreply,
       socket
       |> put_flash(:error, gettext("Billing module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  defp load_document(socket, invoice_uuid, transaction_uuid) do
    case Billing.get_invoice(invoice_uuid, preload: [:order, :user]) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Invoice not found"))
         |> push_navigate(to: Paths.invoices())}

      invoice ->
        invoice_uuid = invoice.uuid

        case Billing.get_transaction(transaction_uuid) do
          %Transaction{invoice_uuid: ^invoice_uuid} = transaction ->
            if Transaction.refund?(transaction) do
              {:noreply, assign_document(socket, invoice, transaction)}
            else
              {:noreply,
               socket
               |> put_flash(:error, gettext("Transaction is not a refund"))
               |> push_navigate(to: Paths.invoice_detail(invoice_uuid))}
            end

          _ ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("Transaction not found"))
             |> push_navigate(to: Paths.invoice_detail(invoice_uuid))}
        end
    end
  end

  defp assign_document(socket, invoice, transaction) do
    project_title = Settings.get_project_title()
    company_info = Billing.get_company_info()
    credit_note_number = generate_credit_note_number(transaction)

    socket =
      socket
      |> assign(:page_title, gettext("Credit Note %{number}", number: credit_note_number))
      |> assign(:project_title, project_title)
      |> assign(:invoice, invoice)
      |> assign(:transaction, transaction)
      |> assign(:credit_note_number, credit_note_number)
      |> assign(:company, company_info)
      |> assign(:logo_url, DocumentBranding.logo_url())
      |> assign(:footer_text, DocumentBranding.footer_text())

    socket
  end

  defp generate_credit_note_number(transaction) do
    prefix = Settings.get_setting("billing_credit_note_prefix", "CN")
    # Use transaction number suffix for credit note
    suffix = transaction.transaction_number |> String.replace(~r/^TXN-/, "")
    "#{prefix}-#{suffix}"
  end
end
