defmodule PhoenixKitBilling.Test.LiveDatabaseGuard do
  @moduledoc """
  S014: this container's shell environment leaks `PGDATABASE=phoenix_kit_dev`
  (and `MIX_ENV=dev`) into every process, including `mix test` run bare, in
  any working directory (see `/root/bin/pk-test`'s own header comment).
  `config/test.exs` honors `PGDATABASE` — precisely so the suite CAN target
  an already-provisioned database when the running role lacks `CREATEDB` —
  which means a bare `mix test` run in this container silently resolves its
  test database to the real, live dev database and hands it straight to the
  Ecto sandbox to migrate and seed.

  `pk-test` already refuses this — but it lives OUTSIDE this repo on
  purpose (a fork shared with an external maintainer must not carry a
  machine-specific wrapper), so it only protects a caller who remembers to
  use it. This guard is the same refusal, INSIDE the repo, so `mix test`
  itself is safe regardless of how it's invoked.

  Deliberately NOT the `phoenix_kit_crm`/`phoenix_kit_entities`
  `SchemaOwnerGuard` pattern (a `schema_migrations` ownership marker):
  that mechanism only catches a database another *tracked, guard-wearing*
  package has already stamped — confirmed live (S014 recon) that it reads
  a database it has never seen, comment-less `schema_migrations` included,
  as `:ok`. A live dev database populated by ordinary `mix ecto.migrate`
  is exactly that shape: nothing has ever stamped it, so a marker check
  alone would wave it through. This guard instead refuses by NAME, against
  the specific databases this container must never let a test suite touch
  — the same check `pk-test` already makes, just checked here too.
  """

  @known_live_databases ~w(phoenix_kit_dev decor_3d_print_dev phoenixkit_hello_world_dev)

  defmodule LiveDatabaseError do
    defexception [:message]
  end

  @doc """
  Raises `LiveDatabaseError` if `database` names one of this container's
  known live databases. Takes the already-resolved name (what
  `config/test.exs` put in `Application.get_env/2`), not `PGDATABASE`
  itself — the config file's own fallback-when-unset logic is the single
  source of truth for what the suite will actually connect to, and
  duplicating it here would drift the moment either copy changed.
  """
  @spec check!(String.t()) :: :ok
  def check!(database) when is_binary(database) do
    if database in @known_live_databases do
      raise LiveDatabaseError,
        message: """
        Test database resolved to #{inspect(database)}, a live database this \
        container must never let a test suite touch (PGDATABASE leaks into \
        every shell here — see this module's moduledoc). Unset PGDATABASE, \
        or point it at an isolated test database instead.\
        """
    else
      :ok
    end
  end
end
