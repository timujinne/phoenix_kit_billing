defmodule PhoenixKitBilling do
  @moduledoc """
  Main context for PhoenixKit Billing system.

  Provides comprehensive billing functionality including currencies, billing profiles,
  orders, and invoices with manual bank transfer payments (Phase 1).

  ## Features

  - **Currencies**: Multi-currency support with exchange rates
  - **Billing Profiles**: User billing information (individuals & companies)
  - **Orders**: Order management with line items and status tracking
  - **Invoices**: Invoice generation with receipt functionality
  - **Bank Payments**: Manual bank transfer workflow

  ## System Enable/Disable

      # Check if billing is enabled
      PhoenixKitBilling.enabled?()

      # Enable/disable billing system
      PhoenixKitBilling.enable_system()
      PhoenixKitBilling.disable_system()

  ## Order Workflow

      # Create order
      {:ok, order} = Billing.create_order(user, %{...})

      # Confirm order
      {:ok, order} = Billing.confirm_order(order)

      # Generate invoice
      {:ok, invoice} = Billing.create_invoice_from_order(order)

      # Send invoice
      {:ok, invoice, _email_result} = Billing.send_invoice(invoice)

      # Mark as paid (generates receipt)
      {:ok, invoice} = Billing.mark_invoice_paid(invoice)
  """

  use PhoenixKit.Module
  use Gettext, backend: PhoenixKitBilling.Gettext

  import Ecto.Query, warn: false

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Utils.CountryData
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Number
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitBilling.BillingProfile
  alias PhoenixKitBilling.Currency
  alias PhoenixKitBilling.DocumentBranding
  alias PhoenixKitBilling.EmailDefaults
  alias PhoenixKitBilling.Events
  alias PhoenixKitBilling.Invoice
  alias PhoenixKitBilling.InvoiceEvents
  alias PhoenixKitBilling.NumberSequence
  alias PhoenixKitBilling.Order
  alias PhoenixKitBilling.PaymentOption
  alias PhoenixKitBilling.Providers
  alias PhoenixKitBilling.Transaction
  alias PhoenixKitWeb.Live.Settings.Organization

  require Logger

  # How many numbers a create tries before it gives up on a run of taken ones.
  @number_attempts 20

  # Appended to the docs of the functions that take a document number.
  @numbering_note """
  The number comes from a per-year counter row that stays locked until the
  transaction that inserts the row commits. Called inside your own
  `Repo.transaction`, that is until yours commits, so keep it short: concurrent
  creates of the same kind wait for it. It needs the default READ COMMITTED
  isolation - under REPEATABLE READ or SERIALIZABLE a concurrent create raises
  a serialization failure (`40001`).
  """

  # For the creates and updates of an order or an invoice.
  @create_note """
  #{@numbering_note}
  A changeset that fails validation comes back as `{:error, changeset}` and
  leaves your transaction usable. So does a generated number that a row made
  outside the counter already has (an older node, a number typed by hand): the
  next one is tried (first lifting the counter to the highest number there is),
  up to #{@number_attempts} times; if all of those are taken it comes back as
  `{:error, changeset}` with an error on the number field, leaves your
  transaction usable and keeps the counter's progress. A number you supply that
  is taken, or any other failure in the database, comes back as
  `{:error, changeset}` too but aborts your transaction.
  """

  # For the functions that record money.
  @payment_note """
  #{@numbering_note}
  Any error aborts your transaction, as these write several rows together,
  except running out of attempts on taken transaction numbers: that returns
  `{:error, changeset}`, leaves your transaction usable and keeps the counter's
  progress.
  """

  # §13: namespace for the currency-table cache — see `children/0`,
  # `get_base_currency/0`, `get_currency_by_code/1`,
  # `invalidate_currency_cache/0`.
  @currency_cache_name :billing_currencies

  # ============================================
  # SYSTEM ENABLE/DISABLE
  # ============================================

  @impl PhoenixKit.Module
  @doc """
  Checks if the billing system is enabled.
  """
  def enabled? do
    Settings.get_boolean_setting("billing_enabled", false)
  rescue
    _ -> false
  end

  @impl PhoenixKit.Module
  def required_modules, do: ["emails"]

  @impl PhoenixKit.Module
  @doc """
  Enables the billing system.
  """
  def enable_system do
    result = Settings.update_boolean_setting_with_module("billing_enabled", true, "billing")
    refresh_dashboard_tabs()
    result
  end

  @impl PhoenixKit.Module
  @doc """
  Disables the billing system.
  """
  def disable_system do
    result = Settings.update_boolean_setting_with_module("billing_enabled", false, "billing")
    refresh_dashboard_tabs()
    result
  end

  defp refresh_dashboard_tabs do
    if Code.ensure_loaded?(PhoenixKit.Dashboard.Registry) and
         PhoenixKit.Dashboard.Registry.initialized?() do
      PhoenixKit.Dashboard.Registry.load_defaults()
    end
  end

  # ============================================
  # MODULE BEHAVIOUR CALLBACKS
  # ============================================

  @impl PhoenixKit.Module
  def module_key, do: "billing"

  # Project-extension catalog entry for the `phoenix_kit_projects` hub —
  # duck-typed contract (no dependency on that package, no `@impl`).
  # HONESTLY LABELED "Customer billing" (the design consult's hard
  # requirement): the tab shows the linked CUSTOMER's money, not a
  # per-project P&L. `rate_cents_per_hour` lives in this config so the
  # projects-side ledger→invoice bridge and the tab share one money
  # settings home.
  def phoenix_kit_project_extensions do
    [
      %{
        key: "billing_customer",
        name: "Customer billing",
        description: "Link a billing profile — the customer's invoices and orders in context",
        icon: "hero-banknotes",
        module_key: "billing",
        default_enabled: false,
        tabs: [
          %{
            key: "billing",
            label: "Billing",
            icon: "hero-banknotes",
            lv: PhoenixKitBilling.Web.ProjectBillingLive
          }
        ],
        config_schema: [
          %{key: "billing_profile_uuid", type: :string, label: "Billing profile UUID"},
          %{key: "rate_cents_per_hour", type: :number, label: "Rate (cents per hour)"}
        ],
        permission_actions: [:view]
      }
    ]
  end

  @impl PhoenixKit.Module
  def module_name, do: "Billing"

  @impl PhoenixKit.Module
  def version do
    Application.spec(:phoenix_kit_billing, :vsn) |> to_string()
  end

  @impl PhoenixKit.Module
  def route_module, do: PhoenixKitBilling.Web.Routes

  # §13: `Currency.present/3` makes up to three currency-table queries per
  # call, and a catalog page renders dozens of prices — this cache is what
  # turns that back into O(1) queries after the first miss per key. Picked
  # up automatically by `PhoenixKit.Supervisor` via
  # `PhoenixKit.ModuleRegistry.static_children/0` — no host wiring needed,
  # and it starts after `PhoenixKit.Cache.Registry` (a fixed, earlier
  # child of that same supervisor). See `get_base_currency/0` and
  # `get_currency_by_code/1` for what reads it, and `invalidate_currency_cache/0`
  # for what clears it.
  @impl PhoenixKit.Module
  def children do
    [
      Supervisor.child_spec(
        {PhoenixKit.Cache, name: @currency_cache_name, ttl: :timer.minutes(5)},
        id: :billing_currencies_cache
      )
    ]
  end

  # `phoenix_kit_payment_provider_configs` is core-created (V135); this
  # chain's V1 only ADOPTS it (stamps the `pkb_schema:` marker, changes
  # no shape) and owns its future evolution — see the moduledoc in
  # PhoenixKitBilling.Migrations. No application code reads or writes the
  # table yet; provider credentials still live in `phoenix_kit_settings`.
  @impl PhoenixKit.Module
  def migration_module, do: PhoenixKitBilling.Migrations

  # Without this the host's `:phoenix_kit_css_sources` compiler emits no
  # `@source` line for this package, so Tailwind never scans the billing
  # templates and purges every class they use out of the host's build.
  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_billing]

  # The four financial emails, with sample variables, for core's email
  # preview (`/admin/settings/email-sending/preview`).
  @impl PhoenixKit.Module
  def email_templates, do: EmailDefaults.catalog_entries()

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "billing",
      label: gettext("Billing"),
      icon: "hero-banknotes",
      description: gettext("Orders, invoices, billing profiles and multi-currency support"),
      # Base "billing" is admin-area READ access. Each sub-permission is a
      # capability this module checks itself (core enforces sub-implies-base).
      #
      # The split follows what an operator would actually delegate: someone
      # who chases invoices is not someone who rotates a payment provider's
      # API keys, and neither is necessarily allowed to refund an order.
      #
      # ⚠️ Upgrade: core auto-grants new sub-permissions to the Admin system
      # role only, so a CUSTOM role holding base "billing" keeps its reads
      # but loses mutations until an operator re-grants. Secure by default,
      # but a breaking authorization change - see AGENTS.md.
      sub_permissions: [
        %{
          key: "manage_orders",
          label: gettext("Manage orders"),
          description: gettext("Create, edit and cancel orders and their transactions")
        },
        %{
          key: "manage_invoices",
          label: gettext("Manage invoices"),
          description: gettext("Issue, edit and void invoices and credit notes")
        },
        %{
          key: "manage_subscriptions",
          label: gettext("Manage subscriptions"),
          description: gettext("Subscriptions and subscription types")
        },
        %{
          key: "manage_settings",
          label: gettext("Manage billing settings"),
          description:
            gettext("Payment providers and their credentials, currencies and tax settings")
        }
      ]
    }
  end

  @doc """
  Returns stats for the module card on the admin Modules page.

  Runs `get_config/0`, which issues three `count` queries (orders,
  invoices, currencies). This is invoked once per render of the admin
  Modules card, so the cost is bounded; it is not cached.
  """
  def module_stats do
    config = get_config()

    [
      %{label: gettext("Orders"), value: config[:orders_count] || 0},
      %{label: gettext("Invoices"), value: config[:invoices_count] || 0},
      %{label: gettext("Currencies"), value: config[:currencies_count] || 0}
    ]
  end

  @doc """
  Notification types this module contributes, collected by core's
  `Notifications.Types` via `function_exported?/3`.

  Admin and customer audiences are separate sub-types on purpose: an
  operator muting the invoice firehose must not also silence their own
  receipts, and a customer's invoice notice must not be governed by an
  admin-facing preference.

  ⚠️ These are the NOTIFY actions. Audit rows use DIFFERENT action strings
  (`billing.invoice_issued_audit` and friends): `Activity.log/1`
  auto-derives notifications from registered actions, so an audit row
  written with a notify action delivers a duplicate on top of the explicit
  fan-out.
  """
  @impl PhoenixKit.Module
  def notification_types do
    [
      %{
        key: "billing",
        label: "Billing",
        description: "Invoices, payments and subscriptions",
        actions: [],
        default: true,
        sub_types: [
          %{
            key: "invoices",
            label: "Invoices and payments",
            description: "An invoice was issued, paid, or a payment failed",
            actions: [
              "billing.invoice_issued",
              "billing.payment_received",
              "billing.payment_failed"
            ],
            default: true
          },
          %{
            key: "your_billing",
            label: "Your invoices and payments",
            description: "Confirmation of invoices and payments on your own account",
            actions: ["billing.your_invoice_issued", "billing.your_payment_received"],
            default: true
          }
        ]
      }
    ]
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      billing_tab!(
        id: :admin_billing,
        label: "Billing",
        icon: "hero-banknotes",
        path: "billing",
        priority: 520,
        level: :admin,
        permission: "billing",
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        live_view: {PhoenixKitBilling.Web.Index, :index}
      ),
      billing_tab!(
        id: :admin_billing_dashboard,
        label: "Dashboard",
        icon: "hero-chart-bar-square",
        path: "billing",
        priority: 521,
        level: :admin,
        permission: "billing",
        parent: :admin_billing,
        match: :exact,
        live_view: {PhoenixKitBilling.Web.Index, :index}
      ),
      billing_tab!(
        id: :admin_billing_orders,
        label: "Orders",
        icon: "hero-shopping-bag",
        path: "billing/orders",
        priority: 522,
        level: :admin,
        permission: "billing.manage_orders",
        parent: :admin_billing,
        live_view: {PhoenixKitBilling.Web.Orders, :index}
      ),
      billing_tab!(
        id: :admin_billing_invoices,
        label: "Invoices",
        icon: "hero-document-text",
        path: "billing/invoices",
        priority: 523,
        level: :admin,
        permission: "billing.manage_invoices",
        parent: :admin_billing,
        live_view: {PhoenixKitBilling.Web.Invoices, :index}
      ),
      billing_tab!(
        id: :admin_billing_transactions,
        label: "Transactions",
        icon: "hero-arrows-right-left",
        path: "billing/transactions",
        priority: 524,
        level: :admin,
        permission: "billing.manage_orders",
        parent: :admin_billing,
        live_view: {PhoenixKitBilling.Web.Transactions, :index}
      ),
      billing_tab!(
        id: :admin_billing_subscriptions,
        label: "Subscriptions",
        icon: "hero-arrow-path",
        path: "billing/subscriptions",
        priority: 525,
        level: :admin,
        permission: "billing.manage_subscriptions",
        parent: :admin_billing,
        live_view: {PhoenixKitBilling.Web.Subscriptions, :index}
      ),
      billing_tab!(
        id: :admin_billing_subscription_types,
        label: "Subscription Types",
        icon: "hero-rectangle-stack",
        path: "billing/subscription-types",
        priority: 526,
        level: :admin,
        permission: "billing.manage_subscriptions",
        parent: :admin_billing,
        live_view: {PhoenixKitBilling.Web.SubscriptionTypes, :index}
      ),
      billing_tab!(
        id: :admin_billing_profiles,
        label: "Billing Profiles",
        icon: "hero-identification",
        path: "billing/profiles",
        priority: 527,
        level: :admin,
        permission: "billing.manage_orders",
        parent: :admin_billing,
        live_view: {PhoenixKitBilling.Web.BillingProfiles, :index}
      ),
      billing_tab!(
        id: :admin_billing_currencies,
        label: "Currencies",
        icon: "hero-currency-dollar",
        path: "billing/currencies",
        priority: 528,
        level: :admin,
        permission: "billing.manage_settings",
        parent: :admin_billing,
        live_view: {PhoenixKitBilling.Web.Currencies, :index}
      ),
      billing_tab!(
        id: :admin_billing_providers,
        label: "Payment Providers",
        icon: "hero-credit-card",
        path: "settings/billing/providers",
        priority: 529,
        level: :admin,
        permission: "billing.manage_settings",
        parent: :admin_billing,
        live_view: {PhoenixKitBilling.Web.ProviderSettings, :index}
      )
    ]
  end

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      billing_tab!(
        id: :admin_settings_billing,
        label: "Billing",
        icon: "hero-banknotes",
        path: "billing",
        priority: 926,
        level: :admin,
        parent: :admin_settings,
        permission: "billing.manage_settings",
        match: :exact,
        live_view: {PhoenixKitBilling.Web.Settings, :index}
      )
    ]
  end

  @impl PhoenixKit.Module
  def user_dashboard_tabs do
    [
      billing_tab!(
        id: :dashboard_orders,
        label: "My Orders",
        icon: "hero-shopping-bag",
        path: "billing-orders",
        priority: 200,
        match: :prefix,
        group: :main,
        live_view: {PhoenixKitBilling.Web.UserOrders, :index},
        user_menu: &__MODULE__.user_menu_with_shop?/1
      ),
      billing_tab!(
        id: :dashboard_billing_profiles,
        label: "Billing Profiles",
        icon: "hero-identification",
        path: "billing-profiles",
        priority: 850,
        match: :prefix,
        group: :account,
        user_menu: &__MODULE__.user_menu_with_shop?/1
      )
    ]
  end

  @doc """
  Whether billing's user tabs ("My Orders", "Billing Profiles") are offered in
  the avatar dropdown (the `Tab` option `:user_menu`): only while the shop
  module is installed and enabled. Without a storefront a visitor has no
  orders of their own to look at, so the entries would be noise in every
  signed-in user's menu. The shop is found by its module key, duck-typed —
  billing does not depend on `phoenix_kit_ecommerce`.

  A core without the `:user_menu` option ignores the key, so this costs no
  core floor.
  """
  @spec user_menu_with_shop?(term()) :: boolean()
  def user_menu_with_shop?(_scope) do
    Permissions.feature_enabled?("shop")
  rescue
    _ -> false
  end

  # Builds a `Tab` with this module's gettext backend/domain defaults
  # merged in, so every tab's label resolves through the billing
  # catalogue without repeating the wiring at each call site. Explicit
  # values in `attrs` win over the defaults.
  defp billing_tab!(attrs) do
    [gettext_backend: PhoenixKitBilling.Gettext, gettext_domain: "default"]
    |> Keyword.merge(attrs)
    |> Tab.new!()
  end

  @impl PhoenixKit.Module
  @doc """
  Returns the current billing configuration.
  """
  def get_config do
    %{
      enabled: enabled?(),
      # §3.3: base = is_default row (billing_default_currency is no longer read)
      default_currency: base_currency_code(),
      tax_enabled: tax_enabled?(),
      default_tax_rate: Settings.get_setting_cached("billing_default_tax_rate", "0"),
      invoice_prefix: Settings.get_setting_cached("billing_invoice_prefix", "INV"),
      order_prefix: Settings.get_setting_cached("billing_order_prefix", "ORD"),
      receipt_prefix: Settings.get_setting_cached("billing_receipt_prefix", "RCP"),
      invoice_due_days:
        String.to_integer(Settings.get_setting_cached("billing_invoice_due_days", "14")),
      orders_count: count_orders(),
      invoices_count: count_invoices(),
      currencies_count: count_currencies()
    }
  end

  @doc """
  Returns whether tax is enabled in billing settings.
  """
  def tax_enabled? do
    Settings.get_setting_cached("billing_tax_enabled", "false") == "true"
  end

  @doc """
  Returns the default tax rate as a Decimal (e.g., Decimal.new("0.20") for 20%).

  Uses the billing settings value. When company country is configured,
  the suggested rate from BeamLabCountries can be applied via billing settings UI.
  """
  def get_tax_rate do
    if tax_enabled?() do
      rate = Settings.get_setting_cached("billing_default_tax_rate", "0")

      case Decimal.parse(rate) do
        {decimal, _} ->
          Decimal.div(decimal, Decimal.new("100"))

        :error ->
          Logger.warning(
            "[Billing] Invalid billing_default_tax_rate #{inspect(rate)}; falling back to 0"
          )

          Decimal.new("0")
      end
    else
      Decimal.new("0")
    end
  end

  @doc """
  Returns the default tax rate as integer percentage (e.g., 20 for 20%).
  """
  def get_tax_rate_percent do
    if tax_enabled?() do
      rate = Settings.get_setting_cached("billing_default_tax_rate", "0")

      case Integer.parse(rate) do
        {value, _} ->
          value

        :error ->
          Logger.warning(
            "[Billing] Invalid billing_default_tax_rate #{inspect(rate)}; falling back to 0"
          )

          0
      end
    else
      0
    end
  end

  @doc """
  Returns dashboard statistics.
  """
  def get_dashboard_stats do
    today = Date.utc_today()
    start_of_month = Date.beginning_of_month(today)
    # §3.3: base = is_default row (billing_default_currency is no longer read)
    default_currency = dashboard_default_currency_code()

    %{
      total_orders: count_orders(),
      orders_this_month: count_orders_since(start_of_month),
      total_invoices: count_invoices(),
      invoices_this_month: count_invoices_since(start_of_month),
      total_paid_revenue: calculate_paid_revenue(),
      pending_revenue: calculate_pending_revenue(),
      paid_invoices_count: count_invoices_by_status("paid"),
      pending_invoices_count:
        count_invoices_by_status("sent") + count_invoices_by_status("overdue"),
      default_currency: default_currency
    }
  end

  # A failed dashboard-stat query used to rescue straight to a fallback
  # value with no log line - a real query error (bad connection, a
  # migration mid-flight, a locked table) rendered as "$0 pending
  # revenue" / "0 orders", indistinguishable from an actually-empty,
  # healthy system. The fallback value is still the right thing to show
  # (a stat tile crashing the whole admin dashboard over a transient
  # query error would be worse), but it needs to be a KNOWN degraded
  # value, not a silent one.
  defp dashboard_stat_fallback(label, fallback, error) do
    Logger.warning("[Billing] dashboard stat #{label} failed: #{Exception.message(error)}")
    fallback
  end

  # Same rescue-and-log treatment as the eight count/aggregate helpers
  # below: `get_base_currency/0` is a real query same as the rest, so a
  # transient failure here must not crash the whole dashboard render —
  # but it must not go silent either.
  defp dashboard_default_currency_code do
    base_currency_code()
  rescue
    e -> dashboard_stat_fallback("default_currency", nil, e)
  end

  # §3.3: base = is_default row. Shared by every non-stat reader that
  # used to fall back to the `billing_default_currency` setting (now
  # retired from code, though the setting row itself is not deleted —
  # that is a separate core-chain change). No literal fallback: `nil`
  # here means "no default currency configured at all", which a
  # changeset should reject loudly rather than paper over with a
  # made-up code.
  defp base_currency_code do
    case get_base_currency() do
      %{code: code} -> code
      nil -> nil
    end
  end

  defp count_orders do
    Order |> not_trashed() |> repo().aggregate(:count)
  rescue
    e -> dashboard_stat_fallback("count_orders", 0, e)
  end

  defp count_invoices do
    Invoice |> not_trashed() |> repo().aggregate(:count)
  rescue
    e -> dashboard_stat_fallback("count_invoices", 0, e)
  end

  defp count_currencies do
    Currency |> where([c], c.enabled == true) |> repo().aggregate(:count)
  rescue
    e -> dashboard_stat_fallback("count_currencies", 0, e)
  end

  defp count_orders_since(date) do
    Order
    |> not_trashed()
    |> where([o], o.inserted_at >= ^NaiveDateTime.new!(date, ~T[00:00:00]))
    |> repo().aggregate(:count)
  rescue
    e -> dashboard_stat_fallback("count_orders_since", 0, e)
  end

  defp count_invoices_since(date) do
    Invoice
    |> not_trashed()
    |> where([i], i.inserted_at >= ^NaiveDateTime.new!(date, ~T[00:00:00]))
    |> repo().aggregate(:count)
  rescue
    e -> dashboard_stat_fallback("count_invoices_since", 0, e)
  end

  defp count_invoices_by_status(status) do
    Invoice
    |> not_trashed()
    |> where([i], i.status == ^status)
    |> repo().aggregate(:count)
  rescue
    e -> dashboard_stat_fallback("count_invoices_by_status(#{status})", 0, e)
  end

  defp calculate_paid_revenue do
    result =
      Invoice
      |> not_trashed()
      |> where([i], i.status == "paid")
      |> select([i], sum(i.total))
      |> repo().one()

    result || Decimal.new(0)
  rescue
    e -> dashboard_stat_fallback("calculate_paid_revenue", Decimal.new(0), e)
  end

  defp calculate_pending_revenue do
    result =
      Invoice
      |> not_trashed()
      |> where([i], i.status in ["sent", "overdue"])
      |> select([i], sum(i.total))
      |> repo().one()

    result || Decimal.new(0)
  rescue
    e -> dashboard_stat_fallback("calculate_pending_revenue", Decimal.new(0), e)
  end

  # ============================================
  # CURRENCIES
  # ============================================

  @doc """
  Lists all currencies with optional filters.

  ## Options
  - `:enabled` - Filter by enabled status
  - `:order_by` - Custom ordering
  """
  def list_currencies(opts \\ []) do
    query = Currency

    query =
      case Keyword.get(opts, :enabled) do
        true -> where(query, [c], c.enabled == true)
        false -> where(query, [c], c.enabled == false)
        _ -> query
      end

    query =
      case Keyword.get(opts, :order_by) do
        nil -> order_by(query, [c], [c.sort_order, c.code])
        custom -> order_by(query, ^custom)
      end

    repo().all(query)
  end

  @doc """
  Lists enabled currencies.
  """
  def list_enabled_currencies do
    list_currencies(enabled: true)
  end

  @doc """
  The staleness threshold (in days) past which `Currency.stale?/2` and
  `currencies_with_stale_rates/0` consider a rate stale (§6.2).

  Backed by the `"fx_rate_max_age_days"` setting; garbage or a value
  `<= 0` reads as the default 30 — a threshold that would make every
  rate instantly stale is worse than not having one at all.

  Reads through `Settings.get_setting_cached/2` — its OWN cache, not
  `:billing_currencies` (deliberately NOT reusing `with_currency_cache/2`
  here, despite the hot-path pressure documented on
  `Currency.present/3`'s live path: that cache is invalidated by CURRENCY
  writes, and an admin editing this setting has no reason to touch a
  currency row, so a threshold cached under that key could sit stale
  indefinitely. `Currency.present/3`'s own `maybe_warn_stale/1` is what
  keeps this cheap on the hot path instead — it memoizes the staleness
  VERDICT per process per currency code, so this function is only
  actually called once per code per process, not once per `present/3`
  call).
  """
  @spec fx_rate_max_age_days() :: pos_integer()
  def fx_rate_max_age_days do
    "fx_rate_max_age_days"
    |> Settings.get_setting_cached("30")
    |> Integer.parse()
    |> case do
      {days, _rest} when days > 0 -> days
      _ -> 30
    end
  end

  @doc """
  Currencies whose `exchange_rate` has not been touched within
  `fx_rate_max_age_days/0` (§6.2) — feeds the admin staleness banner.
  A stale rate keeps converting; this is only ever used to warn.
  """
  @spec currencies_with_stale_rates() :: [Currency.t()]
  def currencies_with_stale_rates do
    max_age_days = fx_rate_max_age_days()
    list_currencies() |> Enum.filter(&Currency.stale?(&1, max_age_days))
  end

  @doc """
  Gets the default currency.
  """
  def get_default_currency do
    Currency
    |> where([c], c.is_default == true)
    |> repo().one()
  end

  @doc """
  The shop's base currency — the `is_default` row.

  Authoring and admin paths (a product's stored price, an order's own
  `currency` before display, anywhere the number being handled is the
  base amount rather than something being shown to a shopper) call this
  directly. Unlike `get_display_currency/0`, it never depends on the
  request: the base currency is a property of the shop, not of who is
  looking at it right now (§4.2).

  Cached (§13): `Currency.present/3` calls this — through
  `resolve_display_currency/1` — on every single price it converts, and
  a catalog page converts dozens of prices per render. `get_default_currency/0`
  itself stays a direct, uncached query (unchanged, on purpose — some
  callers legitimately want the guarantee of a fresh read); this function
  reuses it as the query underneath its own cache rather than duplicating
  the `Ecto` query. See `invalidate_currency_cache/0` for what clears the
  cache and when.
  """
  @spec get_base_currency() :: Currency.t() | nil
  def get_base_currency do
    with_currency_cache(:base, fn -> get_default_currency() end)
  end

  @doc """
  The currency to SHOW and CHARGE for the current request.

  Resolves the request-scoped code set by the host app (a Plug/`on_mount`
  hook calling `PhoenixKitBilling.Currency.put_request_currency/1` — see
  its docs) through `resolve_display_currency/1`, falling back to the
  base currency per §6.3. Call this wherever a price is about to be
  shown to (or charged from) the current shopper; call `get_base_currency/0`
  instead for anything that reads or writes the stored, base-currency
  amount.
  """
  @spec get_display_currency() :: Currency.t() | nil
  def get_display_currency, do: resolve_display_currency(Currency.get_request_currency())

  @doc """
  Resolves a display-currency CODE to a `%Currency{}`, fail-safe per §6.3.

  `nil` (no request override) or the base currency's own code resolve to
  the base, silently — that is the expected, unremarkable case, not a
  failure worth a log line. Any other code resolves to itself only if it
  is a currency this shop actually knows about, has enabled, and carries
  a usable (positive) exchange rate; anything short of that — unknown
  code, disabled currency, missing or non-positive rate — falls back to
  the base currency rather than raising or showing a broken price, and
  logs exactly ONE warning per process per offending code (tracked via
  the process dictionary key `{:phoenix_kit_billing_fx_warned, code}`),
  so a page that calls this many times over one request does not flood
  the log for the same unresolvable code.
  """
  @spec resolve_display_currency(String.t() | nil) :: Currency.t() | nil
  def resolve_display_currency(nil), do: get_base_currency()

  def resolve_display_currency(code) when is_binary(code) do
    base = get_base_currency()

    cond do
      is_nil(base) ->
        nil

      base.code == code ->
        base

      true ->
        case get_currency_by_code(code) do
          %Currency{enabled: true, exchange_rate: %Decimal{} = rate} = currency ->
            if Decimal.compare(rate, 0) == :gt do
              currency
            else
              fallback_to_base(base, code, "non-positive exchange rate")
            end

          %Currency{enabled: false} ->
            fallback_to_base(base, code, "disabled")

          %Currency{} ->
            fallback_to_base(base, code, "no exchange rate")

          nil ->
            fallback_to_base(base, code, "unknown currency")
        end
    end
  end

  defp fallback_to_base(base, code, reason) do
    warned_key = {:phoenix_kit_billing_fx_warned, code}

    unless Process.get(warned_key) do
      Process.put(warned_key, true)

      Logger.warning(
        "[Billing] display currency #{code} unusable (#{reason}); falling back to base #{base.code}"
      )
    end

    base
  end

  @doc """
  Gets a currency by ID or UUID.
  """
  def get_currency(id) when is_binary(id) do
    if UUIDUtils.valid?(id) do
      repo().get_by(Currency, uuid: id)
    else
      nil
    end
  end

  def get_currency(_), do: nil

  @doc """
  Gets a currency by ID or UUID, raises if not found.
  """
  def get_currency!(id) do
    case get_currency(id) do
      nil -> raise Ecto.NoResultsError, queryable: Currency
      currency -> currency
    end
  end

  @doc """
  Gets a currency by code.

  Cached (§13) alongside `get_base_currency/0`, under the same
  `#{inspect(@currency_cache_name)}` namespace — `resolve_display_currency/1`
  calls this for every non-base code `Currency.present/3` resolves.
  """
  def get_currency_by_code(code) do
    upcased = String.upcase(code)

    with_currency_cache(upcased, fn ->
      Currency
      |> where([c], c.code == ^upcased)
      |> repo().one()
    end)
  end

  # §13 cache helper shared by `get_base_currency/0` and
  # `get_currency_by_code/1`. A dedicated sentinel (rather than `nil`)
  # distinguishes "not cached yet" from "cached, and the answer is nil" —
  # a currency table with no default row, or a code nothing matches, is a
  # real answer worth caching too, not just a cache miss to retry forever.
  defp with_currency_cache(key, query_fun) do
    cache_miss = :__cache_not_found__

    case PhoenixKit.Cache.get(@currency_cache_name, key, cache_miss) do
      ^cache_miss ->
        value = query_fun.()
        PhoenixKit.Cache.put(@currency_cache_name, key, value)
        value

      value ->
        value
    end
  end

  # §4.1, §13: clears the WHOLE currency cache namespace rather than one
  # key, because `set_default_currency/1` can change every row's
  # `exchange_rate` in one call (renormalization) — invalidating only the
  # promoted code would leave every OTHER currency's cached rate stale.
  # In-process only: this clears the cache on the node that made the
  # write. That is not as narrow as it sounds — the cache is one named
  # `PhoenixKit.Cache` GenServer (and one ETS table) per BEAM node, not
  # per process, so every process on that node (every request, every
  # LiveView, every `Task`) shares it and sees the clear immediately, no
  # TTL wait involved. What stays invisible until the `ttl` (5 minutes)
  # expires is a write this cache never gets told about at all: a SECOND
  # web node, or anything outside this application entirely (a `mix run`
  # script, a direct SQL `UPDATE`) — the same bound
  # `Settings.get_setting_cached/2`'s cache accepts, and the right
  # tradeoff for a single-node stand. A currency write followed
  # immediately by a read that must see it (this package's own test for
  # exactly that, "resolves on every call") has to go through
  # `update_currency/2` or one of the other three writers below, not a
  # raw `Repo.update_all`.
  # `PhoenixKit.Cache.clear/1` is a cast. The `stats/1` call that follows is
  # a barrier: the cache GenServer handles messages from this process in
  # order, so by the time `stats/1` returns the clear HAS been applied —
  # which is what lets `maybe_broadcast_currencies_changed/1` promise a
  # subscriber a fresh read (§4.2.1 item 5). Without it the broadcast could
  # overtake the clear and a subscriber's re-read would hit the stale entry.
  # `stats/1` already guards a missing/unavailable cache process on its own
  # (returns a default map instead of raising), so no extra guard is needed
  # here.
  defp invalidate_currency_cache do
    PhoenixKit.Cache.clear(@currency_cache_name)
    _ = PhoenixKit.Cache.stats(@currency_cache_name)
    :ok
  end

  # Only clears the cache when the write actually happened — an
  # `{:error, changeset}` (or any other non-`:ok` shape) changed nothing
  # in the table, so there is nothing stale to evict.
  defp maybe_invalidate_currency_cache({:ok, _} = result) do
    invalidate_currency_cache()
    result
  end

  defp maybe_invalidate_currency_cache(result), do: result

  # §4.2.1 item 5: announce AFTER the cache is cleared (the pipe order in the
  # four currency writers is load-bearing), so a subscriber that
  # re-resolves on receipt cannot read the stale entry.
  defp maybe_broadcast_currencies_changed({:ok, %Currency{} = currency} = result) do
    Events.broadcast_currencies_changed(currency)
    result
  end

  defp maybe_broadcast_currencies_changed(result), do: result

  @doc """
  Creates a currency.
  """
  def create_currency(attrs) do
    %Currency{}
    |> Currency.changeset(attrs)
    |> stamp_rate_change(:insert)
    |> repo().insert()
    |> maybe_invalidate_currency_cache()
    |> maybe_broadcast_currencies_changed()
  end

  @doc """
  Updates a currency.
  """
  def update_currency(%Currency{} = currency, attrs) do
    currency
    |> Currency.changeset(attrs)
    |> stamp_rate_change(:update)
    |> repo().update()
    |> maybe_invalidate_currency_cache()
    |> maybe_broadcast_currencies_changed()
  end

  # §6.2: `rate_updated_at` dates the RATE. On an UPDATE, stamp only when
  # the changeset really changes `exchange_rate` — otherwise the column
  # just repeats `updated_at` (which moves on a symbol or sort-order
  # edit) and stops answering the one question it exists for: when was
  # this rate last touched.
  #
  # On an INSERT, always stamp — a row's rate was set right now, by
  # definition, so there is no "did it change" question to ask.
  # `fetch_change/2` alone would get this wrong: `cast/3` only records a
  # change when the cast value differs from the STRUCT's current field
  # value, and a fresh `%Currency{}` already defaults `exchange_rate` to
  # exactly `"1.0"` — so a caller that explicitly passes `"1.0"` (the
  # bulk import always does; the add-currency form starts pre-filled at
  # it) produces a changeset with NO recorded change on `exchange_rate`
  # at all, and the row would go live with `rate_updated_at: nil` — the
  # worst possible reading for a staleness column.
  defp stamp_rate_change(%Ecto.Changeset{} = changeset, :insert) do
    Ecto.Changeset.put_change(changeset, :rate_updated_at, DateTime.utc_now(:second))
  end

  defp stamp_rate_change(%Ecto.Changeset{} = changeset, :update) do
    case Ecto.Changeset.fetch_change(changeset, :exchange_rate) do
      {:ok, _new_rate} ->
        Ecto.Changeset.put_change(changeset, :rate_updated_at, DateTime.utc_now(:second))

      :error ->
        changeset
    end
  end

  @doc """
  Sets a currency as default.

  Promoting a currency renormalizes every currency's `exchange_rate`
  against it as the new base FIRST, via a raw `update_all` that bypasses
  `Currency.changeset/2` entirely (no changeset touches this step at
  all) — only THEN is the promoted row itself updated through the
  changeset, in step 3 below, pinning its own rate to exactly `1.0`. That
  order is the invariant the currency design spec fixes in §3.2 ("the
  base currency's rate must be 1.0"). Renormalizing is a division by
  every rate's ratio to the new base, so no conversion result changes:
  only the displayed numbers become honest about which currency is the
  base.

  Refuses a `nil` or non-positive `exchange_rate` on `currency` with
  `{:error, :invalid_base_rate}` instead of dividing every other rate by
  zero.

  NOTE: `Currency.changeset/2` deliberately does NOT validate "the
  default currency's rate is 1.0". `set_default_currency/1` promotes
  through that same changeset (`update!/1` inside the transaction below),
  so a changeset-level check would also block promoting a currency whose
  own stored rate happens to be wrong — exactly the operation a host
  needs to fix that. The invariant is enforced here, procedurally,
  instead: renormalize, then promote at `1.0`.

  The struct the caller passes may be STALE by the time step 3 runs —
  most importantly when the caller is re-promoting the currency that is
  ALREADY the default (fixing its rate without switching currencies,
  e.g. a one-off renormalization task): step 2's `update_all` has just
  set that very row's `is_default` to `false` in the database, but the
  passed-in struct's own `is_default` field still reads `true` from
  before the call. `Ecto.Changeset.cast/3` compares a field's new value
  against the struct's OWN current value, not a fresh read of the row —
  sees `true -> true`, decides nothing changed, and never puts
  `:is_default` in the changeset's `changes`, so the `UPDATE` it emits
  never touches that column. Left uncorrected, the row stays `false`
  from step 2 and nothing is left default at all. Step 3 therefore
  RELOADS the row before building the promote changeset, and forces both
  `:is_default` and `:exchange_rate` into the changeset regardless of
  what the reloaded row already says — belt-and-braces, since step 1's
  renormalization also just changed this same row's rate out from under
  any struct captured before the transaction.
  """
  def set_default_currency(%Currency{exchange_rate: rate} = currency) do
    if is_nil(rate) or Decimal.compare(rate, 0) != :gt do
      {:error, :invalid_base_rate}
    else
      repo().transaction(fn ->
        # 0. Reload before doing anything else: the caller's struct can be
        #    stale by the time this transaction actually starts (another
        #    process changed the row in between), so the guard above,
        #    checked against the CALLER's copy, is re-checked here against
        #    what the database currently holds — the value step 1 is about
        #    to divide every rate by.
        fresh_before = repo().get_by!(Currency, uuid: currency.uuid)

        if is_nil(fresh_before.exchange_rate) or
             Decimal.compare(fresh_before.exchange_rate, 0) != :gt do
          repo().rollback(:invalid_base_rate)
        end

        base_rate = fresh_before.exchange_rate

        # 1. Renormalize every rate against the new base, past the
        #    changeset — ratios are preserved, so no converted price
        #    moves. Shared with `change_base_currency/2` (see
        #    `renormalize_all_rates!/1`'s own doc for the
        #    `rate_actually_changes?` reasoning).
        {rate_actually_changes?, now} = renormalize_all_rates!(base_rate)

        # 2. Clear the previous default.
        Currency
        |> where([c], c.is_default == true)
        |> repo().update_all(set: [is_default: false])

        # 3. Promote, pinning the base rate to exactly 1.0 (also enables
        #    it). Shared with `change_base_currency/2` — see
        #    `promote_to_base!/3`'s own doc for why it reloads the row
        #    and forces both fields into the changeset regardless of
        #    what that reload already reports.
        promote_to_base!(currency.uuid, rate_actually_changes?, now)
      end)
      |> maybe_invalidate_currency_cache()
      |> maybe_broadcast_currencies_changed()
    end
  end

  @doc """
  Changes the shop's base currency — an OPERATION (§4.9), not a toggle.

  Changing the base without repricing the catalog is a silent
  re-pricing of the whole shop: the number `138.00` stored on a
  product does not change, only its MEANING does (it quietly stops
  being dollars and starts being euros), and no database notices that
  on its own.

  Billing owns only the two steps that are actually about the currency
  table:

    1. renormalize every currency's `exchange_rate` by dividing it by
       the new base's CURRENT rate (§3.2) — real-world ratios are
       preserved, only which currency reads `1.0` changes;
    5. promote the new base, pinning its rate to exactly `1.0`.

  §4.9's steps 2-4 (recompute `price`/`compare_at_price`/`cost_per_item`
  and the fixed option-price modifiers on every catalog item; recompute
  every shipping method's price and its three thresholds; stamp the new
  base code onto every item) belong to whichever package owns the
  catalog and shipping data today — `phoenix_kit_catalogue`, not this
  one. Billing cannot reach those tables and must not try to. The
  CALLER supplies that work as `opts[:reprice]`, a 3-arity
  `(old_base_code, new_base_code, multiplier) -> {:ok, term} | {:error, term}`
  function invoked INSIDE this same transaction, strictly AFTER step 1
  (so it sees already-renormalized rates) and strictly BEFORE step 5
  (so an `{:error, _}` it returns rolls back the renormalization too —
  the catalog and the currency table can never end up disagreeing about
  which currency is base). Both packages resolve
  `PhoenixKit.RepoHelper.repo()` to the same host repo module, so a
  `:reprice` implementation's own repo calls join this transaction
  automatically, with no extra plumbing.

  `multiplier` is the new base's PRE-operation rate — the exact same
  value this function returns as `:rate` below — handed to the callback
  explicitly because it is NOT derivable from inside the transaction
  once step 1 has run: by then, EVERY rate has already been
  renormalized, including the new base's own (now `1.000000`) and the
  old base's (now the reciprocal of the very multiplier a repricing
  implementation needs). A callback that tried to look either of those
  up would find a plausible-looking number that is simply wrong — a
  trap that fires once, in someone else's code, long after this
  function was written. Passing the multiplier closes that off: a
  repricing implementation multiplies its stored prices by it directly
  and never has to reach for a currency row at all.

  `opts[:catalog_size]` — a non-negative integer the caller MUST
  supply; its absence refuses with `{:error, :catalog_size_unknown}`
  ("I don't know how many products there are" is not permission to
  proceed), and a negative value refuses with
  `{:error, :invalid_catalog_size}` (a caller error, not permission to
  skip repricing). When it is greater than zero and no `:reprice` is
  given, refuses with `{:error, :reprice_required}` — a silent
  shop-wide re-pricing is exactly what this function exists to prevent.
  An empty catalog (`catalog_size: 0`) has nothing to reprice, so
  `:reprice` is optional there.

  Refuses `{:error, :unknown_currency}` (no such code),
  `{:error, :currency_not_usable}` (disabled, or `exchange_rate` not
  `> 0`), and `{:error, :already_base}` (already the default) before
  touching anything, and re-checks the same three guards on a freshly
  reloaded row once inside the transaction (the same staleness guard
  `set_default_currency/1` uses, for the same reason: another process
  could have changed the row between the pre-check and the transaction
  actually starting).

  Carts and orders are NEVER touched (§4.9 step 6) — they carry their
  own frozen `currency`/`exchange_rate` (§4.4, §4.5), which is the
  entire point of freezing them; this function does not even reference
  either schema.

  On success, returns `{:ok, %{old_base: <the PREVIOUS base's code>,
  rate: <the divisor every OTHER currency's rate was just divided by —
  the new base's own PRE-operation rate>}}`. `:reprice` needs exactly
  that ratio to convert `old_base_code`-denominated prices into
  `new_base_code`.
  """
  @spec change_base_currency(String.t(), keyword()) ::
          {:ok, %{old_base: String.t(), rate: Decimal.t()}} | {:error, term()}
  def change_base_currency(new_base_code, opts \\ []) do
    reprice = Keyword.get(opts, :reprice)
    catalog_size = Keyword.get(opts, :catalog_size)

    with :ok <- validate_reprice_requirement(catalog_size, reprice),
         {:ok, new_base} <- fetch_currency_for_base_change(new_base_code),
         {:ok, result} <- do_change_base_currency(new_base, reprice) do
      # §4.2.1 item 5: the SAME cache-then-broadcast sequence (and the SAME
      # helpers) every other currency writer uses — this one rewrites
      # EVERY row, the largest change this module can make, so every
      # open storefront tab (subscribed since E2 for exactly this: a
      # rate edit re-renders live, no reload) needs to hear about it
      # too, not just single-currency writes. The newly promoted base's
      # OWN code is the payload `Events.broadcast_currencies_changed/1`
      # expects — not the public `%{old_base:, rate:}` result below,
      # which deliberately does NOT flow through here (it would silently
      # no-op against `maybe_broadcast_currencies_changed/1`'s
      # `%Currency{}` match).
      {:ok, result.promoted}
      |> maybe_invalidate_currency_cache()
      |> maybe_broadcast_currencies_changed()

      {:ok, %{old_base: result.old_base, rate: result.rate}}
    end
  end

  defp validate_reprice_requirement(nil, _reprice), do: {:error, :catalog_size_unknown}

  defp validate_reprice_requirement(catalog_size, _reprice)
       when is_integer(catalog_size) and catalog_size < 0 do
    {:error, :invalid_catalog_size}
  end

  defp validate_reprice_requirement(catalog_size, nil)
       when is_integer(catalog_size) and catalog_size > 0 do
    {:error, :reprice_required}
  end

  defp validate_reprice_requirement(catalog_size, _reprice) when is_integer(catalog_size),
    do: :ok

  defp fetch_currency_for_base_change(code) do
    case repo().get_by(Currency, code: String.upcase(code)) do
      nil -> {:error, :unknown_currency}
      %Currency{is_default: true} -> {:error, :already_base}
      %Currency{enabled: false} -> {:error, :currency_not_usable}
      %Currency{exchange_rate: rate} when is_nil(rate) -> {:error, :currency_not_usable}
      %Currency{exchange_rate: rate} = currency -> currency_if_usable_rate(currency, rate)
    end
  end

  defp currency_if_usable_rate(currency, rate) do
    if Decimal.compare(rate, 0) == :gt do
      {:ok, currency}
    else
      {:error, :currency_not_usable}
    end
  end

  defp do_change_base_currency(%Currency{} = new_base, reprice) do
    repo().transaction(fn ->
      # Reload before doing anything else: the row fetched above can be
      # stale by the time this transaction actually starts (mirrors
      # `set_default_currency/1`'s own guard, for the same reason).
      fresh_new_base = repo().get_by!(Currency, uuid: new_base.uuid)
      validate_fresh_new_base!(fresh_new_base)

      old_base =
        case get_default_currency() do
          nil -> repo().rollback(:no_base_currency)
          %Currency{} = base -> base
        end

      base_rate = fresh_new_base.exchange_rate

      # 1. Renormalize every rate against the new base (§3.2, §4.9 step
      #    1). Shared with `set_default_currency/1` — see
      #    `renormalize_all_rates!/1`'s own doc. No `enabled` filter: a
      #    disabled currency's rate is still real data and still gets
      #    renormalized.
      {rate_actually_changes?, now} = renormalize_all_rates!(base_rate)

      # §4.9 steps 2-4: the CALLER's job. Runs strictly after step 1
      # (rates are already renormalized — `base_rate` below is the
      # multiplier a repricing implementation needs, and it is handed
      # over explicitly because it stops being derivable from the table
      # itself the moment step 1 finishes: the new base's own rate now
      # reads `1.0`, and the old base's reads the RECIPROCAL of this
      # multiplier, not the multiplier itself) and strictly before step
      # 5 (the currency table's own `is_default` has not moved yet) —
      # `Repo.rollback/1` unwinds this whole transaction on `{:error, _}`,
      # so a repricing failure can never leave the catalog and the
      # currency table disagreeing about which currency is base.
      run_reprice!(reprice, old_base.code, fresh_new_base.code, base_rate)

      # 5. Clear the previous default, then promote the new one at
      #    exactly 1.0. Shared with `set_default_currency/1` — see
      #    `promote_to_base!/3`'s own doc.
      Currency
      |> where([c], c.is_default == true)
      |> repo().update_all(set: [is_default: false])

      promoted = promote_to_base!(fresh_new_base.uuid, rate_actually_changes?, now)

      %{old_base: old_base.code, rate: base_rate, promoted: promoted}
    end)
  end

  # Re-checks the three guards `fetch_currency_for_base_change/1` already
  # checked, against a freshly-reloaded row — the pre-check can be stale
  # by the time this transaction actually starts.
  defp validate_fresh_new_base!(%Currency{} = fresh_new_base) do
    cond do
      fresh_new_base.is_default ->
        repo().rollback(:already_base)

      is_nil(fresh_new_base.exchange_rate) or
          Decimal.compare(fresh_new_base.exchange_rate, 0) != :gt ->
        repo().rollback(:currency_not_usable)

      not fresh_new_base.enabled ->
        repo().rollback(:currency_not_usable)

      true ->
        :ok
    end
  end

  defp run_reprice!(nil, _old_base_code, _new_base_code, _multiplier), do: :ok

  defp run_reprice!(fun, old_base_code, new_base_code, multiplier) do
    case fun.(old_base_code, new_base_code, multiplier) do
      {:ok, _} -> :ok
      {:error, reason} -> repo().rollback(reason)
    end
  end

  # Shared by `set_default_currency/1` and `change_base_currency/2` —
  # both renormalize EVERY currency's `exchange_rate` by dividing it by
  # the same `base_rate` (the new base's own pre-operation rate), so a
  # future fix to one path must not be able to miss the other.
  #
  # §6.2: dividing every rate by 1 is the identity — nothing numerically
  # moves anywhere (the re-promote-the-current-default case, or a
  # `change_base_currency/2` call whose target happens to already carry
  # rate `1.0`). Computed from the PRE-renormalization `base_rate`
  # because after this function runs, the promoted row's own rate always
  # reads back as exactly 1.0 regardless of scenario (it divided itself
  # by itself) — a reload afterward can never be used as the signal.
  #
  # This can produce one rare FALSE POSITIVE, never a false negative: a
  # `base_rate` merely close to 1 (e.g. `1.0000001`) counts as "not 1"
  # and re-dates every row, even though rounding to the stored precision
  # (6 decimals) can leave some row's displayed rate numerically
  # unchanged. Re-dating a rate that happened not to move is harmless
  # (the row genuinely WAS recomputed against a new base); erasing a
  # real staleness signal would not be — so this flag only ever errs
  # toward "changed".
  #
  # Returns `{rate_actually_changes?, now}` for the caller to pass into
  # `promote_to_base!/3` unchanged — one instant for the whole operation,
  # not N independently-timed ones.
  defp renormalize_all_rates!(base_rate) do
    now = DateTime.utc_now(:second)
    rate_actually_changes? = not Decimal.equal?(base_rate, Decimal.new("1"))

    base_rate
    |> renormalize_all_rates_query(rate_actually_changes?, now)
    |> repo().update_all([])

    {rate_actually_changes?, now}
  end

  defp renormalize_all_rates_query(base_rate, true = _rate_actually_changes?, now) do
    from(c in Currency,
      update: [
        set: [
          exchange_rate: fragment("round(? / ?, 6)", c.exchange_rate, type(^base_rate, :decimal)),
          rate_updated_at: ^now
        ]
      ]
    )
  end

  defp renormalize_all_rates_query(base_rate, false = _rate_actually_changes?, _now) do
    from(c in Currency,
      update: [
        set: [
          exchange_rate: fragment("round(? / ?, 6)", c.exchange_rate, type(^base_rate, :decimal))
        ]
      ]
    )
  end

  # Shared by `set_default_currency/1` and `change_base_currency/2` —
  # both promote the currency at `uuid` to default the same way, pinning
  # its rate to exactly 1.0. Reloads the row itself rather than trusting
  # a struct the caller captured earlier: whichever step ran immediately
  # before this one may have just changed this very row (its own rate,
  # via `renormalize_all_rates!/1`; or, for the row that WAS the base,
  # the `is_default` clear that runs right before this call), and
  # `Ecto.Changeset.cast/3` only records a "change" when the cast value
  # differs from the struct's CURRENT field value — so both `:is_default`
  # and `:exchange_rate` are forced into the changeset regardless of
  # what the reload already (mis)reports, or the `UPDATE` this emits
  # could end up not touching one of them at all. `rate_updated_at` is
  # NOT decided by `stamp_rate_change/2` here: `force_change/3` above
  # always injects `:exchange_rate` into `changes`, so `fetch_change/2`
  # would always say "changed" — exactly the false positive
  # `rate_actually_changes?` (computed once, upstream, in
  # `renormalize_all_rates!/1`) exists to avoid.
  defp promote_to_base!(uuid, rate_actually_changes?, now) do
    changeset =
      Currency
      |> repo().get_by!(uuid: uuid)
      |> Currency.changeset(%{is_default: true, enabled: true, exchange_rate: Decimal.new("1.0")})
      |> Ecto.Changeset.force_change(:is_default, true)
      |> Ecto.Changeset.force_change(:exchange_rate, Decimal.new("1.0"))

    changeset =
      if rate_actually_changes? do
        Ecto.Changeset.put_change(changeset, :rate_updated_at, now)
      else
        changeset
      end

    repo().update!(changeset)
  end

  @doc """
  Deletes a currency.

  The default currency and currencies referenced by orders cannot be deleted.
  """
  def delete_currency(%Currency{} = currency) do
    cond do
      currency.is_default ->
        {:error, :is_default}

      order_count_for_currency(currency.code) > 0 ->
        {:error, :currency_in_use}

      true ->
        currency
        |> repo().delete()
        |> maybe_invalidate_currency_cache()
        |> maybe_broadcast_currencies_changed()
    end
  end

  defp order_count_for_currency(code) do
    from(o in Order, where: o.currency == ^code, select: count(o.uuid))
    |> repo().one()
  end

  @doc """
  Refreshes `phoenix_kit_currencies.exchange_rate` from the optional
  `:fx_rate_provider` hook (per-domain-currency spec §6.1).

  Rates stay MANUAL by default (the admin form at `web/currencies.ex`) —
  this function exists only for a host that has explicitly configured a
  feed and is not called from anywhere in this package on its own; the
  mix task `phoenix_kit_billing.refresh_fx_rates` is the intended trigger,
  and nothing schedules it.

  ## The hook

      config :phoenix_kit, :fx_rate_provider, {MyApp.FxFeed, :fetch_rates}

  Matches the `:canonical_host_resolver` / `:sitemap_domains_provider`
  convention already accepted in this application (a bare `{mod, fun}`
  tuple, not a 3-element MFA with baked-in args) — nothing new to invent.
  The function is called with NO arguments (`apply(mod, fun, [])`) and
  must return a PLAIN MAP of `%{"CODE" => rate}`, one entry per currency
  it has an opinion about; `rate` may be a `Decimal`, a `float`, an
  `integer` or a `binary` (whatever the provider's own API hands back).
  Prefer `Decimal` or a `binary` when the provider author has a choice —
  a `float` carries its own binary-imprecision, which this function
  cannot undo, only round.

  Currency codes are case-normalized (`String.upcase/1`) before anything
  else, so a provider returning both `"eur"` and `"EUR"` collapses to a
  single entry for `"EUR"` rather than writing (and broadcasting) twice.

  Absent config resolves to `{:error, :no_provider}` — an explicit
  answer, never a silent no-op success.

  ## Validation — refused WHOLE, nothing partially applied

  Every entry is checked BEFORE any write happens, against the SAME
  database snapshot the writes below then use (see "Atomicity"). A
  provider returning even one bad entry refuses the entire batch with
  `{:error, {:invalid_rates, issues}}`, where `issues` is
  `[%{code: code, reason: reason}, ...]` — one entry per problem found,
  not just the first — and the table is left untouched:

    * `reason: :unknown_currency` — this shop has no currency with that
      code;
    * `reason: :invalid_rate` — the value could not be parsed as a
      number at all;
    * `reason: :non_positive_rate` — parsed fine, but `<= 0` (a bad feed
      writing a zero rate would divide-by-zero the storefront the next
      time `Currency.present/3` converts through it);
    * `reason: :rate_too_small` — parsed fine and is `> 0`, but
      `phoenix_kit_currencies.exchange_rate` is `numeric(15,6)`: a value
      like `0.0000001` rounds to exactly `0.000000` once it lands in
      that column — the same divide-by-zero `:non_positive_rate` exists
      to prevent, reached through the column's precision instead of the
      raw value;
    * `reason: :rate_too_large` — rounds (at 6 decimal places) to `1e9`
      or more, which `numeric(15,6)` (9 integer digits, 6 fractional)
      cannot hold at all; Postgres itself raises `numeric field
      overflow` on a write this large, which this check catches before
      that write is ever attempted;
    * `reason: :invalid_code` — the map key itself was not a string.

  The BASE currency (`is_default: true`) is never written — its rate is
  `1.0` by definition and renormalization on a base change depends on
  that staying true. An entry for the base is silently accepted (not an
  error) and reported back under `:skipped_base` instead.

  Other malformed shapes, checked before any per-entry validation runs:

    * the provider's return value is not a map at all —
      `{:error, {:invalid_provider_response, raw}}` (`raw` is exactly
      what the provider returned, for debugging a provider that, say,
      signals its own failure as `{:error, reason}` instead of the map
      this hook expects);
    * the provider raises — `{:error, {:provider_raised, message}}`;
    * the provider exits — `{:error, {:provider_exited, reason}}`.

  ## Atomicity

  Validation and (on success) every write run inside ONE
  `repo().transaction/1` — the base currency is read fresh as the FIRST
  thing inside it, `SELECT ... FOR UPDATE`, not the plain unlocked
  `get_default_currency/0` every other caller in this module gets, and
  not reused from before the transaction opened. Holding that row's lock
  for the life of this transaction is what makes a straddle actually
  impossible rather than merely narrowed: `set_default_currency/1` and
  `change_base_currency/2` both renormalize EVERY currency's rate via a
  table-wide `update_all` (no `WHERE`) as their first write, which always
  touches whichever row is currently the default — so once this function
  holds that row's lock, either call has already fully committed before
  this read ran, or it blocks on that renormalization until this
  transaction ends. A lock-free `SELECT` (or a read taken before the
  transaction opened) would not give that guarantee — nothing stops a
  promotion from committing, and releasing its locks, in the gap between
  such a read and this function's own writes on the very row it just
  promoted.

  The known-code set is also read fresh, inside the same transaction,
  right after the locked base read. If any write fails after others in
  the same batch already succeeded (an unexpected DB-level error — the
  precision checks above are what keep this from happening on any input
  this function itself rejects), the whole transaction rolls back rather
  than leaving a partial write committed.

  ## Writing, and announcing it AFTER it is real

  Accepted rates are written ONE AT A TIME through `update_currency/2`
  — never a direct `Repo` write — so `rate_updated_at` gets stamped the
  same way a manual admin edit stamps it. A write that itself fails —
  `update_currency/2` returning `{:error, reason}`, or raising — rolls
  back the whole transaction and surfaces as
  `{:error, {:write_failed, code, reason}}` rather than crashing this
  function outright.

  `update_currency/2` ALSO invalidates the currency cache and broadcasts
  `currencies_changed` on every write, same as it does for a manual
  edit — but that happens DURING this function's transaction, before it
  is known to ever commit. Under real Postgres (not the single shared
  connection this file's own tests run against) a subscriber reacting
  to that broadcast right then, under READ COMMITTED, cannot see this
  still-open transaction's write — it re-reads the PRE-refresh row and
  repopulates the cache with it, right as the cache was just cleared for
  the opposite reason. Nothing would invalidate or broadcast again on
  its own afterward, so that stale entry would sit there until an
  unrelated write happened to clear it — not a rollback edge case, the
  NORMAL every-thing-worked path, defeating the exact live re-render
  this cache/broadcast pair exists to provide (§4.2.1, stage E2).

  So once `repo().transaction/1` has returned `{:ok, _}` — the write is
  REALLY committed, not merely executed inside a transaction something
  later in the batch could still roll back — this function invalidates
  the cache and broadcasts `currencies_changed` again itself, once per
  code it actually wrote, using the same clear-applied-before-broadcast
  barrier every other writer in this module relies on
  (`invalidate_currency_cache/0`). `update_currency/2`'s own
  in-transaction pair becomes harmless noise once this runs: any
  subscriber that reacted to it too early and cached the pre-refresh
  rate gets corrected by this clear, and the broadcast that follows is
  the one every subscriber can actually trust — the property that was
  broken is restored by reacting a second time, not by trying to
  suppress the first.

  On a rolled-back batch (invalid data, or a write that failed) there is
  nothing to announce here — an in-transaction broadcast that fired
  before the failure already went out for a change that never
  persisted, but every subscriber that reacted to it read the
  UNCHANGED table (the write it announced never survived to be read)
  and rendered the unchanged price; the only cost is one wasted
  re-render, not a wrong one. `:dry_run` writes nothing, so nothing is
  announced there either.

  ## Options

    * `:dry_run` (default `false`) — runs the full fetch-and-validate
      pass inside the same transaction (so a bad provider is still
      caught and reported) but performs no writes; the transaction
      commits with nothing to commit. On success returns
      `{:ok, %{dry_run: true, would_update: [%{code:, previous_rate:, new_rate:}, ...], skipped_base: [code, ...]}}`
      instead of the normal
      `%{updated: [%{code:, previous_rate:, new_rate:}, ...], skipped_base: [code, ...]}`.
  """
  @spec refresh_rates_from_provider(keyword()) :: {:ok, map()} | {:error, term()}
  def refresh_rates_from_provider(opts \\ []) do
    case Application.get_env(:phoenix_kit, :fx_rate_provider) do
      {mod, fun} -> mod |> call_fx_rate_provider(fun) |> apply_provider_rates(opts)
      _ -> {:error, :no_provider}
    end
  end

  defp call_fx_rate_provider(mod, fun) do
    {:ok, apply(mod, fun, [])}
  rescue
    error -> {:error, {:provider_raised, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:provider_exited, reason}}
  end

  defp apply_provider_rates({:error, _} = error, _opts), do: error

  defp apply_provider_rates({:ok, raw}, _opts) when not is_map(raw) do
    {:error, {:invalid_provider_response, raw}}
  end

  defp apply_provider_rates({:ok, raw}, opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    normalized = normalize_provider_keys(raw)

    fn -> classify_and_apply_provider_rates(normalized, dry_run?) end
    |> repo().transaction()
    |> announce_committed_fx_rates()
  end

  # See the moduledoc's "Writing, and announcing it AFTER it is real" for
  # why this exists: `update_currency/2`'s own invalidate+broadcast runs
  # DURING the transaction above, before it is known to ever commit, and
  # under real Postgres that is early enough for a subscriber to
  # repopulate the cache with the pre-refresh row. This re-announces
  # once the write is REALLY committed — nothing to do for a rolled-back
  # batch or a dry run, neither of which wrote anything.
  defp announce_committed_fx_rates({:ok, %{updated: updated} = result}) when updated != [] do
    invalidate_currency_cache()

    Enum.each(updated, fn %{code: code} ->
      Events.broadcast_currencies_changed(%Currency{code: code})
    end)

    {:ok, result}
  end

  defp announce_committed_fx_rates(result), do: result

  # `FOR UPDATE`, deliberately not the plain, unlocked `get_default_currency/0`
  # every other caller in this module gets — see the moduledoc's
  # "Atomicity" section for why holding this specific row's lock for the
  # life of the transaction is what makes "a concurrent promotion cannot
  # straddle this call" true rather than merely likely. Written locally
  # instead of adding a lock option to the shared function, so no other
  # caller's behavior changes. A locked `SELECT` matching zero rows (no
  # default currency at all — a pathological, out-of-scope state) simply
  # returns `nil`, same as the unlocked query.
  defp lock_default_currency_for_update do
    Currency
    |> where([c], c.is_default == true)
    |> lock("FOR UPDATE")
    |> repo().one()
  end

  # Read fresh INSIDE the transaction, not reused from before it opened —
  # see the moduledoc's "Atomicity" section. Both the skip/accept/reject
  # decision below and (on the write path) the writes themselves are
  # backed by this same snapshot.
  defp classify_and_apply_provider_rates(normalized, dry_run?) do
    base = lock_default_currency_for_update()
    known_by_code = Map.new(list_currencies(), &{&1.code, &1})

    classified = Enum.map(normalized, &classify_provider_entry(&1, base, known_by_code))
    issues = for {:error, code, reason} <- classified, do: %{code: code, reason: reason}

    if issues != [] do
      repo().rollback({:invalid_rates, issues})
    else
      accepted = for {:ok, currency, rate} <- classified, do: {currency, rate}
      skipped_base = for {:skip, code, :base_currency} <- classified, do: code

      apply_accepted_fx_rates(accepted, skipped_base, dry_run?)
    end
  end

  defp apply_accepted_fx_rates(accepted, skipped_base, true = _dry_run?) do
    would_update =
      Enum.map(accepted, fn {currency, rate} ->
        %{code: currency.code, previous_rate: currency.exchange_rate, new_rate: rate}
      end)

    %{dry_run: true, would_update: would_update, skipped_base: skipped_base}
  end

  defp apply_accepted_fx_rates(accepted, skipped_base, false = _dry_run?) do
    updated = Enum.map(accepted, fn {currency, rate} -> write_fx_rate!(currency, rate) end)
    %{updated: updated, skipped_base: skipped_base}
  end

  # Rolls the enclosing transaction back on a write failure instead of
  # returning an error tuple to a caller that isn't set up to handle
  # one mid-`Enum.map/2` — `apply_accepted_fx_rates/3`'s write branch is
  # already inside `repo().transaction/1` (see `apply_provider_rates/2`).
  defp write_fx_rate!(currency, rate) do
    case write_fx_rate(currency, rate) do
      {:ok, entry} -> entry
      {:error, reason} -> repo().rollback(reason)
    end
  end

  # Never a hard `{:ok, _} = ...` match: a changeset rejection (unexpected —
  # everything reaching here already passed classification) or a raised
  # DB-level error (e.g. a value this function's own checks somehow missed)
  # both come back as a tagged error the caller rolls the transaction back
  # with, instead of crashing this function outright (§ moduledoc "Writing").
  defp write_fx_rate(%Currency{} = currency, rate) do
    previous_rate = currency.exchange_rate

    case update_currency(currency, %{exchange_rate: rate}) do
      {:ok, updated_currency} ->
        {:ok, %{code: updated_currency.code, previous_rate: previous_rate, new_rate: rate}}

      {:error, reason} ->
        {:error, {:write_failed, currency.code, reason}}
    end
  rescue
    error -> {:error, {:write_failed, currency.code, Exception.message(error)}}
  end

  # Case-normalizes STRING keys only (binary codes are what this hook's
  # contract expects) so `"eur"` and `"EUR"` collapse to one entry before
  # classification ever runs — a raw `Enum.map/2` over the provider's map
  # would otherwise treat them as two different currencies and write (and
  # broadcast) the same row twice. A non-string key is left as-is;
  # `classify_provider_entry/3`'s own catch-all clause reports it as
  # `:invalid_code`.
  defp normalize_provider_keys(raw) do
    Enum.reduce(raw, %{}, fn
      {code, value}, acc when is_binary(code) -> Map.put(acc, String.upcase(code), value)
      {code, value}, acc -> Map.put(acc, code, value)
    end)
  end

  defp classify_provider_entry({code, value}, base, known_by_code) when is_binary(code) do
    cond do
      base != nil and base.code == code ->
        {:skip, code, :base_currency}

      not Map.has_key?(known_by_code, code) ->
        {:error, code, :unknown_currency}

      true ->
        case parse_fx_rate(value) do
          {:ok, rate} -> classify_fx_rate(code, rate, known_by_code)
          :error -> {:error, code, :invalid_rate}
        end
    end
  end

  defp classify_provider_entry({code, _value}, _base, _known_by_code) do
    {:error, inspect(code), :invalid_code}
  end

  defp classify_fx_rate(code, rate, known_by_code) do
    cond do
      not fx_rate_positive?(rate) ->
        {:error, code, :non_positive_rate}

      (reason = fx_rate_column_precision_error(rate)) != nil ->
        {:error, code, reason}

      true ->
        {:ok, Map.fetch!(known_by_code, code), rate}
    end
  end

  defp parse_fx_rate(%Decimal{} = rate), do: {:ok, rate}
  defp parse_fx_rate(n) when is_float(n), do: {:ok, Decimal.from_float(n)}
  defp parse_fx_rate(n) when is_integer(n), do: {:ok, Decimal.new(n)}

  defp parse_fx_rate(s) when is_binary(s) do
    case Decimal.parse(s) do
      {%Decimal{} = rate, ""} -> {:ok, rate}
      _ -> :error
    end
  end

  defp parse_fx_rate(_), do: :error

  defp fx_rate_positive?(%Decimal{} = rate) do
    Decimal.compare(rate, 0) == :gt
  rescue
    _error -> false
  end

  # `phoenix_kit_currencies.exchange_rate` is `numeric(15,6)` — 9 integer
  # digits, 6 fractional (confirmed against Postgres directly: casting
  # `1000000000` — 10^9 — to `numeric(15,6)` raises "numeric field
  # overflow ... must round to an absolute value less than 10^9", and
  # `0.0000001` silently rounds to `0.000000`). A rate that parses and is
  # genuinely `> 0` can still be unusable once it lands in that column —
  # too small and it rounds away to nothing (the exact divide-by-zero
  # `:non_positive_rate` exists to prevent, just reached through a
  # different door); too large and Postgres raises rather than returning
  # a changeset error. Both are checked here, BEFORE any write is
  # attempted, using the same rounding (`:half_up`, matching what
  # Postgres itself does at the halfway point) the column will apply.
  @fx_rate_column_scale 6
  @fx_rate_column_max Decimal.new("1000000000")

  defp fx_rate_column_precision_error(rate) do
    rounded = Decimal.round(rate, @fx_rate_column_scale, :half_up)

    cond do
      Decimal.compare(rounded, 0) != :gt -> :rate_too_small
      Decimal.compare(rounded, @fx_rate_column_max) != :lt -> :rate_too_large
      true -> nil
    end
  rescue
    _error -> :invalid_rate
  end

  # ============================================
  # BILLING PROFILES
  # ============================================

  @doc """
  Lists billing profiles with optional filters.

  ## Options
  - `:user_uuid` - Filter by user UUID
  - `:type` - Filter by type ("individual" or "company")
  - `:search` - Search in name/email/company fields
  - `:page` - Page number
  - `:per_page` - Items per page
  - `:preload` - Associations to preload
  """
  def list_billing_profiles(opts \\ []) do
    BillingProfile
    |> filter_by_user_uuid(Keyword.get(opts, :user_uuid))
    |> filter_by_type(Keyword.get(opts, :type))
    |> filter_by_search(Keyword.get(opts, :search))
    |> order_by([bp], desc: bp.is_default, desc: bp.inserted_at)
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().all()
  end

  defp filter_by_user_uuid(query, nil), do: query

  defp filter_by_user_uuid(query, user_uuid) do
    user_uuid = extract_user_uuid(user_uuid)
    where(query, [bp], bp.user_uuid == ^user_uuid)
  end

  defp filter_by_type(query, nil), do: query
  defp filter_by_type(query, type), do: where(query, [bp], bp.type == ^type)

  defp filter_by_search(query, nil), do: query
  defp filter_by_search(query, ""), do: query

  defp filter_by_search(query, search) do
    search_term = "%#{search}%"

    where(
      query,
      [bp],
      ilike(bp.first_name, ^search_term) or
        ilike(bp.last_name, ^search_term) or
        ilike(bp.email, ^search_term) or
        ilike(bp.company_name, ^search_term)
    )
  end

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)

  @doc """
  Lists billing profiles for a user (shorthand).
  """
  def list_user_billing_profiles(user_uuid) do
    list_billing_profiles(user_uuid: user_uuid)
  end

  @doc """
  Lists billing profiles with count for pagination.
  """
  def list_billing_profiles_with_count(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    offset = (page - 1) * per_page

    base_query = BillingProfile

    base_query =
      case Keyword.get(opts, :type) do
        nil -> base_query
        type -> where(base_query, [bp], bp.type == ^type)
      end

    base_query =
      case Keyword.get(opts, :search) do
        nil ->
          base_query

        "" ->
          base_query

        search ->
          search_term = "%#{search}%"

          where(
            base_query,
            [bp],
            ilike(bp.first_name, ^search_term) or
              ilike(bp.last_name, ^search_term) or
              ilike(bp.email, ^search_term) or
              ilike(bp.company_name, ^search_term)
          )
      end

    total = repo().aggregate(base_query, :count, :uuid)

    preloads = Keyword.get(opts, :preload, [])

    profiles =
      base_query
      |> order_by([bp], desc: bp.is_default, desc: bp.inserted_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> preload(^preloads)
      |> repo().all()

    {profiles, total}
  end

  @doc """
  Gets the default billing profile for a user.

  Saving keeps one default per user; should older data still hold several,
  the most recently updated one is returned instead of raising.
  """
  def get_default_billing_profile(user_uuid) do
    user_uuid = extract_user_uuid(user_uuid)

    BillingProfile
    |> where([bp], bp.user_uuid == ^user_uuid and bp.is_default == true)
    |> order_by([bp], desc: bp.updated_at, desc: bp.inserted_at)
    |> limit(1)
    |> repo().one()
  end

  @doc """
  Gets a billing profile by ID or UUID, returns nil if not found.
  """
  def get_billing_profile(id) when is_binary(id) do
    if UUIDUtils.valid?(id) do
      repo().get_by(BillingProfile, uuid: id)
    else
      nil
    end
  end

  def get_billing_profile(_), do: nil

  @doc """
  Gets a billing profile by ID or UUID, raises if not found.
  """
  def get_billing_profile!(id) do
    case get_billing_profile(id) do
      nil -> raise Ecto.NoResultsError, queryable: BillingProfile
      profile -> profile
    end
  end

  @doc """
  Returns a changeset for billing profile form.
  """
  def change_billing_profile(%BillingProfile{} = profile, attrs \\ %{}) do
    BillingProfile.changeset(profile, attrs)
  end

  @doc """
  Creates a billing profile.
  """
  def create_billing_profile(user_or_uuid, attrs) do
    user_uuid = extract_user_uuid(user_or_uuid)

    result =
      %BillingProfile{}
      |> BillingProfile.changeset(
        attrs
        |> Map.put("user_uuid", user_uuid)
      )
      |> save_keeping_one_default(&repo().insert(&1))

    # If this is the first profile, make it default
    case result do
      {:ok, profile} ->
        Events.broadcast_profile_created(profile)

        if count_user_profiles(user_uuid) == 1 do
          set_default_billing_profile(profile)
        else
          {:ok, profile}
        end

      error ->
        error
    end
  end

  @doc """
  Updates a billing profile.
  """
  def update_billing_profile(%BillingProfile{} = profile, attrs) do
    result =
      profile
      |> BillingProfile.changeset(attrs)
      |> save_keeping_one_default(&repo().update(&1))

    case result do
      {:ok, updated_profile} ->
        Events.broadcast_profile_updated(updated_profile)
        {:ok, updated_profile}

      error ->
        error
    end
  end

  @doc """
  Deletes a billing profile.
  """
  def delete_billing_profile(%BillingProfile{} = profile) do
    result = repo().delete(profile)

    case result do
      {:ok, deleted_profile} ->
        Events.broadcast_profile_deleted(deleted_profile)
        {:ok, deleted_profile}

      error ->
        error
    end
  end

  @doc """
  Sets a billing profile as default.
  """
  def set_default_billing_profile(%BillingProfile{} = profile) do
    repo().transaction(fn ->
      # Clear existing default for user
      BillingProfile
      |> where([bp], bp.user_uuid == ^profile.user_uuid and bp.is_default == true)
      |> repo().update_all(set: [is_default: false])

      # Set new default
      profile
      |> BillingProfile.changeset(%{is_default: true})
      |> repo().update!()
    end)
  end

  # A user has one default profile: saving a profile that becomes the default
  # clears the flag on the user's other profiles in the same transaction, as
  # `set_default_billing_profile/1` does.
  defp save_keeping_one_default(changeset, save) do
    if Ecto.Changeset.get_change(changeset, :is_default) == true do
      repo().transaction(fn ->
        case save.(changeset) do
          {:ok, profile} ->
            clear_other_defaults(profile)
            profile

          {:error, changeset} ->
            repo().rollback(changeset)
        end
      end)
    else
      save.(changeset)
    end
  end

  defp clear_other_defaults(%BillingProfile{uuid: uuid, user_uuid: user_uuid}) do
    BillingProfile
    |> where([bp], bp.user_uuid == ^user_uuid and bp.is_default == true and bp.uuid != ^uuid)
    |> repo().update_all(set: [is_default: false])
  end

  defp count_user_profiles(user_uuid) do
    user_uuid = extract_user_uuid(user_uuid)

    BillingProfile
    |> where([bp], bp.user_uuid == ^user_uuid)
    |> repo().aggregate(:count)
  end

  # ============================================
  # ORDERS
  # ============================================

  @doc """
  Lists all orders with optional filters.

  Orders in the trash are left out. `trashed: :only` lists just the trash,
  `trashed: :include` both.
  """
  def list_orders(filters \\ %{}) do
    Order
    |> apply_order_filters(filters)
    |> order_by([o], desc: o.inserted_at)
    |> preload([:billing_profile])
    |> repo().all()
  end

  @doc """
  Lists orders for a specific user.

  Takes the same filters as `list_orders/1`, so the trash is left out by default.
  The `:invoices` of an order preloaded through `:preload` leave the trash out
  too: this is the list a customer sees.
  """
  def list_user_orders(user_uuid, filters \\ %{}, opts \\ []) do
    user_uuid = extract_user_uuid(user_uuid)
    preloads = opts |> Keyword.get(:preload, []) |> without_trashed_invoices()

    Order
    |> where([o], o.user_uuid == ^user_uuid)
    |> apply_order_filters(filters)
    |> order_by([o], desc: o.inserted_at)
    |> preload(^preloads)
    |> repo().all()
  end

  @doc """
  Lists orders with count for pagination.

  Orders in the trash are left out, and not counted. `trashed: :only` lists just
  the trash (the one trashed last first), `trashed: :include` both.
  """
  def list_orders_with_count(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    offset = (page - 1) * per_page
    search = Keyword.get(opts, :search)
    status = Keyword.get(opts, :status)
    trashed = trashed_option(opts)

    base_query = scope_trashed(Order, trashed)

    base_query =
      case status do
        nil -> base_query
        status -> where(base_query, [o], o.status == ^status)
      end

    base_query =
      case search do
        nil ->
          base_query

        "" ->
          base_query

        search ->
          search_term = "%#{search}%"

          base_query
          |> join(:left, [o], u in assoc(o, :user))
          |> where(
            [o, u],
            ilike(o.order_number, ^search_term) or
              ilike(u.email, ^search_term)
          )
      end

    total = repo().aggregate(base_query, :count, :uuid)

    preloads = Keyword.get(opts, :preload, [])

    orders =
      base_query
      |> order_listing(trashed)
      |> limit(^per_page)
      |> offset(^offset)
      |> preload(^preloads)
      |> repo().all()

    {orders, total}
  end

  @doc """
  Gets an order by ID or UUID.
  """
  def get_order!(id) do
    case get_order(id) do
      nil -> raise Ecto.NoResultsError, queryable: Order
      order -> order
    end
  end

  @doc """
  Gets an order by ID or UUID with optional preloads.
  """
  def get_order(id, opts \\ [])

  def get_order(id, opts) when is_binary(id) do
    preloads = Keyword.get(opts, :preload, [:billing_profile])

    if UUIDUtils.valid?(id) do
      Order
      |> where([o], o.uuid == ^id)
      |> preload(^preloads)
      |> repo().one()
    else
      nil
    end
  end

  def get_order(_, _opts), do: nil

  @doc """
  Gets an order by order number.
  """
  def get_order_by_number(order_number) do
    Order
    |> where([o], o.order_number == ^order_number)
    |> preload([:billing_profile])
    |> repo().one()
  end

  @doc """
  Gets an order by UUID with optional preloads.
  Used for public-facing URLs to prevent ID enumeration.

  An order in the trash is not found, as it is on any other customer-facing
  page; pass `trashed: :include` to find it. The `:invoices` of a `:preload`
  leave the trash out too.
  """
  def get_order_by_uuid(uuid, opts \\ []) do
    preloads = opts |> Keyword.get(:preload, [:billing_profile]) |> without_trashed_invoices()

    Order
    |> scope_trashed(trashed_option(opts))
    |> where([o], o.uuid == ^uuid)
    |> preload(^preloads)
    |> repo().one()
  end

  @doc """
  Creates an order for a user.

  #{@create_note}
  """
  def create_order(user_or_uuid, attrs) do
    user_uuid = extract_user_uuid(user_or_uuid)
    config = get_config()

    # Use string key to match other attrs (avoid mixed keys error)
    attrs =
      attrs
      |> Map.put("user_uuid", user_uuid)
      |> maybe_set_default_currency()
      |> maybe_set_billing_snapshot()

    with %{} = attrs <- attrs do
      insert_order(attrs, config)
    end
  end

  # `maybe_set_billing_snapshot/1` returns an error tuple when the chosen
  # billing profile has vanished; passing that to a changeset would raise.
  #
  # A number the caller supplied is kept (and lifts the counter, see
  # `insert_numbered/4`); otherwise one is generated.
  defp insert_order(attrs, config) do
    {source, attrs} = number_source(attrs, :order_number, "order_number")

    build = fn number ->
      attrs = if number, do: Map.put(attrs, "order_number", number), else: attrs
      Order.changeset(%Order{}, attrs)
    end

    # PubSub after the transaction that inserts the order has ended - the
    # commit, unless the caller's own transaction encloses this call.
    case insert_numbered(build, "order", config.order_prefix, :order_number, source) do
      {:ok, order} ->
        Events.broadcast_order_created(order)
        {:ok, order}

      error ->
        error
    end
  end

  @doc """
  Creates an order from attributes (user_uuid included in attrs).

  #{@create_note}
  """
  def create_order(attrs) when is_map(attrs) do
    config = get_config()

    # Resolve user_uuid from attrs
    user_uuid = Map.get(attrs, :user_uuid) || Map.get(attrs, "user_uuid")

    attrs =
      attrs
      |> Map.put("user_uuid", user_uuid)
      |> maybe_set_default_currency()
      |> maybe_set_billing_snapshot()

    with %{} = attrs <- attrs do
      insert_order(attrs, config)
    end
  end

  @doc """
  Returns an order changeset for form building.
  """
  def change_order(%Order{} = order, attrs \\ %{}) do
    Order.changeset(order, attrs)
  end

  @doc """
  Updates an order.

  A new `order_number` of this year's shape with the configured prefix
  (`PREFIX-YYYY-NNNN`) lifts the year's counter to at least its NNNN, so the
  counter never reaches it. The update opens a transaction, and locks the order
  row first (`FOR UPDATE` when it renumbers), before it lifts the counter.

  Returns `{:ok, order}`, `{:error, :order_not_editable}`,
  `{:error, :order_trashed}` for an order in the trash or `{:error, changeset}`.
  An order is edited only while its STORED status is `draft` or `pending`, and a
  status change is refused with `:order_not_editable` when the stored status is
  no longer the one the struct has - both checked on the locked row. Refusals are returned, not rolled back, so a
  transaction of the caller's stays usable.
  """
  def update_order(%Order{trashed_at: %DateTime{}}, _attrs), do: {:error, :order_trashed}

  def update_order(%Order{} = order, attrs) do
    if Order.editable?(order) do
      # Update billing_snapshot if billing_profile_uuid changed
      attrs = maybe_update_billing_snapshot(order, attrs)

      changeset = Order.changeset(order, attrs)

      # The order may have gone to the trash, or on, since the struct was read:
      # that is checked on the locked row, before the counter and the write.
      result =
        update_numbered(changeset, [order_number: "order"],
          check: fn -> ensure_order_editable(changeset, order) end
        )

      case result do
        {:ok, updated_order} ->
          Events.broadcast_order_updated(updated_order)
          {:ok, updated_order}

        error ->
          error
      end
    else
      {:error, :order_not_editable}
    end
  end

  @doc """
  Confirms an order.

  Takes a row lock on the order for the duration of the call and checks the
  transition against the order's stored status, not the struct's, so call it
  inside your own transaction only if holding that lock until commit is fine.

  Returns `{:ok, order}`, or `{:error, changeset}` when the stored status does
  not allow the transition.
  """
  def confirm_order(%Order{} = order) do
    case confirm_order_transition(order) do
      {:ok, confirmed_order} ->
        Events.broadcast_order_confirmed(confirmed_order)
        {:ok, confirmed_order}

      error ->
        error
    end
  end

  defp confirm_order_transition(order) do
    transition_order(order, fn current ->
      current
      |> Order.status_changeset("confirmed")
      |> repo().update()
    end)
  end

  @doc """
  Marks an order as paid.

  ## Options

  - `:payment_method` - The payment method used (e.g., "bank", "stripe", "paypal")

  Takes a row lock on the order for the duration of the call and checks the
  transition against the order's stored status, not the struct's, so call it
  inside your own transaction only if holding that lock until commit is fine.

  Returns `{:ok, order}`, `{:error, :order_not_payable}` when the stored status
  is not `"confirmed"`, or `{:error, changeset}`.
  """
  def mark_order_paid(%Order{} = order, opts \\ []) do
    case pay_order(order, opts) do
      {:ok, paid_order} ->
        Events.broadcast_order_paid(paid_order)
        {:ok, paid_order}

      error ->
        error
    end
  end

  defp pay_order(order, opts) do
    transition_order(order, fn current ->
      if Order.payable?(current) do
        changeset = Order.status_changeset(current, "paid")

        changeset =
          case opts[:payment_method] do
            nil -> changeset
            pm -> Ecto.Changeset.put_change(changeset, :payment_method, pm)
          end

        repo().update(changeset)
      else
        {:error, :order_not_payable}
      end
    end)
  end

  @doc """
  Marks an order as refunded.

  Takes a row lock on the order for the duration of the call and checks the
  transition against the order's stored status, not the struct's, so call it
  inside your own transaction only if holding that lock until commit is fine.

  Returns `{:ok, order}`, `{:error, :order_not_refundable}` when the stored
  status is not `"paid"`, or `{:error, changeset}`.
  """
  def mark_order_refunded(%Order{} = order) do
    case refund_order(order) do
      {:ok, refunded_order} ->
        Events.broadcast_order_refunded(refunded_order)
        {:ok, refunded_order}

      error ->
        error
    end
  end

  # The transition without the broadcast, for `record_refund/3`, which runs it
  # inside its transaction and sends the broadcast after the commit.
  defp refund_order(%Order{} = order) do
    transition_order(order, fn current ->
      if current.status == "paid" do
        current
        |> Order.status_changeset("refunded")
        |> repo().update()
      else
        {:error, :order_not_refundable}
      end
    end)
  end

  @doc """
  Cancels an order.

  A `reason` is appended to `internal_notes` as a line
  `"Cancelled <YYYY-MM-DD HH:MM UTC>: <reason>"`, after a blank line when there
  are notes already. `metadata["cancelled_from"]` always records the status the
  order had before the cancel, so an integration can tell an order cancelled
  straight from `"draft"` (never sent anywhere) from one cancelled after
  confirmation.

  ## Options

  - `:actor_uuid` - the user who cancels the order, kept in
    `metadata["cancelled_by_uuid"]`

  Takes a row lock on the order for the duration of the call and checks the
  transition against the order's stored status, not the struct's, so call it
  inside your own transaction only if holding that lock until commit is fine.
  The notes and metadata it appends to are the stored ones too.

  Returns `{:ok, order}`, `{:error, :order_not_cancellable}` when the stored
  status is not `"draft"`, `"pending"` or `"confirmed"`, or `{:error, changeset}`.
  """
  def cancel_order(%Order{} = order, reason \\ nil, opts \\ []) do
    result =
      transition_order(order, fn current ->
        if Order.cancellable?(current) do
          current
          |> Order.cancel_changeset(opts[:actor_uuid])
          |> put_reason_note("Cancelled", current.internal_notes, normalize_reason(reason))
          |> repo().update()
        else
          {:error, :order_not_cancellable}
        end
      end)

    case result do
      {:ok, cancelled_order} ->
        Events.broadcast_order_cancelled(cancelled_order)
        {:ok, cancelled_order}

      error ->
        error
    end
  end

  @doc """
  Reinstates a cancelled order: takes it back to the status it was cancelled
  from (`metadata["cancelled_from"]`; `"pending"` for an order cancelled before
  billing kept that trail - see `Order.reinstated_status/1`) and clears
  `cancelled_at`. `refunded` is final and is not reinstated.

  The trail goes into `metadata["reinstated"]` as `"status"`, `"reason"`
  (trimmed and cut like the `cancel_order/3` reason, `nil` when blank),
  `"by_uuid"` and `"at"`; the cancellation's own trail is kept. A reason is also
  appended to `internal_notes` as a line `"Reinstated <YYYY-MM-DD HH:MM UTC>:
  <reason>"`, after a blank line when there are notes already - what was there
  is never replaced. The revision moves on, so an external system takes the
  order again.

  An invoice of the order may have been paid while the order was cancelled
  (paying it does not move a cancelled order). Then the order does not stay at
  the status it went back to: it is confirmed (when it went back to `"draft"` or
  `"pending"`) and marked paid, in the same transaction, as a payment of the
  invoice would have done. A payment or a refund of the invoice that runs at
  the same time waits for the order row and then sees the reinstated order, so
  the order ends up paid (or refunded) whichever commits first.

  ## Options

  - `:actor_uuid` - the user who reinstates the order, kept in
    `metadata["reinstated"]["by_uuid"]`. Leave it out when the system does it
    (an integration that undoes a cancellation an external system refused).

  Takes a row lock on the order for the duration of the call and decides on
  the stored row, not the struct's, so of two concurrent calls one reinstates
  and the other is refused. An order in the trash is refused: restore it with
  `restore_order/2` first.

  Returns `{:ok, order}` (the order as it ends up), `{:error,
  :order_not_reinstatable}` when the stored status is not `"cancelled"`,
  `{:error, :order_trashed}`, or `{:error, changeset}`. Refusals are returned,
  not rolled back. On success an `:order_reinstated` event is broadcast, then
  `:order_confirmed` and `:order_paid` when a paid invoice settled the order.
  """
  def reinstate_order(%Order{} = order, reason \\ nil, opts \\ []) do
    reason = normalize_reason(reason)

    result =
      unwrap_transaction(fn ->
        with {:ok, reinstated} <- reinstate_order_transition(order, reason, opts) do
          {:ok, {reinstated, settle_reinstated_order(reinstated)}}
        end
      end)

    case result do
      {:ok, {reinstated, broadcasts}} ->
        Events.broadcast_order_reinstated(reinstated)
        Enum.each(broadcasts, fn {fun, arg} -> apply(Events, fun, [arg]) end)

        {:ok,
         case List.last(broadcasts) do
           {_fun, settled} -> settled
           nil -> reinstated
         end}

      error ->
        error
    end
  end

  defp reinstate_order_transition(order, reason, opts) do
    transition_order(order, fn current ->
      if current.status == "cancelled" do
        current
        |> Order.reinstate_changeset(opts[:actor_uuid], reason)
        |> put_reason_note("Reinstated", current.internal_notes, reason)
        |> repo().update()
      else
        {:error, :order_not_reinstatable}
      end
    end)
  end

  # Inside reinstate_order/3's transaction, with the order row locked: an
  # invoice paid while the order was cancelled settles it now, the way a payment
  # of it would have. Returns the broadcasts to send after the commit.
  #
  # The invoice is read, not locked (the order row is held, and the lock order
  # takes an invoice row before its order's). A payment that commits meanwhile
  # is not missed: paying an invoice reads its order's status under the order
  # row lock (`maybe_mark_linked_order_paid/1`), so it waits for this
  # transaction and then pays the order it reinstated; one that committed
  # before is seen here.
  defp settle_reinstated_order(%Order{uuid: uuid}) do
    paid_invoice =
      from(i in Invoice,
        where: i.order_uuid == ^uuid and i.status == "paid" and is_nil(i.trashed_at),
        order_by: [asc: i.paid_at],
        limit: 1
      )
      |> repo().one()

    if paid_invoice, do: maybe_mark_linked_order_paid(paid_invoice), else: []
  end

  defp put_reason_note(changeset, _label, _notes, nil), do: changeset

  defp put_reason_note(changeset, label, notes, reason) do
    line = "#{label} #{Calendar.strftime(UtilsDate.utc_now(), "%Y-%m-%d %H:%M UTC")}: #{reason}"

    note =
      case notes do
        blank when blank in [nil, ""] -> line
        existing -> existing <> "\n\n" <> line
      end

    Ecto.Changeset.put_change(changeset, :internal_notes, note)
  end

  # Runs a status transition against the order's CURRENT status. The guards
  # (`Order.payable?/1`, `Order.cancellable?/1`) and `Order.status_changeset/2`
  # read `status` off the struct they are handed, and the UPDATE filters on
  # the primary key only - so a struct read before another caller moved the
  # order would pass its check and overwrite that transition (a payment and a
  # cancellation both succeeding, the order ending `cancelled` with `paid_at`
  # set). The row is locked and its status re-read inside the transaction, and
  # `fun` gets the caller's struct with that status, so check and write are
  # one step. Same pattern as `lock_invoice_for_update/1`. The `internal_notes`
  # and `metadata` it hands over are the stored ones as well: a transition that
  # appends to them (`cancel_order/3`) must not append to what the caller read
  # minutes ago and so drop what was written since.
  #
  # Refusals are RETURNED, not rolled back: this runs inside the invoice-paid
  # transaction too (`maybe_mark_linked_order_paid/1`), where a rollback would
  # abort the whole settlement.
  #
  # An order in the trash changes in no way: that is read off the locked row as
  # well, and refused with `:order_trashed` before `fun` runs.
  defp transition_order(%Order{} = order, fun) when is_function(fun, 1) do
    unwrap_transaction(fn ->
      current = Map.merge(order, lock_order_row(order))

      if Order.trashed?(current), do: {:error, :order_trashed}, else: fun.(current)
    end)
  end

  # SELECT status, internal_notes, metadata, trashed_at ... FOR NO KEY UPDATE. That lock
  # queues transitions behind each other (it conflicts with itself and with
  # the UPDATE that follows) but not with the FOR KEY SHARE an invoice insert
  # takes on the order through its foreign key. A row that has vanished keeps
  # the caller's values, so the UPDATE that follows fails the way it always
  # did.
  defp lock_order_row(%Order{uuid: uuid}) do
    Order
    |> where([o], o.uuid == ^uuid)
    |> lock("FOR NO KEY UPDATE")
    |> select([o], map(o, [:status, :internal_notes, :metadata, :trashed_at]))
    |> repo().one()
    |> Kernel.||(%{})
  end

  @doc """
  Deletes an order (only drafts that have no invoice).

  The foreign key from an invoice to its order is `ON DELETE SET NULL`, so
  deleting the order would silently detach any invoice - even a void one -
  and lose what ties it to the order. An order with an invoice is refused.

  Takes a row lock on the order and checks the status against the stored row,
  not the struct's.

  Returns `{:ok, order}`, `{:error, :can_only_delete_drafts}`,
  `{:error, :order_has_invoices}`, `{:error, :order_trashed}` for an order in
  the trash, `{:error, :not_found}` when the order is gone, or
  `{:error, changeset}`. Refusals are returned, not rolled back, so a
  transaction of the caller's stays usable.
  """
  def delete_order(%Order{trashed_at: %DateTime{}}), do: {:error, :order_trashed}

  def delete_order(%Order{status: "draft", uuid: uuid} = order) do
    unwrap_transaction(fn ->
      # FOR UPDATE conflicts with the FOR KEY SHARE an invoice insert takes on
      # the order, so an invoice created while this runs either is seen below
      # or waits and then fails its foreign key - it is never detached. The
      # status is the stored one: the struct may be from before a confirmation.
      case Order |> where([o], o.uuid == ^uuid) |> lock("FOR UPDATE") |> repo().one() do
        nil -> {:error, :not_found}
        %Order{trashed_at: %DateTime{}} -> {:error, :order_trashed}
        %Order{status: "draft"} -> delete_draft_without_invoices(order)
        %Order{} -> {:error, :can_only_delete_drafts}
      end
    end)
  end

  def delete_order(_order), do: {:error, :can_only_delete_drafts}

  # Inside delete_order/1's transaction, with the order row locked.
  defp delete_draft_without_invoices(%Order{uuid: uuid} = order) do
    if repo().exists?(from(i in Invoice, where: i.order_uuid == ^uuid)) do
      {:error, :order_has_invoices}
    else
      repo().delete(order)
    end
  end

  @doc """
  Moves an order to the trash.

  Only a `draft` or `cancelled` order goes there, and only while none of its
  invoices is open - an invoice that is neither void nor in the trash. The status
  does not change, nothing is emailed, and nothing is deleted: `restore_order/2`
  brings it back.

  ## Options

  - `:actor_uuid` - the user who does it, kept in `trashed_by_uuid`
  - `:reason` - why, optional. Cut like the `cancel_order/3` reason, and appended
    to `internal_notes` (the stored ones) as a line
    `"Trashed <YYYY-MM-DD HH:MM UTC>: <reason>"`, after a blank line when there
    are notes already, in the same write as the trash fields. Without one, or
    with a blank one, the notes are not touched. `updated_at` is not touched
    either way; the revision moves (see `Order`'s moduledoc), and so it does on
    `restore_order/2`.

  Takes a row lock on the order and decides on the stored row, not the struct's:
  the order may have been confirmed, or been given an invoice, since it was read.
  The lock also keeps an invoice from being created for the order while this
  runs.

  Returns `{:ok, order}` (without the preloads of the struct passed in),
  `{:error, :order_not_trashable}` (status other than `draft` or `cancelled`),
  `{:error, :order_has_open_invoices}`, `{:error, :already_trashed}` or
  `{:error, :not_found}` when the order is gone. Refusals are returned, not
  rolled back, so a transaction of the caller's stays usable. On success an
  `:order_trashed` event is broadcast (after the transaction, unless it is the
  caller's); the other order events are not.
  """
  def trash_order(%Order{uuid: uuid}, opts \\ []) do
    result =
      unwrap_transaction(fn ->
        # FOR UPDATE conflicts with the FOR KEY SHARE an invoice insert takes on
        # the order, so an invoice created while this runs is either seen below
        # or waits and then finds the order in the trash.
        case lock_order_for_update(uuid) do
          nil -> {:error, :not_found}
          %Order{} = locked -> trash_locked_order(locked, opts)
        end
      end)

    case result do
      {:ok, trashed} ->
        Events.broadcast_order_trashed(trashed)
        {:ok, trashed}

      error ->
        error
    end
  end

  defp trash_locked_order(locked, opts) do
    cond do
      Order.trashed?(locked) ->
        {:error, :already_trashed}

      not Order.trashable?(locked) ->
        {:error, :order_not_trashable}

      open_invoices?(locked.uuid) ->
        {:error, :order_has_open_invoices}

      true ->
        locked
        |> Order.trash_changeset(opts[:actor_uuid])
        |> put_reason_note("Trashed", locked.internal_notes, normalize_reason(opts[:reason]))
        |> repo().update()
    end
  end

  # An invoice counts against its order until it is void or in the trash.
  defp open_invoices?(order_uuid) do
    repo().exists?(
      from(i in Invoice,
        where: i.order_uuid == ^order_uuid and i.status != "void" and is_nil(i.trashed_at)
      )
    )
  end

  @doc """
  Takes an order out of the trash. Nothing else about it changes.

  Takes a row lock on the order and decides on the stored row. The options are
  accepted for symmetry with `trash_order/2` and not used.

  Returns `{:ok, order}` (without the preloads of the struct passed in),
  `{:error, :not_trashed}` or `{:error, :not_found}` when the order is gone.
  Refusals are returned, not rolled back. On success an `:order_restored` event
  is broadcast.
  """
  def restore_order(%Order{uuid: uuid}, _opts \\ []) do
    result =
      unwrap_transaction(fn ->
        case lock_order_for_update(uuid) do
          nil ->
            {:error, :not_found}

          %Order{} = locked ->
            if Order.trashed?(locked),
              do: locked |> Order.restore_changeset() |> repo().update(),
              else: {:error, :not_trashed}
        end
      end)

    case result do
      {:ok, restored} ->
        Events.broadcast_order_restored(restored)
        {:ok, restored}

      error ->
        error
    end
  end

  defp lock_order_for_update(uuid) do
    Order |> where([o], o.uuid == ^uuid) |> lock("FOR UPDATE") |> repo().one()
  end

  # Before a write to an order, on the locked row: the order may have gone to
  # the trash, or been moved on (cancelled, confirmed, paid), since the caller
  # read it. A stored order is edited only while it is a draft or pending, and a
  # status change asked for is judged against the stored status: the changeset
  # checked it against the struct's, and a struct that is behind could otherwise
  # undo a cancellation. A change of the number takes the row `FOR UPDATE`
  # straight away - that is what the write would take anyway, as the number has a
  # unique index - and any other change `FOR NO KEY UPDATE`, like
  # `lock_order_row/1`. Either way before the number counter is touched.
  defp ensure_order_editable(changeset, %Order{uuid: uuid, status: read_status}) do
    query = from(o in Order, where: o.uuid == ^uuid, select: map(o, [:status, :trashed_at]))

    stored =
      if Map.has_key?(changeset.changes, :order_number),
        do: query |> lock("FOR UPDATE") |> repo().one(),
        else: query |> lock("FOR NO KEY UPDATE") |> repo().one()

    cond do
      is_nil(stored) ->
        :ok

      stored.trashed_at ->
        {:error, :order_trashed}

      stored.status not in ~w(draft pending) ->
        {:error, :order_not_editable}

      Map.has_key?(changeset.changes, :status) and stored.status != read_status ->
        {:error, :order_not_editable}

      true ->
        :ok
    end
  end

  @order_sync_types %{
    state: :string,
    revision: :integer,
    external_id: :string,
    external_number: :string,
    external_status: :string,
    error: :string
  }

  @doc """
  Records an external system's mark on an order, in any status.

  Writes only `metadata["sync"]`: the status, the amounts, `updated_at` and
  `metadata["revision"]` are not touched, and no order event is broadcast, so
  the mark does not make the order look changed. The row is locked while the
  mark is checked and written.

  `order` is an `Order` or its uuid. `attrs` takes (atom or string keys):

    * `:state` (required) - `"synced"` or `"failed"`
    * `:revision` (required) - the revision of the order the external system
      took (see `PhoenixKitBilling.Order.revision/1`). When it is no longer the
      order's current revision, nothing is written and `{:error, :stale_revision}`
      comes back: the order changed after it was read. A mark with no revision
      could land on a revision the external system never saw, so it is refused
      as invalid.
    * `:external_id`, `:external_number`, `:external_status` - what the external
      system calls the order. A key left out keeps the stored value, so a
      `"failed"` mark on an order taken earlier does not forget its id.
    * `:error` - why the external system refused it; kept only with `"failed"`.

  A mark belongs to the revision it was written for: once the order changes,
  `PhoenixKitBilling.Order.sync/1` reports it as `"pending"` again.

  Returns `{:ok, order}`, `{:error, :not_found}`, `{:error, :stale_revision}`
  or `{:error, changeset}` for invalid `attrs`. Repeating a call with the same
  `attrs` leaves the stored mark as it is.
  """
  @spec put_order_sync(Order.t() | String.t(), map()) ::
          {:ok, Order.t()} | {:error, :not_found | :stale_revision | Ecto.Changeset.t()}
  def put_order_sync(%Order{uuid: uuid}, attrs), do: put_order_sync(uuid, attrs)

  def put_order_sync(uuid, attrs) when is_binary(uuid) and is_map(attrs) do
    with {:ok, params} <- order_sync_params(attrs),
         true <- UUIDUtils.valid?(uuid) || {:error, :not_found} do
      repo().transaction(fn ->
        case write_order_sync(uuid, params) do
          :ok -> get_order(uuid)
          {:error, reason} -> repo().rollback(reason)
        end
      end)
    end
  end

  defp order_sync_params(attrs) do
    changeset =
      {%{}, @order_sync_types}
      |> Ecto.Changeset.cast(
        Map.new(attrs, fn {k, v} -> {to_string(k), v} end),
        Map.keys(@order_sync_types)
      )
      |> Ecto.Changeset.validate_required([:state, :revision])
      |> Ecto.Changeset.validate_inclusion(:state, ~w(synced failed))
      |> Ecto.Changeset.validate_number(:revision, greater_than: 0)
      |> Ecto.Changeset.validate_length(:external_id, max: 255)
      |> Ecto.Changeset.validate_length(:external_number, max: 255)
      |> Ecto.Changeset.validate_length(:external_status, max: 255)
      |> Ecto.Changeset.validate_length(:error, max: 2000)

    if changeset.valid?,
      do: {:ok, Ecto.Changeset.apply_changes(changeset)},
      else: {:error, changeset}
  end

  defp write_order_sync(uuid, params) do
    # NO KEY UPDATE, like `lock_order_row/1`: it queues behind every other
    # writer of the row but not behind the FOR KEY SHARE an invoice insert
    # takes on it through its foreign key.
    order = Order |> where([o], o.uuid == ^uuid) |> lock("FOR NO KEY UPDATE") |> repo().one()
    current = order && Order.revision(order)

    cond do
      is_nil(order) ->
        {:error, :not_found}

      params.revision != current ->
        {:error, :stale_revision}

      true ->
        sync = order_sync_mark(order.metadata["sync"], params)

        {1, _} =
          Order
          |> where([o], o.uuid == ^uuid)
          |> update([o],
            set: [
              metadata:
                fragment(
                  "jsonb_set(coalesce(?, '{}'::jsonb), '{sync}', ?, true)",
                  o.metadata,
                  type(^sync, :map)
                )
            ]
          )
          |> repo().update_all([])

        :ok
    end
  end

  defp order_sync_mark(stored, params) do
    stored = if is_map(stored), do: stored, else: %{}

    given =
      for key <- [:external_id, :external_number, :external_status],
          value = params[key],
          into: %{},
          do: {Atom.to_string(key), value}

    mark =
      stored
      |> Map.take(["external_id", "external_number", "external_status", "synced_at"])
      |> Map.merge(given)
      |> Map.merge(%{"state" => params.state, "revision" => params.revision})
      |> put_order_sync_error(params)

    cond do
      Map.reject(mark, &nil_value?/1) == Map.reject(stored, &nil_value?/1) -> stored
      params.state == "synced" -> Map.put(mark, "synced_at", now_iso())
      true -> mark
    end
  end

  defp put_order_sync_error(mark, %{state: "failed", error: error}) when is_binary(error),
    do: Map.put(mark, "error", error)

  defp put_order_sync_error(mark, _params), do: mark

  defp nil_value?({_key, value}), do: is_nil(value)

  defp now_iso, do: DateTime.to_iso8601(UtilsDate.utc_now())

  # -- the trash ---------------------------------------------------------------

  # What a listing does with the trash: `trashed: :only | :include` in its
  # filters or options, anything else (or nothing) leaves the trash out.
  defp trashed_option(opts) do
    Enum.find_value(opts, :exclude, fn
      {:trashed, mode} when mode in [:only, :include] -> mode
      _ -> nil
    end)
  end

  defp scope_trashed(query, :only), do: where(query, [r], not is_nil(r.trashed_at))
  defp scope_trashed(query, :include), do: query
  defp scope_trashed(query, _exclude), do: not_trashed(query)

  # Leaves the trash out of a query over orders or invoices.
  defp not_trashed(query), do: where(query, [r], is_nil(r.trashed_at))

  # Newest first; in the trash, the one trashed last first.
  defp order_listing(query, :only),
    do: order_by(query, [r], desc: r.trashed_at, desc: r.inserted_at)

  defp order_listing(query, _trashed), do: order_by(query, [r], desc: r.inserted_at)

  # The invoices of an order that a customer may see: not the ones in the trash.
  defp without_trashed_invoices(preloads) do
    preloads
    |> List.wrap()
    |> Enum.map(fn
      :invoices -> {:invoices, not_trashed(Invoice)}
      {:invoices, %Ecto.Query{}} = preload -> preload
      {:invoices, {%Ecto.Query{}, _nested}} = preload -> preload
      {:invoices, nested} -> {:invoices, {not_trashed(Invoice), nested}}
      other -> other
    end)
  end

  defp apply_order_filters(query, filters) do
    query = scope_trashed(query, trashed_option(filters))

    Enum.reduce(filters, query, fn
      {:status, status}, q when is_binary(status) ->
        where(q, [o], o.status == ^status)

      {:statuses, statuses}, q when is_list(statuses) ->
        where(q, [o], o.status in ^statuses)

      {:from_date, date}, q ->
        where(q, [o], o.inserted_at >= ^date)

      {:to_date, date}, q ->
        where(q, [o], o.inserted_at <= ^date)

      _, q ->
        q
    end)
  end

  defp maybe_set_default_currency(attrs) do
    # Check both atom and string keys
    if Map.has_key?(attrs, :currency) || Map.has_key?(attrs, "currency") do
      attrs
    else
      # §3.3: base = is_default row. No literal fallback: an order created
      # with no default currency configured at all should fail its
      # changeset loudly (currency is required, §7.3), not silently land
      # on a made-up code.
      Map.put(attrs, "currency", base_currency_code())
    end
  end

  defp maybe_set_billing_snapshot(attrs) do
    # Check both atom and string keys
    profile_uuid = Map.get(attrs, :billing_profile_uuid) || Map.get(attrs, "billing_profile_uuid")

    case profile_uuid do
      nil ->
        attrs

      "" ->
        attrs

      uuid ->
        # NON-raising: this runs inside create_order/2, itself inside the
        # shop's conversion transaction. A raise here escapes the caller's
        # `with`/`else` (exceptions are not matched by else), propagates out
        # of the transaction and takes the checkout LiveView down - a
        # disconnect on the money path rather than a handled error. The
        # window is small (an admin deleting a profile between the shop's
        # ownership check and this lookup) but the failure mode is the worst
        # kind.
        case get_billing_profile(uuid) do
          nil ->
            {:error, :billing_profile_not_found}

          profile ->
            attrs
            |> Map.put("billing_snapshot", BillingProfile.to_snapshot(profile))
            |> Map.put("billing_profile_uuid", profile.uuid)
        end
    end
  end

  # Updates billing_snapshot if billing_profile_uuid changed or snapshot is empty
  defp maybe_update_billing_snapshot(%Order{} = order, attrs) do
    new_profile_uuid =
      Map.get(attrs, :billing_profile_uuid) || Map.get(attrs, "billing_profile_uuid")

    cond do
      # No billing_profile_uuid in attrs - no change
      is_nil(new_profile_uuid) ->
        attrs

      # Empty string means clearing the profile
      new_profile_uuid == "" ->
        attrs
        |> Map.put("billing_snapshot", %{})
        |> Map.put("billing_profile_uuid", nil)

      # Profile UUID present - update snapshot if changed or empty
      true ->
        profile = get_billing_profile(new_profile_uuid)

        snapshot_empty? = is_nil(order.billing_snapshot) || order.billing_snapshot == %{}

        cond do
          # The profile vanished between the caller reading it and this
          # lookup - leave the attrs alone rather than raising out of the
          # caller's transaction.
          is_nil(profile) ->
            attrs

          # An empty snapshot is always filled: there is no history to
          # protect, and rendering nothing is worse than rendering the
          # profile.
          snapshot_empty? ->
            put_snapshot(attrs, profile)

          profile.uuid != order.billing_profile_uuid and snapshot_refreshable?(order) ->
            put_snapshot(attrs, profile)

          true ->
            # Frozen: keep the address the order was billed to, and do not
            # let a later profile switch rewrite it.
            Map.delete(attrs, "billing_snapshot")
        end
    end
  end

  defp put_snapshot(attrs, profile) do
    attrs
    |> Map.put("billing_snapshot", BillingProfile.to_snapshot(profile))
    |> Map.put("billing_profile_uuid", profile.uuid)
  end

  @doc """
  Whether an order's billing snapshot may still be refreshed from the live
  profile.

  The snapshot is the record of who an order was billed to, so rewriting it
  after the fact makes history mutable. The line is drawn at money changing
  hands:

    * `"draft"` / `"pending"` — refreshable
    * `"confirmed"` / `"paid"` / `"refunded"` / `"cancelled"` — frozen

  Operators who want the stricter or looser rule set
  `billing_snapshot_policy` to `"never"` (freeze from creation) or
  `"always"` (the pre-2026-08 behaviour, refresh whenever the order's profile
  changes). Fails closed to the default on a settings-layer error.

  > #### Scope {: .info}
  >
  > This governs a **profile SWITCH** — the order pointing at a different
  > billing profile than before. Editing the fields of the profile an order
  > already points at never refreshes the snapshot, at any status or policy;
  > `maybe_update_billing_snapshot/2` only reconsiders when the incoming
  > `billing_profile_uuid` differs (or the snapshot is empty). Refreshing on
  > in-place profile edits would need the snapshot compared field by field,
  > which is not implemented.
  """
  def snapshot_refreshable?(%Order{status: status}) do
    case snapshot_policy() do
      "never" -> false
      "always" -> true
      _pending_only -> status in ["draft", "pending"]
    end
  end

  @doc "The configured snapshot-refresh policy: pending_only | never | always."
  def snapshot_policy do
    case PhoenixKit.Settings.get_setting_cached("billing_snapshot_policy", "pending_only") do
      value when value in ["pending_only", "never", "always"] -> value
      _ -> "pending_only"
    end
  rescue
    _ -> "pending_only"
  end

  # ============================================
  # INVOICES
  # ============================================

  @doc """
  Lists all invoices with optional filters.

  Invoices in the trash are left out. `trashed: :only` lists just the trash,
  `trashed: :include` both.
  """
  def list_invoices(filters \\ %{}) do
    Invoice
    |> apply_invoice_filters(filters)
    |> order_by([i], desc: i.inserted_at)
    |> preload([:order])
    |> repo().all()
  end

  @doc """
  Lists invoices for a specific user.

  Accepts the shared invoice filters, including `:limit` for callers that
  only need the most recent few (rollup panels) and must not pull a
  long-standing customer's entire invoice history into memory. Invoices in the
  trash are left out unless `trashed: :include` or `trashed: :only` says
  otherwise.
  """
  def list_user_invoices(user_uuid, filters \\ %{}) do
    user_uuid = extract_user_uuid(user_uuid)

    Invoice
    |> where([i], i.user_uuid == ^user_uuid)
    |> apply_invoice_filters(filters)
    |> order_by([i], desc: i.inserted_at)
    |> repo().all()
  end

  @doc """
  Lists invoices with count for pagination.

  Invoices in the trash are left out, and not counted. `trashed: :only` lists
  just the trash (the one trashed last first), `trashed: :include` both.
  """
  def list_invoices_with_count(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    offset = (page - 1) * per_page
    search = Keyword.get(opts, :search)
    status = Keyword.get(opts, :status)
    trashed = trashed_option(opts)

    base_query = scope_trashed(Invoice, trashed)

    base_query =
      case status do
        nil -> base_query
        status -> where(base_query, [i], i.status == ^status)
      end

    base_query =
      case search do
        nil ->
          base_query

        "" ->
          base_query

        search ->
          search_term = "%#{search}%"

          base_query
          |> join(:left, [i], u in assoc(i, :user))
          |> where(
            [i, u],
            ilike(i.invoice_number, ^search_term) or
              ilike(u.email, ^search_term)
          )
      end

    total = repo().aggregate(base_query, :count, :uuid)

    preloads = Keyword.get(opts, :preload, [:order])

    invoices =
      base_query
      |> order_listing(trashed)
      |> limit(^per_page)
      |> offset(^offset)
      |> preload(^preloads)
      |> repo().all()

    {invoices, total}
  end

  @doc """
  Gets an invoice by ID or UUID.
  """
  def get_invoice!(id) do
    case get_invoice(id) do
      nil -> raise Ecto.NoResultsError, queryable: Invoice
      invoice -> invoice
    end
  end

  @doc """
  Gets an invoice by ID or UUID with optional preloads.
  """
  def get_invoice(id, opts \\ [])

  def get_invoice(id, opts) when is_binary(id) do
    preloads = Keyword.get(opts, :preload, [:order])

    if UUIDUtils.valid?(id) do
      Invoice
      |> where([i], i.uuid == ^id)
      |> preload(^preloads)
      |> repo().one()
    else
      nil
    end
  end

  def get_invoice(_, _opts), do: nil

  @doc """
  Lists invoices for a specific order.

  Invoices in the trash are left out; `trashed: :only` lists just those,
  `trashed: :include` all of them.
  """
  def list_invoices_for_order(order_uuid, opts \\ []) when is_binary(order_uuid) do
    Invoice
    |> scope_trashed(trashed_option(opts))
    |> where([i], i.order_uuid == ^order_uuid)
    |> order_by([i], desc: i.inserted_at)
    |> repo().all()
  end

  @doc """
  Gets an invoice by invoice number.
  """
  def get_invoice_by_number(invoice_number) do
    Invoice
    |> where([i], i.invoice_number == ^invoice_number)
    |> preload([:order])
    |> repo().one()
  end

  @doc """
  Creates an invoice from an order.

  Returns `{:error, :order_trashed}` for an order in the trash and
  `{:error, :order_cancelled}` for a cancelled one (checked on the stored row,
  and returned as values: your transaction stays usable).

  #{@create_note}
  """
  def create_invoice_from_order(order, opts \\ [])

  def create_invoice_from_order(%Order{trashed_at: %DateTime{}}, _opts),
    do: {:error, :order_trashed}

  def create_invoice_from_order(%Order{} = order, opts) do
    config = get_config()

    opts =
      opts
      |> Keyword.put_new(:due_days, config.invoice_due_days)
      |> Keyword.put_new(:bank_details, get_bank_details())
      |> Keyword.put_new(:payment_terms, get_payment_terms())

    source =
      if Keyword.has_key?(opts, :invoice_number),
        do: {:supplied, opts[:invoice_number]},
        else: :generate

    build = fn number ->
      opts = if source == :generate, do: Keyword.put(opts, :invoice_number, number), else: opts
      order |> Invoice.from_order(opts) |> Invoice.changeset(%{})
    end

    insert_invoice(build, config, source, order.uuid)
  end

  # The PubSub event goes out after the transaction that inserts the invoice
  # has ended - the commit, unless the caller's own transaction encloses this
  # call.
  #
  # An invoice of an order that is in the trash or cancelled is refused
  # (`:order_trashed`, `:order_cancelled`), checked in the insert's transaction
  # with the order row locked (see `ensure_order_takes_invoice/1`).
  defp insert_invoice(build, config, source, order_uuid) do
    guard = fn -> ensure_order_takes_invoice(order_uuid) end

    case insert_numbered(build, "invoice", config.invoice_prefix, :invoice_number, source, guard) do
      {:ok, created_invoice} ->
        Events.broadcast_invoice_created(created_invoice)
        {:ok, created_invoice}

      error ->
        error
    end
  end

  @doc """
  Creates a standalone invoice (without order).

  With an `order_uuid` it is held to the same rule as `create_invoice_from_order/2`:
  `{:error, :order_trashed}` or `{:error, :order_cancelled}` when the order cannot
  take an invoice.

  #{@create_note}
  """
  def create_invoice(user_or_uuid, attrs) do
    user_uuid = extract_user_uuid(user_or_uuid)
    config = get_config()

    # Keys of the style the caller used (a changeset refuses a map with both).
    string_keyed? = string_keyed?(attrs)
    key = fn name -> if string_keyed?, do: Atom.to_string(name), else: name end
    attrs = Map.put(attrs, key.(:user_uuid), user_uuid)

    {source, attrs} = number_source(attrs, :invoice_number, key.(:invoice_number))

    build = fn number ->
      attrs = if number, do: Map.put(attrs, key.(:invoice_number), number), else: attrs
      Invoice.changeset(%Invoice{}, attrs)
    end

    order_uuid = Map.get(attrs, :order_uuid) || Map.get(attrs, "order_uuid")
    insert_invoice(build, config, source, order_uuid)
  end

  # The order an invoice is created for, moved onto or restored onto must be able
  # to take it:
  # not in the trash, not cancelled. Checked in the transaction that writes the
  # invoice, with the order row locked `FOR KEY SHARE` - what the invoice's
  # foreign key takes on the order anyway. That conflicts with the `FOR UPDATE`
  # of `trash_order/2`, so an order is trashed before this looks (and the invoice
  # is refused) or after the invoice is in (and the trash is refused), never in
  # between. The lock is taken BEFORE the invoice counter; see "Lock order" in
  # the `PhoenixKitBilling.Migrations` moduledoc.
  defp ensure_order_takes_invoice(order_uuid) do
    case lock_order_state(order_uuid) do
      %{trashed_at: %DateTime{}} -> {:error, :order_trashed}
      %{status: "cancelled"} -> {:error, :order_cancelled}
      _ -> :ok
    end
  end

  # `nil` for no order, an invalid uuid or an order that is gone (the invoice's
  # foreign key then says what is wrong).
  defp lock_order_state(order_uuid) do
    if is_binary(order_uuid) and UUIDUtils.valid?(order_uuid) do
      from(o in Order,
        where: o.uuid == ^order_uuid,
        lock: "FOR KEY SHARE",
        select: map(o, [:status, :trashed_at])
      )
      |> repo().one()
    end
  end

  defp string_keyed?(attrs), do: attrs |> Map.keys() |> Enum.any?(&is_binary/1)

  # Whether the caller supplied the number, and the attrs to build from: a number
  # under either key counts (the atom key first), a nil or blank one does not -
  # the number is generated and no key of it is left behind. A supplied number
  # is kept under `key`, the style the rest of the attrs use.
  defp number_source(attrs, field, key) do
    names = [field, Atom.to_string(field)]
    rest = Map.drop(attrs, names)

    case names |> Enum.map(&Map.get(attrs, &1)) |> Enum.find(&(not blank_number?(&1))) do
      nil -> {:generate, rest}
      supplied -> {{:supplied, supplied}, Map.put(rest, key, supplied)}
    end
  end

  defp blank_number?(nil), do: true
  defp blank_number?(number) when is_binary(number), do: String.trim(number) == ""
  defp blank_number?(_number), do: false

  @doc """
  Updates a draft invoice.

  Takes a row lock on the invoice and checks that it is still a draft on the
  stored row, not the struct's. The status is not editable here (see
  `Invoice.changeset/2`).

  A new `invoice_number` or `receipt_number` of this year's shape with the
  configured prefix (`PREFIX-YYYY-NNNN`) lifts the year's counter for it to at
  least its NNNN, so the counter never reaches it (invoice row first, then the
  counter - see "Lock order" in the `PhoenixKitBilling.Migrations` moduledoc).

  Returns `{:ok, invoice}`, `{:error, :invoice_not_editable}`,
  `{:error, :invoice_trashed}` for an invoice in the trash,
  `{:error, :order_trashed}` / `{:error, :order_cancelled}` when the edit moves
  it onto an order that cannot take an invoice,
  `{:error, :invoice_not_found}` or `{:error, changeset}`. Refusals are
  returned, not rolled back, so a transaction of the caller's stays usable.
  """
  def update_invoice(%Invoice{} = invoice, attrs) do
    unwrap_transaction(fn ->
      case fetch_locked_invoice(invoice) do
        nil ->
          {:error, :invoice_not_found}

        %Invoice{trashed_at: %DateTime{}} ->
          {:error, :invoice_trashed}

        locked ->
          if Invoice.editable?(locked) do
            changeset = Invoice.changeset(locked, attrs)

            update_numbered(changeset, [invoice_number: "invoice", receipt_number: "receipt"],
              check: fn -> ensure_relinked_order_takes_invoice(changeset) end
            )
          else
            {:error, :invoice_not_editable}
          end
      end
    end)
  end

  # An edit that moves the invoice onto another order is held to the rule for a
  # new invoice: the order must be able to take it.
  defp ensure_relinked_order_takes_invoice(changeset) do
    case Ecto.Changeset.get_change(changeset, :order_uuid) do
      nil -> :ok
      order_uuid -> ensure_order_takes_invoice(order_uuid)
    end
  end

  # Runs `fun` in a transaction and returns what it returned. For functions
  # that report a refusal as a value: nothing has been written when they do,
  # and a rollback would doom a transaction the caller may be holding.
  defp unwrap_transaction(fun) do
    case repo().transaction(fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Moves a draft invoice to the trash.

  Only a `draft` that was never sent goes there; an issued invoice is voided
  (`void_invoice/3`), never trashed. The status does not change, nothing is
  emailed, and nothing is deleted - **the invoice's number stays used**, so it is
  never handed out again. `restore_invoice/2` brings the invoice back.

  ## Options

  - `:actor_uuid` - the user who does it, kept in `trashed_by_uuid`

  Takes a row lock on the invoice and decides on the stored row, not the
  struct's: the invoice may have been sent or voided since it was read.

  Returns `{:ok, invoice}` (without the preloads of the struct passed in),
  `{:error, :invoice_not_trashable}`, `{:error, :already_trashed}` or
  `{:error, :invoice_not_found}`. Refusals are returned, not rolled back, so a
  transaction of the caller's stays usable. On success an `:invoice_trashed`
  event is broadcast (after the transaction, unless it is the caller's); no
  durable `PhoenixKitBilling.InvoiceEvents` event is enqueued.
  """
  def trash_invoice(%Invoice{} = invoice, opts \\ []) do
    result =
      unwrap_transaction(fn ->
        case fetch_locked_invoice(invoice) do
          nil -> {:error, :invoice_not_found}
          locked -> trash_locked_invoice(locked, opts[:actor_uuid])
        end
      end)

    case result do
      {:ok, trashed} ->
        Events.broadcast_invoice_trashed(trashed)
        {:ok, trashed}

      error ->
        error
    end
  end

  defp trash_locked_invoice(locked, actor_uuid) do
    cond do
      Invoice.trashed?(locked) -> {:error, :already_trashed}
      not Invoice.trashable?(locked) -> {:error, :invoice_not_trashable}
      true -> locked |> Invoice.trash_changeset(actor_uuid) |> repo().update()
    end
  end

  @doc """
  Takes an invoice out of the trash. Nothing else about it changes.

  Takes a row lock on the invoice, and then on its order, and decides on the
  stored rows. A restored invoice is open again, so its order is held to the rule
  for a new invoice: an order in the trash has no open invoice, and a cancelled
  one takes none, so an invoice trashed from a cancelled order stays in the trash
  until the order is reinstated (`reinstate_order/3`; its number stays used).

  Returns `{:ok, invoice}` (without the preloads of the struct passed in),
  `{:error, :not_trashed}`, `{:error, :order_trashed}` when its order is in the
  trash, `{:error, :order_cancelled}` when it is cancelled or
  `{:error, :invoice_not_found}`. Refusals are returned, not rolled
  back. On success an `:invoice_restored` event is broadcast. The options are
  accepted for symmetry with `trash_invoice/2` and not used.
  """
  def restore_invoice(%Invoice{} = invoice, _opts \\ []) do
    result =
      unwrap_transaction(fn ->
        case fetch_locked_invoice(invoice) do
          nil ->
            {:error, :invoice_not_found}

          locked ->
            with true <- Invoice.trashed?(locked) || {:error, :not_trashed},
                 :ok <- ensure_order_takes_invoice(locked.order_uuid) do
              locked |> Invoice.restore_changeset() |> repo().update()
            end
        end
      end)

    case result do
      {:ok, restored} ->
        Events.broadcast_invoice_restored(restored)
        {:ok, restored}

      error ->
        error
    end
  end

  @doc """
  Sends an invoice (marks as sent and sends email).

  Options:
  - `:send_email` - Whether to send email (default: true)
  - `:invoice_url` - URL to view invoice online (optional)

  Returns `{:ok, invoice, email_result}` on success — the status/history
  update always commits independently of the email, so it's never folded
  into `{:error, _}`. `email_result` is `:skipped` when `:send_email` is
  `false`, otherwise whatever `send_invoice_email/2` returned — check it
  if the caller cares whether the customer was actually emailed, not
  just whether the invoice record itself updated.

  An invoice in the trash is refused with `{:error, :invoice_trashed}`, and
  nobody is emailed.
  """
  def send_invoice(invoice, opts \\ [])

  def send_invoice(%Invoice{trashed_at: %DateTime{}}, _opts), do: {:error, :invoice_trashed}

  def send_invoice(%Invoice{} = invoice, opts) do
    if Invoice.sendable?(invoice) or Invoice.resendable?(invoice) do
      do_send_invoice(invoice, opts)
    else
      {:error, :invoice_not_sendable}
    end
  end

  defp do_send_invoice(invoice, opts) do
    send_email? = Keyword.get(opts, :send_email, true)
    to_email = Keyword.get(opts, :to_email)

    # Preload user if not loaded
    invoice = ensure_preloaded(invoice, [:order, :user])

    # Determine recipient email
    recipient_email = to_email || invoice_recipient(invoice)

    if is_nil(recipient_email) do
      {:error, :no_recipient_email}
    else
      case record_invoice_sent(invoice, recipient_email) do
        {:ok, updated_invoice} ->
          updated_invoice = ensure_preloaded(updated_invoice, [:order, :user])

          # Broadcast invoice sent event
          Events.broadcast_invoice_sent(updated_invoice)

          # Send email if requested. The status/metadata update above
          # already committed - that part of "send invoice" genuinely
          # succeeded regardless of what happens next - so this can't
          # become part of an {:error, _} return without misreporting a
          # real, committed change as a failure. The email outcome is
          # carried as a third element instead: {:ok, invoice, :skipped}
          # when send_email? is false, otherwise whatever
          # send_invoice_email/2 returned, most importantly
          # {:error, :emails_module_not_installed} when that's what
          # happened - see B003. Callers that only need to know "did the
          # billing operation succeed" keep matching on {:ok, invoice, _};
          # callers that also care whether the customer was actually
          # emailed check the third element.
          email_result =
            if send_email? do
              send_invoice_email(updated_invoice, Keyword.put(opts, :to_email, recipient_email))
            else
              :skipped
            end

          {:ok, updated_invoice, email_result}

        error ->
          error
      end
    end
  end

  # The status change and the history entry, written on the LOCKED row. The
  # caller's struct may be minutes old: a void committed since must not be
  # undone by a send built from it ("sent" over "void", the void trail gone),
  # and the history is appended to what is stored, not to what was read. The
  # email goes out only after this has committed, so a refused send mails
  # nobody.
  defp record_invoice_sent(invoice, recipient_email) do
    unwrap_transaction(fn ->
      case fetch_locked_invoice(invoice) do
        nil ->
          {:error, :invoice_not_found}

        locked ->
          with {:ok, changeset} <- send_changeset(locked) do
            send_entry = %{
              "sent_at" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
              "email" => recipient_email
            }

            metadata = locked.metadata || %{}
            history = Map.get(metadata, "send_history", []) ++ [send_entry]

            changeset
            |> Ecto.Changeset.put_change(:metadata, Map.put(metadata, "send_history", history))
            |> repo().update()
          end
      end
    end)
  end

  defp send_changeset(locked) do
    cond do
      Invoice.trashed?(locked) -> {:error, :invoice_trashed}
      # First send - change status to "sent"
      Invoice.sendable?(locked) -> {:ok, Invoice.status_changeset(locked, "sent")}
      # Resend - don't change status, just record in history
      Invoice.resendable?(locked) -> {:ok, Ecto.Changeset.change(locked)}
      true -> {:error, :invoice_not_sendable}
    end
  end

  @doc """
  Sends invoice email to the customer.
  """
  def send_invoice_email(invoice, opts \\ [])

  def send_invoice_email(%Invoice{trashed_at: %DateTime{}}, _opts), do: {:error, :invoice_trashed}

  def send_invoice_email(%Invoice{} = invoice, opts) do
    # Preload user if not loaded
    invoice = ensure_preloaded(invoice, [:order, :user])

    # Use to_email from opts, or fall back to user email
    to_email = Keyword.get(opts, :to_email)
    recipient_email = to_email || invoice_recipient(invoice)

    case recipient_email do
      nil ->
        {:error, :no_recipient_email}

      email ->
        user = invoice.user
        variables = build_invoice_email_variables(invoice, user, opts)

        send_email_if_available(
          "billing_invoice",
          email,
          variables,
          email_send_opts("billing_invoice", variables, user, %{
            invoice_uuid: invoice.uuid,
            invoice_number: invoice.invoice_number
          })
        )
    end
  end

  @doc """
  Sends receipt for a paid invoice.

  Options:
  - `:send_email` - Whether to send email (default: true)
  - `:to_email` - Override recipient email address
  - `:receipt_url` - URL to view receipt online (optional)

  Returns `{:ok, invoice, email_result}` — see `send_invoice/2`'s own
  docs for what `email_result` means.
  """
  def send_receipt(%Invoice{} = invoice, opts \\ []) do
    cond do
      # Has receipt number - can send
      not is_nil(invoice.receipt_number) ->
        do_send_receipt(invoice, opts)

      # No receipt generated yet
      is_nil(invoice.receipt_number) ->
        {:error, :receipt_not_generated}

      true ->
        {:error, :receipt_not_sendable}
    end
  end

  defp do_send_receipt(invoice, opts) do
    send_email? = Keyword.get(opts, :send_email, true)
    to_email = Keyword.get(opts, :to_email)

    # Preload user if not loaded
    invoice = ensure_preloaded(invoice, [:order, :user])

    # Get recipient email
    recipient_email = to_email || invoice_recipient(invoice)

    if is_nil(recipient_email) do
      {:error, :no_recipient_email}
    else
      # Record in receipt_data.send_history (analogous to metadata.send_history for invoices)
      send_entry = %{
        "sent_at" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
        "email" => recipient_email
      }

      current_receipt_data = invoice.receipt_data || %{}
      send_history = Map.get(current_receipt_data, "send_history", [])
      updated_send_history = send_history ++ [send_entry]
      updated_receipt_data = Map.put(current_receipt_data, "send_history", updated_send_history)

      changeset =
        invoice
        |> Ecto.Changeset.change(%{receipt_data: updated_receipt_data})

      case repo().update(changeset) do
        {:ok, updated_invoice} ->
          # Send email if requested. See do_send_invoice/3 for why the
          # email outcome is a third tuple element rather than folded
          # into {:ok, _} / {:error, _} - the receipt-data update above
          # already committed independently of whether the email goes
          # out.
          email_result =
            if send_email? do
              send_receipt_email(updated_invoice, Keyword.put(opts, :to_email, recipient_email))
            else
              :skipped
            end

          {:ok, updated_invoice, email_result}

        error ->
          error
      end
    end
  end

  @doc """
  Sends receipt email to the customer.
  """
  def send_receipt_email(%Invoice{} = invoice, opts \\ []) do
    # Preload user if not loaded
    invoice = ensure_preloaded(invoice, [:order, :user])

    # Use to_email from opts, or fall back to user email
    to_email = Keyword.get(opts, :to_email)
    recipient_email = to_email || invoice_recipient(invoice)

    case recipient_email do
      nil ->
        {:error, :no_recipient_email}

      email ->
        user = invoice.user
        variables = build_receipt_email_variables(invoice, user, opts)

        send_email_if_available(
          "billing_receipt",
          email,
          variables,
          email_send_opts("billing_receipt", variables, user, %{
            invoice_uuid: invoice.uuid,
            receipt_number: invoice.receipt_number,
            invoice_number: invoice.invoice_number
          })
        )
    end
  end

  @doc """
  Sends a credit note email for a refund transaction.

  ## Parameters

  - `invoice` - The invoice associated with the refund
  - `transaction` - The refund transaction
  - `opts` - Options:
    - `:to_email` - Override recipient email
    - `:credit_note_url` - URL to view credit note online

  Returns `{:ok, transaction, email_result}` — see `send_invoice/2`'s own
  docs for what `email_result` means.

  ## Examples

      {:ok, transaction, _email_result} =
        Billing.send_credit_note(invoice, transaction, credit_note_url: "https://...")
  """
  def send_credit_note(%Invoice{} = invoice, %Transaction{} = transaction, opts \\ []) do
    # Verify transaction is a refund
    if Transaction.refund?(transaction) do
      do_send_credit_note(invoice, transaction, opts)
    else
      {:error, :not_a_refund}
    end
  end

  defp do_send_credit_note(invoice, transaction, opts) do
    send_email? = Keyword.get(opts, :send_email, true)
    to_email = Keyword.get(opts, :to_email)

    # Preload user if not loaded
    invoice = ensure_preloaded(invoice, [:order, :user])

    # Get recipient email
    recipient_email = to_email || invoice_recipient(invoice)

    if is_nil(recipient_email) do
      {:error, :no_recipient_email}
    else
      # Record in transaction metadata.send_history
      send_entry = %{
        "sent_at" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
        "email" => recipient_email
      }

      current_metadata = transaction.metadata || %{}
      send_history = Map.get(current_metadata, "credit_note_send_history", [])
      updated_send_history = send_history ++ [send_entry]

      updated_metadata =
        Map.put(current_metadata, "credit_note_send_history", updated_send_history)

      changeset =
        transaction
        |> Ecto.Changeset.change(%{metadata: updated_metadata})

      case repo().update(changeset) do
        {:ok, updated_transaction} ->
          # Broadcast credit note sent event
          Events.broadcast_credit_note_sent(invoice, updated_transaction)

          # Send email if requested. See do_send_invoice/3 for why the
          # email outcome is a third tuple element.
          email_result =
            if send_email? do
              send_credit_note_email(
                invoice,
                updated_transaction,
                Keyword.put(opts, :to_email, recipient_email)
              )
            else
              :skipped
            end

          {:ok, updated_transaction, email_result}

        error ->
          error
      end
    end
  end

  @doc """
  Sends credit note email to the customer.
  """
  def send_credit_note_email(%Invoice{} = invoice, %Transaction{} = transaction, opts \\ []) do
    # Preload user if not loaded
    invoice = ensure_preloaded(invoice, [:order, :user])

    # Use to_email from opts, or fall back to user email
    to_email = Keyword.get(opts, :to_email)
    recipient_email = to_email || invoice_recipient(invoice)

    case recipient_email do
      nil ->
        {:error, :no_recipient_email}

      email ->
        user = invoice.user
        variables = build_credit_note_email_variables(invoice, transaction, user, opts)

        send_email_if_available(
          "billing_credit_note",
          email,
          variables,
          email_send_opts("billing_credit_note", variables, user, %{
            invoice_uuid: invoice.uuid,
            transaction_uuid: transaction.uuid,
            invoice_number: invoice.invoice_number,
            transaction_number: transaction.transaction_number
          })
        )
    end
  end

  @doc false
  def build_credit_note_email_variables(invoice, transaction, user, opts) do
    credit_note_url = Keyword.get(opts, :credit_note_url, "")
    billing_details = invoice.billing_details || %{}
    prefix = Settings.get_setting("billing_credit_note_prefix", "CN")
    suffix = transaction.transaction_number |> String.replace(~r/^TXN-/, "")
    credit_note_number = "#{prefix}-#{suffix}"
    company = get_company_details(user)

    %{
      "user_email" => (user && user.email) || Invoice.payer_email(invoice.billing_details),
      "user_name" => extract_user_name(billing_details, user),
      "credit_note_number" => credit_note_number,
      "invoice_number" => invoice.invoice_number,
      "refund_date" => format_date(transaction.inserted_at, user),
      "refund_amount" => format_decimal(Decimal.abs(transaction.amount)),
      "refund_reason" => transaction.description || "Refund issued",
      "transaction_number" => transaction.transaction_number,
      "currency" => transaction.currency,
      "company_name" => company.name,
      "company_address" => company.address,
      "company_vat" => company.vat,
      "credit_note_url" => credit_note_url
    }
    |> Map.merge(DocumentBranding.email_variables())
  end

  @doc """
  Sends a payment confirmation email for an individual payment transaction.

  ## Parameters

  - `invoice` - The invoice associated with the payment
  - `transaction` - The payment transaction
  - `opts` - Options including:
    - `:to_email` - Override recipient email address
    - `:payment_url` - URL to view payment confirmation online
    - `:send_email` - Whether to send email (default: true)

  Returns `{:ok, transaction, email_result}` — see `send_invoice/2`'s own
  docs for what `email_result` means.
  """
  def send_payment_confirmation(%Invoice{} = invoice, %Transaction{} = transaction, opts \\ []) do
    # Verify transaction is a payment (positive amount)
    if Transaction.payment?(transaction) do
      do_send_payment_confirmation(invoice, transaction, opts)
    else
      {:error, :not_a_payment}
    end
  end

  defp do_send_payment_confirmation(invoice, transaction, opts) do
    send_email? = Keyword.get(opts, :send_email, true)
    to_email = Keyword.get(opts, :to_email)

    # Preload user if not loaded
    invoice = ensure_preloaded(invoice, [:order, :user])

    # Get recipient email
    recipient_email = to_email || invoice_recipient(invoice)

    if is_nil(recipient_email) do
      {:error, :no_recipient_email}
    else
      # Record in transaction metadata.payment_confirmation_send_history
      send_entry = %{
        "sent_at" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
        "email" => recipient_email
      }

      current_metadata = transaction.metadata || %{}
      send_history = Map.get(current_metadata, "payment_confirmation_send_history", [])
      updated_send_history = send_history ++ [send_entry]

      updated_metadata =
        Map.put(current_metadata, "payment_confirmation_send_history", updated_send_history)

      changeset =
        transaction
        |> Ecto.Changeset.change(%{metadata: updated_metadata})

      case repo().update(changeset) do
        {:ok, updated_transaction} ->
          # Send email if requested. See do_send_invoice/3 for why the
          # email outcome is a third tuple element.
          email_result =
            if send_email? do
              send_payment_confirmation_email(
                invoice,
                updated_transaction,
                Keyword.put(opts, :to_email, recipient_email)
              )
            else
              :skipped
            end

          {:ok, updated_transaction, email_result}

        error ->
          error
      end
    end
  end

  @doc """
  Sends payment confirmation email to the customer.
  """
  def send_payment_confirmation_email(
        %Invoice{} = invoice,
        %Transaction{} = transaction,
        opts \\ []
      ) do
    # Preload user if not loaded
    invoice = ensure_preloaded(invoice, [:order, :user])

    # Use to_email from opts, or fall back to user email
    to_email = Keyword.get(opts, :to_email)
    recipient_email = to_email || invoice_recipient(invoice)

    case recipient_email do
      nil ->
        {:error, :no_recipient_email}

      email ->
        user = invoice.user
        variables = build_payment_confirmation_email_variables(invoice, transaction, user, opts)

        send_email_if_available(
          "billing_payment_confirmation",
          email,
          variables,
          email_send_opts("billing_payment_confirmation", variables, user, %{
            invoice_uuid: invoice.uuid,
            transaction_uuid: transaction.uuid,
            invoice_number: invoice.invoice_number,
            transaction_number: transaction.transaction_number
          })
        )
    end
  end

  @doc false
  def build_payment_confirmation_email_variables(invoice, transaction, user, opts) do
    payment_url = Keyword.get(opts, :payment_url, "")
    billing_details = invoice.billing_details || %{}
    prefix = Settings.get_setting("billing_payment_confirmation_prefix", "PMT")
    suffix = transaction.transaction_number |> String.replace(~r/^TXN-/, "")
    confirmation_number = "#{prefix}-#{suffix}"
    company = get_company_details(user)

    # Calculate remaining balance
    remaining_balance = Decimal.sub(invoice.total, invoice.paid_amount || Decimal.new(0))
    is_final_payment = Decimal.lte?(remaining_balance, Decimal.new(0))

    %{
      "user_email" => (user && user.email) || Invoice.payer_email(invoice.billing_details),
      "user_name" => extract_user_name(billing_details, user),
      "confirmation_number" => confirmation_number,
      "invoice_number" => invoice.invoice_number,
      "payment_date" => format_date(transaction.inserted_at, user),
      "payment_amount" => format_decimal(transaction.amount),
      "payment_method" => String.capitalize(transaction.payment_method || "bank"),
      "transaction_number" => transaction.transaction_number,
      "invoice_total" => format_decimal(invoice.total),
      "total_paid" => format_decimal(invoice.paid_amount),
      "remaining_balance" => format_decimal(Decimal.max(remaining_balance, Decimal.new(0))),
      "is_final_payment" => is_final_payment,
      "currency" => invoice.currency,
      "company_name" => company.name,
      "company_address" => company.address,
      "company_vat" => company.vat,
      "payment_url" => payment_url
    }
    |> Map.merge(DocumentBranding.email_variables())
  end

  @doc false
  # The options of one financial email's send, in one place so a test can see
  # exactly what reaches `PhoenixKit.Mailer.send_from_template/4`:
  #
  #   * `:defaults` — this package's own copy (`EmailDefaults`), so the four
  #     emails keep sending once the `phoenix_kit_email_templates` table is
  #     retired. The button to the document online is left out when the send
  #     has no link for it. The database row still wins over it, so nothing
  #     changes for an install that has one.
  #   * `:layout` — core's layout in the `billing` group, so a host can give
  #     billing emails their own `_layout-billing`, `_header-billing` or
  #     `_footer-billing`.
  #   * `:locale` — the customer's own preference. The recipient handed to the
  #     mailer is a bare address, which carries none, so without this every
  #     billing email went out in the site's default language.
  @spec email_send_opts(String.t(), map(), map() | nil, map()) :: keyword()
  def email_send_opts(template, variables, user, metadata) do
    locale = RecipientLocale.for_rendering(user)
    base_locale = base_locale(locale)
    defaults = EmailDefaults.defaults_for(template, variables)

    localized_defaults =
      if defaults do
        fn -> Gettext.with_locale(PhoenixKitBilling.Gettext, base_locale, defaults) end
      end

    [
      user_uuid: user && user.uuid,
      locale: locale,
      metadata: metadata,
      defaults: localized_defaults,
      layout: EmailDefaults.layout_group()
    ]
  end

  defp recipient_base_locale(user), do: user |> RecipientLocale.for_rendering() |> base_locale()

  @doc false
  # A locale's base language code: "uk" for "uk-UA", "en" for "en_GB". The
  # catalogues and country names are keyed by it.
  @spec base_locale(String.t()) :: String.t()
  def base_locale(locale), do: locale |> String.split(["-", "_"]) |> hd() |> String.downcase()

  # Sends email via PhoenixKit.Modules.Emails.Templates if available, carrying
  # this package's own default content so the send survives that package's
  # templates table being retired. Dropping the emails dependency outright is
  # deliberately NOT done here: `{:error, :emails_module_not_installed}` is a
  # contract the invoice detail UI and four regression tests hold, and Phase B
  # of the table retirement does not need it broken.
  # Uses apply/3 to avoid compile-time warnings when phoenix_kit_emails is not installed.
  #
  # Checks `Templates` itself, not the `PhoenixKit.Modules.Emails` namespace
  # module one level up — the two can be loaded independently (a host with
  # phoenix_kit_emails installed but pinned to a release that renamed or
  # dropped `Templates.send_email/4` would have the former without the
  # latter), and `apply/3` on a function that doesn't exist raises
  # `UndefinedFunctionError` instead of falling through to the "not
  # available" branch below.
  #
  # Not installed is a legitimate configuration — most hosts don't install
  # phoenix_kit_emails — but returning bare `:ok` for it made "the email
  # was sent" and "there is no email system to send it with" identical to
  # every caller, and invisible to an operator who never compares against
  # what they expected. Logged and returned as a distinguishable error
  # instead, matching the `{:error, :no_recipient_email}` shape these
  # callers already return for the other way sending can fail. No PII in
  # the log line — `notifications.ex`'s "money copy carries no PII"
  # principle applies here too: metadata (invoice/transaction uuids) is
  # fine, the raw recipient address is not.
  #
  # The *return value* is `{:error, :emails_module_not_installed}` on
  # every single call, unconditionally — every caller must always be
  # able to tell this apart from success. This is the ONLY thing this
  # function itself is responsible for guaranteeing: what a caller two
  # or three frames up eventually does with that return value is a
  # separate concern (see `do_send_invoice/3` — B003 round 2 found that
  # its `if send_email? do send_invoice_email(...) end` used to discard
  # this exact return value entirely, so `send_invoice/2` always reported
  # `{:ok, invoice}` regardless of whether the email went anywhere; fixed
  # there by carrying the result through as a third tuple element instead
  # of relying on the log below to be the only record).
  #
  # The *log line* is a separate, strictly secondary concern with a
  # different right answer: on an install that has deliberately not
  # installed phoenix_kit_emails (the owner's own case this contract
  # started from), every invoice/receipt/credit-note/payment-confirmation
  # email attempt would otherwise log an identical `:warning` — real
  # noise for a known, accepted configuration, not new information after
  # the first one. `:warning` (not a quieter level) stays the severity,
  # since this project's own `config/test.exs` pins `:logger, level:
  # :warning` — a common production floor too — and a quieter level
  # risks the message never appearing anywhere at all. So: log once per
  # BEAM boot at `:warning`, via `:persistent_term` (write-once,
  # read-cheap, exactly this shape). This is now safe to deduplicate
  # PRECISELY BECAUSE the return value above is never deduplicated —
  # every individual failure is still fully addressable through the
  # caller's own return value; the log is a "here's the pattern, and
  # here's one example of it" breadcrumb for someone grepping server
  # logs without correlating application state, not the only record of
  # any given instance. Its metadata is labeled as belonging to that one
  # first occurrence, not implied to describe every occurrence.
  defp send_email_if_available(template, email, variables, opts) do
    if Code.ensure_loaded?(PhoenixKit.Modules.Emails.Templates) and
         function_exported?(PhoenixKit.Modules.Emails.Templates, :send_email, 4) do
      # `opts` come from `email_send_opts/4`: this package's own defaults,
      # the `billing` layout group and the customer's locale.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(PhoenixKit.Modules.Emails.Templates, :send_email, [template, email, variables, opts])
    else
      warn_emails_unavailable_once(template, opts)
      {:error, :emails_module_not_installed}
    end
  end

  @emails_unavailable_warned_key {__MODULE__, :emails_unavailable_warned}

  defp warn_emails_unavailable_once(template, opts) do
    if :persistent_term.get(@emails_unavailable_warned_key, false) do
      :ok
    else
      :persistent_term.put(@emails_unavailable_warned_key, true)

      Logger.warning(
        "[Billing] phoenix_kit_emails is not installed - #{template} email not sent " <>
          "(first occurrence this run: #{inspect(Keyword.get(opts, :metadata, %{}))}). " <>
          "This condition won't change until the app restarts, so this line won't repeat " <>
          "for later occurrences - each send_*_email/2,3 call still returns " <>
          "{:error, :emails_module_not_installed} on every attempt, so check the caller's " <>
          "own return value/handling for any specific instance, not this log."
      )
    end
  end

  @doc false
  # Test-only: `:persistent_term` state outlives individual tests, so a
  # test asserting on the warn-once log needs to clear this between runs
  # rather than race whichever test happens to trigger it first.
  def reset_emails_unavailable_warning! do
    :persistent_term.erase(@emails_unavailable_warned_key)
    :ok
  end

  @doc false
  def build_receipt_email_variables(invoice, user, opts) do
    receipt_url = Keyword.get(opts, :receipt_url, "")
    billing_details = invoice.billing_details || %{}
    company = get_company_details(user)

    %{
      "user_email" => (user && user.email) || Invoice.payer_email(invoice.billing_details),
      "user_name" => extract_user_name(billing_details, user),
      "receipt_number" => invoice.receipt_number,
      "invoice_number" => invoice.invoice_number,
      "payment_date" => format_date(invoice.paid_at, user),
      "subtotal" => format_decimal(invoice.subtotal),
      "tax_amount" => format_decimal(invoice.tax_amount),
      "total" => format_decimal(invoice.total),
      "paid_amount" => format_decimal(invoice.paid_amount),
      "currency" => invoice.currency,
      "line_items_html" => EmailDefaults.line_items_html(invoice.line_items),
      "line_items_table_html" =>
        EmailDefaults.line_items_table_html(invoice.line_items, invoice.currency),
      "line_items_text" => EmailDefaults.line_items_text(invoice.line_items),
      "company_name" => company.name,
      "company_address" => company.address,
      "company_vat" => company.vat,
      "receipt_url" => receipt_url
    }
    |> Map.merge(DocumentBranding.email_variables())
  end

  defp ensure_preloaded(%{__struct__: _} = struct, preloads) do
    Enum.reduce(preloads, struct, fn preload, acc ->
      case Map.get(acc, preload) do
        %Ecto.Association.NotLoaded{} -> repo().preload(acc, preload)
        _ -> acc
      end
    end)
  end

  @doc false
  # Public for the email tests only: what each placeholder of the defaults is
  # filled with.
  def build_invoice_email_variables(invoice, user, opts) do
    invoice_url = Keyword.get(opts, :invoice_url, "")
    invoice_bank = invoice.bank_details || %{}
    billing_details = invoice.billing_details || %{}
    company = get_company_details(user)
    bank = Organization.get_bank_details()

    %{
      "user_email" => (user && user.email) || Invoice.payer_email(invoice.billing_details),
      "user_name" => extract_user_name(billing_details, user),
      "invoice_number" => invoice.invoice_number,
      "invoice_date" => format_date(invoice.inserted_at, user),
      "due_date" => format_date(invoice.due_date, user),
      "subtotal" => format_decimal(invoice.subtotal),
      "tax_amount" => format_decimal(invoice.tax_amount),
      "total" => format_decimal(invoice.total),
      "currency" => invoice.currency,
      "line_items_html" => EmailDefaults.line_items_html(invoice.line_items),
      "line_items_table_html" =>
        EmailDefaults.line_items_table_html(invoice.line_items, invoice.currency),
      "line_items_text" => EmailDefaults.line_items_text(invoice.line_items),
      "company_name" => company.name,
      "company_address" => company.address,
      "company_vat" => company.vat,
      "bank_name" => invoice_bank["bank_name"] || bank["bank_name"] || "",
      "bank_iban" => invoice_bank["iban"] || bank["iban"] || "",
      "bank_swift" => invoice_bank["swift"] || bank["swift"] || "",
      "payment_terms" =>
        invoice.payment_terms ||
          Settings.get_setting("billing_payment_terms", "Payment due within 14 days."),
      "invoice_url" => invoice_url
    }
    |> Map.merge(DocumentBranding.email_variables())
  end

  defp extract_user_name(%{"company_name" => name}, _user) when is_binary(name) and name != "",
    do: name

  defp extract_user_name(%{"first_name" => first, "last_name" => last}, _user)
       when is_binary(first) and first != "",
       do: "#{first} #{last}"

  defp extract_user_name(_billing, %{first_name: first, last_name: last})
       when is_binary(first) and first != "",
       do: "#{first} #{last}"

  defp extract_user_name(%{"name" => name}, _user) when is_binary(name) and name != "",
    do: name

  # A guest payer (billing V5) has no user — their details are the invoice's.
  defp extract_user_name(billing, nil), do: Invoice.payer_email(billing)

  defp extract_user_name(_billing, user), do: user.email

  # Who an invoice's mail goes to: the user's address, or — for a guest
  # payer (billing V5) — the email on the invoice's billing details.
  defp invoice_recipient(%Invoice{user: %{email: email}}) when is_binary(email), do: email
  defp invoice_recipient(%Invoice{billing_details: details}), do: Invoice.payer_email(details)

  defp format_date(date, user) do
    RecipientLocale.in_locale(RecipientLocale.for_rendering(user), fn ->
      EmailDefaults.format_date(date)
    end)
  end

  defp format_decimal(nil), do: "0.00"
  defp format_decimal(%Decimal{} = d), do: Decimal.to_string(d, :normal)

  @doc """
  Marks an invoice as paid (generates receipt).

  Takes the invoice row lock, then a transaction number (for the settlement
  row) and a receipt number. #{@payment_note}
  """
  def mark_invoice_paid(invoice, admin_user \\ nil)

  def mark_invoice_paid(%Invoice{trashed_at: %DateTime{}}, _admin_user),
    do: {:error, :invoice_trashed}

  def mark_invoice_paid(%Invoice{} = invoice, admin_user) do
    if Invoice.payable?(invoice) do
      config = get_config()

      result =
        repo().transaction(fn ->
          # Same FOR UPDATE row lock record_payment/3 takes. Without it a
          # concurrent payment and a mark-paid each compute the outstanding
          # balance from their own pre-transaction read and both record it,
          # putting more in the ledger than the invoice bills - the very
          # overpayment the balance check exists to prevent.
          locked = lock_invoice_for_update(invoice)

          # The payable? check above ran on the caller's struct, before the
          # lock. A void committed in between would otherwise get its status
          # overwritten by "paid" (and the transition validation raises).
          if Invoice.trashed?(locked), do: repo().rollback(:invoice_trashed)
          unless Invoice.payable?(locked), do: repo().rollback(:invoice_not_payable)

          # A settlement needs a LEDGER ROW, not just a status and a number.
          # Without one the invoice reads paid while its transactions sum to
          # zero, and a later refund recalculates paid_amount from those
          # transactions - producing a NEGATIVE amount that rolls the refund
          # back. The operator is left unable to refund an invoice the
          # system says was paid.
          #
          # A failed insert ROLLS BACK rather than being discarded: committing
          # the status without the row is exactly the inconsistency this
          # transaction exists to close, and swallowing the error would let it
          # come back silently.
          case record_settlement_transaction(locked, admin_user) do
            {:error, reason} ->
              repo().rollback(reason)

            # A run of taken transaction numbers: nothing has been written, and
            # the counter keeps its progress past them.
            {:exhausted, changeset} ->
              {:exhausted, changeset}

            _recorded_or_nothing_to_record ->
              # Taken here, with the invoice locked, so a failure above gives
              # no receipt number away.
              receipt_number = next_number("receipt", config.receipt_prefix, current_year())

              paid =
                locked
                |> Invoice.paid_changeset(receipt_number)
                |> repo().update!()

              # Committed with the payment or not at all — see InvoiceEvents.
              InvoiceEvents.enqueue(:paid, paid)
              paid
          end
        end)

      # Also mark the order as paid if linked
      case result do
        {:ok, {:exhausted, changeset}} ->
          {:error, changeset}

        {:ok, paid_invoice} ->
          Events.broadcast_invoice_paid(paid_invoice)

          Enum.each(maybe_mark_linked_order_paid(paid_invoice), fn {fun, arg} ->
            apply(Events, fun, [arg])
          end)

          {:ok, paid_invoice}

        error ->
          error
      end
    else
      {:error, :invoice_not_payable}
    end
  end

  # The outstanding balance, recorded as an offline payment so the ledger
  # matches the invoice. Nothing to record when it is already settled.
  defp record_settlement_transaction(%Invoice{} = invoice, admin_user) do
    outstanding = Invoice.remaining_amount(invoice)

    if Decimal.positive?(outstanding) do
      attrs = %{
        amount: outstanding,
        payment_method: "bank",
        description: "Marked as paid"
      }

      invoice
      |> build_transaction_attrs(outstanding, attrs, admin_user)
      |> insert_transaction()
    else
      :ok
    end
  end

  @doc """
  Voids an invoice.

  The trail goes into the invoice's `metadata["void"]` as `"reason"` (trimmed,
  `nil` when blank), `"by_uuid"` and `"at"`. `notes` is never touched: it is
  customer-visible and printed on the invoice.

  ## Options

  - `:actor_uuid` - the user who voids the invoice

  Takes a row lock on the invoice for the duration of the call and checks
  `Invoice.voidable?/1` and `Invoice.has_payments?/1` against the stored row,
  not the struct's, so a payment committed since the struct was read is not
  overwritten. An invoice with money on it (a partial payment leaves the status
  at `"sent"`) is not voided: refund the payments first. Call it inside your own
  transaction only if holding that lock until commit is fine.

  Returns `{:ok, invoice}` (without the preloads of the struct passed in),
  `{:error, :invoice_not_voidable}`, `{:error, :invoice_has_payments}`,
  `{:error, :invoice_trashed}` for an invoice in the trash,
  `{:error, :invoice_not_found}` when the invoice is gone, or
  `{:error, changeset}`. Refusals are returned, not rolled
  back, so a transaction of the caller's stays usable.
  """
  def void_invoice(%Invoice{} = invoice, reason \\ nil, opts \\ []) do
    # A transaction so the durable event commits with the void.
    result = unwrap_transaction(fn -> void_locked_invoice(invoice, reason, opts) end)

    case result do
      {:ok, voided_invoice} ->
        Events.broadcast_invoice_voided(voided_invoice)
        {:ok, voided_invoice}

      error ->
        error
    end
  end

  defp void_locked_invoice(invoice, reason, opts) do
    # The caller's struct may be minutes old: a payment recorded since would
    # otherwise be overwritten by the void (status "paid" -> "void" with the
    # money still in the ledger).
    case fetch_locked_invoice(invoice) do
      nil ->
        {:error, :invoice_not_found}

      %Invoice{trashed_at: %DateTime{}} ->
        {:error, :invoice_trashed}

      locked ->
        cond do
          not Invoice.voidable?(locked) -> {:error, :invoice_not_voidable}
          Invoice.has_payments?(locked) -> {:error, :invoice_has_payments}
          true -> void_row(locked, reason, opts)
        end
    end
  end

  defp void_row(locked, reason, opts) do
    trail = %{
      "reason" => normalize_reason(reason),
      "by_uuid" => opts[:actor_uuid],
      "at" => now_iso()
    }

    locked
    |> Invoice.status_changeset("void")
    |> Ecto.Changeset.put_change(:metadata, Map.put(locked.metadata || %{}, "void", trail))
    |> repo().update()
    |> case do
      {:ok, voided} ->
        InvoiceEvents.enqueue(:voided, voided)
        {:ok, voided}

      error ->
        error
    end
  end

  @doc """
  Keeps, on a void invoice, a provider charge that arrived after the void.

  The money is NOT booked on the invoice. It is appended to
  `metadata["void"]["payments_after_void"]` as `"provider"`, `"charge_id"`,
  `"amount"`, `"currency"`, `"event_id"` and `"at"` - ids and amounts only - so
  that the operator can find the charge and refund it at the provider. An
  event or charge id already on the list is not added again.

  `charge` is a map with the keys `:provider`, `:charge_id`, `:amount`,
  `:currency` and `:event_id`. Takes the invoice row lock.

  Returns `{:ok, invoice, :added}` when the charge was appended,
  `{:ok, invoice, :duplicate}` when the trail had it already (nothing is
  written; a caller that tells someone about new charges tells them only on
  `:added`), `{:error, :invoice_not_void}` when the stored invoice is not void,
  or `{:error, :invoice_not_found}`. Refusals are returned, not rolled back.
  """
  def record_payment_after_void(%Invoice{} = invoice, charge) when is_map(charge) do
    unwrap_transaction(fn ->
      case fetch_locked_invoice(invoice) do
        nil -> {:error, :invoice_not_found}
        %Invoice{status: "void"} = locked -> append_charge_after_void(locked, charge)
        %Invoice{} -> {:error, :invoice_not_void}
      end
    end)
  end

  defp append_charge_after_void(locked, charge) do
    metadata = locked.metadata || %{}
    trail = if is_map(metadata["void"]), do: metadata["void"], else: %{}
    entries = Map.get(trail, "payments_after_void", [])

    if charge_recorded?(entries, charge) do
      {:ok, locked, :duplicate}
    else
      entry = %{
        "provider" => charge[:provider] && to_string(charge[:provider]),
        "charge_id" => charge[:charge_id] && to_string(charge[:charge_id]),
        "amount" => charge_amount(charge[:amount]),
        "currency" => charge[:currency],
        "event_id" => charge[:event_id],
        "at" => now_iso()
      }

      trail = Map.put(trail, "payments_after_void", entries ++ [entry])

      locked
      |> Ecto.Changeset.change(metadata: Map.put(metadata, "void", trail))
      |> repo().update()
      |> case do
        {:ok, updated} -> {:ok, updated, :added}
        error -> error
      end
    end
  end

  # The same event, or the same charge reported by another event.
  defp charge_recorded?(entries, charge) do
    event_id = charge[:event_id]
    charge_id = charge[:charge_id] && to_string(charge[:charge_id])

    Enum.any?(entries, fn entry ->
      (event_id != nil and entry["event_id"] == event_id) or
        (charge_id != nil and entry["charge_id"] == charge_id)
    end)
  end

  defp charge_amount(%Decimal{} = amount), do: Decimal.to_string(amount, :normal)
  defp charge_amount(nil), do: nil
  defp charge_amount(amount), do: to_string(amount)

  @reason_max_length 500

  @doc "The longest reason `void_invoice/3`, `cancel_order/3` and `trash_order/2` keep; longer ones are cut."
  def reason_max_length, do: @reason_max_length

  @doc false
  # A free-text reason as typed in a form: surrounding whitespace is noise, a
  # blank one means no reason was given, and a runaway one is cut.
  def normalize_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @reason_max_length)
    end
  end

  def normalize_reason(_), do: nil

  @doc """
  Generates a receipt for an invoice.

  Receipts can be generated:
  - When invoice is fully paid (status: "paid")
  - When invoice has any payment (paid_amount > 0) - partial receipt

  Receipt status:
  - "paid" - fully paid
  - "partially_paid" - partial payment received
  - "refunded" - fully refunded after payment

  Returns `{:error, :receipt_already_generated}` or `{:error, :no_payments}`
  when there is nothing to issue. Two concurrent calls on one invoice issue one
  receipt: the second finds it on the locked row.

  Takes the invoice row lock, then a receipt number. #{@numbering_note}
  A refusal (`:receipt_already_generated`, `:no_payments`) writes nothing and
  leaves your transaction usable; any other error aborts it.
  """
  def generate_receipt(%Invoice{} = invoice) do
    # The caller's struct settles the common refusals without a transaction;
    # the locked row below settles the race.
    case receipt_blocker(invoice) do
      nil -> issue_receipt(invoice)
      reason -> {:error, reason}
    end
  end

  defp receipt_blocker(%Invoice{} = invoice) do
    cond do
      # Already has a receipt
      not is_nil(invoice.receipt_number) ->
        :receipt_already_generated

      # No payments yet
      is_nil(invoice.paid_amount) or Decimal.eq?(invoice.paid_amount, Decimal.new(0)) ->
        :no_payments

      true ->
        nil
    end
  end

  defp issue_receipt(%Invoice{} = invoice) do
    config = get_config()

    # Invoice row first, then the counter: the order mark_invoice_paid/2 and
    # record_payment/3 take them in, so the two cannot deadlock. Everything
    # below is read from the locked row, not from the caller's struct.
    repo().transaction(fn ->
      locked = lock_invoice_for_update(invoice)

      # Nothing has been written yet, so a refusal ends the transaction
      # without rolling it back: a caller's own transaction carries on.
      case receipt_blocker(locked) do
        nil ->
          receipt_number = next_number("receipt", config.receipt_prefix, current_year())

          locked
          |> Ecto.Changeset.change(%{
            receipt_number: receipt_number,
            receipt_generated_at: UtilsDate.utc_now(),
            receipt_data: build_receipt_data(locked)
          })
          |> repo().update()
          |> case do
            {:ok, updated} -> {:issued, updated}
            {:error, changeset} -> repo().rollback(changeset)
          end

        reason ->
          {:refused, reason}
      end
    end)
    |> case do
      {:ok, {:issued, updated}} -> {:ok, updated}
      {:ok, {:refused, reason}} -> {:error, reason}
      error -> error
    end
  end

  defp build_receipt_data(invoice) do
    receipt_status = calculate_receipt_status(invoice)

    %{
      "invoice_number" => invoice.invoice_number,
      "total" => Decimal.to_string(invoice.total),
      "paid_amount" => Decimal.to_string(invoice.paid_amount || Decimal.new(0)),
      "currency" => invoice.currency,
      "paid_at" => if(invoice.paid_at, do: DateTime.to_iso8601(invoice.paid_at), else: nil),
      "billing_details" => invoice.billing_details,
      "status" => receipt_status
    }
  end

  @doc """
  Calculates the current receipt status based on invoice state and transactions.
  """
  def calculate_receipt_status(invoice, transactions \\ nil) do
    # Get transactions if not provided
    transactions = transactions || list_invoice_transactions(invoice.uuid)

    total_refunded =
      transactions
      |> Enum.filter(&Decimal.negative?(&1.amount))
      |> Enum.map(& &1.amount)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
      |> Decimal.abs()

    paid_amount = invoice.paid_amount || Decimal.new(0)

    cond do
      # Fully refunded
      Decimal.gt?(total_refunded, Decimal.new(0)) and
          Decimal.gte?(total_refunded, paid_amount) ->
        "refunded"

      # Fully paid
      invoice.status == "paid" or Decimal.gte?(paid_amount, invoice.total) ->
        "paid"

      # Partially paid
      Decimal.gt?(paid_amount, Decimal.new(0)) ->
        "partially_paid"

      # No payment
      true ->
        "unpaid"
    end
  end

  @doc """
  Updates the receipt status based on current invoice state.
  Call this after refunds to update the receipt status.
  """
  def update_receipt_status(%Invoice{} = invoice) do
    if invoice.receipt_number do
      current_receipt_data = invoice.receipt_data || %{}
      new_status = calculate_receipt_status(invoice)

      updated_receipt_data = Map.put(current_receipt_data, "status", new_status)

      invoice
      |> Ecto.Changeset.change(%{receipt_data: updated_receipt_data})
      |> repo().update()
    else
      {:ok, invoice}
    end
  end

  @doc """
  Marks overdue invoices.
  """
  def mark_overdue_invoices do
    today = Date.utc_today()

    {count, _} =
      Invoice
      |> where([i], i.status == "sent" and i.due_date < ^today)
      |> repo().update_all(set: [status: "overdue"])

    {:ok, count}
  end

  defp apply_invoice_filters(query, filters) do
    query = scope_trashed(query, trashed_option(filters))

    Enum.reduce(filters, query, fn
      {:status, status}, q when is_binary(status) ->
        where(q, [i], i.status == ^status)

      {:statuses, statuses}, q when is_list(statuses) ->
        where(q, [i], i.status in ^statuses)

      {:from_date, date}, q ->
        where(q, [i], i.inserted_at >= ^date)

      {:to_date, date}, q ->
        where(q, [i], i.inserted_at <= ^date)

      {:overdue, true}, q ->
        today = Date.utc_today()
        where(q, [i], i.status in ["sent", "overdue"] and i.due_date < ^today)

      {:limit, n}, q when is_integer(n) and n > 0 ->
        limit(q, ^n)

      _, q ->
        q
    end)
  end

  # ============================================
  # NUMBER GENERATION
  # ============================================

  # The trailing digits of a number shaped `PREFIX-YEAR-NNNN`, as an integer;
  # NULL when the number does not end that way.
  defmacrop number_suffix(column, pattern) do
    quote do
      type(
        fragment(
          "CAST(substring(? from ?) AS bigint)",
          unquote(column),
          type(unquote(pattern), :string)
        ),
        :integer
      )
    end
  end

  # Read once per public operation and passed down, so a retry that crosses
  # midnight on 31 December cannot draw a number of the new year for a row
  # started in the old one.
  #
  # `:number_clock` is an internal, test-only key: the module whose `utc_today/0`
  # dates a number, to pin the date a test runs on. Hosts leave it unset.
  defp current_year,
    do: Application.get_env(:phoenix_kit_billing, :number_clock, Date).utc_today().year

  # Numbers come from `phoenix_kit_billing_number_sequences`: one counter per
  # (scope, year), not per prefix, so changing a prefix mid-year carries the
  # sequence on. They used to be `count(rows of the year) + 1`, which hands out
  # a taken number once any row but the last is deleted - and again and again,
  # as the count no longer grows - and the same number to two concurrent calls.
  #
  # MUST run inside the transaction that inserts the row using the number. The
  # counter row stays locked until that transaction ends, so concurrent creates
  # queue up, a rolled-back insert gives its number back (no gap), and a
  # deleted row never frees one. A caller that supplied a number takes none.
  defp next_number(scope, prefix, year) do
    sequence = next_sequence(scope, year)
    "#{prefix}-#{year}-#{String.pad_leading(to_string(sequence), 4, "0")}"
  end

  # Inserts what `build` makes, with a number. `build.(nil)` is the record as
  # the caller described it - a generated number is not needed to judge it - and
  # `build.(number)` the one to insert.
  #
  # Validated first: a changeset that fails is returned as it is (with the
  # action a form needs to show it), without a transaction and without taking a
  # number, so a caller's own transaction carries on. Only a valid one opens the
  # transaction in which the number is taken (or, for a number the caller
  # supplied, the counter is lifted past it - see `raise_sequence_floor/4`) and
  # the row inserted.
  #
  # `field` is the column of the number, which has a unique index.
  defp insert_numbered(build, scope, prefix, field, source, guard \\ fn -> :ok end) do
    year = current_year()

    case build.(nil) do
      %Ecto.Changeset{valid?: false} = invalid ->
        {:error, %{invalid | action: :insert}}

      _valid ->
        result =
          repo().transaction(fn ->
            # `guard` runs before anything is written or numbered, so a refusal
            # is a value and leaves a caller's transaction usable.
            case guard.() do
              :ok -> insert_with_source(build, scope, prefix, field, year, source)
              {:error, reason} -> {:refused, reason}
            end
          end)

        case result do
          {:ok, {:inserted, record}} -> {:ok, record}
          {:ok, {:exhausted, changeset}} -> {:error, changeset}
          {:ok, {:refused, reason}} -> {:error, reason}
          {:error, _changeset} = error -> error
        end
    end
  end

  # Inside `insert_numbered/6`'s transaction.
  defp insert_with_source(build, scope, prefix, field, year, source) do
    inserted =
      case source do
        :generate ->
          insert_with_number(build, scope, prefix, field, year)

        {:supplied, supplied} ->
          raise_sequence_floor(scope, prefix, year, supplied)
          build.(supplied) |> repo().insert()
      end

    case inserted do
      {:ok, record} -> {:inserted, record}
      # A run of taken numbers: nothing is wrong with what is inserted,
      # so the counter keeps the progress it made past them.
      {:exhausted, changeset} -> {:exhausted, changeset}
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  # Takes a number and inserts what `build` makes with it, inside a transaction.
  # The insert runs in a savepoint: when the number is already taken - by a row
  # made outside the counter, an older node or a person - only the insert is
  # undone, the number stays used up, and the next one is tried, up to
  # `@number_attempts` times. Any other error is returned as it is.
  #
  # The first time a number is found taken, the counter is first lifted to the
  # highest number of this year with the configured prefix, so a long run of
  # numbers made outside the counter is stepped over at once, not 20 at a time.
  #
  # Returns `{:ok, record}`, `{:error, changeset}`, or `{:exhausted, changeset}`
  # when every number tried was taken (with an error that says so).
  defp insert_with_number(build, scope, prefix, field, year, attempt \\ 1) do
    number = next_number(scope, prefix, year)

    case build.(number) |> repo().insert(mode: :savepoint) do
      {:ok, record} ->
        {:ok, record}

      {:error, changeset} ->
        cond do
          not number_taken?(changeset, field) ->
            {:error, changeset}

          attempt < @number_attempts ->
            Logger.warning(
              "[Billing] #{scope} number already taken, trying the next " <>
                "(#{attempt}/#{@number_attempts})"
            )

            if attempt == 1, do: lift_to_highest_number(scope, prefix, year)
            insert_with_number(build, scope, prefix, field, year, attempt + 1)

          true ->
            {:exhausted, numbers_taken(changeset, field)}
        end
    end
  end

  defp lift_to_highest_number(scope, prefix, year) do
    highest = highest_number_of_year(scope, year, configured_number_pattern(prefix, year))
    if highest > 0, do: lift_sequence(scope, year, highest)
  end

  # What the changeset says when every number tried was taken, in place of the
  # database's "has already been taken" for the last one.
  defp numbers_taken(%Ecto.Changeset{} = changeset, field) do
    changeset = %{changeset | errors: Keyword.delete(changeset.errors, field)}

    Ecto.Changeset.add_error(
      changeset,
      field,
      "could not be generated: the next #{@number_attempts} generated numbers were already taken"
    )
  end

  defp number_taken?(%Ecto.Changeset{errors: errors}, field) do
    Enum.any?(errors, fn
      {^field, {_message, opts}} -> opts[:constraint] == :unique
      _other -> false
    end)
  end

  # An update that changes a number (`numbers`: field -> scope) lifts the
  # counter past it in the same transaction; any other update is a plain one.
  #
  # `check:` is a function run first inside that transaction - before any counter
  # is touched, so it can take the row locks that belong ahead of the counters -
  # that returns `:ok` or `{:error, reason}`. A refusal is returned as a value,
  # not a rollback, and nothing has been written, not even a counter. Giving a
  # `check:` makes every valid update run in a transaction.
  defp update_numbered(%Ecto.Changeset{valid?: true} = changeset, numbers, opts) do
    year = current_year()

    floors =
      for {field, scope} <- numbers,
          number = Map.get(changeset.changes, field),
          is_binary(number),
          do: {scope, number}

    check = Keyword.get(opts, :check)

    if floors == [] and is_nil(check) do
      repo().update(changeset)
    else
      result =
        repo().transaction(fn ->
          with :ok <- run_check(check),
               :ok <- raise_sequence_floors(floors, year),
               {:ok, record} <- repo().update(changeset) do
            record
          else
            {:error, %Ecto.Changeset{} = changeset} -> repo().rollback(changeset)
            {:error, reason} -> {:refused, reason}
          end
        end)

      case result do
        {:ok, {:refused, reason}} -> {:error, reason}
        other -> other
      end
    end
  end

  defp update_numbered(%Ecto.Changeset{} = changeset, _numbers, _opts),
    do: repo().update(changeset)

  defp raise_sequence_floors(floors, year) do
    Enum.each(floors, fn {scope, number} ->
      raise_sequence_floor(scope, number_prefix(scope), year, number)
    end)
  end

  defp run_check(nil), do: :ok
  defp run_check(check), do: check.()

  defp number_prefix("order"), do: Settings.get_setting_cached("billing_order_prefix", "ORD")
  defp number_prefix("invoice"), do: Settings.get_setting_cached("billing_invoice_prefix", "INV")
  defp number_prefix("receipt"), do: Settings.get_setting_cached("billing_receipt_prefix", "RCP")

  defp next_sequence(scope, year) do
    bump =
      from(s in NumberSequence,
        where: s.scope == ^scope and s.year == ^year,
        update: [
          set: [last_value: fragment("? + 1", s.last_value), updated_at: fragment("now()")]
        ],
        select: s.last_value
      )

    case repo().update_all(bump, []) do
      {1, [value]} ->
        value

      {0, []} ->
        # ON CONFLICT: two callers can both get here, and the second must take
        # the next value, not fail on the first one's row.
        conflict =
          from(s in NumberSequence,
            update: [
              set: [last_value: fragment("? + 1", s.last_value), updated_at: fragment("now()")]
            ]
          )

        insert_sequence(scope, year, sequence_seed(scope, year) + 1, conflict)
    end
  end

  # A number the caller typed (or changed to) that has this year's shape and the
  # scope's configured prefix lifts the counter to at least its NNNN, without
  # using a value: the counter would otherwise reach it one day. (A number of
  # another shape is not a number this counter would hand out; one that is taken
  # anyway is skipped by `insert_with_number/6`.)
  defp raise_sequence_floor(scope, prefix, year, number) when is_binary(number) do
    pattern = Regex.compile!(configured_number_pattern(prefix, year))

    case Regex.run(pattern, number) do
      [_, digits] -> lift_sequence(scope, year, String.to_integer(digits))
      nil -> :ok
    end
  end

  defp raise_sequence_floor(_scope, _prefix, _year, _number), do: :ok

  # `PREFIX-YEAR-NNNN` as this counter writes it: the digits are zero-padded to
  # at least four, so a shorter run (`ORD-2026-7`) is not a number it hands out.
  defp configured_number_pattern(prefix, year),
    do: "^#{Regex.escape(prefix)}-#{year}-([0-9]{4,15})$"

  defp lift_sequence(scope, year, floor) do
    lift = fn value ->
      from(s in NumberSequence,
        update: [
          set: [
            last_value: fragment("GREATEST(?, ?)", s.last_value, type(^value, :integer)),
            updated_at: fragment("now()")
          ]
        ]
      )
    end

    case repo().update_all(
           from(s in lift.(floor), where: s.scope == ^scope and s.year == ^year),
           []
         ) do
      {1, _} ->
        :ok

      {0, _} ->
        # No row yet: it starts at the rows already numbered, or the floor.
        value = max(sequence_seed(scope, year), floor)
        insert_sequence(scope, year, value, lift.(value))
        :ok
    end
  end

  defp insert_sequence(scope, year, value, on_conflict) do
    %NumberSequence{last_value: inserted} =
      repo().insert!(
        %NumberSequence{
          scope: scope,
          year: year,
          last_value: value,
          updated_at: UtilsDate.utc_now()
        },
        on_conflict: on_conflict,
        conflict_target: [:scope, :year],
        returning: [:last_value]
      )

    inserted
  end

  # What is already numbered, so an install that predates the counter carries
  # on from where it was.
  defp sequence_seed(scope, year),
    do: max(rows_of_year(scope, year), highest_number_of_year(scope, year))

  # Counted on the raw column with a half-open range of UTC instants - the year
  # `Date.utc_today().year` names (the former `DATE(column)` went by the
  # session's time zone). Only the orders' `inserted_at` is indexed, so that scan
  # can use the index (`DATE(column)` could not); the others stay sequential, once
  # per scope-year.
  defp rows_of_year("order", year) do
    {first, after_last} = year_bounds(year)

    Order
    |> where([o], o.inserted_at >= ^first and o.inserted_at < ^after_last)
    |> repo().aggregate(:count)
  end

  defp rows_of_year("invoice", year) do
    {first, after_last} = year_bounds(year)

    Invoice
    |> where([i], i.inserted_at >= ^first and i.inserted_at < ^after_last)
    |> repo().aggregate(:count)
  end

  defp rows_of_year("transaction", year) do
    {first, after_last} = year_bounds(year)

    Transaction
    |> where([t], t.inserted_at >= ^first and t.inserted_at < ^after_last)
    |> repo().aggregate(:count)
  end

  defp rows_of_year("receipt", year) do
    {first, after_last} = year_bounds(year)

    Invoice
    |> where([i], not is_nil(i.receipt_number))
    |> where([i], i.receipt_generated_at >= ^first and i.receipt_generated_at < ^after_last)
    |> repo().aggregate(:count)
  end

  # The first instant of the year and of the next one (UTC).
  defp year_bounds(year) do
    {DateTime.new!(Date.new!(year, 1, 1), ~T[00:00:00]),
     DateTime.new!(Date.new!(year + 1, 1, 1), ~T[00:00:00])}
  end

  # The highest NNNN among numbers shaped `PREFIX-YEAR-NNNN`, whatever the
  # prefix. The digits are capped so a freak number cannot overflow bigint.
  #
  # Orders, invoices and transactions only read rows from the last day of the
  # previous year on - a number of this year sits on a row made this year, give
  # or take a day for the clock - and a number a window misses is skipped on its
  # unique index. Receipts have no unique index, so nothing would catch a number
  # issued twice: their scan has no window and sees a number written long
  # before. It runs from `sequence_seed/2` - the first value of a scope-year, and
  # the no-row path of `lift_sequence/3` - never from the taken-number
  # look-ahead, which receipts do not go through.
  defp highest_number_of_year(scope, year, pattern \\ nil) do
    pattern = pattern || "-#{year}-([0-9]{1,15})$"
    since = DateTime.new!(Date.add(Date.new!(year, 1, 1), -1), ~T[00:00:00])

    highest =
      case scope do
        "order" ->
          repo().one(
            from(o in Order,
              where: o.inserted_at >= ^since,
              select: max(number_suffix(o.order_number, ^pattern))
            )
          )

        "invoice" ->
          repo().one(
            from(i in Invoice,
              where: i.inserted_at >= ^since,
              select: max(number_suffix(i.invoice_number, ^pattern))
            )
          )

        "receipt" ->
          repo().one(
            from(i in Invoice,
              where: not is_nil(i.receipt_number),
              select: max(number_suffix(i.receipt_number, ^pattern))
            )
          )

        "transaction" ->
          repo().one(
            from(t in Transaction,
              where: t.inserted_at >= ^since,
              select: max(number_suffix(t.transaction_number, ^pattern))
            )
          )
      end

    highest || 0
  end

  # ============================================
  # TRANSACTIONS
  # ============================================

  @doc """
  Lists all transactions with optional filters.

  ## Options

  - `:invoice_uuid` - Filter by invoice UUID
  - `:user_uuid` - Filter by user who created the transaction
  - `:payment_method` - Filter by payment method
  - `:type` - Filter by type: "payment" (amount > 0) or "refund" (amount < 0)
  - `:search` - Search by transaction number
  - `:limit` - Limit results
  - `:offset` - Offset for pagination
  - `:preload` - Associations to preload

  ## Examples

      Billing.list_transactions(invoice_uuid: "some-uuid")
      Billing.list_transactions(type: "payment", limit: 10)
  """
  def list_transactions(opts \\ []) do
    transactions =
      Transaction
      |> order_by([t], desc: t.inserted_at)
      |> filter_transactions(opts)
      |> repo().all()

    if preloads = opts[:preload] do
      repo().preload(transactions, preloads)
    else
      transactions
    end
  end

  defp filter_transactions(query, opts) do
    query
    |> filter_transactions_by_invoice(opts)
    |> filter_transactions_by_user(opts[:user_uuid])
    |> filter_transactions_by_payment_method(opts[:payment_method])
    |> filter_transactions_by_type(opts[:type])
    |> filter_transactions_by_search(opts[:search])
    |> maybe_limit(opts[:limit])
    |> maybe_offset(opts[:offset])
  end

  defp filter_transactions_by_invoice(query, opts) do
    if invoice_uuid = opts[:invoice_uuid] do
      where(query, [t], t.invoice_uuid == ^invoice_uuid)
    else
      query
    end
  end

  defp filter_transactions_by_user(query, nil), do: query

  defp filter_transactions_by_user(query, user_uuid) do
    where(query, [t], t.user_uuid == ^user_uuid)
  end

  defp filter_transactions_by_payment_method(query, nil), do: query

  defp filter_transactions_by_payment_method(query, payment_method) do
    where(query, [t], t.payment_method == ^payment_method)
  end

  defp filter_transactions_by_type(query, "payment"), do: where(query, [t], t.amount > 0)
  defp filter_transactions_by_type(query, "refund"), do: where(query, [t], t.amount < 0)
  defp filter_transactions_by_type(query, _), do: query

  defp filter_transactions_by_search(query, nil), do: query

  defp filter_transactions_by_search(query, search) do
    search_term = "%#{search}%"
    where(query, [t], ilike(t.transaction_number, ^search_term))
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp maybe_offset(query, nil), do: query
  defp maybe_offset(query, offset), do: offset(query, ^offset)

  @doc """
  Lists transactions with count for pagination.
  """
  def list_transactions_with_count(opts \\ []) do
    transactions = list_transactions(opts)

    count_query =
      Transaction
      |> select([t], count(t.uuid))

    count_query =
      if invoice_uuid = opts[:invoice_uuid] do
        where(count_query, [t], t.invoice_uuid == ^invoice_uuid)
      else
        count_query
      end

    count_query =
      if payment_method = opts[:payment_method] do
        where(count_query, [t], t.payment_method == ^payment_method)
      else
        count_query
      end

    count_query =
      case opts[:type] do
        "payment" -> where(count_query, [t], t.amount > 0)
        "refund" -> where(count_query, [t], t.amount < 0)
        _ -> count_query
      end

    count_query =
      if search = opts[:search] do
        search_term = "%#{search}%"
        where(count_query, [t], ilike(t.transaction_number, ^search_term))
      else
        count_query
      end

    count = repo().one(count_query)

    {transactions, count}
  end

  @doc """
  Gets transactions for a specific invoice.
  """
  def list_invoice_transactions(invoice_uuid) when is_binary(invoice_uuid) do
    list_transactions(invoice_uuid: invoice_uuid, preload: [])
  end

  @doc """
  Gets a transaction by ID or UUID.
  """
  def get_transaction(id, opts \\ [])

  def get_transaction(id, opts) when is_binary(id) do
    transaction =
      if UUIDUtils.valid?(id) do
        repo().get_by(Transaction, uuid: id)
      else
        nil
      end

    if transaction && opts[:preload] do
      repo().preload(transaction, opts[:preload])
    else
      transaction
    end
  end

  def get_transaction(_, _opts), do: nil

  @doc """
  Gets a transaction by ID or UUID, raises if not found.
  """
  def get_transaction!(id, opts \\ []) do
    case get_transaction(id, opts) do
      nil -> raise Ecto.NoResultsError, queryable: Transaction
      transaction -> transaction
    end
  end

  @doc """
  Gets a transaction by number.
  """
  def get_transaction_by_number(number) do
    repo().get_by(Transaction, transaction_number: number)
  end

  @doc """
  Records a payment for an invoice.

  Creates a transaction with positive amount and updates invoice's paid_amount.
  If paid_amount >= total, marks invoice as paid and generates receipt.

  ## Parameters

  - `invoice` - The invoice to pay
  - `attrs` - Transaction attributes including :amount, :payment_method, :description
  - `admin_user` - The admin user recording the payment

  ## Examples

      {:ok, transaction} = Billing.record_payment(invoice, %{amount: "100.00", payment_method: "bank"}, admin)

  Takes the invoice row lock, then a transaction number, and a receipt number
  when the payment settles the invoice. #{@payment_note}
  """
  def record_payment(%Invoice{trashed_at: %DateTime{}}, _attrs, _admin_user),
    do: {:error, :invoice_trashed}

  def record_payment(%Invoice{} = invoice, attrs, admin_user) do
    amount = parse_decimal(attrs[:amount] || attrs["amount"])
    remaining = Invoice.remaining_amount(invoice)

    cond do
      # The UI already handles :not_payable; the context never returned it,
      # so a crafted event or a library caller could record money against a
      # draft or voided invoice - money in the ledger against a document
      # that was never issued.
      not Invoice.payable?(invoice) ->
        {:error, :not_payable}

      Decimal.compare(amount, Decimal.new(0)) != :gt ->
        {:error, :invalid_amount}

      # An invoice cannot take more than it is owed. The admin UI already
      # renders an :exceeds_remaining error the context never returned, so
      # a mistyped amount silently overstated cash: paid_amount ran past
      # total, remaining_amount/1 went negative, and the invoice flipped to
      # "paid" carrying more money than it billed.
      #
      # Overpayment IS a real business event, but it belongs in a credit or
      # a separate transaction an operator chooses deliberately - not as a
      # side effect of a typo.
      Decimal.compare(amount, remaining) == :gt ->
        {:error, :exceeds_remaining}

      true ->
        do_record_transaction(invoice, amount, attrs, admin_user)
    end
  end

  # The ledger row's shape, lifted out so do_record_transaction/4 stays
  # readable.
  # SELECT ... FOR UPDATE on the invoice row: serializes concurrent payment
  # recording for the SAME invoice so the balance check cannot be raced.
  defp lock_invoice_for_update(%Invoice{} = invoice) do
    fetch_locked_invoice(invoice) || invoice
  end

  # The same lock, but `nil` for a row that has vanished: for the callers that
  # would otherwise go on to UPDATE it and raise.
  defp fetch_locked_invoice(%Invoice{uuid: uuid}) do
    Invoice
    |> where([i], i.uuid == ^uuid)
    |> lock("FOR UPDATE")
    |> repo().one()
  end

  # Takes a transaction number and inserts the row, inside the caller's
  # transaction - see `insert_with_number/6`.
  defp insert_transaction(attrs) do
    build = fn number ->
      Transaction.changeset(%Transaction{}, Map.put(attrs, :transaction_number, number))
    end

    insert_with_number(
      build,
      "transaction",
      transaction_prefix(),
      :transaction_number,
      current_year()
    )
  end

  defp transaction_prefix, do: Settings.get_setting("billing_transaction_prefix", "TXN")

  defp build_transaction_attrs(invoice, amount, attrs, admin_user) do
    %{
      amount: amount,
      currency: invoice.currency,
      payment_method: attrs[:payment_method] || attrs["payment_method"] || "bank",
      description: attrs[:description] || attrs["description"],
      invoice_uuid: invoice.uuid,
      # A webhook- or worker-driven payment has NO admin actor, and
      # user_uuid is required - so every provider-confirmed payment failed
      # to insert: the customer was charged, the invoice stayed unpaid with
      # paid_amount 0, and there was no ledger row to reconcile against.
      # The invoice's own user is the right attribution for those.
      user_uuid: extract_user_uuid(admin_user) || invoice.user_uuid,
      # Carried, not dropped: callers already pass these, and
      # find_transaction_by_provider_id/1 needs them to match a later
      # refund webhook to the charge it reverses.
      provider_transaction_id:
        attrs[:provider_transaction_id] || attrs["provider_transaction_id"],
      provider_data: jsonable(attrs[:provider_data] || attrs["provider_data"] || %{})
    }
  end

  # `provider_data` is a `:map` column, and Ecto passes a struct through cast
  # AND dump untouched - the failure only surfaces at the JSON encoder, as a
  # raise from inside the repo transaction. That is the worst place for it:
  # the card has already been charged, the raise escapes the caller's `with`
  # (exceptions are not matched by `else`), and Oban retries the whole
  # renewal - charging the customer again.
  #
  # Providers hand us `%ChargeResult{}` / `%RefundResult{}` structs, so the
  # sanitizing belongs here at the library boundary rather than at each call
  # site: a host recording a payment from its own controller passes whatever
  # its provider client returned.
  defp jsonable(%Decimal{} = value), do: value
  defp jsonable(%Date{} = value), do: value
  defp jsonable(%Time{} = value), do: value
  defp jsonable(%DateTime{} = value), do: value
  defp jsonable(%NaiveDateTime{} = value), do: value

  defp jsonable(%_{} = struct), do: struct |> Map.from_struct() |> jsonable()

  defp jsonable(%{} = map) do
    Map.new(map, fn {key, value} -> {jsonable_key(key), jsonable(value)} end)
  end

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()
  defp jsonable(value) when is_pid(value) or is_reference(value), do: inspect(value)
  defp jsonable(value), do: value

  defp jsonable_key(key) when is_atom(key) or is_binary(key), do: key
  defp jsonable_key(key), do: to_string(key)

  @doc """
  Records a refund for an invoice.

  Creates a transaction with negative amount and updates invoice's paid_amount.

  ## Parameters

  - `invoice` - The invoice to refund
  - `attrs` - Transaction attributes including :amount (positive value), :description (reason)
  - `admin_user` - The admin user recording the refund

  ## Examples

      {:ok, transaction} = Billing.record_refund(invoice, %{amount: "50.00", description: "Partial refund"}, admin)

  Returns `{:ok, transaction}`, `{:error, :invalid_amount}` for an amount that
  is not positive, or `{:error, :exceeds_paid_amount}` when the amount is more
  than the invoice has been paid. The bound is checked on the invoice struct
  first and again on the invoice row under lock, so a stale `invoice` cannot
  refund more than is currently paid.

  Takes the invoice row lock, then a transaction number. #{@payment_note}
  """
  def record_refund(%Invoice{trashed_at: %DateTime{}}, _attrs, _admin_user),
    do: {:error, :invoice_trashed}

  def record_refund(%Invoice{} = invoice, attrs, admin_user) do
    amount = parse_decimal(attrs[:amount] || attrs["amount"])
    max_refund = invoice.paid_amount

    cond do
      Decimal.compare(amount, Decimal.new(0)) != :gt ->
        {:error, :invalid_amount}

      Decimal.compare(amount, max_refund) == :gt ->
        {:error, :exceeds_paid_amount}

      true ->
        # Convert to negative for refund
        negative_amount = Decimal.negate(amount)
        do_record_transaction(invoice, negative_amount, attrs, admin_user)
    end
  end

  defp do_record_transaction(invoice, amount, attrs, admin_user) do
    transaction_attrs = build_transaction_attrs(invoice, amount, attrs, admin_user)

    result =
      repo().transaction(fn ->
        # Re-check the balance on the LOCKED invoice. The caller's check runs
        # on an invoice read before the transaction, so two concurrent
        # payments could each see the same remaining balance and both pass -
        # check-then-act on money. A positive amount that no longer fits
        # rolls the whole thing back. A refund (negative amount) is bounded
        # the same way by the locked invoice's paid_amount; without this the
        # second of two refunds that each fit only died later, when the
        # recalculated paid_amount went negative and `update!` raised.
        locked = lock_invoice_for_update(invoice)

        with {:error, reason} <- check_transaction_fits(locked, amount) do
          repo().rollback(reason)
        end

        insert_ledger_row(locked, amount, transaction_attrs)
      end)

    # PubSub only AFTER the commit: broadcasting inside the transaction let
    # a listener read the invoice before the change was visible. The
    # durable events were enqueued inside it (InvoiceEvents).
    case result do
      {:ok, {:exhausted, changeset}} ->
        {:error, changeset}

      {:ok, {transaction, broadcasts}} ->
        Enum.each(broadcasts, fn {fun, arg} -> apply(Events, fun, [arg]) end)
        {:ok, transaction}

      error ->
        error
    end
  end

  # Inside the transaction, with the invoice locked: the ledger row, then the
  # invoice brought in line with it. Returns what the transaction returns.
  defp insert_ledger_row(locked, amount, transaction_attrs) do
    case insert_transaction(transaction_attrs) do
      {:ok, transaction} ->
        # From the LOCKED invoice: `paid_amount_changeset/2` is a plain
        # `change/2`, so against the caller's older struct it drops the
        # update whenever the ledger sum happens to equal the old value,
        # leaving the column out of step with the ledger.
        invoice_broadcasts = apply_transaction_to_invoice(locked, amount)

        transaction_broadcast =
          if Decimal.negative?(amount),
            do: {:broadcast_transaction_refunded, transaction},
            else: {:broadcast_transaction_created, transaction}

        {transaction, [transaction_broadcast | invoice_broadcasts]}

      # A run of taken numbers: the invoice is untouched, and the counter
      # keeps its progress past them.
      {:exhausted, changeset} ->
        {:exhausted, changeset}

      {:error, changeset} ->
        repo().rollback(changeset)
    end
  end

  # What the LOCKED invoice allows: see the comments in do_record_transaction/4.
  defp check_transaction_fits(locked, amount) do
    cond do
      # Trashed since the caller read the invoice: nothing is booked on it.
      Invoice.trashed?(locked) ->
        {:error, :invoice_trashed}

      Decimal.positive?(amount) and
          Decimal.compare(amount, Invoice.remaining_amount(locked)) == :gt ->
        {:error, :exceeds_remaining}

      # `record_payment/3` checked this on the caller's struct. A void
      # committed since would let money land on a void invoice. After the
      # balance check so that the second of two payments that each cover the
      # balance still reads `:exceeds_remaining`, not `:not_payable` (the
      # first one made the invoice "paid"). Refunds (negative amounts) are
      # bounded by what was paid instead.
      Decimal.positive?(amount) and not Invoice.payable?(locked) ->
        {:error, :not_payable}

      Decimal.negative?(amount) and
          Decimal.compare(Decimal.negate(amount), locked.paid_amount) == :gt ->
        {:error, :exceeds_paid_amount}

      true ->
        :ok
    end
  end

  # Inside the transaction: brings the invoice in line with its ledger and
  # returns the broadcasts to send once it commits.
  defp apply_transaction_to_invoice(invoice, amount) do
    new_paid_amount = calculate_invoice_paid_amount(invoice.uuid)

    invoice
    |> Invoice.paid_amount_changeset(new_paid_amount)
    |> repo().update!()

    updated_invoice = get_invoice!(invoice.uuid)

    became_paid =
      if Invoice.fully_paid?(updated_invoice) && updated_invoice.status in ["sent", "overdue"] do
        config = get_config()
        receipt_number = next_number("receipt", config.receipt_prefix, current_year())

        paid =
          updated_invoice
          |> Invoice.paid_changeset(receipt_number)
          |> repo().update!()

        order_broadcasts = maybe_mark_linked_order_paid(paid)
        InvoiceEvents.enqueue(:paid, paid)
        # A provider-confirmed payment arrives HERE (webhooks call
        # record_payment/3), and never used to announce the invoice as paid
        # at all — only the admin "Mark paid" action did.
        [{:broadcast_invoice_paid, paid} | order_broadcasts]
      else
        []
      end

    if Decimal.negative?(amount) do
      order_broadcasts = handle_refund_transaction(invoice.uuid)
      InvoiceEvents.enqueue(:refunded, get_invoice!(invoice.uuid))
      became_paid ++ order_broadcasts
    else
      became_paid
    end
  end

  @doc """
  Calculates the total paid amount for an invoice from all transactions.
  """
  def calculate_invoice_paid_amount(invoice_uuid) when is_binary(invoice_uuid) do
    Transaction
    |> where([t], t.invoice_uuid == ^invoice_uuid)
    |> select([t], sum(t.amount))
    |> repo().one()
    |> case do
      nil -> Decimal.new(0)
      amount -> amount
    end
  end

  def calculate_invoice_paid_amount(_), do: Decimal.new(0)

  @doc """
  Updates an invoice's paid_amount based on its transactions.
  """
  def update_invoice_paid_amount(%Invoice{} = invoice) do
    new_paid_amount = calculate_invoice_paid_amount(invoice.uuid)

    invoice
    |> Invoice.paid_amount_changeset(new_paid_amount)
    |> repo().update()
  end

  @doc """
  Gets the remaining amount for an invoice.
  """
  def get_invoice_remaining_amount(%Invoice{} = invoice) do
    Invoice.remaining_amount(invoice)
  end

  @doc """
  Takes the next transaction number (`TXN-2026-0001`) from the counter.

  Call it inside the transaction that inserts the transaction row: the counter
  row stays locked until that transaction ends, and a rollback gives the number
  back. Called on its own it uses up a value.
  """
  def generate_transaction_number do
    next_number("transaction", transaction_prefix(), current_year())
  end

  defp parse_decimal(value) when is_binary(value) do
    case Number.parse_decimal(value) do
      {:ok, decimal} -> decimal
      {:error, _reason} -> Decimal.new(0)
    end
  end

  defp parse_decimal(%Decimal{} = value), do: value
  defp parse_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp parse_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp parse_decimal(_), do: Decimal.new(0)

  # ============================================
  # SUBSCRIPTIONS
  # ============================================

  alias PhoenixKitBilling.{PaymentMethod, Subscription, SubscriptionType}

  @doc """
  Lists all subscriptions for a user.

  ## Options

  - `:status` - Filter by status (e.g., "active", "cancelled")
  - `:preload` - Associations to preload (default: [:subscription_type])

  ## Examples

      Billing.list_subscriptions(user_uuid)
      Billing.list_subscriptions(user_uuid, status: "active")
  """
  def list_subscriptions(opts \\ [])

  def list_subscriptions(opts) when is_list(opts) do
    status = Keyword.get(opts, :status)
    search = Keyword.get(opts, :search)
    preloads = Keyword.get(opts, :preload, [:subscription_type])

    query =
      from(s in Subscription,
        order_by: [desc: s.inserted_at]
      )

    query =
      if status do
        from(s in query, where: s.status == ^status)
      else
        query
      end

    query =
      if search && search != "" do
        search_term = "%#{search}%"
        from(s in query, join: u in assoc(s, :user), where: ilike(u.email, ^search_term))
      else
        query
      end

    query
    |> repo().all()
    |> repo().preload(preloads)
  end

  @doc """
  Lists all subscriptions for a specific user.

  ## Options
    * `:status` - filter by status (e.g., "active", "cancelled")
    * `:preload` - list of associations to preload (default: [:subscription_type])

  ## Examples

      Billing.list_user_subscriptions(user.uuid)
      Billing.list_user_subscriptions(user.uuid, status: "active")
  """
  def list_user_subscriptions(user_uuid, opts \\ []) do
    status = Keyword.get(opts, :status)
    preloads = Keyword.get(opts, :preload, [:subscription_type])

    query =
      from(s in Subscription,
        where: s.user_uuid == ^user_uuid,
        order_by: [desc: s.inserted_at]
      )

    query =
      if status do
        from(s in query, where: s.status == ^status)
      else
        query
      end

    query
    |> repo().all()
    |> repo().preload(preloads)
  end

  @doc """
  Gets a subscription by ID or UUID.

  ## Options
    * `:preload` - list of associations to preload (default: [])
  """
  def get_subscription(id, opts \\ [])

  def get_subscription(id, opts) when is_binary(id) do
    preloads = Keyword.get(opts, :preload, [])

    subscription =
      if UUIDUtils.valid?(id) do
        repo().get_by(Subscription, uuid: id)
      else
        nil
      end

    if subscription, do: repo().preload(subscription, preloads), else: nil
  end

  def get_subscription(_, _opts), do: nil

  @doc """
  Gets a subscription by ID or UUID, raises if not found.
  """
  def get_subscription!(id) do
    case get_subscription(id) do
      nil -> raise Ecto.NoResultsError, queryable: Subscription
      subscription -> subscription
    end
  end

  @doc """
  Creates a new subscription for a user.

  This creates the master subscription record. The first payment should be
  processed separately via checkout session.

  ## Parameters

  - `user_uuid` - The user creating the subscription (UUID)
  - `attrs` - Subscription attributes:
    - `:subscription_type_uuid` - Required: subscription type UUID
    - `:billing_profile_uuid` - Optional: billing profile UUID to use
    - `:payment_method_uuid` - Optional: saved payment method UUID for renewals
    - `:trial_days` - Optional: override type's trial days
    - `:plan_uuid` - Alternative: can use `:plan_uuid` instead of `:subscription_type_uuid`

  ## Examples

      Billing.create_subscription(user.uuid, %{subscription_type_uuid: type.uuid})
      Billing.create_subscription(user.uuid, %{subscription_type_uuid: type.uuid, trial_days: 14})

      # Using plan_uuid parameter
      Billing.create_subscription(user.uuid, %{plan_uuid: type.uuid})
  """
  def create_subscription(user_uuid, attrs) do
    type_uuid =
      attrs[:subscription_type_uuid] || attrs["subscription_type_uuid"] ||
        attrs[:plan_uuid] || attrs["plan_uuid"]

    with :ok <- ensure_payment_method_usable(user_uuid, attrs),
         {:ok, type} <- get_subscription_type(type_uuid) do
      trial_days = attrs[:trial_days] || type.trial_days || 0
      now = UtilsDate.utc_now()

      {status, trial_end, period_start, period_end} =
        if trial_days > 0 do
          trial_end = DateTime.add(now, trial_days, :day)
          period_end = SubscriptionType.next_billing_date(type, DateTime.to_date(trial_end))
          {"trialing", trial_end, now, datetime_from_date(period_end)}
        else
          period_end = SubscriptionType.next_billing_date(type, Date.utc_today())
          {"active", nil, now, datetime_from_date(period_end)}
        end

      billing_profile_uuid = attrs[:billing_profile_uuid]
      payment_method_uuid = attrs[:payment_method_uuid]

      subscription_attrs = %{
        user_uuid: user_uuid,
        subscription_type_uuid: type.uuid,
        billing_profile_uuid: billing_profile_uuid,
        payment_method_uuid: payment_method_uuid,
        plan_name: type.name,
        price: type.price,
        # §3.3: base = is_default row (billing_default_currency is no longer read)
        currency: type.currency || base_currency_code(),
        status: status,
        current_period_start: period_start,
        current_period_end: period_end,
        trial_start: if(trial_days > 0, do: now),
        trial_end: trial_end
      }

      result =
        %Subscription{}
        |> Subscription.changeset(subscription_attrs)
        |> repo().insert()

      case result do
        {:ok, subscription} ->
          Events.broadcast_subscription_created(subscription)
          {:ok, subscription}

        error ->
          error
      end
    end
  end

  @doc """
  Cancels a subscription.

  ## Options

  - `immediately: true` - Cancel immediately instead of at period end

  ## Examples

      Billing.cancel_subscription(subscription)
      Billing.cancel_subscription(subscription, immediately: true)
  """
  def cancel_subscription(%Subscription{} = subscription, opts \\ []) do
    immediately = Keyword.get(opts, :immediately, false)

    result =
      subscription
      |> Subscription.cancel_changeset(immediately)
      |> repo().update()

    case result do
      {:ok, cancelled_subscription} ->
        Events.broadcast_subscription_cancelled(cancelled_subscription)
        {:ok, cancelled_subscription}

      error ->
        error
    end
  end

  @doc """
  Pauses a subscription.

  Paused subscriptions don't renew until resumed.
  """
  def pause_subscription(%Subscription{} = subscription) do
    subscription
    |> Subscription.pause_changeset()
    |> repo().update()
  end

  @doc """
  Resumes a paused subscription.
  """
  def resume_subscription(%Subscription{} = subscription) do
    subscription
    |> Subscription.resume_changeset()
    |> repo().update()
  end

  # Fields the generic `update_subscription/2` is allowed to touch.
  # Lifecycle/status fields (`status`, `cancel_at_period_end`,
  # `cancelled_at`, `grace_period_end`, renewal bookkeeping) are
  # deliberately excluded: status transitions must go through the
  # dedicated `cancel_subscription/1`, `pause_subscription/1`,
  # `resume_subscription/1`, and `activate_subscription/2` functions so
  # their broadcasts and side effects always run.
  @updatable_subscription_fields ~w(
    plan_name
    price
    currency
    provider
    provider_subscription_id
    current_period_start
    current_period_end
    trial_start
    trial_end
    last_renewal_error
    metadata
    billing_profile_uuid
    subscription_type_uuid
    payment_method_uuid
  )a

  @doc """
  Updates a subscription with the given attributes.

  Useful for administrative adjustments such as extending the billing
  period or correcting plan details. Status/lifecycle fields are *not*
  updatable here — use the dedicated `cancel_subscription/1`,
  `pause_subscription/1`, and `resume_subscription/1` functions instead,
  so their broadcasts and bookkeeping always fire.
  """
  def update_subscription(%Subscription{} = subscription, attrs) do
    with :ok <- ensure_payment_method_usable(subscription.user_uuid, attrs) do
      subscription
      |> Subscription.changeset(safe_subscription_attrs(attrs))
      |> repo().update()
    end
  end

  # Rejects a payment_method_uuid that isn't one of the user's own active
  # methods. Enforced here in the context — not only in the SubscriptionForm
  # LiveView — so every caller of create_subscription/2 and
  # update_subscription/2 is covered (the changeset only FK-checks the UUID,
  # which proves existence, not ownership). A nil/absent/blank payment method
  # is allowed; the field is optional.
  defp ensure_payment_method_usable(user_uuid, attrs) do
    case attrs[:payment_method_uuid] || attrs["payment_method_uuid"] do
      blank when blank in [nil, ""] ->
        :ok

      pm_uuid ->
        pm_uuid = to_string(pm_uuid)

        user_uuid
        |> list_payment_methods(status: "active")
        |> Enum.any?(fn pm -> to_string(pm.uuid) == pm_uuid end)
        |> if(do: :ok, else: {:error, :payment_method_not_usable})
    end
  end

  defp safe_subscription_attrs(attrs) do
    allowed_strings = Enum.map(@updatable_subscription_fields, &Atom.to_string/1)

    Enum.filter(attrs, fn
      {key, _value} when is_atom(key) -> key in @updatable_subscription_fields
      {key, _value} when is_binary(key) -> key in allowed_strings
      _ -> false
    end)
    |> Map.new()
  end

  @doc """
  Changes a subscription's type.

  By default, the new type takes effect at the next billing cycle.
  """
  def change_subscription_type(%Subscription{} = subscription, new_type_uuid, _opts \\ []) do
    old_type_uuid = subscription.subscription_type_uuid

    type_uuid = resolve_subscription_type_uuid(new_type_uuid)

    result =
      subscription
      |> Ecto.Changeset.change(%{subscription_type_uuid: type_uuid})
      |> repo().update()

    case result do
      {:ok, updated_subscription} ->
        Events.broadcast_subscription_type_changed(
          updated_subscription,
          old_type_uuid,
          new_type_uuid
        )

        {:ok, updated_subscription}

      error ->
        error
    end
  end

  # ============================================
  # SUBSCRIPTION TYPES
  # ============================================

  @doc """
  Lists all subscription types.

  ## Options

  - `:active_only` - Only return active types (default: true)
  """
  def list_subscription_types(opts \\ []) do
    active_only = Keyword.get(opts, :active_only, true)

    query =
      from(t in SubscriptionType,
        order_by: [asc: t.sort_order, asc: t.name]
      )

    query =
      if active_only do
        from(t in query, where: t.active == true)
      else
        query
      end

    repo().all(query)
  end

  @doc """
  Gets a subscription type by ID or UUID.
  """
  def get_subscription_type(id) when is_binary(id) do
    type =
      if UUIDUtils.valid?(id) do
        repo().get_by(SubscriptionType, uuid: id)
      else
        nil
      end

    case type do
      nil -> {:error, :subscription_type_not_found}
      type -> {:ok, type}
    end
  end

  def get_subscription_type(_), do: {:error, :subscription_type_not_found}

  @doc """
  Gets a subscription type by slug.
  """
  def get_subscription_type_by_slug(slug) do
    case repo().get_by(SubscriptionType, slug: slug) do
      nil -> {:error, :subscription_type_not_found}
      type -> {:ok, type}
    end
  end

  @doc """
  Creates a subscription type.
  """
  def create_subscription_type(attrs) do
    %SubscriptionType{}
    |> SubscriptionType.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates a subscription type.
  """
  def update_subscription_type(%SubscriptionType{} = type, attrs) do
    type
    |> SubscriptionType.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a subscription type.

  Types with active subscriptions cannot be deleted.
  """
  def delete_subscription_type(%SubscriptionType{} = type) do
    active_count =
      from(s in Subscription,
        where:
          s.subscription_type_uuid == ^type.uuid and
            s.status in ["active", "trialing", "past_due"],
        select: count(s.uuid)
      )
      |> repo().one()

    if active_count > 0 do
      {:error, :has_active_subscriptions}
    else
      repo().delete(type)
    end
  end

  # ============================================
  # PAYMENT METHODS
  # ============================================

  @doc """
  Returns list of available payment methods for manual recording.
  Bank transfer is always available, plus any enabled providers (Stripe/PayPal/Razorpay).

  ## Examples

      iex> Billing.available_payment_methods()
      ["bank"]  # Only bank if no providers enabled

      iex> Billing.available_payment_methods()
      ["bank", "stripe", "paypal"]  # Bank + enabled providers
  """
  def available_payment_methods do
    providers = Providers.list_available_providers()
    provider_names = Enum.map(providers, &Atom.to_string/1)
    ["bank" | provider_names] |> Enum.uniq()
  end

  @doc """
  Lists saved payment methods for a user.
  """
  def list_payment_methods(user_uuid, opts \\ []) do
    query =
      from(pm in PaymentMethod,
        where: pm.user_uuid == ^user_uuid,
        order_by: [desc: pm.is_default, desc: pm.inserted_at]
      )

    query
    |> filter_payment_methods_by_status(opts)
    |> repo().all()
  end

  # An explicit `status:` filters to that exact status; otherwise
  # `active_only` (default `true`) keeps the historical active-only scoping.
  defp filter_payment_methods_by_status(query, opts) do
    cond do
      status = opts[:status] -> from(pm in query, where: pm.status == ^status)
      Keyword.get(opts, :active_only, true) -> from(pm in query, where: pm.status == "active")
      true -> query
    end
  end

  @doc """
  Gets a payment method by ID or UUID.
  """
  def get_payment_method(id) when is_binary(id) do
    if UUIDUtils.valid?(id) do
      repo().get_by(PaymentMethod, uuid: id)
    else
      nil
    end
  end

  def get_payment_method(_), do: nil

  @doc """
  Gets the default payment method for a user.
  """
  def get_default_payment_method(user_uuid) do
    from(pm in PaymentMethod,
      where: pm.user_uuid == ^user_uuid and pm.is_default == true and pm.status == "active",
      limit: 1
    )
    |> repo().one()
  end

  @doc """
  Creates a payment method record.

  Usually called after a successful setup session webhook.
  """
  def create_payment_method(attrs) do
    %PaymentMethod{}
    |> PaymentMethod.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Sets a payment method as the default for a user.

  Unsets any existing default.
  """
  def set_default_payment_method(%PaymentMethod{} = payment_method) do
    repo().transaction(fn ->
      # Unset current default
      from(pm in PaymentMethod,
        where: pm.user_uuid == ^payment_method.user_uuid and pm.is_default == true
      )
      |> repo().update_all(set: [is_default: false])

      # Set new default
      payment_method
      |> PaymentMethod.set_default_changeset()
      |> repo().update!()
    end)
  end

  @doc """
  Removes a payment method.

  Marks as removed in database. Should also delete from provider.
  """
  def remove_payment_method(%PaymentMethod{} = payment_method) do
    payment_method
    |> PaymentMethod.remove_changeset()
    |> repo().update()
  end

  # ============================================
  # CHECKOUT SESSIONS
  # ============================================

  @doc """
  Creates a checkout session for paying an invoice.

  Returns the checkout URL to redirect the user to.

  ## Parameters

  - `invoice` - The invoice to pay
  - `provider` - Payment provider atom (:stripe, :paypal, :razorpay)
  - `opts` - Options forwarded to the provider:
    - `:success_url` - URL to redirect after success (required)
    - `:cancel_url` - URL to redirect if cancelled (defaults to `:success_url`)
    - `:customer_email`, `:save_payment_method`, `:metadata` - optional, provider-dependent

  ## Examples

      {:ok, url} = Billing.create_checkout_session(invoice, :stripe, success_url: "/success")
  """
  def create_checkout_session(%Invoice{} = invoice, provider, opts \\ []) do
    # Fail fast with a clear error if the caller forgot success_url, then
    # default cancel_url to it. The provider derives amount, currency,
    # line items and metadata directly from the invoice struct, so we
    # forward the invoice itself — not a hand-built options map.
    success_url = Keyword.fetch!(opts, :success_url)
    provider_opts = Keyword.put_new(opts, :cancel_url, success_url)

    # A session for an invoice that is void (or paid) would send the customer
    # to pay for it. Checked on the stored row, before the provider call - not
    # under a lock, which must not be held across a network call.
    if stored_payable?(invoice) do
      case Providers.create_checkout_session(provider, invoice, provider_opts) do
        {:ok, session} -> persist_checkout_session(invoice, provider, session)
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invoice_not_payable}
    end
  end

  defp stored_payable?(%Invoice{uuid: uuid}) do
    case repo().get(Invoice, uuid) do
      nil -> false
      stored -> Invoice.payable?(stored)
    end
  end

  # Record checkout session info on the invoice. The invoice schema has no
  # dedicated checkout columns, so it is stashed under metadata["checkout"],
  # merged into the LOCKED row. The invoice may have been voided while the
  # provider call was in flight: then nothing is written and the customer is
  # not sent to a session for a void invoice (the provider's session just
  # expires). A failed update is only logged: it must not lose the live
  # session URL we already owe the caller.
  defp persist_checkout_session(invoice, provider, session) do
    case record_checkout_session(invoice, provider, session) do
      :ok ->
        {:ok, session.url}

      {:error, :invoice_not_payable} ->
        {:error, :invoice_not_payable}

      {:error, reason} ->
        Logger.warning(
          "Checkout session created but failed to persist to invoice " <>
            "#{invoice.invoice_number}: #{inspect(reason)}"
        )

        {:ok, session.url}
    end
  end

  @doc false
  # Public for the tests only: the persistence half of create_checkout_session/3.
  def record_checkout_session(%Invoice{} = invoice, provider, session) do
    result =
      unwrap_transaction(fn ->
        case fetch_locked_invoice(invoice) do
          nil ->
            {:error, :invoice_not_found}

          locked ->
            if Invoice.payable?(locked) do
              checkout = %{
                "provider_session_id" => session.id,
                "url" => session.url,
                "provider" => to_string(provider),
                "created_at" => UtilsDate.utc_now() |> DateTime.to_iso8601()
              }

              locked
              |> Ecto.Changeset.change(%{
                metadata: Map.put(locked.metadata || %{}, "checkout", checkout)
              })
              |> repo().update()
            else
              {:error, :invoice_not_payable}
            end
        end
      end)

    case result do
      {:ok, _invoice} -> :ok
      {:error, %Ecto.Changeset{errors: errors}} -> {:error, errors}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a setup session for saving a payment method.

  Returns the setup URL to redirect the user to.

  ## Parameters

  - `user_uuid` - The user saving the payment method
  - `provider` - Payment provider atom
  - `opts` - Options (success_url required)
  """
  def create_setup_session(user_uuid, provider, opts \\ []) do
    success_url = Keyword.fetch!(opts, :success_url)
    cancel_url = Keyword.get(opts, :cancel_url, success_url)

    session_opts = %{
      uuid: user_uuid,
      success_url: success_url,
      cancel_url: cancel_url
    }

    Providers.create_setup_session(provider, session_opts)
  end

  defp datetime_from_date(date) do
    DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  end

  # ============================================
  # HELPERS
  # ============================================

  defp extract_user_uuid(%{user: %{uuid: uuid}}), do: uuid
  defp extract_user_uuid(%{uuid: uuid}) when is_binary(uuid), do: uuid
  defp extract_user_uuid(uuid) when is_binary(uuid), do: uuid
  defp extract_user_uuid(_), do: nil

  # Resolves subscription type UUID from various input types
  defp resolve_subscription_type_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> id
      :error -> nil
    end
  end

  defp resolve_subscription_type_uuid(_), do: nil

  # Like refunds, linked order transitions are silent inside the payment
  # transaction. Both callers publish the returned events after it commits.
  defp maybe_mark_linked_order_paid(%{order_uuid: nil}), do: []

  # The order's status is read under its row lock (step 7 of the lock order in
  # `PhoenixKitBilling.Migrations`, after the invoice row), held until the
  # transaction ends, or for this call's own when the payment has committed
  # already. A `reinstate_order/3` in flight holds that row: the payment waits
  # for it and pays the order it reinstated, instead of reading the order as
  # still cancelled while the reinstate, which cannot see the uncommitted
  # payment, leaves it unpaid.
  defp maybe_mark_linked_order_paid(%{order_uuid: order_uuid} = invoice) do
    # Get the primary payment method from the invoice's transactions
    invoice_with_txns = repo().preload(invoice, :transactions)
    payment_method = Invoice.primary_payment_method(invoice_with_txns)

    fn ->
      case lock_linked_order(order_uuid) do
        %Order{status: "confirmed"} = order ->
          order_paid_broadcasts(order, payment_method)

        %Order{status: status} = order when status in ["draft", "pending"] ->
          case confirm_order_transition(order) do
            {:ok, confirmed} ->
              paid_broadcasts = order_paid_broadcasts(confirmed, payment_method)
              [{:broadcast_order_confirmed, confirmed} | paid_broadcasts]

            _ ->
              []
          end

        _ ->
          []
      end
    end
    |> repo().transaction()
    |> case do
      {:ok, broadcasts} -> broadcasts
      {:error, _} -> []
    end
  end

  defp lock_linked_order(order_uuid) do
    Order |> where([o], o.uuid == ^order_uuid) |> lock("FOR NO KEY UPDATE") |> repo().one()
  end

  defp order_paid_broadcasts(order, payment_method) do
    case pay_order(order, payment_method: payment_method) do
      {:ok, paid} -> [{:broadcast_order_paid, paid}]
      _ -> []
    end
  end

  # Returns the broadcasts to send once the surrounding transaction commits.
  defp maybe_mark_linked_order_refunded(%{order_uuid: nil}), do: []

  # Under the order row lock, like `maybe_mark_linked_order_paid/1`: a full
  # refund that meets a reinstate settling the order on this invoice waits for
  # it and refunds the order it paid.
  defp maybe_mark_linked_order_refunded(%{order_uuid: order_uuid}) do
    case lock_linked_order(order_uuid) do
      %Order{status: "paid"} = order ->
        case refund_order(order) do
          {:ok, refunded} -> [{:broadcast_order_refunded, refunded}]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp handle_refund_transaction(invoice_uuid) do
    invoice = get_invoice!(invoice_uuid)
    update_receipt_status(invoice)

    # If fully refunded (paid_amount = 0), mark invoice as void and order as refunded
    if Decimal.eq?(invoice.paid_amount, Decimal.new(0)) do
      invoice
      |> Invoice.status_changeset("void")
      |> repo().update!()

      maybe_mark_linked_order_refunded(invoice)
    else
      []
    end
  end

  defp get_bank_details do
    bank = Organization.get_bank_details()

    %{
      bank_name: bank["bank_name"] || "",
      iban: bank["iban"] || "",
      swift: bank["swift"] || "",
      account_holder: Settings.get_setting("billing_bank_account_holder", "")
    }
  end

  defp get_payment_terms do
    Settings.get_setting("billing_payment_terms", "Payment due within 14 days of invoice date.")
  end

  # Returns company details for email templates using consolidated Settings.
  # The address names its country, so it is formatted in the language the
  # email goes out in, not the sender's.
  defp get_company_details(user) do
    company = Organization.get_company_info()

    address =
      Gettext.with_locale(PhoenixKitBilling.Gettext, recipient_base_locale(user), fn ->
        format_company_address(company)
      end)

    %{
      name: company["name"] || "",
      address: address,
      vat: company["vat_number"] || ""
    }
  end

  # Countries whose addresses read postal code first, then the region, the
  # locality and the street, on one line: "36007, Полтавська обл., м. Полтава,
  # вул. ...". The country follows on a line of its own.
  @postal_first_countries ~w(BY KZ RU UA)

  @doc """
  Formats an address for a printed document or an email: a `company_info`
  map (`Organization.get_company_info/0`), or a billing-details snapshot —
  both carry `address_line1`, `address_line2`, `city`, `state`,
  `postal_code` and `country` (an ISO code).

  Lines are joined with `"\\n"` and blank parts left out. Most countries read
  street first:

      Narva mnt 5
      Tallinn 10117
      Estonia

  Ukraine, Russia, Belarus and Kazakhstan put the postal code, region,
  locality and street on one line:

      36007, Полтавська обл., м. Полтава, вул. Петра Юрченка, 19
      Україна

  The country is named in the current locale of this module's Gettext
  backend, falling back to its English name, then to the code itself.
  """
  def format_company_address(company_info) when is_map(company_info) do
    country = company_info["country"] || ""

    lines =
      if String.upcase(country) in @postal_first_countries do
        [
          join_present(
            [
              company_info["postal_code"],
              company_info["state"],
              company_info["city"],
              company_info["address_line1"],
              company_info["address_line2"]
            ],
            ", "
          )
        ]
      else
        [
          company_info["address_line1"],
          company_info["address_line2"],
          join_present([company_info["city"], company_info["postal_code"]], " "),
          company_info["state"]
        ]
      end

    join_present(lines ++ [country_display_name(country)], "\n")
  end

  defp join_present(parts, separator) do
    parts
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map_join(separator, &String.trim/1)
  end

  defp country_display_name(""), do: ""

  defp country_display_name(code) do
    translated_country_name(code) || CountryData.get_country_name(code) || code
  end

  # `BeamLabCountries` arrives with core; its translations module only in
  # its later releases, so an older one falls back to the English name.
  defp translated_country_name(code) do
    translations = BeamLabCountries.Translations

    if Code.ensure_loaded?(translations) and function_exported?(translations, :get_name, 2) do
      translations.get_name(code, base_locale(Gettext.get_locale(PhoenixKitBilling.Gettext)))
    end
  end

  @doc """
  Returns the company info map used by the printable document views
  (invoice, receipt, credit note, payment confirmation).

  Combines organization company details and bank details into a single
  map of formatted, print-ready strings.
  """
  def get_company_info do
    company = Organization.get_company_info()
    bank = Organization.get_bank_details()

    %{
      name: company["name"] || "",
      address: format_company_address(company),
      vat: company["vat_number"] || "",
      registration: company["registration_number"] || "",
      bank_name: bank["bank_name"] || "",
      bank_iban: bank["iban"] || "",
      bank_swift: bank["swift"] || ""
    }
  end

  # ============================================
  # PAYMENT OPTIONS
  # ============================================

  @doc """
  Lists all payment options.
  """
  def list_payment_options do
    PaymentOption
    |> order_by([p], [p.position, p.name])
    |> repo().all()
  end

  @doc """
  Lists active payment options for checkout.
  """
  def list_active_payment_options do
    PaymentOption
    |> where([p], p.active == true)
    |> order_by([p], [p.position, p.name])
    |> repo().all()
  end

  @doc """
  Gets a payment option by ID.
  """
  def get_payment_option(uuid) when is_binary(uuid) do
    repo().get_by(PaymentOption, uuid: uuid)
  end

  @doc """
  Gets a payment option by code.
  """
  def get_payment_option_by_code(code) when is_binary(code) do
    PaymentOption
    |> where([p], p.code == ^code)
    |> repo().one()
  end

  @doc """
  Creates a new payment option.
  """
  def create_payment_option(attrs) do
    %PaymentOption{}
    |> PaymentOption.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates a payment option.
  """
  def update_payment_option(%PaymentOption{} = payment_option, attrs) do
    payment_option
    |> PaymentOption.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a payment option.
  """
  def delete_payment_option(%PaymentOption{} = payment_option) do
    repo().delete(payment_option)
  end

  @doc """
  Toggles the active status of a payment option.
  """
  def toggle_payment_option_active(%PaymentOption{} = payment_option) do
    update_payment_option(payment_option, %{active: !payment_option.active})
  end

  @doc """
  Checks if a payment option requires a billing profile.
  """
  def payment_option_requires_billing?(%PaymentOption{requires_billing_profile: true}), do: true
  def payment_option_requires_billing?(_), do: false

  @doc """
  Returns a changeset for tracking payment option changes.
  """
  def change_payment_option(%PaymentOption{} = payment_option, attrs \\ %{}) do
    PaymentOption.changeset(payment_option, attrs)
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
