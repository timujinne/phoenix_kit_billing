defmodule PhoenixKitBilling.CoreCompat do
  @moduledoc """
  The PhoenixKit core surface this package calls, in one list, checked against
  whichever core actually resolved.

  `mix.exs` requires `phoenix_kit ~> 2.0` — every core 2.x, and nothing else;
  core 1.7 is excluded because 2.0.0 squashed the migration chain to a `V135`
  floor this module is verified against (see `core_pin_conformance_test.exs`).
  Admitting a minor is not the same as working on one: 2.1 may move or drop
  anything. What this module buys is a legible failure — the surface is declared
  here, so a core that moved something reports a named list at boot and in the
  test suite, instead of raising `UndefinedFunctionError` at whichever call site
  a user happens to reach first.

  Four lists, because the failure modes differ:

    * `runtime_calls/0` — called unguarded. A gap here is a broken feature.
    * `optional_calls/0` — already behind `Code.ensure_loaded?/1` or
      `function_exported?/3` at the call site, so a gap degrades quietly by
      design (the dashboard registry).
    * `compile_time_modules/0` — `use`d or `import`ed. A gap here fails the
      build before any check in this module can run; they are listed so the
      inventory of what core owes this package is complete in one place.
    * `sibling_calls/0` — a `PhoenixKit.*` namespace owned by another package
      rather than by core, checked only when that package is installed.

  Not covered: behaviour *semantics*. A core that keeps `Settings.get_setting/2`
  but changes what it returns passes every check here and still breaks billing.
  Only the test suite against a real core can catch that.
  """

  require Logger

  # Unguarded calls into core. Extracted from the source AST rather than by
  # hand, so pipes and aliases are accounted for — except the `defdelegate`
  # targets, which the extractor does not see as calls and which are listed
  # by hand below.
  @runtime_calls [
    {PhoenixKit.Activity, :log, 3},
    # The generated `ExpectedSchema` validates the prefix it is handed.
    {PhoenixKit.Migrations.Postgres.Helpers, :validate_prefix!, 1},
    # InvoiceEvents finds modules declaring billing_invoice_event_handlers/0.
    {PhoenixKit.ModuleRegistry, :all_modules, 0},
    {PhoenixKit.RepoHelper, :repo, 0},
    {PhoenixKit.Settings, :get_setting, 2},
    {PhoenixKit.Settings, :get_setting_cached, 2},
    {PhoenixKit.Settings, :get_boolean_setting, 2},
    {PhoenixKit.Settings, :get_project_title, 0},
    {PhoenixKit.Settings, :update_setting, 2},
    {PhoenixKit.Settings, :update_boolean_setting_with_module, 3},
    {PhoenixKit.Utils.Number, :parse_decimal, 1},
    {PhoenixKit.Utils.Number, :parse_decimal, 2},
    {PhoenixKit.Utils.Routes, :path, 1},
    {PhoenixKit.Utils.Routes, :url, 1},
    {PhoenixKit.Utils.Date, :utc_now, 0},
    {PhoenixKit.Utils.Date, :short_month, 1},
    {PhoenixKit.Utils.UUID, :valid?, 1},
    # The customer's language for the four financial emails — the send's
    # recipient is a bare address, which carries no preference.
    {PhoenixKit.Utils.RecipientLocale, :for_rendering, 1},
    {PhoenixKit.Utils.RecipientLocale, :in_locale, 2},
    {PhoenixKit.Utils.CountryData, :countries_for_select, 0},
    {PhoenixKit.Utils.CountryData, :eu_member?, 1},
    {PhoenixKit.Utils.CountryData, :get_country_name, 1},
    {PhoenixKit.Utils.CountryData, :get_standard_vat_percent, 1},
    {PhoenixKit.Utils.CountryData, :get_standard_vat_rate, 1},
    {PhoenixKit.Utils.CountryData, :get_subdivision_label, 1},
    {PhoenixKit.Users.Auth, :get_user, 1},
    {PhoenixKit.Users.Auth, :list_users_paginated, 1},
    {PhoenixKit.Users.Auth.Scope, :can?, 2},
    {PhoenixKit.Users.Permissions, :users_with_permission, 1},
    # user_menu_with_shop?/1 — the avatar-dropdown gate on the shop module.
    {PhoenixKit.Users.Permissions, :feature_enabled?, 1},
    {PhoenixKit.Users.Roles, :users_with_role, 1},
    {PhoenixKit.PubSub.Manager, :broadcast, 2},
    {PhoenixKit.PubSub.Manager, :subscribe, 1},
    {PhoenixKit.Notifications, :create, 1},
    {PhoenixKit.Notifications, :create_many, 2},
    {PhoenixKit.Dashboard.Tab, :new!, 1},
    {PhoenixKitWeb.Actor, :role, 1},
    {PhoenixKitWeb.Actor, :uuid, 1},
    # §13 currency cache — get_base_currency/0, get_currency_by_code/1,
    # invalidate_currency_cache/0 in phoenix_kit_billing.ex.
    {PhoenixKit.Cache, :get, 3},
    {PhoenixKit.Cache, :put, 3},
    {PhoenixKit.Cache, :clear, 1},
    # §4.2.1 item 5 — invalidate_currency_cache/0's post-clear barrier: a
    # same-process GenServer.call the cache GenServer must finish handling
    # after the clear cast before this returns, so a subscriber reacting to
    # `{:currencies_changed, code}` cannot observe the stale entry.
    {PhoenixKit.Cache, :stats, 1},
    # Company and bank details for invoices live on a core *LiveView* module.
    # Reaching into a web module from a context is the most fragile line in
    # this list: core owes it no API stability, and a 2.0 that reorganises
    # PhoenixKitWeb would take invoice headers with it.
    {PhoenixKitWeb.Live.Settings.Organization, :get_company_info, 0},
    {PhoenixKitWeb.Live.Settings.Organization, :get_bank_details, 0},
    # The logo on printed documents and in billing emails (DocumentBranding).
    {PhoenixKit.Modules.Storage, :get_file, 1},
    {PhoenixKit.Modules.Storage, :list_file_instances, 1},
    {PhoenixKit.Modules.Storage.Libraries, :private_file?, 1},
    {PhoenixKit.Modules.Storage.URLSigner, :signed_url, 2},
    {PhoenixKit.Modules.Storage.URLSigner, :signed_url, 3},
    {PhoenixKit.Utils.Routes, :base_url, 0},
    # Billing → Settings → Printed Documents: the logo and footer are saved in
    # one transaction; the logo picker's uploads go to the host's branding
    # folder.
    {PhoenixKit.Settings, :update_settings_batch, 1},
    {PhoenixKit.UploadsParentFolder, :resolve, 3},
    # The logo picker, a LiveComponent mounted from settings.html.heex — a
    # module reference no call extractor sees. Its contract: the attrs `mode`,
    # `file_type_filter`, `lock_file_type`, `title`, `selected_uuids`,
    # `scope_folder_id`, `phoenix_kit_current_user`, and the messages
    # `{:media_selected, uuids}` / `{:media_selector_closed}` it sends to the
    # LiveView that mounts it.
    {PhoenixKitWeb.Live.Components.MediaSelectorModal, :update, 2}
  ]

  # Guarded at the call site — listed so an upgrade shows what quietly stopped
  # working, which is otherwise invisible precisely because it fails open.
  @optional_calls [
    {PhoenixKit.Dashboard.Registry, :initialized?, 0},
    {PhoenixKit.Dashboard.Registry, :load_defaults, 0}
  ]

  # Sits under a `PhoenixKit.*` namespace but is owned by a *sibling package*,
  # not core: `PhoenixKit.Modules.Emails.Templates` ships with phoenix_kit_emails,
  # which billing does not depend on and which most hosts do not install. Its
  # absence is the normal case, so it cannot be checked like the lists above —
  # only when the module is actually loaded does a missing function mean the
  # sibling moved its API out from under the `apply/3` call in
  # `send_email_if_available/4`.
  @sibling_calls [
    {PhoenixKit.Modules.Emails.Templates, :send_email, 4}
  ]

  # `use`d or `import`ed; a gap fails compilation, not these checks.
  @compile_time_modules [
    PhoenixKit.Module,
    PhoenixKit.SchemaPrefix,
    PhoenixKitWeb.LayoutHelpers,
    PhoenixKitWeb.Components.Core.Accordion,
    PhoenixKitWeb.Components.Core.AdminPageHeader,
    PhoenixKitWeb.Components.Core.Checkbox,
    PhoenixKitWeb.Components.Core.DecimalInput,
    PhoenixKitWeb.Components.Core.EmptyState,
    PhoenixKitWeb.Components.Core.FormFieldError,
    PhoenixKitWeb.Components.Core.Icon,
    PhoenixKitWeb.Components.Core.Input,
    PhoenixKitWeb.Components.Core.NavTabs,
    PhoenixKitWeb.Components.Core.Pagination,
    PhoenixKitWeb.Components.Core.Select,
    PhoenixKitWeb.Components.Core.TableDefault,
    PhoenixKitWeb.Components.Core.TableRowMenu,
    PhoenixKitWeb.Components.Core.Textarea,
    PhoenixKitWeb.Components.Core.TimeDisplay,
    PhoenixKitWeb.Components.Core.UserInfo
  ]

  @type mfa_tuple :: {module(), atom(), arity()}

  @doc "Core functions billing calls without a guard."
  @spec runtime_calls() :: [mfa_tuple()]
  def runtime_calls, do: @runtime_calls

  @doc "Core functions billing calls behind an existence guard."
  @spec optional_calls() :: [mfa_tuple()]
  def optional_calls, do: @optional_calls

  @doc "Core modules billing `use`s or `import`s."
  @spec compile_time_modules() :: [module()]
  def compile_time_modules, do: @compile_time_modules

  @doc """
  Calls into sibling `phoenix_kit_*` packages under a `PhoenixKit.*` namespace.

  Checked only when the module is loaded — see `missing_sibling_calls/0`.
  """
  @spec sibling_calls() :: [mfa_tuple()]
  def sibling_calls, do: @sibling_calls

  @doc """
  The resolved core version, or `nil` when `:phoenix_kit` is not loaded.

  Read from the application spec rather than a compile-time constant, so it
  reports the core actually running, not the one this package was built against.
  """
  @spec core_version() :: String.t() | nil
  def core_version do
    case Application.spec(:phoenix_kit, :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  end

  @doc "Unguarded core calls the resolved core does not export."
  @spec missing_runtime_calls() :: [mfa_tuple()]
  def missing_runtime_calls, do: Enum.reject(@runtime_calls, &exported?/1)

  @doc "Guarded core calls the resolved core does not export."
  @spec missing_optional_calls() :: [mfa_tuple()]
  def missing_optional_calls, do: Enum.reject(@optional_calls, &exported?/1)

  @doc "Core modules from `compile_time_modules/0` that are not loadable."
  @spec missing_compile_time_modules() :: [module()]
  def missing_compile_time_modules do
    Enum.reject(@compile_time_modules, &Code.ensure_loaded?/1)
  end

  @doc """
  Sibling-package calls whose module is installed but no longer exports them.

  An uninstalled sibling returns nothing: not having phoenix_kit_emails is a
  supported configuration, not a compatibility break.
  """
  @spec missing_sibling_calls() :: [mfa_tuple()]
  def missing_sibling_calls do
    Enum.filter(@sibling_calls, fn {module, fun, arity} ->
      Code.ensure_loaded?(module) and not function_exported?(module, fun, arity)
    end)
  end

  @doc """
  `:ok`, or `{:error, report}` naming every gap against the resolved core.

  The report is a human-readable string meant for a log line or a test failure
  message — it names the core version so a bug report says which core it was.
  """
  @spec check() :: :ok | {:error, String.t()}
  def check do
    required = missing_runtime_calls()
    optional = missing_optional_calls() ++ missing_sibling_calls()
    modules = missing_compile_time_modules()

    if required == [] and optional == [] and modules == [] do
      :ok
    else
      {:error, report(required, optional, modules)}
    end
  end

  @doc """
  Logs `check/0`'s report when the resolved core is missing something.

  Called from the supervisor, so a host that upgraded core past what this
  package understands is told once at boot, by name, instead of discovering it
  one crash at a time. Missing *unguarded* calls log at `:error`, everything
  else at `:warning` — the former is a broken feature, the latter is degradation
  the call sites already handle.
  """
  @spec log_check() :: :ok
  def log_check do
    case check() do
      :ok ->
        :ok

      {:error, report} ->
        if missing_runtime_calls() == [] do
          Logger.warning(report)
        else
          Logger.error(report)
        end

        :ok
    end
  end

  defp exported?({module, fun, arity}) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end

  defp report(required, optional, modules) do
    core = core_version() || "unknown"
    billing = to_version(Application.spec(:phoenix_kit_billing, :vsn))

    [
      "phoenix_kit_billing #{billing} does not match the resolved phoenix_kit #{core}.",
      section("Missing (billing calls these unguarded — these features are broken)", required),
      section("Missing (guarded — these features silently do nothing)", optional),
      section("Missing modules", modules),
      "Declared in PhoenixKitBilling.CoreCompat. Either pin phoenix_kit back or " <>
        "port the call sites to the new core API."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp section(_title, []), do: nil

  defp section(title, entries) do
    "#{title}:\n" <> Enum.map_join(entries, "\n", &("  - " <> describe(&1)))
  end

  defp describe({module, fun, arity}), do: "#{inspect(module)}.#{fun}/#{arity}"
  defp describe(module), do: inspect(module)

  defp to_version(nil), do: "(unloaded)"
  defp to_version(vsn), do: List.to_string(vsn)
end
