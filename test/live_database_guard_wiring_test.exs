defmodule PhoenixKitBilling.LiveDatabaseGuardWiringTest do
  @moduledoc """
  S014: `PhoenixKitBilling.Test.LiveDatabaseGuardTest` calls `check!/1`
  directly — it proves the logic is correct, not that `test_helper.exs`
  actually calls it. Deleting the call from `test_helper.exs` leaves that
  test green; it would prove the module still works, not that anything
  still protects a real `mix test` run.

  This test runs `test_helper.exs` for real, as a genuine `mix test`
  subprocess, with `PGDATABASE` set to one of the exact live database
  names the guard exists to refuse. It never lets that subprocess reach a
  real Postgres server, though — `PGHOST` points at an address nothing is
  listening on. That is what makes it safe to name `phoenix_kit_dev`
  literally here: whatever the guard does or doesn't do, no real Postgres
  exists at the address this subprocess is given, so it can never actually
  touch the real database.

  Verified live (mutation, not assumption) that this still tells a correct
  refusal apart from a cut wiring call: with the `check!/1` call commented
  out, the subprocess does NOT fail — `test_helper.exs`'s own existing
  "can't reach the database" fallback (already there for a genuinely
  missing DB) catches the bogus host, prints its own warning, excludes
  `:integration`, and exits 0 normally, since this test file needs no
  database at all. A correct refusal looks categorically different: a
  nonzero exit and the guard's own `LiveDatabaseError` in the output,
  before that fallback ever gets a chance to paper over anything. This
  test asserts exactly that pair (exit code, exception name) rather than
  looking for a connection-failure message that a cut wiring call turns
  out not to produce.
  """

  use ExUnit.Case, async: true

  # A loopback port nothing binds inside this container's test run —
  # `ECONNREFUSED` is near-instant, unlike a routed-but-silent address
  # (which would hang for a connect timeout instead of failing fast).
  @unreachable_host "127.0.0.1"
  @unreachable_port "1"

  for live_db <- ~w(phoenix_kit_dev decor_3d_print_dev phoenixkit_hello_world_dev) do
    test "refuses before any connection attempt when PGDATABASE=#{live_db}" do
      env = [
        {"PGDATABASE", unquote(live_db)},
        {"PGHOST", @unreachable_host},
        {"PGPORT", @unreachable_port},
        {"PGUSER", "postgres"},
        {"PGPASSWORD", "postgres"},
        {"MIX_ENV", "test"}
      ]

      # One fast, unrelated test file — test_helper.exs's boot code runs
      # unconditionally as part of loading the suite, regardless of which
      # test is targeted.
      {output, exit_code} =
        System.cmd("mix", ["test", "test/live_database_guard_test.exs"],
          env: env,
          stderr_to_stdout: true,
          cd: File.cwd!()
        )

      refute exit_code == 0,
             "a boot with PGDATABASE=#{unquote(live_db)} must refuse, not succeed:\n#{output}"

      # Matches the raised-exception banner specifically
      # (`** (...LiveDatabaseError) ...`), not a bare "LiveDatabaseError"
      # substring — this repo's `Code.require_file`-based support loading
      # makes every subprocess boot print "redefining module
      # ...LiveDatabaseError" compiler warnings regardless of whether the
      # guard actually fires, so a bare substring check would pass even on
      # a cut wiring call.
      assert output =~ "** (PhoenixKitBilling.Test.LiveDatabaseGuard.LiveDatabaseError)",
             "process failed, but not with the guard's own exception — some other crash " <>
               "reached this nonzero exit instead:\n#{output}"

      assert output =~ unquote(live_db),
             "refusal happened but didn't name the actual database, not the legible " <>
               "message the guard promises:\n#{output}"
    end
  end

  test "an isolated test database name is not refused — the guard does not block a real run" do
    # No PGHOST/PGUSER/PGPASSWORD overrides here on purpose: this process is
    # itself already running as a `mix test` inside this exact repo, which
    # only happens with a working, resolved connection to the real isolated
    # test database — inheriting that ambient environment gives the
    # subprocess a genuine, already-proven-safe connection without this
    # tracked file ever needing to know a password or a machine-specific
    # path (the same reason `pk-test` itself lives outside the repo).
    env = [{"PGDATABASE", System.get_env("PGDATABASE", "phoenix_kit_billing_test")}]

    {output, exit_code} =
      System.cmd("mix", ["test", "test/live_database_guard_test.exs"],
        env: env,
        stderr_to_stdout: true,
        cd: File.cwd!()
      )

    assert exit_code == 0,
           "a boot against the real isolated test database must succeed, not be blocked " <>
             "by the live-database guard:\n#{output}"

    # Same reasoning as the raise-banner match above: a bare "LiveDatabaseError"
    # substring is always present in this repo's compiler warnings, guard fired
    # or not, so it can't distinguish a real refusal from noise.
    refute output =~ "** (PhoenixKitBilling.Test.LiveDatabaseGuard.LiveDatabaseError)",
           "the guard fired on a database it must not refuse:\n#{output}"
  end
end
