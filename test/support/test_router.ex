defmodule PhoenixKitBilling.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by the billing module's admin tabs so `live/2` calls in tests
  work with exactly the same URLs the LiveViews push themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the
  phoenix_kit_settings table is unavailable, and admin paths always get
  the default locale ("en") prefix — so our base becomes
  `/en/admin/billing` for the billing tabs (and `/en/admin/settings/billing`
  for the module's settings tabs).
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitBilling.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  scope "/en/admin/billing", PhoenixKitBilling.Web do
    pipe_through(:browser)

    live_session :billing_test,
      layout: {PhoenixKitBilling.Test.Layouts, :app},
      on_mount: {PhoenixKitBilling.Test.Hooks, :assign_scope} do
      # Dashboard / index
      live("/", Index, :index, as: :billing_index)

      # Orders
      live("/orders", Orders, :index, as: :billing_orders)
      live("/orders/new", OrderForm, :new, as: :billing_order_new)
      live("/orders/:id", OrderDetail, :show, as: :billing_order_detail)
      live("/orders/:id/edit", OrderForm, :edit, as: :billing_order_edit)

      # Invoices
      live("/invoices", Invoices, :index, as: :billing_invoices)
      live("/invoices/:id", InvoiceDetail, :show, as: :billing_invoice_detail)
      live("/invoices/:id/print", InvoicePrint, :print, as: :billing_invoice_print)
      live("/invoices/:id/receipt", ReceiptPrint, :print, as: :billing_receipt_print)

      live(
        "/invoices/:invoice_uuid/credit-note/:transaction_uuid",
        CreditNotePrint,
        :print,
        as: :billing_credit_note_print
      )

      live(
        "/invoices/:invoice_uuid/payment-confirmation/:transaction_uuid",
        PaymentConfirmationPrint,
        :print,
        as: :billing_payment_confirmation_print
      )

      # Transactions
      live("/transactions", Transactions, :index, as: :billing_transactions)

      # Subscriptions
      live("/subscriptions", Subscriptions, :index, as: :billing_subscriptions)
      live("/subscriptions/new", SubscriptionForm, :new, as: :billing_subscription_new)
      live("/subscriptions/:id", SubscriptionDetail, :show, as: :billing_subscription_detail)
      live("/subscriptions/:id/edit", SubscriptionForm, :edit, as: :billing_subscription_edit)

      # Subscription Types
      live("/subscription-types", SubscriptionTypes, :index, as: :billing_subscription_types)

      live("/subscription-types/new", SubscriptionTypeForm, :new,
        as: :billing_subscription_type_new
      )

      live("/subscription-types/:id/edit", SubscriptionTypeForm, :edit,
        as: :billing_subscription_type_edit
      )

      # Billing Profiles
      live("/profiles", BillingProfiles, :index, as: :billing_profiles)
      live("/profiles/new", BillingProfileForm, :new, as: :billing_profile_new)
      live("/profiles/:id/edit", BillingProfileForm, :edit, as: :billing_profile_edit)

      # Currencies
      live("/currencies", Currencies, :index, as: :billing_currencies)
    end
  end

  # The lists patch to `Routes.path/1`, which has no locale segment for the
  # primary language, so the pages they patch between answer there too.
  scope "/admin/billing", PhoenixKitBilling.Web do
    pipe_through(:browser)

    live_session :billing_test_unprefixed,
      layout: {PhoenixKitBilling.Test.Layouts, :app},
      on_mount: {PhoenixKitBilling.Test.Hooks, :assign_scope} do
      live("/orders", Orders, :index, as: :billing_orders_unprefixed)
      live("/invoices", Invoices, :index, as: :billing_invoices_unprefixed)
    end
  end

  # Customer dashboard tabs live under `/dashboard` in production.
  scope "/en/dashboard", PhoenixKitBilling.Web do
    pipe_through(:browser)

    live_session :billing_dashboard_test,
      layout: {PhoenixKitBilling.Test.Layouts, :app},
      on_mount: {PhoenixKitBilling.Test.Hooks, :assign_scope} do
      live("/billing-orders", UserOrders, :index, as: :billing_user_orders)
      # Same paths and params as core's `PhoenixKitWeb.Integration` routes.
      live("/billing-profiles/new", UserBillingProfileForm, :new, as: :billing_user_profile_new)

      live("/billing-profiles/:uuid/edit", UserBillingProfileForm, :edit,
        as: :billing_user_profile_edit
      )

      # A host routing the page itself with `:id`.
      live("/legacy-billing-profiles/:id/edit", UserBillingProfileForm, :edit,
        as: :billing_user_profile_legacy_edit
      )
    end
  end

  # Settings tabs live under `/admin/settings/billing` in production.
  scope "/en/admin/settings/billing", PhoenixKitBilling.Web do
    pipe_through(:browser)

    live_session :billing_settings_test,
      layout: {PhoenixKitBilling.Test.Layouts, :app},
      on_mount: {PhoenixKitBilling.Test.Hooks, :assign_scope} do
      live("/", Settings, :index, as: :billing_settings)
      live("/providers", ProviderSettings, :index, as: :billing_provider_settings)
    end
  end
end
