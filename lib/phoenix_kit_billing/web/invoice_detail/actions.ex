defmodule PhoenixKitBilling.Web.InvoiceDetail.Actions do
  @moduledoc """
  Action handlers for the invoice detail LiveView.

  Contains business logic for payment recording, refunds,
  sending documents, voiding, and receipt generation.
  Each function takes a socket and returns `{:noreply, socket}`.
  """

  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Activity
  alias PhoenixKitBilling.Paths

  def record_payment(socket) do
    %{
      invoice: invoice,
      payment_amount: amount,
      payment_description: desc,
      selected_payment_method: payment_method
    } = socket.assigns

    current_scope = socket.assigns[:phoenix_kit_current_scope]

    attrs = %{
      amount: amount,
      payment_method: payment_method,
      description: if(desc == "", do: nil, else: desc)
    }

    case Billing.record_payment(invoice, attrs, current_scope) do
      {:ok, transaction} ->
        Activity.log("billing.payment_recorded",
          actor_uuid: actor_uuid(socket),
          actor_role: actor_role(socket),
          resource_type: "transaction",
          resource_uuid: transaction.uuid,
          metadata: %{
            "invoice_number" => invoice.invoice_number,
            "amount" => to_string(amount),
            "currency" => invoice.currency
          }
        )

        socket = reload_invoice(socket)

        # After the payment is committed. Best-effort by construction: a
        # notification reports a recorded payment and must not be able to
        # undo it. The amount RECORDED is passed explicitly - a partial
        # payment must not be announced as the invoice total.
        _ =
          PhoenixKitBilling.Notifications.payment_received(
            socket.assigns.invoice,
            transaction.amount
          )

        {:noreply,
         socket
         |> Phoenix.Component.assign(:show_payment_modal, false)
         |> put_flash(:info, "Payment recorded successfully")}

      {:error, :not_payable} ->
        {:noreply, put_flash(socket, :error, "Invoice cannot receive payments in current status")}

      {:error, :exceeds_remaining} ->
        {:noreply, put_flash(socket, :error, "Payment amount exceeds remaining balance")}

      {:error, :invalid_amount} ->
        {:noreply, put_flash(socket, :error, "Invalid payment amount")}

      {:error, changeset} when is_struct(changeset, Ecto.Changeset) ->
        {:noreply, put_flash(socket, :error, "Failed to record payment")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to record payment: #{inspect(reason)}")}
    end
  end

  def pay_with_provider(socket, provider_str) do
    provider = String.to_existing_atom(provider_str)
    invoice = socket.assigns.invoice

    success_url = Routes.base_url() <> Paths.invoice_detail(invoice.uuid) <> "?payment=success"
    cancel_url = Routes.base_url() <> Paths.invoice_detail(invoice.uuid) <> "?payment=cancelled"

    opts = [
      success_url: success_url,
      cancel_url: cancel_url,
      currency: invoice.currency,
      metadata: %{
        invoice_uuid: invoice.uuid,
        invoice_number: invoice.invoice_number
      }
    ]

    socket = Phoenix.Component.assign(socket, :checkout_loading, provider)

    case Billing.create_checkout_session(invoice, provider, opts) do
      {:ok, checkout_url} when is_binary(checkout_url) ->
        {:noreply, redirect(socket, external: checkout_url)}

      {:error, :provider_not_available} ->
        {:noreply,
         socket
         |> Phoenix.Component.assign(:checkout_loading, nil)
         |> put_flash(:error, "Payment provider #{provider} is not available")}

      {:error, reason} ->
        {:noreply,
         socket
         |> Phoenix.Component.assign(:checkout_loading, nil)
         |> put_flash(:error, "Failed to create checkout session: #{inspect(reason)}")}
    end
  end

  def record_refund(socket) do
    %{
      invoice: invoice,
      refund_amount: amount,
      refund_description: desc,
      selected_refund_payment_method: payment_method
    } = socket.assigns

    current_scope = socket.assigns[:phoenix_kit_current_scope]

    if desc == "" do
      {:noreply, put_flash(socket, :error, "Refund reason is required")}
    else
      attrs = %{
        amount: amount,
        payment_method: payment_method,
        description: desc
      }

      case Billing.record_refund(invoice, attrs, current_scope) do
        {:ok, transaction} ->
          Activity.log("billing.refund_recorded",
            actor_uuid: actor_uuid(socket),
            actor_role: actor_role(socket),
            resource_type: "transaction",
            resource_uuid: transaction.uuid,
            metadata: %{
              "invoice_number" => invoice.invoice_number,
              "amount" => to_string(amount),
              "currency" => invoice.currency
            }
          )

          socket = reload_invoice(socket)

          {:noreply,
           socket
           |> Phoenix.Component.assign(:show_refund_modal, false)
           |> put_flash(:info, "Refund recorded successfully")}

        {:error, :not_refundable} ->
          {:noreply, put_flash(socket, :error, "Invoice has no payments to refund")}

        {:error, :exceeds_paid_amount} ->
          {:noreply, put_flash(socket, :error, "Refund amount exceeds paid amount")}

        {:error, :invalid_amount} ->
          {:noreply, put_flash(socket, :error, "Invalid refund amount")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to record refund")}
      end
    end
  end

  def send_invoice(socket) do
    invoice = socket.assigns.invoice
    email = socket.assigns.send_email
    invoice_url = Routes.base_url() <> Paths.invoice_print(invoice.uuid)

    case Billing.send_invoice(invoice, invoice_url: invoice_url, to_email: email) do
      {:ok, updated_invoice, email_result} ->
        Activity.log("billing.invoice_sent",
          actor_uuid: actor_uuid(socket),
          actor_role: actor_role(socket),
          resource_type: "invoice",
          resource_uuid: updated_invoice.uuid,
          metadata: %{
            "invoice_number" => updated_invoice.invoice_number,
            "status" => updated_invoice.status
          }
        )

        # Issuing IS sending, from the customer's point of view.
        _ = PhoenixKitBilling.Notifications.invoice_issued(updated_invoice)

        {kind, message} = send_email_flash("Invoice", email, email_result)

        {:noreply,
         socket
         |> Phoenix.Component.assign(:invoice, updated_invoice)
         |> Phoenix.Component.assign(:show_send_modal, false)
         |> put_flash(kind, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send invoice: #{reason}")}
    end
  end

  def send_receipt(socket) do
    invoice = socket.assigns.invoice
    email = socket.assigns.send_receipt_email
    receipt_url = Routes.base_url() <> Paths.receipt_print(invoice.uuid)

    case Billing.send_receipt(invoice, receipt_url: receipt_url, to_email: email) do
      {:ok, updated_invoice, email_result} ->
        Activity.log("billing.receipt_sent",
          actor_uuid: actor_uuid(socket),
          actor_role: actor_role(socket),
          resource_type: "invoice",
          resource_uuid: updated_invoice.uuid,
          metadata: %{
            "invoice_number" => updated_invoice.invoice_number,
            "status" => updated_invoice.status
          }
        )

        {kind, message} = send_email_flash("Receipt", email, email_result)

        {:noreply,
         socket
         |> Phoenix.Component.assign(:invoice, updated_invoice)
         |> Phoenix.Component.assign(:show_send_receipt_modal, false)
         |> put_flash(kind, message)}

      {:error, :invoice_not_paid} ->
        {:noreply, put_flash(socket, :error, "Invoice must be paid before sending receipt")}

      {:error, :receipt_not_generated} ->
        {:noreply, put_flash(socket, :error, "Receipt has not been generated yet")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send receipt: #{inspect(reason)}")}
    end
  end

  def send_credit_note(socket) do
    invoice = socket.assigns.invoice
    email = socket.assigns.send_credit_note_email
    transaction_uuid = socket.assigns.send_credit_note_transaction_uuid
    transaction = Enum.find(socket.assigns.transactions, &(&1.uuid == transaction_uuid))

    credit_note_url = Routes.base_url() <> Paths.credit_note(invoice.uuid, transaction_uuid)

    with %{} <- transaction,
         {:ok, updated_transaction, email_result} <-
           Billing.send_credit_note(invoice, transaction,
             credit_note_url: credit_note_url,
             to_email: email
           ) do
      Activity.log("billing.credit_note_sent",
        actor_uuid: actor_uuid(socket),
        actor_role: actor_role(socket),
        resource_type: "transaction",
        resource_uuid: updated_transaction.uuid,
        metadata: %{"invoice_number" => invoice.invoice_number}
      )

      updated_transactions =
        update_transaction_in_list(socket.assigns.transactions, updated_transaction)

      {kind, message} = send_email_flash("Credit note", email, email_result)

      {:noreply,
       socket
       |> Phoenix.Component.assign(:transactions, updated_transactions)
       |> Phoenix.Component.assign(:show_send_credit_note_modal, false)
       |> Phoenix.Component.assign(:send_credit_note_transaction_uuid, nil)
       |> put_flash(kind, message)}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Transaction not found")}

      {:error, :not_a_refund} ->
        {:noreply, put_flash(socket, :error, "Transaction is not a refund")}

      {:error, :no_recipient_email} ->
        {:noreply, put_flash(socket, :error, "No recipient email address")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send credit note: #{inspect(reason)}")}
    end
  end

  def send_payment_confirmation(socket) do
    invoice = socket.assigns.invoice
    email = socket.assigns.send_payment_confirmation_email
    transaction_uuid = socket.assigns.send_payment_confirmation_transaction_uuid
    transaction = Enum.find(socket.assigns.transactions, &(&1.uuid == transaction_uuid))

    payment_url = Routes.base_url() <> Paths.payment_confirmation(invoice.uuid, transaction_uuid)

    with %{} <- transaction,
         {:ok, updated_transaction, email_result} <-
           Billing.send_payment_confirmation(invoice, transaction,
             payment_url: payment_url,
             to_email: email
           ) do
      Activity.log("billing.payment_confirmation_sent",
        actor_uuid: actor_uuid(socket),
        actor_role: actor_role(socket),
        resource_type: "transaction",
        resource_uuid: updated_transaction.uuid,
        metadata: %{"invoice_number" => invoice.invoice_number}
      )

      updated_transactions =
        update_transaction_in_list(socket.assigns.transactions, updated_transaction)

      {kind, message} = send_email_flash("Payment confirmation", email, email_result)

      {:noreply,
       socket
       |> Phoenix.Component.assign(:transactions, updated_transactions)
       |> Phoenix.Component.assign(:show_send_payment_confirmation_modal, false)
       |> Phoenix.Component.assign(:send_payment_confirmation_transaction_uuid, nil)
       |> put_flash(kind, message)}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Transaction not found")}

      {:error, :not_a_payment} ->
        {:noreply, put_flash(socket, :error, "Transaction is not a payment")}

      {:error, :no_recipient_email} ->
        {:noreply, put_flash(socket, :error, "No recipient email address")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to send payment confirmation: #{inspect(reason)}")}
    end
  end

  def void_invoice(socket) do
    case Billing.void_invoice(socket.assigns.invoice) do
      {:ok, invoice} ->
        Activity.log("billing.invoice_voided",
          actor_uuid: actor_uuid(socket),
          actor_role: actor_role(socket),
          resource_type: "invoice",
          resource_uuid: invoice.uuid,
          metadata: %{"invoice_number" => invoice.invoice_number, "status" => invoice.status}
        )

        {:noreply,
         socket
         |> Phoenix.Component.assign(:invoice, invoice)
         |> put_flash(:info, "Invoice voided")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to void invoice: #{reason}")}
    end
  end

  def generate_receipt(socket) do
    case Billing.generate_receipt(socket.assigns.invoice) do
      {:ok, invoice} ->
        Activity.log("billing.receipt_generated",
          actor_uuid: actor_uuid(socket),
          actor_role: actor_role(socket),
          resource_type: "invoice",
          resource_uuid: invoice.uuid,
          metadata: %{
            "invoice_number" => invoice.invoice_number,
            "receipt_number" => invoice.receipt_number
          }
        )

        {:noreply,
         socket
         |> Phoenix.Component.assign(:invoice, invoice)
         |> put_flash(:info, "Receipt generated: #{invoice.receipt_number}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to generate receipt: #{reason}")}
    end
  end

  # Private helpers

  defp actor_uuid(socket), do: Activity.actor_uuid(socket)
  defp actor_role(socket), do: Activity.actor_role(socket)

  defp reload_invoice(socket) do
    invoice = socket.assigns.invoice
    updated_invoice = Billing.get_invoice(invoice.uuid, preload: [:order, :transactions, :user])
    transactions = Billing.list_invoice_transactions(invoice.uuid)

    socket
    |> Phoenix.Component.assign(:invoice, updated_invoice)
    |> Phoenix.Component.assign(:transactions, transactions)
  end

  defp update_transaction_in_list(transactions, updated_transaction) do
    Enum.map(transactions, fn t ->
      if t.uuid == updated_transaction.uuid, do: updated_transaction, else: t
    end)
  end

  # The record-level operation (status change, send-history entry) behind
  # `subject` already committed by the time this runs regardless of
  # `email_result` — that part is real and done, so it's never reported
  # as a failure. Only the wording changes based on whether the customer
  # was actually emailed: B003 found that `do_send_invoice/3` and its
  # three siblings used to silently discard this outcome entirely, so
  # the flash always claimed "sent to <email>" even when
  # phoenix_kit_emails wasn't installed and nothing went out.
  defp send_email_flash(subject, email, email_result) do
    case email_result do
      {:error, :emails_module_not_installed} ->
        {:warning, "#{subject} saved, but no email was sent — the emails module isn't installed"}

      {:error, reason} ->
        {:warning, "#{subject} saved, but the email failed: #{inspect(reason)}"}

      :skipped ->
        {:info, "#{subject} saved (no email requested)"}

      _ ->
        {:info, "#{subject} sent to #{email}"}
    end
  end
end
