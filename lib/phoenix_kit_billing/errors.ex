defmodule PhoenixKitBilling.Errors do
  @moduledoc """
  Central mapping from the error atoms returned by the billing module's
  context, payment providers, and webhook handlers to translated
  human-readable strings.

  Keeping the API layer locale-agnostic means callers and integration
  consumers can pattern-match on atoms and decide their own presentation.
  Anything user-facing (flash messages, error banners) goes through
  `message/1`, which wraps each mapping in `gettext/1` using the
  module's own `PhoenixKitBilling.Gettext` backend so the strings are
  extractable into `priv/gettext`.

  ## Supported reason shapes

    * plain atoms — `:not_found`, `:card_declined`, `:invalid_signature`, etc.
    * `%Ecto.Changeset{}` — formatted as `"field: message; ..."` so a
      changeset returned alongside domain atoms in a shared `{:error, _}`
      branch still renders readably
    * strings — passed through unchanged (legacy / interpolated messages)
    * anything else — rendered as `"Unexpected error: <inspect>"` so
      nothing silently surfaces a raw struct

  ## Example

      iex> PhoenixKitBilling.Errors.message(:card_declined)
      "The card was declined."
  """

  use Gettext, backend: PhoenixKitBilling.Gettext

  @type error ::
          :already_paid
          | :already_refunded
          | :already_trashed
          | :authentication_failed
          | :can_only_delete_drafts
          | :card_declined
          | :currency_in_use
          | :duplicate_event
          | :event_log_failed
          | :exceeds_paid_amount
          | :exceeds_remaining
          | :has_active_subscriptions
          | :has_subscriptions
          | :invalid_amount
          | :invalid_format
          | :invalid_json
          | :invalid_payload
          | :invalid_response
          | :invalid_signature
          | :invalid_timestamp
          | :invoice_has_payments
          | :invoice_not_editable
          | :invoice_not_found
          | :invoice_not_paid
          | :invoice_not_payable
          | :invoice_not_sendable
          | :invoice_not_trashable
          | :invoice_not_void
          | :invoice_not_voidable
          | :invoice_trashed
          | :is_default
          | :max_retries_exceeded
          | :missing_reference
          | :no_charge_id
          | :no_payment_method
          | :no_payments
          | :no_plan
          | :no_raw_body
          | :no_recipient_email
          | :no_signature
          | :no_user
          | :not_a_payment
          | :not_a_refund
          | :not_configured
          | :not_found
          | :not_payable
          | :not_refundable
          | :not_supported
          | :not_trashed
          | :order_has_invoices
          | :order_cancelled
          | :order_has_open_invoices
          | :order_not_cancellable
          | :order_not_editable
          | :order_not_payable
          | :order_not_reinstatable
          | :order_not_refundable
          | :order_not_trashable
          | :order_trashed
          | :payment_method_expired
          | :payment_method_not_usable
          | :processing_error
          | :provider_not_available
          | :provider_not_found
          | :receipt_already_generated
          | :receipt_not_generated
          | :receipt_not_sendable
          | :request_failed
          | :requires_action
          | :signature_mismatch
          | :subscription_type_not_found
          | :timestamp_too_old
          | :transaction_not_found
          | :unknown_event

  @doc """
  Translates an error reason (atom, string, or any term) into a
  user-facing string via gettext.
  """
  @spec message(error() | term()) :: String.t()
  def message(:already_paid), do: gettext("This has already been paid.")
  def message(:already_refunded), do: gettext("This payment has already been refunded.")

  def message(:already_trashed), do: gettext("This record is already in the trash.")

  def message(:authentication_failed),
    do: gettext("Authentication with the payment provider failed.")

  def message(:can_only_delete_drafts), do: gettext("Only draft records can be deleted.")
  def message(:card_declined), do: gettext("The card was declined.")
  def message(:currency_in_use), do: gettext("This currency is in use and cannot be removed.")
  def message(:duplicate_event), do: gettext("This event has already been processed.")
  def message(:event_log_failed), do: gettext("Failed to record the billing event.")
  def message(:exceeds_paid_amount), do: gettext("The amount exceeds the amount paid.")
  def message(:exceeds_remaining), do: gettext("The amount exceeds the remaining balance.")

  def message(:has_active_subscriptions),
    do: gettext("Cannot proceed while there are active subscriptions.")

  def message(:has_subscriptions),
    do: gettext("Cannot proceed while there are existing subscriptions.")

  def message(:invalid_amount), do: gettext("The amount is invalid.")
  def message(:invalid_format), do: gettext("The format is invalid.")
  def message(:invalid_json), do: gettext("The response was not valid JSON.")
  def message(:invalid_payload), do: gettext("The webhook payload is invalid.")

  def message(:invalid_response),
    do: gettext("The payment provider returned an invalid response.")

  def message(:invalid_signature), do: gettext("The webhook signature is invalid.")
  def message(:invalid_timestamp), do: gettext("The webhook timestamp is invalid.")

  def message(:invoice_has_payments),
    do: gettext("This invoice has payments and cannot be voided. Issue a refund instead.")

  def message(:invoice_not_editable), do: gettext("This invoice can no longer be edited.")
  def message(:invoice_not_found), do: gettext("Invoice not found.")
  def message(:invoice_not_paid), do: gettext("This invoice has not been paid.")

  def message(:invoice_not_payable),
    do: gettext("This invoice cannot be paid in its current state.")

  def message(:invoice_not_sendable),
    do: gettext("This invoice cannot be sent in its current state.")

  def message(:invoice_not_trashable),
    do:
      gettext(
        "Only a draft invoice that was never sent can be moved to the trash. Void an issued invoice instead."
      )

  def message(:invoice_not_void), do: gettext("This invoice has not been voided.")

  def message(:invoice_not_voidable),
    do: gettext("This invoice cannot be voided in its current state.")

  def message(:invoice_trashed),
    do: gettext("This invoice is in the trash. Restore it to change it.")

  def message(:is_default), do: gettext("The default item cannot be removed.")

  def message(:max_retries_exceeded),
    do: gettext("This event exceeded the maximum number of retries.")

  def message(:missing_reference), do: gettext("A required reference is missing.")
  def message(:no_charge_id), do: gettext("No charge identifier is available.")
  def message(:no_payment_method), do: gettext("No payment method is available.")
  def message(:no_payments), do: gettext("There are no payments to process.")
  def message(:no_plan), do: gettext("No plan is associated with this record.")
  def message(:no_raw_body), do: gettext("The webhook request body is missing.")
  def message(:no_recipient_email), do: gettext("No recipient email address is available.")
  def message(:no_signature), do: gettext("The webhook signature header is missing.")
  def message(:no_user), do: gettext("No user is associated with this record.")
  def message(:not_a_payment), do: gettext("This transaction is not a payment.")
  def message(:not_a_refund), do: gettext("This transaction is not a refund.")
  def message(:not_configured), do: gettext("The payment provider is not configured.")
  def message(:not_found), do: gettext("The requested record was not found.")
  def message(:not_payable), do: gettext("This record cannot be paid in its current state.")
  def message(:not_refundable), do: gettext("This record cannot be refunded.")
  def message(:not_supported), do: gettext("This operation is not supported.")
  def message(:not_trashed), do: gettext("This record is not in the trash.")

  def message(:order_has_invoices),
    do: gettext("This order has invoices and cannot be deleted.")

  def message(:order_cancelled),
    do: gettext("This order is cancelled and cannot take this invoice.")

  def message(:order_has_open_invoices),
    do: gettext("This order has an invoice that is neither void nor in the trash.")

  def message(:order_not_cancellable),
    do: gettext("This order cannot be cancelled in its current state.")

  def message(:order_not_editable), do: gettext("This order can no longer be edited.")
  def message(:order_not_payable), do: gettext("This order cannot be paid in its current state.")

  def message(:order_not_reinstatable),
    do: gettext("Only a cancelled order can be reinstated.")

  def message(:order_not_refundable), do: gettext("This order cannot be refunded.")

  def message(:order_not_trashable),
    do: gettext("Only a draft or cancelled order can be moved to the trash.")

  def message(:order_trashed), do: gettext("This order is in the trash. Restore it to change it.")

  def message(:payment_method_expired), do: gettext("The payment method has expired.")
  def message(:payment_method_not_usable), do: gettext("This payment method cannot be used.")
  def message(:processing_error), do: gettext("An error occurred while processing the payment.")
  def message(:provider_not_available), do: gettext("The payment provider is not available.")
  def message(:provider_not_found), do: gettext("The payment provider was not found.")
  def message(:receipt_already_generated), do: gettext("A receipt has already been generated.")
  def message(:receipt_not_generated), do: gettext("No receipt has been generated yet.")

  def message(:receipt_not_sendable),
    do: gettext("This receipt cannot be sent in its current state.")

  def message(:request_failed), do: gettext("The request to the payment provider failed.")

  def message(:requires_action),
    do: gettext("Additional action is required to complete the payment.")

  def message(:signature_mismatch), do: gettext("The webhook signature does not match.")
  def message(:subscription_type_not_found), do: gettext("Subscription type not found.")
  def message(:timestamp_too_old), do: gettext("The webhook timestamp is too old.")
  def message(:transaction_not_found), do: gettext("Transaction not found.")
  def message(:unknown_event), do: gettext("The webhook event type is not recognized.")

  def message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end

  def message(reason) when is_binary(reason), do: reason

  def message(reason) do
    gettext("Unexpected error: %{reason}", reason: inspect(reason))
  end
end
