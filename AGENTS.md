# AGENTS.md

Guidance for AI agents working on `phoenix_kit_billing`.

## Overview

Billing for PhoenixKit: currencies, billing profiles, orders, invoices,
transactions and credit notes, subscriptions and subscription types, payment
methods and provider integrations. Subscriptions run on **internal control** —
they live in this module's tables and providers only collect money. Ships admin
LiveViews for every entity, two customer pages, print views, provider webhook
endpoints, and Oban workers for renewals and dunning.

- **Depends on:** `phoenix_kit` `>= 2.44.0 and < 3.0.0` (Hex). No sibling `phoenix_kit_*` deps.
  Runtime libraries: `phoenix_live_view ~> 1.1`, `phoenix ~> 1.7`,
  `ecto_sql ~> 3.12`, `oban ~> 2.20`, `uuidv7 ~> 1.0`, `stripity_stripe ~> 3.2`,
  `req ~> 0.5`, `jason ~> 1.4`, `gettext ~> 1.0`.
- **Consumed by:** `phoenix_kit_ecommerce` (hard dependency). `phoenix_kit_projects`
  picks up the "Customer billing" project extension by duck-typing
  `phoenix_kit_project_extensions/0` — neither package depends on the other.
- **Admin surface:** `Billing` tab at `/admin/billing` with subtabs Dashboard,
  Orders, Invoices, Transactions, Subscriptions, Subscription Types, Billing
  Profiles, Currencies, Payment Providers (`/admin/settings/billing/providers`);
  a settings tab at `/admin/settings/billing`; user-dashboard tabs "My Orders"
  (`/dashboard/billing-orders`) and "Billing Profiles"
  (`/dashboard/billing-profiles`). Both are also offered in the avatar
  dropdown (`Tab` option `user_menu:`), but only while the shop module is
  enabled — `user_menu_with_shop?/1` checks the `"shop"` key duck-typed.
- **Module key** `"billing"`; settings prefix `billing_`. `required_modules/0`
  returns `["emails"]` (invoice delivery).

## What this module does NOT do

- **No storefront.** Cart, checkout UI and catalogue pricing belong to
  `phoenix_kit_ecommerce`; this module owns the money objects it creates.
- **No provider-owned subscriptions.** Providers handle hosted checkout, saving
  a payment method, charging a saved method and refunds. Renewal schedules,
  trials, dunning and status live here.
- **No authorization in the context API.** `PhoenixKitBilling.*` context
  functions (and the `compat/billing.ex` re-exports) take no scope on purpose —
  hosts call them from controllers, workers and scripts under authority this
  package cannot know. Capability checks are bundled-UI policy in
  `PhoenixKitBilling.Web.Authz`. Ownership guards (billing-profile ownership,
  order-user scoping) stay in the context regardless; those are invariants, not
  UI policy.
- **No JavaScript.** No hooks, no `js_sources/0`, no inline `<script>`.
- **No provider credentials in `phoenix_kit_payment_provider_configs`.** That
  core-created table is adopted by this module's migration chain but no
  application code reads or writes it; credentials live in `phoenix_kit_settings`
  via `PhoenixKitBilling.Providers`.
- **No floats for money**, ever.

## Commands

```bash
mix deps.get
createdb phoenix_kit_billing_test          # once; DB-backed tests are tagged :integration and auto-skip without it
mix test
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer; run before every commit
```

`phoenix_kit*` deps resolve from Hex. To run against a local checkout, export
`<APP>_PATH` (the dep's app name upper-cased plus `_PATH`); `pk_dep/3` in
`mix.exs` swaps the Hex pin for a `path:` dep at resolve time. Unset means the
Hex pin, so `mix hex.publish` is unaffected. Run `mix deps.get` with the var
exported before the first `mix test` (a stale lock aborts on the optional
`igniter` dep), and never commit a hand-edited `path:` tuple.

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix deps.get && PHOENIX_KIT_PATH=../phoenix_kit mix test
```

`mix precommit` here also runs `deps.unlock --check-unused` and `mix hex.audit`
before the quality chain. `mix quality` / `mix quality.ci` run the quality chain
alone.

## Conventions

- **Module key `"billing"`** in every callback. Tab ids are prefixed
  `:admin_billing`, `:admin_settings_billing` and `:dashboard_*`; URL segments
  use hyphens (`billing/subscription-types`), never underscores.
- **Paths come from `PhoenixKitBilling.Paths`.** Never hardcode a URL in a
  LiveView, controller or template; use `Paths` for this module's pages and
  `PhoenixKit.Utils.Routes.path/1` for cross-module links (it applies the host's
  URL prefix and locale segment).
- **Routing split.** List pages are auto-generated from the `live_view:` field on
  `admin_tabs/0` entries. Detail, form and print routes are declared in
  `Web.Routes.admin_routes/0` and `admin_locale_routes/0` (same route list, `_locale`
  route-name suffix) — a path is registered by one mechanism or the other, never
  both. Public webhook routes come from `Web.Routes.generate/1`, reached through
  `route_module/0`. A host never hand-registers any of them.
- **LiveViews use `use Phoenix.LiveView`** plus `use Gettext, backend:
  PhoenixKitBilling.Gettext` and explicit imports of the core components they
  need (`PhoenixKitWeb.Components.Core.*`). They do not use the `PhoenixKitWeb`
  macro and do not wrap templates in `LayoutWrapper` — admin chrome comes from
  core's route wiring. Assigns available in admin pages:
  `@phoenix_kit_current_scope`, `@current_locale`, `@url_path`.
- **Gettext:** own backend `PhoenixKitBilling.Gettext` over `priv/gettext`
  (`en`, `et`, `ru`, `uk`, `de`, `fr` — `de`/`fr` cover only the shared billing
  profile form so far). `billing_tab!/1` injects `gettext_backend:` and
  `gettext_domain: "default"` into every `Tab.new!/1` call, so tab labels
  localize. `priv/gettext/default.pot` is **maintained by hand** — tab labels are
  plain strings inside `Tab.new!(label: ...)` and `mix gettext.extract` cannot
  see them. Add the msgid to the `.pot`, then `mix gettext.merge priv/gettext`.
- **JS hooks: none.** If one is ever needed, prefer a core hook; ship your own
  only through a prebuilt bundle declared by `js_sources/0` under a namespaced
  global. Never register a hook from an inline `<script>` — morphdom does not
  execute inserted script tags, so the hook vanishes on LiveView navigation.
- **`css_sources/0` returns `[:phoenix_kit_billing]`.** Core's
  `:phoenix_kit_css_sources` compiler collects it from every discovered module and
  regenerates the host's `assets/css/_phoenix_kit_sources.css`, emitting
  `@source "../../deps/phoenix_kit_billing";`. Without the callback Tailwind never
  scans this package and purges every class unique to it. The bare app-name atom
  already covers path deps — the compiler reads the host's dep tuple.
- **`enabled?/0` rescues and returns `false`** (the database may not be up).
- **Activity logging goes through `PhoenixKitBilling.Activity`**, at the LiveView
  layer, on the `{:ok, _}` branch of a successful mutation — never inside context
  functions, which stay pure and scope-less. The wrapper adds the module key
  and the actor role to core's `PhoenixKit.Activity.log/3`, which never
  raises; the actor and role come from `PhoenixKitWeb.Actor`.
  Actions read `billing.<resource>_<verb>`. **PII rule:** log uuids, statuses,
  amounts, currency codes, document numbers and counts only — never email, phone,
  names, card data, tokens or free text.
- **Audit actions are not notify actions.** `Activity.log/1` auto-derives
  notifications from registered actions, so audit rows use distinct strings
  (`billing.invoice_issued_audit` and friends). Reusing a notify action in an
  audit row delivers a duplicate on top of the explicit fan-out.
- **Sub-permissions are re-checked in the UI.** Core's route gate admits anyone
  holding base `"billing"`. Every mutating event handler re-checks the specific
  capability through `Web.Authz`, and pages showing customer data check on mount;
  `Authz.can?/2` fails closed on an absent or malformed scope. Background jobs are
  authorized at enqueue time by the LiveView that starts them; the workers
  themselves run without a scope by design.
- **Providers must never default a currency.** A caller that omits `:currency`
  gets a raise, not a fallback. `PhoenixKitBilling.Providers.@providers` is the
  registry to sweep when a rule applies to "every provider", and
  `test/phoenix_kit_billing/providers/currency_required_test.exs` enumerates it
  and fails until a newly added provider is classified `:requires_currency` or
  `{:exempt, reason}`. EveryPay is the one exempt case: it charges in the currency
  fixed by the processing account and sends no currency field.
- **Money is `Decimal`.** Schemas use UUIDv7 primary keys
  (`@primary_key {:uuid, UUIDv7, autogenerate: true}`) and every table-backed
  schema does `use PhoenixKit.SchemaPrefix`.
- **Async billing work runs on Oban** (renewal and dunning workers). Never spawn a
  bare `Task` for it.
- **Config lives in PhoenixKit Settings**, not application env; read it through
  `PhoenixKitBilling.get_config/0` and friends. Provider registration is automatic
  (`ApplicationIntegration.register/0` from `Supervisor.init/1`); a host configures
  nothing by hand.
- **`CoreCompat` is the inventory of what core owes this package.** When core
  moves an API, update the call sites and the `CoreCompat` list in the same commit.
  Never delete an entry to make the suite green.
- **The compat shim delegates in both directions.** `compat/billing.ex` redefines
  the legacy `PhoenixKit.Modules.Billing` namespace; core resolves callbacks with
  `function_exported?/3` against whichever module a host registered, so a delegate
  missing there is silent.

### Landmines

- **Tab labels never reach the `.pot` automatically.** A new tab renders in raw
  English under `ru`/`et`/`uk` unless you add the msgid by hand; `pot_drift_test.exs`
  fails when you forget.
- **Losing `css_sources/0` or a compat delegate is silent** — both are resolved
  with `function_exported?/3`, so the symptom is Tailwind purging billing classes
  or notifications disappearing from a host, far from the cause.
  `compat_delegate_test.exs` guards both directions.
- **Do not copy core's path-dep `@source_root` example verbatim.** It assumes the
  callback lives at `lib/<app>/<app>.ex`. Here it lives in
  `lib/phoenix_kit_billing.ex`, so `__DIR__` is `<pkg>/lib` and `../..` resolves to
  `deps/` — an `@source` over the whole dependency tree.
- **Webhooks need the host's raw body.** Without
  `PhoenixKitBilling.Plugs.CacheBodyReader` in the host's `Plug.Parsers`, every
  provider webhook returns `400` with `:no_raw_body` before processing — see
  Architecture below.

## Architecture

A library, not a standalone Phoenix app: a `PhoenixKit.Module` implementation
that core auto-discovers by scanning `.beam` files at startup.

```
lib/phoenix_kit_billing.ex               # PhoenixKit.Module behaviour + main context
lib/phoenix_kit_billing/
├── activity.ex                          # Activity-log wrapper (module key + actor role)
├── application_integration.ex           # Provider registration at boot
├── core_compat.ex                       # Declared core API surface + boot report
├── document_branding.ex                 # Logo + footer text for printed documents and emails
├── email_defaults.ex                    # Default invoice/receipt email copy
├── errors.ex                            # Atom errors -> gettext strings
├── events.ex                            # PubSub broadcasts
├── gettext.ex                           # Module gettext backend
├── invoice_events.ex                    # Durable paid/refunded/voided hook for other modules (Oban)
├── migrations.ex                        # Module-owned migration chain
├── notifications.ex                     # Audience resolution + copy for core notifications
├── paths.ex                             # Centralized URL helpers
├── supervisor.ex                        # Registers providers, logs the CoreCompat report
├── compat/                              # Legacy PhoenixKit.Modules.Billing delegates
├── mix_tasks/                           # phoenix_kit_billing.install
├── plugs/cache_body_reader.ex           # Raw-body cache for webhook signatures
├── providers/                           # Provider behaviour (10 callbacks, `detach_payment_method/1` optional), registry, 4 impls, types
├── schemas/                             # 11 Ecto schemas
├── utils/                               # IBAN data, webhook_processor.ex
├── workers/                             # Oban: subscription renewal, dunning
└── web/
    ├── routes.ex                        # generate/1 (webhooks) + admin_routes/0 + admin_locale_routes/0
    ├── webhook_controller.ex            # stripe / paypal / razorpay / everypay actions
    ├── authz.ex                         # Sub-permission checks for the bundled LVs
    ├── <entity>.ex / <entity>_form.ex   # Admin LiveViews (list, form, detail)
    ├── *_print.ex                       # Invoice, receipt, credit note, payment confirmation
    │                                    #   (shared parts: components/print_document.ex)
    ├── project_billing_live.ex          # "Customer billing" project-extension tab
    └── components/                      # CurrencyDisplay, status badges, settings tabs, subscription helpers, BillingProfileFields (shared billing profile form fields)
```

### Schemas and tables

| Schema | Table | Notes |
|---|---|---|
| `BillingProfile` | `phoenix_kit_billing_profiles` | Individual and company details, address, tax ID, IBAN |
| `Order` | `phoenix_kit_orders` | Line items, status, billing snapshot, frozen `base_currency`/`exchange_rate`/`base_total` |
| `Invoice` | `phoenix_kit_invoices` | Generated from an order; receipt generation |
| `Transaction` | `phoenix_kit_transactions` | Payments, refunds, credit notes |
| `Subscription` | `phoenix_kit_subscriptions` | Renewal cycle, dunning state |
| `SubscriptionType` | `phoenix_kit_subscription_types` | Plan pricing, interval, trial |
| `PaymentMethod` | `phoenix_kit_payment_methods` | Saved provider methods |
| `PaymentOption` | `phoenix_kit_payment_options` | Checkout options |
| `Currency` | `phoenix_kit_currencies` | Rates, `is_default`, `rounding_rule`, `rate_updated_at` |
| `WebhookEvent` | `phoenix_kit_webhook_events` | Provider event log |
| `NumberSequence` | `phoenix_kit_billing_number_sequences` | Counter behind order, invoice, receipt and transaction numbers, one row per (scope, year); created by V7 |

Invoice status workflow: `draft → sent → paid`, with `sent → overdue → paid` and
`→ void` as the exits.

**The trash.** `Order` and `Invoice` carry `trashed_at` / `trashed_by_uuid` (V8),
billing's own: `changeset/2` cannot set or clear them, only `trash_order/2`,
`restore_order/2`, `trash_invoice/2` and `restore_invoice/2` do. Trash is the only
"delete" the admin UI has; nothing purges it. Only a `draft` or `cancelled` order
without an open invoice (neither void nor in the trash) can be trashed, and only
a `draft` invoice that was never sent - an issued invoice is voided. The status
does not change, no email goes out, and the number stays used. A trashed order or
invoice refuses every change with `:order_trashed` / `:invoice_trashed`
(`get_order/2`, `get_invoice/2` and the lookups by number still find it);
`put_order_sync/2` still takes an external system's mark. Every listing, count and
the dashboard leave the trash out by default (`trashed: :only | :include`
brings it back), and so do a customer's orders, the invoices preloaded on them
and `get_order_by_uuid/2`. An invoice cannot be created for, or restored onto,
an order in the trash or cancelled (`:order_trashed`, `:order_cancelled`): the
checks lock the order row against `trash_order/2`, and `update_invoice/2` applies
them when it moves an invoice onto another order. Trashing and restoring do not
touch `updated_at`. A void invoice of an order in the trash stays in the invoice
lists: it is an issued document, and only a draft can be trashed.

### Contexts and services

- **`PhoenixKitBilling`** — system config, and CRUD plus lifecycle for orders,
  invoices, transactions, subscriptions, billing profiles and currencies.
- **`Events`** — PubSub broadcasts for LiveView updates.
- **`Providers`** — registry (`:stripe`, `:paypal`, `:razorpay`, `:everypay`),
  availability checks, routing to the right implementation.
- **`Utils.WebhookProcessor`** — normalizes provider webhooks into transactions
  and status updates.
- **`EmailDefaults`** — the fallback copy for the four financial emails, handed
  to `PhoenixKit.Mailer.send_from_template/4` as `:defaults`. Resolution order is
  an active database template, then a host override file for the recipient's
  locale, then this — so billing owns its own copy rather than depending on
  `phoenix_kit_emails` seeding it. Each email is a `subject`, a `markdown` body
  (the HTML version: a button to the document, the line items as
  `{{{line_items_table_html}}}`, which billing builds escaped and styled inline)
  and a `text` body (`{{line_items_text}}`). `PhoenixKitBilling.email_send_opts/4`
  is everything a send passes: the defaults, `layout: "billing"` and the
  customer's `locale:`. `catalog_entries/0` feeds core's email preview through
  `email_templates/0`. `line_items_html` stays bare `<tr>` rows — database
  templates and exported `html.html` files wrap it in their own table.
- **`Notifications`** — resolves the admin audience as the union of permission
  holders, Owner-role holders and `"*"` superadmins (the first alone misses the
  primary operator of a default install). Notification copy carries a document
  number and an amount, never customer PII. Every send is wrapped: a notification
  reports a committed fact and must never be able to undo it.

### Currency cache

`children/0` starts a `PhoenixKit.Cache` named `:billing_currencies` (5-minute
TTL), picked up automatically by `PhoenixKit.Supervisor` — no host wiring.
`Currency.present/3` makes up to three currency queries per call and a catalogue
page renders dozens of prices; the cache makes that O(1) after the first miss.
`get_base_currency/0` and `get_currency_by_code/1` read it,
`invalidate_currency_cache/0` clears it and then issues a `Cache.stats/1` call as
a barrier, so a subscriber reacting to `{:currencies_changed, code}` cannot
observe a stale entry.

### PubSub topics

`phoenix_kit:billing:orders`, `:invoices`, `:profiles`, `:transactions`,
`:credit_notes`, `:subscriptions`, `:currencies`. Every topic also supports a
per-user form with a `:user:<user_uuid>` suffix.

Trashing announces `{:order_trashed, order}` / `{:order_restored, order}` and
`{:invoice_trashed, invoice}` / `{:invoice_restored, invoice}` on the order and
invoice topics - and nothing else with them: not `:order_updated`, `:order_cancelled`
or `:invoice_voided`, and no durable `InvoiceEvents` event. A subscriber with a
strict `handle_info/2` needs a catch-all clause for these.

### Permissions

Base key `"billing"` is admin-area read access. Sub-permissions (core enforces
sub-implies-base): `manage_orders`, `manage_invoices`, `manage_subscriptions`,
`manage_settings`. The split follows what an operator would actually delegate —
chasing invoices is not rotating provider API keys, and neither is refunding an
order.

⚠️ Core auto-grants a **new** sub-permission to the Admin system role only, so a
custom role holding base `"billing"` keeps its reads and loses mutations until an
operator re-grants. Secure by default, but a breaking authorization change for
that host — say so when adding one.

### Settings keys

All stored through `PhoenixKit.Settings` under module `"billing"`, prefix
`billing_`:

- System: `billing_enabled`, `billing_tax_enabled`, `billing_default_tax_rate`,
  `billing_invoice_due_days`, `billing_payment_terms`, `billing_snapshot_policy`.
- Numbering prefixes: `billing_invoice_prefix` (`INV`), `billing_order_prefix`
  (`ORD`), `billing_receipt_prefix` (`RCP`), `billing_credit_note_prefix`,
  `billing_payment_confirmation_prefix`, `billing_transaction_prefix`.
- Company and bank: `billing_company_name`, `billing_company_country`,
  `billing_bank_account_holder` (company and bank details for invoice headers also
  come from core's `PhoenixKitWeb.Live.Settings.Organization`).
- Printed documents (`DocumentBranding`): `billing_document_logo_file_uuid` (a
  media-library file; unset falls back to core's `auth_logo_file_uuid`, then the
  company name) and `billing_document_footer` (free text closing every printable
  document and every financial email; at most 1000 characters, core's limit for
  a setting value). The settings page saves both in one transaction.
- Subscriptions: `billing_subscription_grace_days`, `billing_dunning_max_attempts`.
- Per provider: `billing_<provider>_enabled`, `_mode`, plus that provider's
  credential keys (`billing_stripe_secret_key`, `billing_paypal_client_id`,
  `billing_razorpay_key_id`, `billing_everypay_api_username`, …) and webhook
  secrets.

The base currency is the `is_default` row in `phoenix_kit_currencies`, not a
setting.

### Core compatibility

`mix.exs` requires `phoenix_kit >= 2.44.0 and < 3.0.0` — every core 2.x from
2.44.0 on and nothing else. Core 1.7 is excluded because core 2.0.0 squashed the
migration chain into a single `V135` baseline, and this module is verified only
against that baseline. The 2.44.0 floor is where email `markdown` parts, layout
groups (`layout: "billing"`) and the `email_templates/0` preview callback first
shipped — the email defaults are a `markdown` part, which an older core ignores.
2.38.0's `PhoenixKitWeb.Actor` and `PhoenixKit.Activity.log/3`, and 2.26's
`<.decimal_input>` and `PhoenixKit.Utils.Number.parse_decimal/2`, are subsumed.
Adopting a newer core API means raising the floor in the same commit.
`test/core_pin_conformance_test.exs` guards the requirement in both directions:
it fails if the pin is re-narrowed to a single minor (a three-segment `~> 2.38.0`
admits no 2.39), if it re-admits a core below the floor or 1.7, or if a local
`path:` override reaches a commit.

That covers *which* core resolves, not whether it still exports what this package
calls. `PhoenixKitBilling.CoreCompat` declares that surface in four lists —
unguarded `runtime_calls/0`, `optional_calls/0` already behind
`Code.ensure_loaded?/1`, `compile_time_modules/0` that are `use`d or `import`ed,
and `sibling_calls/0` owned by another package — and:

- `test/phoenix_kit_billing/core_api_contract_test.exs` fails with the missing
  functions named, so `mix test` after a core bump reports exactly what moved. One
  test re-derives the call list from billing's own AST, so a new call site nobody
  declared fails the suite instead of escaping the inventory.
- `Supervisor.init/1` logs the same report at boot: `:error` when unguarded calls
  are missing, `:warning` when only guarded ones are.

It does not cover semantics. A core that keeps `Settings.get_setting/2` and
changes its return shape passes every check here; only running the suite against
that core catches it (`PHOENIX_KIT_PATH`, above).

### Host integration

⚠️ **Webhook signature verification requires the host to wire
`PhoenixKitBilling.Plugs.CacheBodyReader` into `Plug.Parsers`.** Provider
webhooks verify signatures against the **raw** request body, so the host endpoint
must pass `body_reader: {PhoenixKitBilling.Plugs.CacheBodyReader, :read_body, []}`.
`mix phoenix_kit_billing.install` wires it automatically. Without it every webhook
returns `400` with `:no_raw_body` before any processing: the default parser has
already consumed the body and the signature check cannot run.

Exercising the Stripe webhook path on localhost (test keys, `stripe listen`, the
`whsec_…` secret, `stripe trigger`) is written up under "Testing Stripe locally"
in `README.md`.

## Database & migrations

Owns a versioned chain: `PhoenixKitBilling.Migrations` via `migration_module/0`,
marker `pkb_schema:<N>` as a `COMMENT ON TABLE
phoenix_kit_payment_provider_configs`, currently **V8**. A marker-less table reads
as version 0 (the core-baseline shape). `mix phoenix_kit.update` applies the chain
in hosts; the test suite applies it by executing
`Migrations.up_statements/2` as data (see Testing).

- **V1 adopts, it does not change.** `phoenix_kit_payment_provider_configs` is a
  core V135 baseline table; V1 runs a shape-identical `CREATE TABLE IF NOT EXISTS`
  with core's own index and constraint names and stamps the marker. From then on
  this chain owns the table's future shape. Because V1 changes nothing, core's
  `ExpectedSchema` manifest (which still audits the V135 shape) stays accurate and
  no core release is required. Never edit V1 — a shape change is V2+.
- **V2 shapes `phoenix_kit_currencies`** (also core-created): a partial unique
  index `phoenix_kit_currencies_default_uidx` on `(is_default) WHERE is_default`,
  plus `rounding_rule` (`varchar(16) NOT NULL DEFAULT 'exact'`) and
  `rate_updated_at`. Uniqueness of the default currency was held only by the
  transaction in `set_default_currency/1`; two `is_default` rows make
  `get_default_currency/0` raise `Ecto.MultipleResultsError`. A host can already be
  in that state, so V2 demotes every default but one (lowest `sort_order`, then
  oldest) immediately before creating the index — otherwise `CREATE UNIQUE INDEX`
  aborts the chain on exactly the databases that need it. That `UPDATE` is the only
  row-level write this chain makes to a core-created table, and it only repairs a
  state no reader can handle.
- **V3 adds `phoenix_kit_orders`' frozen-currency columns** — `base_currency`,
  `exchange_rate`, `base_total`, nullable, with the exact names and types core's
  own eventual migration uses, so that release's `ADD COLUMN IF NOT EXISTS` no-ops
  and its backfill still does the work. V3 deliberately backfills nothing:
  inventing a derivation here would duplicate — and risk disagreeing with — logic
  that belongs to whichever release owns getting it right. Every reader treats
  `nil` as "unknown".
- **V4 adopts the remaining core-baseline billing tables** (no shape change).
- **V6 closes V4's ordering gap**: V2 and V3 alter `phoenix_kit_currencies` and
  `phoenix_kit_orders`, which V4 creates, so on a database without core's copy
  V2 failed first. V6 emits those two tables' base `CREATE TABLE IF NOT EXISTS`
  (shared with V4) **between V1 and V2**, and carries core's seed rows (EUR
  default/GBP/USD currencies; bank_transfer/cod/paypal/stripe payment options)
  inside the `DO` block that creates the table — so they appear only on a
  database this chain builds and never over a host's own rows (re-seeding with
  `ON CONFLICT DO NOTHING` would restore deleted ones, and EUR as default would
  collide with V2's unique index). A target below 6 builds the old chain. Core
  still creates all of these first; since V6 this chain builds them alone
  (`test/phoenix_kit_billing/integration/migrations_build_alone_test.exs`, seeds in
  `migrations_adoption_test.exs`). A shape change is a new version here, never a
  core migration. The email templates core seeds for billing are not carried:
  `EmailDefaults` is billing's own fallback.
- **V7 adds the number counter**: `phoenix_kit_billing_number_sequences`, the
  one table this chain creates itself (core never had it). Order, invoice,
  receipt and transaction numbers come from it, taken in the transaction that inserts the row
  using the number (`next_number/2` in `PhoenixKitBilling`); the old
  `count(rows of the year) + 1` handed out a taken number once a row was
  deleted. A generated number that a row already has is skipped (a savepoint,
  after lifting the counter to the highest number there; up to 20 tries). `down/1` below V7 drops the table. A create holds its counter row
  until its transaction ends; the lock order (counters, invoice rows and the order
  rows the trash and the invoice guards take) and the rules for calling a create
  inside your own transaction are in the "Lock order" section of the `Migrations`
  moduledoc and the `@doc`s.
- **V8 adds the trash**: `trashed_at` and `trashed_by_uuid` (no foreign key) on
  `phoenix_kit_orders` and `phoenix_kit_invoices`, plus a partial index per table
  over the rows not in the trash and one over the rows that are. `down/1` below V8
  drops the four columns and four indexes - never a table - so what was in the
  trash reads as not trashed again.
- **V5 lets a payer be a billing email instead of an account**:
  `phoenix_kit_invoices.user_uuid` and `phoenix_kit_transactions.user_uuid`
  drop `NOT NULL`, and `phoenix_kit_invoices_payer_check` requires a user or a
  non-blank `billing_details->>'email'`. `down/1` below V5 raises while guest
  rows exist rather than deleting or re-attributing money records.
- **One chain version per release, not one per column.** Related changes ride in
  the same version.
- **`down/1` never drops a core-created table.** It unstamps the marker and reverses the
  objects a version added (V3's columns, V2's index and columns). The tables are
  core-created; only core's own baseline rollback may drop them (V7's counter table,
  which this chain created, is the one `down/1` drops; V8's columns and indexes on
  core's orders and invoices tables are dropped, the tables never).
- A version that changes the shape of a core-created table can put core's
  `ExpectedSchema` manifest out of date — coordinate before adding one, do not
  assume silence means agreement. Core's own chain no longer touches module
  tables (since V223), so a change belongs here.
- The schema prefix is validated against `^[a-zA-Z_][a-zA-Z0-9_]*$` before it
  reaches interpolated DDL, and an invalid prefix must surface as the
  `ArgumentError`, never be swallowed into version 0.

All schemas `use PhoenixKit.SchemaPrefix` and use UUIDv7 primary keys, except
`NumberSequence`, which is keyed by (scope, year); migrations generate uuids with
`uuid_generate_v7()`, never `gen_random_uuid()`.

## Testing

Test database `phoenix_kit_billing_test`. Unit tests (schemas, changesets, pure
functions, the migration-statement parsers, the pin and pot guards) always run.
DB-backed tests are tagged `:integration` through `PhoenixKitBilling.DataCase` and
are excluded automatically when the database is absent or unreachable — the helper
probes with `psql -lqt` and falls back to a connection attempt.

`test/test_helper.exs`:

- `Code.require_file/2`s each `test/support` module explicitly. Elixir 1.19's
  `mix test` no longer auto-loads modules from `:elixirc_paths` test directories at
  test-helper time.
- Builds the schema with `PhoenixKit.Migration.ensure_current/2` (the call a host
  makes in production), then applies this module's chain on top by executing
  `PhoenixKitBilling.Migrations.up_statements/2` as data — `up/1` would need an
  `Ecto.Migrator` runner. **Both halves are required:** from V2 on, `Currency`
  declares columns only this chain creates, so core's baseline alone makes every
  currency insert raise `undefined_column`.
- Starts the pieces the host supervisor would: `PhoenixKit.PubSub.Manager`,
  `PhoenixKit.Cache.Registry` then the `:billing_currencies` cache (in that order —
  without it the currency getters degrade to a silent permanent cache miss and the
  query-count test measures the uncached number), `PhoenixKit.ModuleRegistry` with
  `PhoenixKitBilling` registered (without it every `Scope.can?/2` answers false and
  the authorization tests pass for the wrong reason), and
  `PhoenixKit.Users.RateLimiter.Backend` (registration flows crash without its ETS
  table).
- Forces `PhoenixKit.Config`'s URL prefix to `/` in `:persistent_term`, so the test
  router matches admin paths at `/en/admin/billing/...`.
- Starts `PhoenixKitBilling.Test.Endpoint` (with `server: false`) only when the
  database is available.
- Excludes `:requires_phoenix_kit_i18n_api` when the resolved core lacks
  `PhoenixKit.Dashboard.Tab.localized_label/1`; those tests re-enable themselves on
  a core that ships it.
- Excludes `:requires_core_user_menu` when the resolved core lacks
  `PhoenixKit.Dashboard.Tab.user_menu?/2`; likewise re-enabled by a core that
  ships it.

Support modules under `test/support/`: `DataCase` (Ecto SQL sandbox),
`LiveCase` (LiveView cases wired to the test `Endpoint` + `Router`), `Test.Repo`,
`Test.Endpoint`, `Test.Router`, `Test.Layouts`, `Test.Hooks` (the test endpoint
does not load core's hooks, so this replicates what `live_session
:phoenix_kit_admin` does in production: populating
`@phoenix_kit_current_scope` and `@phoenix_kit_current_user` from the test
session), `ActivityLogAssertions`. Test-only deps: `lazy_html` for HTML assertions;
`.dialyzer_ignore.exs` filters known third-party warnings. `mix test.setup` creates
the test repo, `mix test.reset` drops and recreates it.


## Feature notes

| Feature | Constraint | Notes |
|---|---|---|
| Agentic Commerce payment leg | The payment leg maps onto the existing `Providers.Provider` behaviour and the Stripe provider (`charge_payment_method` plus webhook idempotency) — a watch-item, nothing is built. The feed and checkout endpoints belong to ecommerce or a bridge plugin, not here. | `dev_docs/agentic_commerce_payments.md` |

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. GitHub release via `gh release create` if the repo does those (`gh release list` shows whether it does).

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`).
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

## TODOs

- **Compat shim removal.** Delete `lib/phoenix_kit_billing/compat/billing.ex` and
  the `elixirc_options: [ignore_module_conflict: true]` line in `mix.exs` once core
  no longer ships the `PhoenixKit.Modules.Billing` namespace. The option exists only
  to tolerate that deliberate redefinition.
- **Component migration tail.** Subscription-type, billing-profile and order forms
  use core `<.input>/<.select>/<.textarea>`. Still raw HTML by design: the order
  form's customer and billing-profile dynamic selects and per-row line-item inputs
  (custom `phx-` handling, no changeset backing), checkbox and radio groups with
  bespoke daisyUI layouts, and the filter/action selects on list pages. Migrate one
  when it gains changeset backing.
