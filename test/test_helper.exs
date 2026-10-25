require Logger

# Test helper for PhoenixKitBilling.
#
# Level 1: Unit tests (schemas, changesets, pure functions) always run.
# Level 2: Integration tests (tagged `:integration` via PhoenixKitBilling.DataCase)
#          require PostgreSQL — automatically excluded when the database
#          is unavailable.
#
# First-time setup:
#
#   createdb phoenix_kit_billing_test
#
# After that, `mix test` boots the repo, runs core's versioned migrations
# via `PhoenixKit.Migration.ensure_current/2`, then applies this module's
# own chain (`PhoenixKitBilling.Migrations.up_statements/2`) on top, and
# lets the Ecto sandbox handle isolation.

# Elixir 1.19's `mix test` no longer auto-loads modules from
# `:elixirc_paths` test directories at test-helper time — only files
# matching `:test_load_filters` get loaded by the test runner. Explicit
# `Code.require_file/2` is needed before `test_helper.exs` references
# the support modules.
support_dir = Path.expand("support", __DIR__)

[
  "test_repo.ex",
  "test_layouts.ex",
  "hooks.ex",
  "test_router.ex",
  "test_endpoint.ex",
  "activity_log_assertions.ex",
  "data_case.ex",
  "live_case.ex",
  "live_database_guard.ex"
]
|> Enum.each(&Code.require_file(&1, support_dir))

alias PhoenixKitBilling.Test.Repo, as: TestRepo

db_name =
  Application.get_env(:phoenix_kit_billing, TestRepo, [])[:database] ||
    "phoenix_kit_billing_test"

# S014: refuse before anything else touches the database — see
# PhoenixKitBilling.Test.LiveDatabaseGuard's moduledoc for why this exists
# alongside (not instead of) the external `pk-test` wrapper.
PhoenixKitBilling.Test.LiveDatabaseGuard.check!(db_name)

db_check =
  if Code.ensure_loaded?(PhoenixKit.TestSupport.PostgresPreflight) do
    # One classified connection attempt, with the repo's OWN credentials and
    # transport, before anything starts the pool.
    #
    # This replaces a `psql -lqt` listing. That check asked the wrong question:
    # it ran as the shell's user over a unix socket, so it reported "the
    # database is there" and said nothing about whether the CONFIGURED role
    # could reach it over TCP. When it could not, the answer arrived minutes
    # later as a pool checkout timeout that reads like a flaky test.
    case PhoenixKit.TestSupport.PostgresPreflight.check(
           Application.get_env(:phoenix_kit_billing, PhoenixKitBilling.Test.Repo, [])
         ) do
      :ok ->
        :exists

      {:error, _reason, message} ->
        IO.puts(:stderr, "\n" <> message)
        :not_found
    end
  else
    :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""

      Cannot reach test database "#{db_name}" — integration tests excluded.
       The reason is printed above.
    """)

    false
  else
    try do
      {:ok, _} = TestRepo.start_link()

      # Build the schema directly from core's versioned migrations — same
      # call the host app makes in production. `ensure_current/2`
      # re-applies any newly-shipped Vxxx migrations on every boot.
      PhoenixKit.Migration.ensure_current(TestRepo, log: false)

      # Core's baseline is only half the shape. This module owns the rest
      # through its own chain (V2 adds `rounding_rule` / `rate_updated_at`
      # and the default-currency unique index to `phoenix_kit_currencies`),
      # and `PhoenixKitBilling.Currency` declares those columns — without
      # this, every currency insert in the suite raises `undefined_column`.
      # `up/1` needs an `Ecto.Migrator` runner, so the statements are
      # executed as data via the same `up_statements/2` the migration runs.
      PhoenixKitBilling.Migrations.up_statements()
      |> Enum.each(&Ecto.Adapters.SQL.query!(TestRepo, &1, []))

      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
      true
    rescue
      e ->
        IO.puts("""

          Could not connect to test database — integration tests excluded.
          The reason is printed above.
          Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""

          Could not connect to test database — integration tests excluded.
          The reason is printed above.
          Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_billing, :test_repo_available, repo_available)

# Minimal PhoenixKit services needed by the context layer.
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])

# §13 currency cache: production gets this via `PhoenixKitBilling.children/0`,
# picked up by `PhoenixKit.Supervisor` (core's own tree, not started here).
# This suite manually wires the same two pieces that supervisor would have
# started, in the same order (Registry, then the named cache) — without
# this, `get_base_currency/0`/`get_currency_by_code/1` degrade to their
# unwarmed :noproc fallback (a permanent cache miss, silently) and
# currency_query_count_test.exs would measure the un-cached number even
# after caching is implemented.
{:ok, _pid} = PhoenixKit.Cache.Registry.start_link()
{:ok, _pid} = PhoenixKit.Cache.start_link(name: :billing_currencies, ttl: :timer.minutes(5))

# The permission layer resolves a sub-permission through the module
# registry: Scope.can?/2 requires feature_enabled?/1, which asks the
# registry which module owns a key. Without it EVERY can?/2 answers false
# and the authorization tests would pass for the wrong reason.
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])
:ok = PhoenixKit.ModuleRegistry.register(PhoenixKitBilling)

# Flows that register users go through the Hammer-backed rate limiter.
# Without this its ETS table is absent and registration crashes. Mirrors
# core's `phoenix_kit/test/test_helper.exs`.
{:ok, _pid} = PhoenixKit.Users.RateLimiter.Backend.start_link([])

# Force PhoenixKit's URL prefix cache to "/" for tests so `Routes.path/1`
# etc. produce paths the test router can match. Admin paths always get
# the default locale ("en") prefix, so our router scope is `/en/admin/billing`.
:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")

# Start the test Endpoint so Phoenix.LiveViewTest can drive our LiveViews
# via `live/2` with real URLs. Runs with `server: false`, so no port is
# opened. Only starts when the test DB is available — without DB,
# LiveView tests are excluded anyway.
if repo_available do
  {:ok, _} = PhoenixKitBilling.Test.Endpoint.start_link()
end

# i18n tests require phoenix_kit with the `gettext_backend` API
# (see BeamLabEU/phoenix_kit#522). When building against an older
# published phoenix_kit lacking `PhoenixKit.Dashboard.Tab.localized_label/1`,
# exclude those tests — they run automatically once the dep resolves to a
# release that includes the API.
i18n_exclude =
  if Code.ensure_loaded?(PhoenixKit.Dashboard.Tab) and
       function_exported?(PhoenixKit.Dashboard.Tab, :localized_label, 1) do
    []
  else
    Logger.info(
      "[test_helper] PhoenixKit.Dashboard.Tab.localized_label/1 not available — " <>
        "i18n tests excluded. They will run automatically once `phoenix_kit` is " <>
        "upgraded to a release that ships the gettext_backend API."
    )

    [:requires_phoenix_kit_i18n_api]
  end

integration_exclude = if repo_available, do: [], else: [:integration]

# The avatar-dropdown flag (`Tab` option `:user_menu`, read by
# `Tab.user_menu?/2`). An older core ignores the option, so the tests about
# it run once the dep resolves to a release that ships it.
user_menu_exclude =
  if Code.ensure_loaded?(PhoenixKit.Dashboard.Tab) and
       function_exported?(PhoenixKit.Dashboard.Tab, :user_menu?, 2) do
    []
  else
    Logger.info(
      "[test_helper] PhoenixKit.Dashboard.Tab.user_menu?/2 not available - avatar-dropdown " <>
        "tab tests excluded. They will run automatically once `phoenix_kit` is " <>
        "upgraded to a release that ships it."
    )

    [:requires_core_user_menu]
  end

# `migrations_build_alone_test.exs` uses core's
# `PhoenixKit.TestSupport.ModuleChainCheck`, which the first core release after
# 2.64.1 ships; against an older core in `deps/` it is excluded.
chain_check_exclude =
  if Code.ensure_loaded?(PhoenixKit.TestSupport.ModuleChainCheck),
    do: [],
    else: [:requires_module_chain_check]

ExUnit.start(
  exclude: i18n_exclude ++ integration_exclude ++ user_menu_exclude ++ chain_check_exclude
)
