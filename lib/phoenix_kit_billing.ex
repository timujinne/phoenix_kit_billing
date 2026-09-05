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
  alias PhoenixKit.Utils.CountryData
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitBilling.BillingProfile
  alias PhoenixKitBilling.Currency
  alias PhoenixKitBilling.Events
  alias PhoenixKitBilling.Invoice
  alias PhoenixKitBilling.Order
  alias PhoenixKitBilling.PaymentOption
  alias PhoenixKitBilling.Providers
  alias PhoenixKitBilling.Transaction
  alias PhoenixKitWeb.Live.Settings.Organization

  require Logger

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
        live_view: {PhoenixKitBilling.Web.UserOrders, :index}
      ),
      billing_tab!(
        id: :dashboard_billing_profiles,
        label: "Billing Profiles",
        icon: "hero-identification",
        path: "billing-profiles",
        priority: 850,
        match: :prefix,
        group: :account
      )
    ]
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
      default_currency: Settings.get_setting_cached("billing_default_currency", "EUR"),
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
    default_currency = Settings.get_setting("billing_default_currency", "EUR")

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

  defp count_orders do
    Order |> repo().aggregate(:count)
  rescue
    e -> dashboard_stat_fallback("count_orders", 0, e)
  end

  defp count_invoices do
    Invoice |> repo().aggregate(:count)
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
    |> where([o], o.inserted_at >= ^NaiveDateTime.new!(date, ~T[00:00:00]))
    |> repo().aggregate(:count)
  rescue
    e -> dashboard_stat_fallback("count_orders_since", 0, e)
  end

  defp count_invoices_since(date) do
    Invoice
    |> where([i], i.inserted_at >= ^NaiveDateTime.new!(date, ~T[00:00:00]))
    |> repo().aggregate(:count)
  rescue
    e -> dashboard_stat_fallback("count_invoices_since", 0, e)
  end

  defp count_invoices_by_status(status) do
    Invoice
    |> where([i], i.status == ^status)
    |> repo().aggregate(:count)
  rescue
    e -> dashboard_stat_fallback("count_invoices_by_status(#{status})", 0, e)
  end

  defp calculate_paid_revenue do
    result =
      Invoice
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
  Gets the default currency.
  """
  def get_default_currency do
    Currency
    |> where([c], c.is_default == true)
    |> repo().one()
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
  """
  def get_currency_by_code(code) do
    Currency
    |> where([c], c.code == ^String.upcase(code))
    |> repo().one()
  end

  @doc """
  Creates a currency.
  """
  def create_currency(attrs) do
    %Currency{}
    |> Currency.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates a currency.
  """
  def update_currency(%Currency{} = currency, attrs) do
    currency
    |> Currency.changeset(attrs)
    |> repo().update()
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
        #    changeset — ratios are preserved, so no converted price moves.
        from(c in Currency,
          update: [
            set: [
              exchange_rate:
                fragment("round(? / ?, 6)", c.exchange_rate, type(^base_rate, :decimal))
            ]
          ]
        )
        |> repo().update_all([])

        # 2. Clear the previous default.
        Currency
        |> where([c], c.is_default == true)
        |> repo().update_all(set: [is_default: false])

        # 3. Promote, pinning the base rate to exactly 1.0 (also enables
        #    it). Reload again — step 1/2 just changed this same row out
        #    from under `fresh_before` — and force both fields into the
        #    changeset so the UPDATE always carries them, even when the
        #    reloaded row already (mis)reports them as unchanged (see the
        #    moduledoc note above).
        fresh = repo().get_by!(Currency, uuid: currency.uuid)

        fresh
        |> Currency.changeset(%{
          is_default: true,
          enabled: true,
          exchange_rate: Decimal.new("1.0")
        })
        |> Ecto.Changeset.force_change(:is_default, true)
        |> Ecto.Changeset.force_change(:exchange_rate, Decimal.new("1.0"))
        |> repo().update!()
      end)
    end
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
        repo().delete(currency)
    end
  end

  defp order_count_for_currency(code) do
    from(o in Order, where: o.currency == ^code, select: count(o.uuid))
    |> repo().one()
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
  """
  def get_default_billing_profile(user_uuid) do
    user_uuid = extract_user_uuid(user_uuid)

    BillingProfile
    |> where([bp], bp.user_uuid == ^user_uuid and bp.is_default == true)
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
      |> repo().insert()

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
      |> repo().update()

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
  """
  def list_user_orders(user_uuid, filters \\ %{}, opts \\ []) do
    user_uuid = extract_user_uuid(user_uuid)
    preloads = Keyword.get(opts, :preload, [])

    Order
    |> where([o], o.user_uuid == ^user_uuid)
    |> apply_order_filters(filters)
    |> order_by([o], desc: o.inserted_at)
    |> preload(^preloads)
    |> repo().all()
  end

  @doc """
  Lists orders with count for pagination.
  """
  def list_orders_with_count(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    offset = (page - 1) * per_page
    search = Keyword.get(opts, :search)
    status = Keyword.get(opts, :status)

    base_query = Order

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
      |> order_by([o], desc: o.inserted_at)
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
  """
  def get_order_by_uuid(uuid, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [:billing_profile])

    Order
    |> where([o], o.uuid == ^uuid)
    |> preload(^preloads)
    |> repo().one()
  end

  @doc """
  Creates an order for a user.
  """
  def create_order(user_or_uuid, attrs) do
    user_uuid = extract_user_uuid(user_or_uuid)
    config = get_config()

    # Use string key to match other attrs (avoid mixed keys error)
    attrs =
      attrs
      |> Map.put("user_uuid", user_uuid)
      |> maybe_set_default_currency()
      |> maybe_set_order_number(config)
      |> maybe_set_billing_snapshot()

    with %{} = attrs <- attrs do
      insert_order(attrs)
    end
  end

  # `maybe_set_billing_snapshot/1` returns an error tuple when the chosen
  # billing profile has vanished; passing that to a changeset would raise.
  defp insert_order(attrs) do
    case %Order{} |> Order.changeset(attrs) |> repo().insert() do
      {:ok, order} ->
        Events.broadcast_order_created(order)
        {:ok, order}

      error ->
        error
    end
  end

  @doc """
  Creates an order from attributes (user_uuid included in attrs).
  """
  def create_order(attrs) when is_map(attrs) do
    config = get_config()

    # Resolve user_uuid from attrs
    user_uuid = Map.get(attrs, :user_uuid) || Map.get(attrs, "user_uuid")

    attrs =
      attrs
      |> Map.put("user_uuid", user_uuid)
      |> maybe_set_default_currency()
      |> maybe_set_order_number(config)
      |> maybe_set_billing_snapshot()

    with %{} = attrs <- attrs do
      insert_order(attrs)
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
  """
  def update_order(%Order{} = order, attrs) do
    if Order.editable?(order) do
      # Update billing_snapshot if billing_profile_uuid changed
      attrs = maybe_update_billing_snapshot(order, attrs)

      result =
        order
        |> Order.changeset(attrs)
        |> repo().update()

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
  """
  def confirm_order(%Order{} = order) do
    result =
      order
      |> Order.status_changeset("confirmed")
      |> repo().update()

    case result do
      {:ok, confirmed_order} ->
        Events.broadcast_order_confirmed(confirmed_order)
        {:ok, confirmed_order}

      error ->
        error
    end
  end

  @doc """
  Marks an order as paid.

  ## Options

  - `:payment_method` - The payment method used (e.g., "bank", "stripe", "paypal")
  """
  def mark_order_paid(%Order{} = order, opts \\ []) do
    if Order.payable?(order) do
      changeset = Order.status_changeset(order, "paid")

      changeset =
        case opts[:payment_method] do
          nil -> changeset
          pm -> Ecto.Changeset.put_change(changeset, :payment_method, pm)
        end

      result = repo().update(changeset)

      case result do
        {:ok, paid_order} ->
          Events.broadcast_order_paid(paid_order)
          {:ok, paid_order}

        error ->
          error
      end
    else
      {:error, :order_not_payable}
    end
  end

  @doc """
  Marks an order as refunded.
  """
  def mark_order_refunded(%Order{} = order) do
    if order.status == "paid" do
      order
      |> Order.status_changeset("refunded")
      |> repo().update()
    else
      {:error, :order_not_refundable}
    end
  end

  @doc """
  Cancels an order.
  """
  def cancel_order(%Order{} = order, reason \\ nil) do
    if Order.cancellable?(order) do
      changeset =
        order
        |> Order.status_changeset("cancelled")

      changeset =
        if reason do
          Ecto.Changeset.put_change(changeset, :internal_notes, reason)
        else
          changeset
        end

      result = repo().update(changeset)

      case result do
        {:ok, cancelled_order} ->
          Events.broadcast_order_cancelled(cancelled_order)
          {:ok, cancelled_order}

        error ->
          error
      end
    else
      {:error, :order_not_cancellable}
    end
  end

  @doc """
  Deletes an order (only drafts).
  """
  def delete_order(%Order{status: "draft"} = order) do
    repo().delete(order)
  end

  def delete_order(_order), do: {:error, :can_only_delete_drafts}

  defp apply_order_filters(query, filters) do
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

  defp maybe_set_order_number(attrs, config) do
    # Check both atom and string keys since params may come from forms (string keys)
    if Map.has_key?(attrs, :order_number) || Map.has_key?(attrs, "order_number") do
      attrs
    else
      Map.put(attrs, "order_number", generate_order_number(config.order_prefix))
    end
  end

  defp maybe_set_default_currency(attrs) do
    # Check both atom and string keys
    if Map.has_key?(attrs, :currency) || Map.has_key?(attrs, "currency") do
      attrs
    else
      default = Settings.get_setting("billing_default_currency", "EUR")
      Map.put(attrs, "currency", default)
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
  long-standing customer's entire invoice history into memory.
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
  """
  def list_invoices_with_count(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    offset = (page - 1) * per_page
    search = Keyword.get(opts, :search)
    status = Keyword.get(opts, :status)

    base_query = Invoice

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
      |> order_by([i], desc: i.inserted_at)
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
  """
  def list_invoices_for_order(order_uuid) when is_binary(order_uuid) do
    Invoice
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
  """
  def create_invoice_from_order(%Order{} = order, opts \\ []) do
    config = get_config()

    opts =
      opts
      |> Keyword.put_new(:due_days, config.invoice_due_days)
      |> Keyword.put_new(:invoice_number, generate_invoice_number(config.invoice_prefix))
      |> Keyword.put_new(:bank_details, get_bank_details())
      |> Keyword.put_new(:payment_terms, get_payment_terms())

    invoice = Invoice.from_order(order, opts)

    result =
      invoice
      |> Invoice.changeset(%{})
      |> repo().insert()

    case result do
      {:ok, created_invoice} ->
        Events.broadcast_invoice_created(created_invoice)
        {:ok, created_invoice}

      error ->
        error
    end
  end

  @doc """
  Creates a standalone invoice (without order).
  """
  def create_invoice(user_or_uuid, attrs) do
    user_uuid = extract_user_uuid(user_or_uuid)
    config = get_config()

    attrs =
      attrs
      |> Map.put(:user_uuid, user_uuid)
      |> Map.put_new(:invoice_number, generate_invoice_number(config.invoice_prefix))

    result =
      %Invoice{}
      |> Invoice.changeset(attrs)
      |> repo().insert()

    case result do
      {:ok, created_invoice} ->
        Events.broadcast_invoice_created(created_invoice)
        {:ok, created_invoice}

      error ->
        error
    end
  end

  @doc """
  Updates an invoice.
  """
  def update_invoice(%Invoice{} = invoice, attrs) do
    if Invoice.editable?(invoice) do
      invoice
      |> Invoice.changeset(attrs)
      |> repo().update()
    else
      {:error, :invoice_not_editable}
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
  """
  def send_invoice(%Invoice{} = invoice, opts \\ []) do
    cond do
      Invoice.sendable?(invoice) ->
        # First send - change status to "sent"
        do_send_invoice(invoice, opts, change_status: true)

      Invoice.resendable?(invoice) ->
        # Resend - don't change status, just send email and record in history
        do_send_invoice(invoice, opts, change_status: false)

      true ->
        {:error, :invoice_not_sendable}
    end
  end

  defp do_send_invoice(invoice, opts, change_status: change_status) do
    send_email? = Keyword.get(opts, :send_email, true)
    to_email = Keyword.get(opts, :to_email)

    # Preload user if not loaded
    invoice = ensure_preloaded(invoice, [:order, :user])

    # Determine recipient email
    recipient_email = to_email || (invoice.user && invoice.user.email)

    if is_nil(recipient_email) do
      {:error, :no_recipient_email}
    else
      # Build send history entry
      send_entry = %{
        "sent_at" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
        "email" => recipient_email
      }

      # Get current send history from metadata
      current_metadata = invoice.metadata || %{}
      send_history = Map.get(current_metadata, "send_history", [])
      updated_send_history = send_history ++ [send_entry]
      updated_metadata = Map.put(current_metadata, "send_history", updated_send_history)

      # Build changeset
      changeset =
        if change_status do
          invoice
          |> Invoice.status_changeset("sent")
          |> Ecto.Changeset.put_change(:metadata, updated_metadata)
        else
          invoice
          |> Ecto.Changeset.change(%{metadata: updated_metadata})
        end

      case repo().update(changeset) do
        {:ok, updated_invoice} ->
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

  @doc """
  Sends invoice email to the customer.
  """
  def send_invoice_email(%Invoice{} = invoice, opts \\ []) do
    # Preload user if not loaded
    invoice = ensure_preloaded(invoice, [:order, :user])

    # Use to_email from opts, or fall back to user email
    to_email = Keyword.get(opts, :to_email)
    recipient_email = to_email || (invoice.user && invoice.user.email)

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
          user_uuid: user && user.uuid,
          metadata: %{invoice_uuid: invoice.uuid, invoice_number: invoice.invoice_number}
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
    recipient_email = to_email || (invoice.user && invoice.user.email)

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
    recipient_email = to_email || (invoice.user && invoice.user.email)

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
          user_uuid: user && user.uuid,
          metadata: %{
            invoice_uuid: invoice.uuid,
            receipt_number: invoice.receipt_number,
            invoice_number: invoice.invoice_number
          }
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
    recipient_email = to_email || (invoice.user && invoice.user.email)

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
    recipient_email = to_email || (invoice.user && invoice.user.email)

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
          user_uuid: user && user.uuid,
          metadata: %{
            invoice_uuid: invoice.uuid,
            transaction_uuid: transaction.uuid,
            invoice_number: invoice.invoice_number,
            transaction_number: transaction.transaction_number
          }
        )
    end
  end

  defp build_credit_note_email_variables(invoice, transaction, user, opts) do
    credit_note_url = Keyword.get(opts, :credit_note_url, "")
    billing_details = invoice.billing_details || %{}
    prefix = Settings.get_setting("billing_credit_note_prefix", "CN")
    suffix = transaction.transaction_number |> String.replace(~r/^TXN-/, "")
    credit_note_number = "#{prefix}-#{suffix}"
    company = get_company_details()

    %{
      "user_email" => user && user.email,
      "user_name" => extract_user_name(billing_details, user),
      "credit_note_number" => credit_note_number,
      "invoice_number" => invoice.invoice_number,
      "refund_date" => format_date(transaction.inserted_at),
      "refund_amount" => format_decimal(Decimal.abs(transaction.amount)),
      "refund_reason" => transaction.description || "Refund issued",
      "transaction_number" => transaction.transaction_number,
      "currency" => transaction.currency,
      "company_name" => company.name,
      "company_address" => company.address,
      "company_vat" => company.vat,
      "credit_note_url" => credit_note_url
    }
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
    recipient_email = to_email || (invoice.user && invoice.user.email)

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
    recipient_email = to_email || (invoice.user && invoice.user.email)

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
          user_uuid: user && user.uuid,
          metadata: %{
            invoice_uuid: invoice.uuid,
            transaction_uuid: transaction.uuid,
            invoice_number: invoice.invoice_number,
            transaction_number: transaction.transaction_number
          }
        )
    end
  end

  defp build_payment_confirmation_email_variables(invoice, transaction, user, opts) do
    payment_url = Keyword.get(opts, :payment_url, "")
    billing_details = invoice.billing_details || %{}
    prefix = Settings.get_setting("billing_payment_confirmation_prefix", "PMT")
    suffix = transaction.transaction_number |> String.replace(~r/^TXN-/, "")
    confirmation_number = "#{prefix}-#{suffix}"
    company = get_company_details()

    # Calculate remaining balance
    remaining_balance = Decimal.sub(invoice.total, invoice.paid_amount || Decimal.new(0))
    is_final_payment = Decimal.lte?(remaining_balance, Decimal.new(0))

    %{
      "user_email" => user && user.email,
      "user_name" => extract_user_name(billing_details, user),
      "confirmation_number" => confirmation_number,
      "invoice_number" => invoice.invoice_number,
      "payment_date" => format_date(transaction.inserted_at),
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
      "payment_url" => payment_url
    }
  end

  # Sends email via PhoenixKit.Modules.Emails.Templates if available.
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

  defp build_receipt_email_variables(invoice, user, opts) do
    receipt_url = Keyword.get(opts, :receipt_url, "")
    billing_details = invoice.billing_details || %{}
    company = get_company_details()

    %{
      "user_email" => user.email,
      "user_name" => extract_user_name(billing_details, user),
      "receipt_number" => invoice.receipt_number,
      "invoice_number" => invoice.invoice_number,
      "payment_date" => format_date(invoice.paid_at),
      "subtotal" => format_decimal(invoice.subtotal),
      "tax_amount" => format_decimal(invoice.tax_amount),
      "total" => format_decimal(invoice.total),
      "paid_amount" => format_decimal(invoice.paid_amount),
      "currency" => invoice.currency,
      "line_items_html" => format_line_items_html(invoice.line_items),
      "line_items_text" => format_line_items_text(invoice.line_items),
      "company_name" => company.name,
      "company_address" => company.address,
      "company_vat" => company.vat,
      "receipt_url" => receipt_url
    }
  end

  defp ensure_preloaded(%{__struct__: _} = struct, preloads) do
    Enum.reduce(preloads, struct, fn preload, acc ->
      case Map.get(acc, preload) do
        %Ecto.Association.NotLoaded{} -> repo().preload(acc, preload)
        _ -> acc
      end
    end)
  end

  defp build_invoice_email_variables(invoice, user, opts) do
    invoice_url = Keyword.get(opts, :invoice_url, "")
    invoice_bank = invoice.bank_details || %{}
    billing_details = invoice.billing_details || %{}
    company = get_company_details()
    bank = Organization.get_bank_details()

    %{
      "user_email" => user.email,
      "user_name" => extract_user_name(billing_details, user),
      "invoice_number" => invoice.invoice_number,
      "invoice_date" => format_date(invoice.inserted_at),
      "due_date" => format_date(invoice.due_date),
      "subtotal" => format_decimal(invoice.subtotal),
      "tax_amount" => format_decimal(invoice.tax_amount),
      "total" => format_decimal(invoice.total),
      "currency" => invoice.currency,
      "line_items_html" => format_line_items_html(invoice.line_items),
      "line_items_text" => format_line_items_text(invoice.line_items),
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
  end

  defp extract_user_name(%{"company_name" => name}, _user) when is_binary(name) and name != "",
    do: name

  defp extract_user_name(%{"first_name" => first, "last_name" => last}, _user)
       when is_binary(first) and first != "",
       do: "#{first} #{last}"

  defp extract_user_name(_billing, %{first_name: first, last_name: last})
       when is_binary(first) and first != "",
       do: "#{first} #{last}"

  defp extract_user_name(_billing, user), do: user.email

  defp format_line_items_html(nil), do: ""

  defp format_line_items_html(items) do
    Enum.map_join(items, "\n", fn item ->
      desc =
        if item["description"],
          do: "<div class=\"item-desc\">#{item["description"]}</div>",
          else: ""

      """
      <tr>
        <td>
          <div class="item-name">#{item["name"]}</div>
          #{desc}
        </td>
        <td class="text-right">#{item["quantity"]}</td>
        <td class="text-right">#{item["unit_price"]}</td>
        <td class="text-right">#{item["total"]}</td>
      </tr>
      """
    end)
  end

  defp format_line_items_text(nil), do: ""

  defp format_line_items_text(items) do
    Enum.map_join(items, "\n", fn item ->
      "#{item["name"]} x #{item["quantity"]} @ #{item["unit_price"]} = #{item["total"]}"
    end)
  end

  defp format_date(nil), do: "-"
  defp format_date(%Date{} = date), do: Calendar.strftime(date, "%B %d, %Y")
  defp format_date(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%B %d, %Y")
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%B %d, %Y")

  defp format_decimal(nil), do: "0.00"
  defp format_decimal(%Decimal{} = d), do: Decimal.to_string(d, :normal)

  @doc """
  Marks an invoice as paid (generates receipt).
  """
  def mark_invoice_paid(%Invoice{} = invoice, admin_user \\ nil) do
    if Invoice.payable?(invoice) do
      config = get_config()
      receipt_number = generate_receipt_number(config.receipt_prefix)

      result =
        repo().transaction(fn ->
          # Same FOR UPDATE row lock record_payment/3 takes. Without it a
          # concurrent payment and a mark-paid each compute the outstanding
          # balance from their own pre-transaction read and both record it,
          # putting more in the ledger than the invoice bills - the very
          # overpayment the balance check exists to prevent.
          locked = lock_invoice_for_update(invoice)

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

            _recorded_or_nothing_to_record ->
              locked
              |> Invoice.paid_changeset(receipt_number)
              |> repo().update!()
          end
        end)

      # Also mark the order as paid if linked
      case result do
        {:ok, paid_invoice} ->
          Events.broadcast_invoice_paid(paid_invoice)
          maybe_mark_linked_order_paid(paid_invoice)
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

      %Transaction{}
      |> Transaction.changeset(build_transaction_attrs(invoice, outstanding, attrs, admin_user))
      |> repo().insert()
    else
      :ok
    end
  end

  @doc """
  Voids an invoice.
  """
  def void_invoice(%Invoice{} = invoice, reason \\ nil) do
    if Invoice.voidable?(invoice) do
      changeset = Invoice.status_changeset(invoice, "void")

      changeset =
        if reason do
          Ecto.Changeset.put_change(changeset, :notes, reason)
        else
          changeset
        end

      result = repo().update(changeset)

      case result do
        {:ok, voided_invoice} ->
          Events.broadcast_invoice_voided(voided_invoice)
          {:ok, voided_invoice}

        error ->
          error
      end
    else
      {:error, :invoice_not_voidable}
    end
  end

  @doc """
  Generates a receipt for an invoice.

  Receipts can be generated:
  - When invoice is fully paid (status: "paid")
  - When invoice has any payment (paid_amount > 0) - partial receipt

  Receipt status:
  - "paid" - fully paid
  - "partially_paid" - partial payment received
  - "refunded" - fully refunded after payment
  """
  def generate_receipt(%Invoice{} = invoice) do
    cond do
      # Already has a receipt
      not is_nil(invoice.receipt_number) ->
        {:error, :receipt_already_generated}

      # No payments yet
      is_nil(invoice.paid_amount) or Decimal.eq?(invoice.paid_amount, Decimal.new(0)) ->
        {:error, :no_payments}

      # Has payments - generate receipt
      true ->
        config = get_config()
        receipt_number = generate_receipt_number(config.receipt_prefix)

        invoice
        |> Ecto.Changeset.change(%{
          receipt_number: receipt_number,
          receipt_generated_at: UtilsDate.utc_now(),
          receipt_data: build_receipt_data(invoice)
        })
        |> repo().update()
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

  defp generate_order_number(prefix) do
    year = Date.utc_today().year
    sequence = get_next_sequence("order", year)
    "#{prefix}-#{year}-#{String.pad_leading(to_string(sequence), 4, "0")}"
  end

  defp generate_invoice_number(prefix) do
    year = Date.utc_today().year
    sequence = get_next_sequence("invoice", year)
    "#{prefix}-#{year}-#{String.pad_leading(to_string(sequence), 4, "0")}"
  end

  defp generate_receipt_number(prefix) do
    year = Date.utc_today().year
    sequence = get_next_sequence("receipt", year)
    "#{prefix}-#{year}-#{String.pad_leading(to_string(sequence), 4, "0")}"
  end

  defp get_next_sequence(type, year) do
    # Simple approach: count existing records for the year
    # For production, consider using a separate sequence table
    start_of_year = Date.new!(year, 1, 1)
    end_of_year = Date.new!(year, 12, 31)

    count =
      case type do
        "order" ->
          Order
          |> where([o], fragment("DATE(?)", o.inserted_at) >= ^start_of_year)
          |> where([o], fragment("DATE(?)", o.inserted_at) <= ^end_of_year)
          |> repo().aggregate(:count)

        "invoice" ->
          Invoice
          |> where([i], fragment("DATE(?)", i.inserted_at) >= ^start_of_year)
          |> where([i], fragment("DATE(?)", i.inserted_at) <= ^end_of_year)
          |> repo().aggregate(:count)

        "receipt" ->
          Invoice
          |> where([i], not is_nil(i.receipt_number))
          |> where([i], fragment("DATE(?)", i.receipt_generated_at) >= ^start_of_year)
          |> where([i], fragment("DATE(?)", i.receipt_generated_at) <= ^end_of_year)
          |> repo().aggregate(:count)
      end

    count + 1
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
  """
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
  defp lock_invoice_for_update(%Invoice{uuid: uuid} = invoice) do
    Invoice
    |> where([i], i.uuid == ^uuid)
    |> lock("FOR UPDATE")
    |> repo().one()
    |> case do
      nil -> invoice
      locked -> locked
    end
  end

  defp build_transaction_attrs(invoice, amount, attrs, admin_user) do
    %{
      transaction_number: generate_transaction_number(),
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
  """
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

    repo().transaction(fn ->
      # Re-check the balance on the LOCKED invoice. The caller's check runs
      # on an invoice read before the transaction, so two concurrent
      # payments could each see the same remaining balance and both pass -
      # check-then-act on money. A positive amount that no longer fits
      # rolls the whole thing back.
      locked = lock_invoice_for_update(invoice)

      if Decimal.positive?(amount) and
           Decimal.compare(amount, Invoice.remaining_amount(locked)) == :gt do
        repo().rollback(:exceeds_remaining)
      end

      # Create transaction
      case %Transaction{} |> Transaction.changeset(transaction_attrs) |> repo().insert() do
        {:ok, transaction} ->
          # Update invoice paid_amount
          new_paid_amount = calculate_invoice_paid_amount(invoice.uuid)

          invoice
          |> Invoice.paid_amount_changeset(new_paid_amount)
          |> repo().update!()

          # Check if fully paid and update status
          updated_invoice = get_invoice!(invoice.uuid)

          if Invoice.fully_paid?(updated_invoice) && updated_invoice.status in ["sent", "overdue"] do
            config = get_config()
            receipt_number = generate_receipt_number(config.receipt_prefix)

            updated_invoice
            |> Invoice.paid_changeset(receipt_number)
            |> repo().update!()

            # Mark linked order as paid if applicable
            maybe_mark_linked_order_paid(updated_invoice)
          end

          # Handle refund: update receipt status and check for full refund
          if Decimal.negative?(amount) do
            handle_refund_transaction(invoice.uuid)
            Events.broadcast_transaction_refunded(transaction)
          else
            Events.broadcast_transaction_created(transaction)
          end

          transaction

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
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
  Generates a unique transaction number.
  """
  def generate_transaction_number do
    prefix = Settings.get_setting("billing_transaction_prefix", "TXN")
    year = Date.utc_today().year
    count = count_transactions_this_year()
    "#{prefix}-#{year}-#{String.pad_leading(Integer.to_string(count), 4, "0")}"
  end

  defp count_transactions_this_year do
    year = Date.utc_today().year
    start_of_year = Date.new!(year, 1, 1)
    end_of_year = Date.new!(year, 12, 31)

    count =
      Transaction
      |> where([t], fragment("DATE(?)", t.inserted_at) >= ^start_of_year)
      |> where([t], fragment("DATE(?)", t.inserted_at) <= ^end_of_year)
      |> repo().aggregate(:count)

    count + 1
  end

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, _} -> decimal
      :error -> Decimal.new(0)
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
        currency: type.currency || Settings.get_setting("billing_default_currency", "EUR"),
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

    case Providers.create_checkout_session(provider, invoice, provider_opts) do
      {:ok, session} ->
        # Record checkout session info on the invoice. The invoice schema
        # has no dedicated checkout columns, so it is stashed under
        # metadata["checkout"]. Best-effort: a failed update must not lose
        # the live session URL we already owe the caller.
        updated_metadata =
          Map.put(invoice.metadata || %{}, "checkout", %{
            "provider_session_id" => session.id,
            "url" => session.url,
            "provider" => to_string(provider),
            "created_at" => UtilsDate.utc_now() |> DateTime.to_iso8601()
          })

        case invoice
             |> Ecto.Changeset.change(%{metadata: updated_metadata})
             |> repo().update() do
          {:ok, _invoice} ->
            :ok

          {:error, changeset} ->
            Logger.warning(
              "Checkout session created but failed to persist to invoice " <>
                "#{invoice.invoice_number}: #{inspect(changeset.errors)}"
            )
        end

        {:ok, session.url}

      {:error, reason} ->
        {:error, reason}
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

  defp maybe_mark_linked_order_paid(%{order_uuid: nil}), do: :ok

  defp maybe_mark_linked_order_paid(%{order_uuid: order_uuid} = invoice) do
    # Get the primary payment method from the invoice's transactions
    invoice_with_txns = repo().preload(invoice, :transactions)
    payment_method = Invoice.primary_payment_method(invoice_with_txns)

    case get_order!(order_uuid) do
      %Order{status: "confirmed"} = order ->
        mark_order_paid(order, payment_method: payment_method)

      %Order{status: "draft"} = order ->
        # Auto-confirm draft order, then mark as paid
        with {:ok, confirmed_order} <- confirm_order(order) do
          mark_order_paid(confirmed_order, payment_method: payment_method)
        end

      %Order{status: "pending"} = order ->
        # Auto-confirm pending order, then mark as paid
        with {:ok, confirmed_order} <- confirm_order(order) do
          mark_order_paid(confirmed_order, payment_method: payment_method)
        end

      _ ->
        :ok
    end
  end

  defp maybe_mark_linked_order_refunded(%{order_uuid: nil}), do: :ok

  defp maybe_mark_linked_order_refunded(%{order_uuid: order_uuid}) do
    case get_order!(order_uuid) do
      %Order{status: "paid"} = order ->
        mark_order_refunded(order)

      _ ->
        :ok
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

  # Returns company details for email templates using consolidated Settings
  defp get_company_details do
    company = Organization.get_company_info()

    %{
      name: company["name"] || "",
      address: format_company_address(company),
      vat: company["vat_number"] || ""
    }
  end

  @doc """
  Formats company address from a `company_info` map for document printing.

  The map is required (callers pass the result of
  `Organization.get_company_info/0`), keeping this function pure.
  """
  def format_company_address(company_info) when is_map(company_info) do
    country_name =
      case CountryData.get_country_name(company_info["country"] || "") do
        nil -> company_info["country"] || ""
        name -> name
      end

    city_postal =
      [company_info["city"], company_info["postal_code"]]
      |> Enum.filter(&(&1 && &1 != ""))
      |> Enum.join(" ")
      |> String.trim()

    [
      company_info["address_line1"],
      company_info["address_line2"],
      city_postal,
      company_info["state"],
      country_name
    ]
    |> Enum.filter(&(&1 && &1 != ""))
    |> Enum.join("\n")
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
