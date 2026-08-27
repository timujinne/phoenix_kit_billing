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
# via `PhoenixKit.Migration.ensure_current/2`, and lets the Ecto sandbox
# handle isolation. No module-owned DDL.

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
  try do
    case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
      {output, 0} ->
        exists =
          output
          |> String.split("\n")
          |> Enum.any?(fn line ->
            line |> String.split("|") |> List.first("") |> String.trim() == db_name
          end)

        if exists, do: :exists, else: :not_found

      _ ->
        :try_connect
    end
  rescue
    # `psql` not on PATH (CI / minimal env). Fall through to the
    # connection attempt — if the repo can't start, integration tests
    # are excluded; otherwise the existing rescue prints a hint.
    ErlangError -> :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""

      Test database "#{db_name}" not found — integration tests excluded.
      Run: createdb #{db_name}
    """)

    false
  else
    try do
      {:ok, _} = TestRepo.start_link()

      # Build the schema directly from core's versioned migrations — same
      # call the host app makes in production. `ensure_current/2`
      # re-applies any newly-shipped Vxxx migrations on every boot.
      PhoenixKit.Migration.ensure_current(TestRepo, log: false)

      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
      true
    rescue
      e ->
        IO.puts("""

          Could not connect to test database — integration tests excluded.
          Run: createdb #{db_name}
          Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""

          Could not connect to test database — integration tests excluded.
          Run: createdb #{db_name}
          Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_billing, :test_repo_available, repo_available)

# Minimal PhoenixKit services needed by the context layer.
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])

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

ExUnit.start(exclude: i18n_exclude ++ integration_exclude)
