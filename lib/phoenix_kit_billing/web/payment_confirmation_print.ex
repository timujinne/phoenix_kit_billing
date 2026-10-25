defmodule PhoenixKitBilling.Web.PaymentConfirmationPrint do
  @moduledoc """
  Printable payment confirmation view - displays individual payment in a print-friendly format.

  This page is designed to be printed or saved as PDF directly from the browser.
  Payment confirmations are generated for individual payment transactions.
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
            if Transaction.payment?(transaction) do
              {:noreply, assign_document(socket, invoice, transaction)}
            else
              {:noreply,
               socket
               |> put_flash(:error, gettext("Transaction is not a payment"))
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
    confirmation_number = generate_confirmation_number(transaction)
    all_transactions = Billing.list_invoice_transactions(invoice.uuid)
    payment_context = calculate_payment_context(invoice, transaction, all_transactions)

    socket =
      socket
      |> assign(
        :page_title,
        gettext("Payment Confirmation %{number}", number: confirmation_number)
      )
      |> assign(:project_title, project_title)
      |> assign(:invoice, invoice)
      |> assign(:transaction, transaction)
      |> assign(:confirmation_number, confirmation_number)
      |> assign(:company, company_info)
      |> assign(:logo_url, DocumentBranding.logo_url())
      |> assign(:footer_text, DocumentBranding.footer_text())
      |> assign(:payment_context, payment_context)

    socket
  end

  defp generate_confirmation_number(transaction) do
    prefix = Settings.get_setting("billing_payment_confirmation_prefix", "PMT")
    suffix = transaction.transaction_number |> String.replace(~r/^TXN-/, "")
    "#{prefix}-#{suffix}"
  end

  defp calculate_payment_context(invoice, transaction, all_transactions) do
    # Payments up to and including this transaction
    sorted_payments =
      all_transactions
      |> Enum.filter(&Decimal.positive?(&1.amount))
      |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})

    # Find position of current payment
    payment_index =
      Enum.find_index(sorted_payments, fn t -> t.uuid == transaction.uuid end) || 0

    # Total paid up to and including this payment
    payments_up_to_now = Enum.take(sorted_payments, payment_index + 1)

    total_paid_so_far =
      payments_up_to_now
      |> Enum.map(& &1.amount)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    remaining_balance = Decimal.sub(invoice.total, total_paid_so_far)

    is_final_payment = Decimal.lte?(remaining_balance, Decimal.new(0))

    %{
      payment_number: payment_index + 1,
      total_payments: length(sorted_payments),
      total_paid_so_far: total_paid_so_far,
      remaining_balance: Decimal.max(remaining_balance, Decimal.new(0)),
      is_final_payment: is_final_payment
    }
  end
end
