import Config

# Integration tests run against a real PostgreSQL database. Create it with:
#   createdb phoenix_kit_billing_test
config :phoenix_kit_billing, ecto_repos: [PhoenixKitBilling.Test.Repo]

config :phoenix_kit_billing, PhoenixKitBilling.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  # test_helper.exs never creates this database itself. README's Development
  # section lists `mix deps.get && mix test` with no createdb step, while a
  # separate section below it adds `createdb phoenix_kit_billing_test` as a
  # one-time step — a reader who follows the first path hits the same silent
  # skip as a host that cannot create databases at all. PGDATABASE lets
  # either kind of reader point the suite at an existing database instead of
  # losing the whole integration half without a clear reason why. Same shape
  # as phoenix_kit_document_creator.
  #
  # Known limitation: PGDATABASE overrides MIX_TEST_PARTITION entirely, so a
  # partitioned run would share one database across partitions instead of
  # getting one each. Harmless today — this repo has no partitioned CI — but
  # worth knowing before adding one.
  database:
    System.get_env(
      "PGDATABASE",
      "phoenix_kit_billing_test#{System.get_env("MIX_TEST_PARTITION")}"
    ),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Wire repo for PhoenixKit.RepoHelper — without this, context-layer DB calls crash.
config :phoenix_kit, repo: PhoenixKitBilling.Test.Repo

# Test Endpoint for LiveView tests. `phoenix_kit_billing` has no endpoint
# of its own in production — the host app provides one — so this
# endpoint only exists for `Phoenix.LiveViewTest`.
config :phoenix_kit_billing, PhoenixKitBilling.Test.Endpoint,
  secret_key_base: String.duplicate("t", 64),
  live_view: [signing_salt: "billing-test-salt"],
  server: false,
  url: [host: "localhost"],
  render_errors: [formats: [html: PhoenixKitBilling.Test.Layouts]]

# The date that numbers are given a year by: a test can pin it.
config :phoenix_kit_billing, :number_clock, PhoenixKitBilling.Test.NumberClock

config :phoenix, :json_library, Jason

config :logger, level: :warning
