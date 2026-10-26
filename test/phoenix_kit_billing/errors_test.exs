defmodule PhoenixKitBilling.ErrorsTest do
  @moduledoc """
  One assertion per error atom guarding the EXACT user-facing string
  produced by `PhoenixKitBilling.Errors.message/1`. The default (English)
  locale is the source-of-truth msgid; if a clause is removed or its copy
  changes, the matching test breaks deliberately.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitBilling.Errors

  describe "message/1 for known atoms" do
    test ":already_paid",
      do: assert(Errors.message(:already_paid) == "This has already been paid.")

    test ":already_refunded",
      do: assert(Errors.message(:already_refunded) == "This payment has already been refunded.")

    test ":authentication_failed",
      do:
        assert(
          Errors.message(:authentication_failed) ==
            "Authentication with the payment provider failed."
        )

    test ":can_only_delete_drafts",
      do: assert(Errors.message(:can_only_delete_drafts) == "Only draft records can be deleted.")

    test ":card_declined", do: assert(Errors.message(:card_declined) == "The card was declined.")

    test ":currency_in_use",
      do:
        assert(
          Errors.message(:currency_in_use) == "This currency is in use and cannot be removed."
        )

    test ":duplicate_event",
      do: assert(Errors.message(:duplicate_event) == "This event has already been processed.")

    test ":event_log_failed",
      do: assert(Errors.message(:event_log_failed) == "Failed to record the billing event.")

    test ":exceeds_paid_amount",
      do: assert(Errors.message(:exceeds_paid_amount) == "The amount exceeds the amount paid.")

    test ":exceeds_remaining",
      do:
        assert(Errors.message(:exceeds_remaining) == "The amount exceeds the remaining balance.")

    test ":has_active_subscriptions",
      do:
        assert(
          Errors.message(:has_active_subscriptions) ==
            "Cannot proceed while there are active subscriptions."
        )

    test ":has_subscriptions",
      do:
        assert(
          Errors.message(:has_subscriptions) ==
            "Cannot proceed while there are existing subscriptions."
        )

    test ":invalid_amount",
      do: assert(Errors.message(:invalid_amount) == "The amount is invalid.")

    test ":invalid_format",
      do: assert(Errors.message(:invalid_format) == "The format is invalid.")

    test ":invalid_json",
      do: assert(Errors.message(:invalid_json) == "The response was not valid JSON.")

    test ":invalid_payload",
      do: assert(Errors.message(:invalid_payload) == "The webhook payload is invalid.")

    test ":invalid_response",
      do:
        assert(
          Errors.message(:invalid_response) ==
            "The payment provider returned an invalid response."
        )

    test ":invalid_signature",
      do: assert(Errors.message(:invalid_signature) == "The webhook signature is invalid.")

    test ":invalid_timestamp",
      do: assert(Errors.message(:invalid_timestamp) == "The webhook timestamp is invalid.")

    test ":invoice_not_editable",
      do: assert(Errors.message(:invoice_not_editable) == "This invoice can no longer be edited.")

    test ":invoice_not_found",
      do: assert(Errors.message(:invoice_not_found) == "Invoice not found.")

    test ":invoice_not_paid",
      do: assert(Errors.message(:invoice_not_paid) == "This invoice has not been paid.")

    test ":invoice_not_payable",
      do:
        assert(
          Errors.message(:invoice_not_payable) ==
            "This invoice cannot be paid in its current state."
        )

    test ":invoice_not_sendable",
      do:
        assert(
          Errors.message(:invoice_not_sendable) ==
            "This invoice cannot be sent in its current state."
        )

    test ":invoice_not_void",
      do: assert(Errors.message(:invoice_not_void) == "This invoice has not been voided.")

    test ":invoice_not_voidable",
      do:
        assert(
          Errors.message(:invoice_not_voidable) ==
            "This invoice cannot be voided in its current state."
        )

    test ":is_default",
      do: assert(Errors.message(:is_default) == "The default item cannot be removed.")

    test ":max_retries_exceeded",
      do:
        assert(
          Errors.message(:max_retries_exceeded) ==
            "This event exceeded the maximum number of retries."
        )

    test ":missing_reference",
      do: assert(Errors.message(:missing_reference) == "A required reference is missing.")

    test ":no_charge_id",
      do: assert(Errors.message(:no_charge_id) == "No charge identifier is available.")

    test ":no_payment_method",
      do: assert(Errors.message(:no_payment_method) == "No payment method is available.")

    test ":no_payments",
      do: assert(Errors.message(:no_payments) == "There are no payments to process.")

    test ":no_plan",
      do: assert(Errors.message(:no_plan) == "No plan is associated with this record.")

    test ":no_raw_body",
      do: assert(Errors.message(:no_raw_body) == "The webhook request body is missing.")

    test ":no_recipient_email",
      do:
        assert(Errors.message(:no_recipient_email) == "No recipient email address is available.")

    test ":no_signature",
      do: assert(Errors.message(:no_signature) == "The webhook signature header is missing.")

    test ":no_user",
      do: assert(Errors.message(:no_user) == "No user is associated with this record.")

    test ":not_a_payment",
      do: assert(Errors.message(:not_a_payment) == "This transaction is not a payment.")

    test ":not_a_refund",
      do: assert(Errors.message(:not_a_refund) == "This transaction is not a refund.")

    test ":not_configured",
      do: assert(Errors.message(:not_configured) == "The payment provider is not configured.")

    test ":not_found",
      do: assert(Errors.message(:not_found) == "The requested record was not found.")

    test ":not_payable",
      do:
        assert(Errors.message(:not_payable) == "This record cannot be paid in its current state.")

    test ":not_refundable",
      do: assert(Errors.message(:not_refundable) == "This record cannot be refunded.")

    test ":not_supported",
      do: assert(Errors.message(:not_supported) == "This operation is not supported.")

    test ":order_has_invoices",
      do:
        assert(
          Errors.message(:order_has_invoices) ==
            "This order has invoices and cannot be deleted."
        )

    test ":order_not_cancellable",
      do:
        assert(
          Errors.message(:order_not_cancellable) ==
            "This order cannot be cancelled in its current state."
        )

    test ":order_not_editable",
      do: assert(Errors.message(:order_not_editable) == "This order can no longer be edited.")

    test ":order_not_payable",
      do:
        assert(
          Errors.message(:order_not_payable) ==
            "This order cannot be paid in its current state."
        )

    test ":order_not_refundable",
      do: assert(Errors.message(:order_not_refundable) == "This order cannot be refunded.")

    test ":payment_method_expired",
      do: assert(Errors.message(:payment_method_expired) == "The payment method has expired.")

    test ":payment_method_not_usable",
      do:
        assert(
          Errors.message(:payment_method_not_usable) == "This payment method cannot be used."
        )

    test ":processing_error",
      do:
        assert(
          Errors.message(:processing_error) ==
            "An error occurred while processing the payment."
        )

    test ":provider_not_available",
      do:
        assert(
          Errors.message(:provider_not_available) == "The payment provider is not available."
        )

    test ":provider_not_found",
      do: assert(Errors.message(:provider_not_found) == "The payment provider was not found.")

    test ":receipt_already_generated",
      do:
        assert(
          Errors.message(:receipt_already_generated) ==
            "A receipt has already been generated."
        )

    test ":receipt_not_generated",
      do: assert(Errors.message(:receipt_not_generated) == "No receipt has been generated yet.")

    test ":receipt_not_sendable",
      do:
        assert(
          Errors.message(:receipt_not_sendable) ==
            "This receipt cannot be sent in its current state."
        )

    test ":request_failed",
      do: assert(Errors.message(:request_failed) == "The request to the payment provider failed.")

    test ":requires_action",
      do:
        assert(
          Errors.message(:requires_action) ==
            "Additional action is required to complete the payment."
        )

    test ":signature_mismatch",
      do: assert(Errors.message(:signature_mismatch) == "The webhook signature does not match.")

    test ":subscription_type_not_found",
      do: assert(Errors.message(:subscription_type_not_found) == "Subscription type not found.")

    test ":timestamp_too_old",
      do: assert(Errors.message(:timestamp_too_old) == "The webhook timestamp is too old.")

    test ":transaction_not_found",
      do: assert(Errors.message(:transaction_not_found) == "Transaction not found.")

    test ":unknown_event",
      do: assert(Errors.message(:unknown_event) == "The webhook event type is not recognized.")
  end

  describe "message/1 for the trash" do
    test ":already_trashed",
      do: assert(Errors.message(:already_trashed) == "This record is already in the trash.")

    test ":not_trashed",
      do: assert(Errors.message(:not_trashed) == "This record is not in the trash.")

    test ":order_trashed",
      do:
        assert(
          Errors.message(:order_trashed) == "This order is in the trash. Restore it to change it."
        )

    test ":invoice_trashed",
      do:
        assert(
          Errors.message(:invoice_trashed) ==
            "This invoice is in the trash. Restore it to change it."
        )

    test ":order_cancelled",
      do:
        assert(
          Errors.message(:order_cancelled) ==
            "This order is cancelled and cannot take a new invoice."
        )

    test ":order_not_trashable",
      do:
        assert(
          Errors.message(:order_not_trashable) ==
            "Only a draft or cancelled order can be moved to the trash."
        )

    test ":invoice_not_trashable",
      do:
        assert(
          Errors.message(:invoice_not_trashable) ==
            "Only a draft invoice that was never sent can be moved to the trash. Void an issued invoice instead."
        )

    test ":order_has_open_invoices",
      do:
        assert(
          Errors.message(:order_has_open_invoices) ==
            "This order has an invoice that is neither void nor in the trash."
        )
  end

  describe "message/1 fallbacks" do
    test "passes strings through unchanged" do
      assert Errors.message("custom provider message") == "custom provider message"
    end

    test "renders unknown reasons via inspect" do
      assert Errors.message({:weird, 1}) == "Unexpected error: {:weird, 1}"
      assert Errors.message(:totally_unmapped) == "Unexpected error: :totally_unmapped"
    end

    test "formats an Ecto.Changeset into a field: message string" do
      changeset =
        {%{}, %{name: :string}}
        |> Ecto.Changeset.cast(%{}, [:name])
        |> Ecto.Changeset.validate_required([:name])

      assert Errors.message(changeset) == "name: can't be blank"
    end
  end
end
