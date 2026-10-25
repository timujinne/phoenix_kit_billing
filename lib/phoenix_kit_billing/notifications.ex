defmodule PhoenixKitBilling.Notifications do
  @moduledoc """
  Billing notifications: who hears about an invoice or a payment, and when.

  Sends go through core's notification layer, so each recipient's own
  per-type preferences and delivery channels (in-app inbox, email,
  Telegram, digest cadence) apply. This module only decides the audience
  and the copy.

  ## Recipients

  `admin_recipients/1` unions three sources, because no single one is
  complete:

    * holders of the relevant permission key (`users_with_permission/1`)
    * **Owner-role holders**, whose access is implicit and who therefore
      have no permission rows at all
    * holders of the `"*"` superadmin key, likewise absent from a
      key-specific query

  A resolver that queried only the first would miss the primary operator
  of a default install — the person most likely to want the notification.

  ## Money copy carries no PII

  Notification text names an invoice or order NUMBER and an amount, never
  a customer name, address or email: a notification lands in someone's
  inbox and can be routed onward to email or Telegram.

  ## Failure is never fatal

  Every send is wrapped. A notification reports a committed fact — a
  payment that has been recorded, an invoice that has been issued — and
  must never be able to undo it.
  """

  require Logger

  alias PhoenixKit.Notifications
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling.Paths

  @invoice_issued_action "billing.invoice_issued"
  @payment_received_action "billing.payment_received"
  @payment_failed_action "billing.payment_failed"
  @customer_invoice_action "billing.your_invoice_issued"
  @customer_payment_action "billing.your_payment_received"

  @doc """
  An invoice was issued: tells billing operators, and the customer.

  Separate sub-types, so an operator muting the invoice firehose does not
  also silence their own receipts.
  """
  def invoice_issued(invoice) do
    safely(fn ->
      notify_admins(
        "billing.manage_invoices",
        @invoice_issued_action,
        "Invoice #{number(invoice)} issued — #{amount(invoice)}",
        "hero-document-text",
        Routes.path("/admin/billing/invoices")
      )

      notify_customer(
        invoice,
        @customer_invoice_action,
        "Invoice #{number(invoice)} is ready — #{amount(invoice)}",
        "hero-document-text"
      )
    end)
  end

  @doc """
  A payment was recorded against an invoice.

  `paid` is the amount actually recorded. It matters: quoting the invoice
  total on a PARTIAL payment tells an operator 500 arrived when 50 did.
  Falls back to the invoice total when a caller has no amount to hand.
  """
  def payment_received(invoice, paid \\ nil) do
    safely(fn ->
      notify_admins(
        "billing.manage_invoices",
        @payment_received_action,
        "Payment received for #{number(invoice)} — #{paid_amount(invoice, paid)}",
        "hero-banknotes",
        Routes.path("/admin/billing/invoices")
      )

      notify_customer(
        invoice,
        @customer_payment_action,
        "We received your payment for #{number(invoice)}",
        "hero-check-circle"
      )
    end)
  end

  @doc """
  A payment attempt failed.

  Admin-only: the customer already saw the failure in the checkout flow,
  and a second channel telling them their card was declined is noise at
  best. Operators need it, because a failed payment is work.

  The reason `:invoice_void` is a payment the provider CONFIRMED for an
  invoice that was voided meanwhile: it was not recorded and needs refunding
  at the provider.
  """
  def payment_failed(invoice, reason) do
    safely(fn ->
      notify_admins(
        "billing.manage_invoices",
        @payment_failed_action,
        payment_failed_text(invoice, reason),
        "hero-exclamation-triangle",
        Routes.path("/admin/billing/invoices")
      )
    end)
  end

  defp payment_failed_text(invoice, :invoice_void) do
    "A payment arrived for void invoice #{number(invoice)} and was not recorded - " <>
      "refund it at the payment provider"
  end

  defp payment_failed_text(invoice, reason) do
    "Payment failed for #{number(invoice)}: #{truncate(to_string(reason), 100)}"
  end

  defp notify_admins(permission_key, action, text, icon, link) do
    Notifications.create_many(admin_recipients(permission_key), %{
      action: action,
      text: text,
      icon: icon,
      link: link
    })
  end

  # Only a real, confirmed account gets an in-app notification: a guest
  # placeholder user's channel is the transactional email, and sending both
  # would double-message someone who has not confirmed an address.
  defp notify_customer(%{user_uuid: nil}, _action, _text, _icon), do: :ok

  defp notify_customer(%{user_uuid: user_uuid} = record, action, text, icon) do
    case Auth.get_user(user_uuid) do
      %{confirmed_at: confirmed} when not is_nil(confirmed) ->
        Notifications.create(%{
          recipient_uuid: user_uuid,
          action: action,
          text: text,
          icon: icon,
          link: customer_link(record)
        })

      _unconfirmed_or_missing ->
        :ok
    end
  end

  defp notify_customer(_record, _action, _text, _icon), do: :ok

  # `/dashboard/billing-orders` is what this module actually registers, via
  # `:dashboard_orders`'s own `:live_view` in `user_dashboard_tabs/0`.
  # `/dashboard/orders` is core-reserved for `phoenix_kit_ecommerce`'s own
  # (separate) orders screen — see the hardcoded
  # `authenticated_live_routes/0`/`authenticated_live_locale_routes/0` blocks
  # in `deps/phoenix_kit/lib/phoenix_kit_web/integration.ex` — and must never
  # be reused here: on a host with both modules installed it would collide
  # with, or silently shadow, the ecommerce module's own UI over the same
  # underlying `PhoenixKitBilling.Order` data.
  defp customer_link(_record), do: Paths.user_orders()

  @doc """
  Everyone who should hear about billing operations: holders of `key`,
  unioned with Owner-role holders and `"*"` superadmins.
  """
  def admin_recipients(key) do
    (Permissions.users_with_permission(key) ++
       Permissions.users_with_permission("*") ++
       Roles.users_with_role("Owner"))
    |> Enum.map(&user_uuid/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  rescue
    error ->
      Logger.warning("[Billing] could not resolve notification recipients: #{inspect(error)}")
      []
  end

  defp user_uuid(%{uuid: uuid}), do: uuid
  defp user_uuid(%{user_uuid: uuid}), do: uuid
  defp user_uuid(uuid) when is_binary(uuid), do: uuid
  defp user_uuid(_), do: nil

  defp number(%{invoice_number: n}) when is_binary(n), do: n
  defp number(%{order_number: n}) when is_binary(n), do: n
  defp number(_), do: ""

  defp amount(%{total: total, currency: currency}) when not is_nil(total) do
    "#{Decimal.round(total, 2)} #{currency}"
  end

  defp amount(_), do: ""

  defp paid_amount(%{currency: currency}, %Decimal{} = paid),
    do: "#{Decimal.round(paid, 2)} #{currency}"

  defp paid_amount(invoice, _paid), do: amount(invoice)

  # String.slice/2, not binary_part/3: a provider's decline reason can carry
  # non-ASCII, and cutting on a byte boundary yields an invalid UTF-8 string
  # that Postgres and the JSON encoder both reject.
  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  # A notification must never take down the thing it is reporting on.
  defp safely(fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.warning("[Billing] notification failed: #{inspect(error)}")
      :ok
  catch
    kind, value ->
      Logger.warning("[Billing] notification failed: #{inspect(kind)} #{inspect(value)}")
      :ok
  end
end
