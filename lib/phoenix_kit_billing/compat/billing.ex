defmodule PhoenixKit.Modules.Billing do
  # Temporary compatibility alias for PhoenixKitBilling.
  #
  # This module exists to maintain backward compatibility with PhoenixKit core
  # which still references the old `PhoenixKit.Modules.Billing.*` namespace.
  # Will be removed once core is fully migrated to `PhoenixKitBilling.*`.
  #
  # All public functions are explicitly delegated to PhoenixKitBilling. Hidden
  # from HexDocs because consumers should target `PhoenixKitBilling.*` directly.
  @moduledoc false

  # Module info and config
  defdelegate enabled?(), to: PhoenixKitBilling
  defdelegate version(), to: PhoenixKitBilling
  defdelegate required_modules(), to: PhoenixKitBilling
  defdelegate enable_system(), to: PhoenixKitBilling
  defdelegate disable_system(), to: PhoenixKitBilling
  defdelegate module_key(), to: PhoenixKitBilling
  defdelegate module_name(), to: PhoenixKitBilling
  defdelegate route_module(), to: PhoenixKitBilling
  defdelegate permission_metadata(), to: PhoenixKitBilling
  defdelegate admin_tabs(), to: PhoenixKitBilling
  defdelegate settings_tabs(), to: PhoenixKitBilling
  defdelegate user_dashboard_tabs(), to: PhoenixKitBilling
  defdelegate get_config(), to: PhoenixKitBilling

  # Core resolves these with `function_exported?/3` against whichever module is
  # registered, so a gap here is silent: a host registering the legacy namespace
  # loses its Tailwind @source line and its notification types with no error
  # anywhere. (`module_stats/0`, resolved the same way, is under "Utilities".)
  defdelegate css_sources(), to: PhoenixKitBilling
  defdelegate notification_types(), to: PhoenixKitBilling
  defdelegate email_templates(), to: PhoenixKitBilling

  # Tax
  defdelegate tax_enabled?(), to: PhoenixKitBilling
  defdelegate get_tax_rate(), to: PhoenixKitBilling
  defdelegate get_tax_rate_percent(), to: PhoenixKitBilling

  # Dashboard
  defdelegate get_dashboard_stats(), to: PhoenixKitBilling

  # Currencies
  defdelegate list_currencies(opts \\ []), to: PhoenixKitBilling
  defdelegate list_enabled_currencies(), to: PhoenixKitBilling
  defdelegate get_default_currency(), to: PhoenixKitBilling
  defdelegate get_currency(id), to: PhoenixKitBilling
  defdelegate get_currency!(id), to: PhoenixKitBilling
  defdelegate get_currency_by_code(code), to: PhoenixKitBilling
  defdelegate create_currency(attrs), to: PhoenixKitBilling
  defdelegate update_currency(currency, attrs), to: PhoenixKitBilling
  defdelegate set_default_currency(currency), to: PhoenixKitBilling
  defdelegate delete_currency(currency), to: PhoenixKitBilling

  # Billing Profiles
  defdelegate list_billing_profiles(opts \\ []), to: PhoenixKitBilling
  defdelegate list_user_billing_profiles(user_uuid), to: PhoenixKitBilling
  defdelegate list_billing_profiles_with_count(opts), to: PhoenixKitBilling
  defdelegate get_default_billing_profile(user_uuid), to: PhoenixKitBilling
  defdelegate get_billing_profile(id), to: PhoenixKitBilling
  defdelegate get_billing_profile!(id), to: PhoenixKitBilling
  defdelegate change_billing_profile(profile, attrs \\ %{}), to: PhoenixKitBilling
  defdelegate create_billing_profile(user_or_uuid, attrs), to: PhoenixKitBilling
  defdelegate update_billing_profile(profile, attrs), to: PhoenixKitBilling
  defdelegate delete_billing_profile(profile), to: PhoenixKitBilling
  defdelegate set_default_billing_profile(profile), to: PhoenixKitBilling

  # Orders
  defdelegate list_orders(filters \\ %{}), to: PhoenixKitBilling
  defdelegate list_orders_with_count(opts), to: PhoenixKitBilling
  defdelegate list_user_orders(user_uuid, filters \\ %{}), to: PhoenixKitBilling
  defdelegate get_order(id, opts \\ []), to: PhoenixKitBilling
  defdelegate get_order!(id), to: PhoenixKitBilling
  defdelegate get_order_by_number(order_number), to: PhoenixKitBilling
  defdelegate get_order_by_uuid(uuid, opts \\ []), to: PhoenixKitBilling
  defdelegate change_order(order, attrs \\ %{}), to: PhoenixKitBilling
  defdelegate create_order(user_or_uuid, attrs), to: PhoenixKitBilling
  defdelegate update_order(order, attrs), to: PhoenixKitBilling
  defdelegate delete_order(order), to: PhoenixKitBilling
  defdelegate confirm_order(order), to: PhoenixKitBilling
  defdelegate cancel_order(order, reason \\ nil, opts \\ []), to: PhoenixKitBilling
  defdelegate mark_order_paid(order, opts \\ []), to: PhoenixKitBilling
  defdelegate mark_order_refunded(order), to: PhoenixKitBilling

  # Invoices
  defdelegate list_invoices(filters \\ %{}), to: PhoenixKitBilling
  defdelegate list_invoices_with_count(opts), to: PhoenixKitBilling
  defdelegate list_invoices_for_order(order_uuid), to: PhoenixKitBilling
  defdelegate list_user_invoices(user_uuid, filters \\ %{}), to: PhoenixKitBilling
  defdelegate get_invoice(id, opts \\ []), to: PhoenixKitBilling
  defdelegate get_invoice!(id), to: PhoenixKitBilling
  defdelegate get_invoice_by_number(invoice_number), to: PhoenixKitBilling
  defdelegate get_invoice_remaining_amount(invoice), to: PhoenixKitBilling
  defdelegate create_invoice(user_or_uuid, attrs), to: PhoenixKitBilling
  defdelegate create_invoice_from_order(order, opts \\ []), to: PhoenixKitBilling
  defdelegate update_invoice(invoice, attrs), to: PhoenixKitBilling
  defdelegate send_invoice(invoice, opts \\ []), to: PhoenixKitBilling
  defdelegate void_invoice(invoice, reason \\ nil, opts \\ []), to: PhoenixKitBilling
  defdelegate mark_invoice_paid(invoice), to: PhoenixKitBilling
  defdelegate update_invoice_paid_amount(invoice), to: PhoenixKitBilling
  defdelegate calculate_invoice_paid_amount(invoice_uuid), to: PhoenixKitBilling
  defdelegate mark_overdue_invoices(), to: PhoenixKitBilling
  defdelegate update_receipt_status(invoice), to: PhoenixKitBilling
  defdelegate calculate_receipt_status(invoice, transactions \\ nil), to: PhoenixKitBilling
  defdelegate generate_receipt(invoice), to: PhoenixKitBilling
  defdelegate send_receipt(invoice, opts \\ []), to: PhoenixKitBilling
  defdelegate send_credit_note(invoice, transaction, opts \\ []), to: PhoenixKitBilling
  defdelegate send_payment_confirmation(invoice, transaction, opts \\ []), to: PhoenixKitBilling
  defdelegate list_invoice_transactions(uuid), to: PhoenixKitBilling

  # Transactions
  defdelegate list_transactions(opts \\ []), to: PhoenixKitBilling
  defdelegate list_transactions_with_count(opts), to: PhoenixKitBilling
  defdelegate get_transaction(id, opts \\ []), to: PhoenixKitBilling
  defdelegate get_transaction!(id, opts \\ []), to: PhoenixKitBilling
  defdelegate get_transaction_by_number(number), to: PhoenixKitBilling
  defdelegate generate_transaction_number(), to: PhoenixKitBilling
  defdelegate record_payment(invoice, attrs, admin_user), to: PhoenixKitBilling
  defdelegate record_refund(invoice, attrs, admin_user), to: PhoenixKitBilling

  # Subscriptions
  defdelegate list_subscriptions(opts \\ []), to: PhoenixKitBilling
  defdelegate list_user_subscriptions(user_uuid, opts \\ []), to: PhoenixKitBilling
  defdelegate get_subscription(id, opts \\ []), to: PhoenixKitBilling
  defdelegate get_subscription!(id), to: PhoenixKitBilling
  defdelegate create_subscription(user_uuid, attrs), to: PhoenixKitBilling
  defdelegate update_subscription(subscription, attrs), to: PhoenixKitBilling
  defdelegate cancel_subscription(subscription, opts \\ []), to: PhoenixKitBilling
  defdelegate pause_subscription(subscription), to: PhoenixKitBilling
  defdelegate resume_subscription(subscription), to: PhoenixKitBilling

  defdelegate change_subscription_type(subscription, new_type_uuid, opts \\ []),
    to: PhoenixKitBilling

  # Subscription Types
  defdelegate list_subscription_types(opts \\ []), to: PhoenixKitBilling
  defdelegate get_subscription_type(id), to: PhoenixKitBilling
  defdelegate get_subscription_type_by_slug(slug), to: PhoenixKitBilling
  defdelegate create_subscription_type(attrs), to: PhoenixKitBilling
  defdelegate update_subscription_type(type, attrs), to: PhoenixKitBilling
  defdelegate delete_subscription_type(type), to: PhoenixKitBilling

  # Payment Methods
  defdelegate list_payment_methods(user_uuid, opts \\ []), to: PhoenixKitBilling
  defdelegate get_payment_method(id), to: PhoenixKitBilling
  defdelegate get_default_payment_method(user_uuid), to: PhoenixKitBilling
  defdelegate create_payment_method(attrs), to: PhoenixKitBilling
  defdelegate set_default_payment_method(payment_method), to: PhoenixKitBilling
  defdelegate remove_payment_method(payment_method), to: PhoenixKitBilling
  defdelegate available_payment_methods(), to: PhoenixKitBilling

  # Payment Options
  defdelegate list_payment_options(), to: PhoenixKitBilling
  defdelegate list_active_payment_options(), to: PhoenixKitBilling
  defdelegate get_payment_option(uuid), to: PhoenixKitBilling
  defdelegate get_payment_option_by_code(code), to: PhoenixKitBilling
  defdelegate change_payment_option(payment_option, attrs \\ %{}), to: PhoenixKitBilling
  defdelegate create_payment_option(attrs), to: PhoenixKitBilling
  defdelegate update_payment_option(payment_option, attrs), to: PhoenixKitBilling
  defdelegate delete_payment_option(payment_option), to: PhoenixKitBilling
  defdelegate toggle_payment_option_active(payment_option), to: PhoenixKitBilling
  defdelegate payment_option_requires_billing?(payment_option), to: PhoenixKitBilling

  # Checkout
  defdelegate create_checkout_session(invoice, provider, opts \\ []), to: PhoenixKitBilling
  defdelegate create_setup_session(user_uuid, provider, opts \\ []), to: PhoenixKitBilling

  # Utilities
  defdelegate format_company_address(company_info), to: PhoenixKitBilling
  defdelegate module_stats(), to: PhoenixKitBilling
end
