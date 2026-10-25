## Unreleased

### Changed

- The migration chain is now V6. V2 and V3 alter `phoenix_kit_currencies` and
  `phoenix_kit_orders`, which V4 creates, so on a database without core's copy
  of those tables the chain failed at V2 before adopting anything. V6 emits the
  base `CREATE TABLE IF NOT EXISTS` of those two tables between V1 and V2 (a
  no-op wherever core created them), carrying core's seed rows (the EUR/GBP/USD
  currencies and the bank transfer, cash on delivery, PayPal and card payment
  options) only when it creates the table itself, never over a host's own rows.
  Published versions' statements are untouched, and `down/1` never drops a
  table. With it the chain builds all eleven tables without core
  (`test/phoenix_kit_billing/integration/migrations_build_alone_test.exs`, core's
  `ModuleChainCheck`). See core's
  `dev_docs/plans/2026-10-25-module-table-ownership.md`.

### Fixed

- Four subscription tests no longer `@tag :skip`: `subscription_type_uuid`
  exists on a from-scratch build, so the documented "core chain gap" is gone.
  The matching AGENTS.md landmine and TODO are removed.

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 0.23.0 - 2026-10-24

An order revision and sync mark for external systems (PR #54), locked order
transitions and refund bounds (PR #56), an `:order_refunded` event (PR #57)
and working payment confirmation links (PR #58).

### Added

- **Order revision and external sync mark.** `PhoenixKitBilling.Order.revision/1`
  counts the changes an external system cares about (status, amounts, order
  number, buyer, the confirmation/payment/cancellation times), bumped under the
  order row lock. `PhoenixKitBilling.put_order_sync/2` records an external
  system's mark (`state: "synced" | "failed"`, the `revision` it took, and
  optional `external_id`, `external_number`, `external_status`, `error`) in
  `metadata["sync"]` without touching the order or broadcasting; it returns
  `{:error, :stale_revision}` when the order changed since that revision, and
  refuses a mark with no revision. `Order.sync/1` reports the mark, or
  `"pending"` once the order changes again, and `Order.where_sync/2`
  narrows a query to `:pending`, `:synced` or `:any` orders. (PR #54)
- **`:order_refunded` event** on `phoenix_kit:billing:orders` and the per-user
  orders topic (`Events.broadcast_order_refunded/1`), sent when an order is
  marked refunded, including by the refund that zeroes its invoice. The admin
  order list and detail pages refresh on it. (PR #57)

### Changed

- `confirm_order/1`, `mark_order_paid/2`, `mark_order_refunded/1` and
  `cancel_order/2` lock the order row and check the transition against the
  stored status, so a payment and a cancellation racing on the same order can
  no longer both succeed. Refusals are returned, not raised. The lock is
  `FOR NO KEY UPDATE`, so it does not block an invoice being created for the
  order. (PR #56)
- A refund larger than the invoice's locked `paid_amount` returns
  `{:error, :exceeds_paid_amount}` instead of raising
  `Ecto.InvalidChangesetError`. (PR #56)
- Order events raised by a payment or refund (`:order_confirmed`,
  `:order_paid`, `:order_refunded`) are broadcast after the transaction
  commits, alongside the invoice and transaction events, so a listener that
  re-reads the order sees the new state and a rolled-back payment announces
  nothing. The standalone order functions still broadcast as before.
- The Gettext backend compiles one module per locale and domain, so the
  catalogues compile in parallel instead of holding up dependent apps.
  Lookups are unchanged. (PR #53)
- Dependencies refreshed to `phoenix_kit` 2.64.1. The `phoenix_kit`
  requirement is unchanged.

### Fixed

- **"Print Payment Confirmation" on the invoice page and "View payment
  confirmation online" in the email led to a 404**; both now link to the
  `payment-confirmation` route. (PR #58)
- The payment confirmation and credit note print pages refuse a transaction
  that belongs to another invoice (it used to print one invoice's customer
  next to another's payment), report "Transaction is not a payment" / "is not
  a refund" instead of claiming billing is disabled, and re-validate when
  navigated to another invoice.
- A refund applied to an invoice whose `paid_amount` the caller held stale
  could leave the column out of step with the ledger; it is now applied to the
  locked invoice.

## 0.22.0 - 2026-10-13

The avatar dropdown lists "My Orders" and "Billing Profiles" beside a shop
(PR #52).

### Added

- **Avatar-menu entries for the user tabs.** Both user-dashboard tabs carry the
  core `user_menu:` option, gated by `PhoenixKitBilling.user_menu_with_shop?/1`:
  they appear in the dropdown only while the shop module (key `"shop"`,
  duck-typed) is installed and enabled. A core without the option ignores it, so
  the dependency floor is unchanged.

### Tests

- The shop gate is now covered on its positive path too: a stand-in `"shop"`
  module registered in `ModuleRegistry` proves the tabs reach the dropdown while
  it is enabled and leave it when it is switched off.

## 0.21.0 - 2026-10-10

A shared billing profile form (PR #50), the dashboard edit-link fix (PR #49)
and Ukrainian printed documents (PR #51).

### Added

- **`Web.Components.BillingProfileFields`** — the billing profile form fields,
  defined once and rendered by the dashboard form, the admin form and any other
  caller (the e-commerce checkout). Inputs bind to `@form[:field]`; the caller
  owns the `<form>`, its events and the submit button.
- `BillingProfile.fields_changeset/3` and `BillingProfile.form_fields/0` — the
  user-facing field rules without the owner or `is_default`, with
  `:require_email` and `:require_address` options, so a form with no persisted
  owner yet can validate. Field lengths mirror the column sizes and count code
  points like Postgres.
- **German (`de`) and French (`fr`) catalogues** for the shared billing profile
  form; every other string falls back to English.
- Ukrainian translations for the printed billing documents and the billing
  profile form.

### Changed

- The billing profile validation messages are translated through
  `PhoenixKitBilling.Gettext`.
- The business billing profile label drops its "EU" qualifier.
- `get_default_billing_profile/1` returns the most recently updated default
  instead of raising when older data holds several.

### Fixed

- **The dashboard "Edit billing profile" link opened the "New Billing Profile"
  form**, and saving created a duplicate. Core routes the page with `:uuid`; the
  form read only `id`. Both are accepted now.
- Saving a billing profile as default clears the flag on the user's other
  profiles in the same transaction, so a user keeps one default.
- An over-long display name (first + last name) is cut to the column size
  instead of raising `Postgrex.Error`.

## 0.20.0 - 2026-10-10

Ukrainian translations (PR #47) and translated, branded printable documents
(PR #48).

### Added

- **Ukrainian (`uk`)** — a complete `priv/gettext/uk` catalogue (675 entries,
  plurals included); the four financial emails render in Ukrainian.
- **Printed-document branding.** A "Printed Documents" card under Billing →
  Settings sets a logo (a media-library file; unset falls back to the project
  logo, then the company name) and a footer text of up to 1000 characters.
  Both close every printable document, and the footer closes every financial
  email too. A PNG/JPEG/GIF billing logo replaces the site logo in the email
  header. Saving needs `manage_settings`. New settings:
  `billing_document_logo_file_uuid`, `billing_document_footer`.
- `PhoenixKitBilling.DocumentBranding` and `Web.Components.PrintDocument`
  (the shared parts of the four print views).

### Changed

- **The invoice, receipt, credit note and payment confirmation print views are
  translated** (`en`, `et`, `ru`, `uk`): labels, dates (with genitive month
  names) and `<html lang>` follow the locale. The company address is written
  in the reader's language, postal-code-first for UA/RU/BY/KZ, and the same
  formatting now applies to the customer.
- The seller block shows the registration number; the invoice's bank block
  shows the account holder and drops empty rows.

### Fixed

- **The invoice's parties were swapped** — the seller now sits under From and
  the customer under Bill To.
- The invoice status filter's "Voided" option no longer reads as the action
  label "Void" in Ukrainian.

## 0.19.1 - 2026-10-04

Follow-up fixes to the 0.19.0 billing emails (PR #46 review).

### Fixed

- **Billing's email copy could come out in the sender's language.** The
  defaults relied on core to install the customer's locale for billing's own
  Gettext backend, which core before 2.48.0 does not do and later cores do not
  do over a locale already set on that backend. `email_send_opts/4` now
  resolves the customer's (or the site's) language itself and builds the
  defaults inside it, restoring the caller's locale afterwards.
- **Dates in the emails were English in every locale.** Invoice, due, payment
  and refund dates are now written in the customer's language
  (`Oct 16, 2026`, `16 Okt 2026`, `16 Окт 2026`).
- **The plain-text bodies kept empty sections.** Bank-transfer details, VAT
  lines and links to the document are now left out of the plain text as well as
  the HTML when the send has no value for them; a bank name or SWIFT code is
  optional on its own, and the payment confirmation's text footer carries VAT
  like its HTML footer.
- A missing due date no longer prints "Please pay it by -."

### Changed

- Gettext: the plain-text email bodies are translated by section (`en`, `et`,
  `ru` updated).

## 0.19.0 - 2026-10-04

Billing emails rebuilt on core's Markdown email parts, with a line-items table,
the `billing` layout group and the customer's own language (PR #46).

### Changed

- **⚠️ Requires `phoenix_kit >= 2.44.0 and < 3.0.0`** (was `>= 2.38.0`).
  The email defaults are a `markdown` part sent in the `billing` layout group,
  and the emails register with core's preview through `email_templates/0` — all
  first shipped in core 2.44.0. Hosts on core 2.38–2.43 stay on 0.18.x.
- **The four financial emails** (invoice, receipt, credit note, payment
  confirmation) are now a `subject`, a `markdown` body and a separate `text`
  body. The HTML version has a button to the document, the line items as a
  styled table, and the company's details as a closing block. The button, the
  invoice's bank-transfer section and each blank company line are left out when
  the send has no value for them. A database template still wins over all of
  it, so an install that customized one keeps its copy.
- **Line items are HTML-escaped.** `line_items_html` (the bare `<tr>` rows for
  database templates) used to interpolate item names and descriptions raw.
- The emails are sent in the customer's own `preferred_locale` rather than the
  site's default language (billing's own copy follows it on core 2.48.0 and up).

### Added

- `PhoenixKitBilling.email_send_opts/4` — everything a financial email's send
  passes: the defaults, `layout: "billing"` and the customer's `locale:`.
- `PhoenixKitBilling.email_templates/0` (and the compat delegate): the four
  emails, with sample values, in core's email preview at
  `/admin/settings/email-sending/preview`.
- `EmailDefaults.line_items_table_html/2` and the `{{{line_items_table_html}}}`
  variable, plus `company_vat` on the payment-confirmation email.
- A host can restyle billing emails with `_layout-billing`, `_header-billing`
  and `_footer-billing` files.

## 0.18.0 - 2026-09-28

Actor and activity logging through core, and a full header trail on every
billing admin page (PR #44); spec references written in English (PR #45).

### Changed

- **⚠️ Requires `phoenix_kit >= 2.38.0 and < 3.0.0`** (was `~> 2.26`).
  Activity logging now reads the actor and role through
  `PhoenixKitWeb.Actor` and writes through `PhoenixKit.Activity.log/3`, both
  first shipped in core 2.38.0 and called without a feature check, so an
  older core cannot compile this release. Hosts on core 2.26–2.37 stay on
  0.17.x.
- **Admin header trail.** Every billing page now sets core's
  `page_section`, `page_crumbs` and `page_title`, so the header reads
  `Admin Panel / Billing / Orders / ORD-…` with links back up instead of
  `Admin Panel / <title>`. Titles no longer carry a dash-joined trail
  ("Order %{number}", "Edit Order %{number}"); edit pages are titled "Edit"
  and the form's own heading names the page. Settings pages sit under
  "Settings".
- Gettext: new msgids "New order", "New subscription", "New subscription
  type", "New billing profile" and "Providers" (translated in `et` and
  `ru`); four unused msgids dropped.
- Code comments and test names write the per-domain-currency spec's stage
  labels in English (`E1`–`E5`, `item N`). No behaviour change.

## 0.17.0 - 2026-09-21

Guest payers, a durable invoice-event hook for other modules, and EveryPay
payments that record (PR #43).

### Added

- **`PhoenixKitBilling.InvoiceEvents`** — a durable way for other modules to
  learn that an invoice was paid, refunded or voided. A PhoenixKit module
  exports `billing_invoice_event_handlers/0` (or a host sets
  `config :phoenix_kit_billing, invoice_event_handlers: [...]`); each handler
  implements `handle_invoice_event/2`. Events are enqueued as one
  `InvoiceEventWorker` Oban job per handler (queue `:billing`) in the same
  transaction as the invoice change, delivered at least once with the invoice
  as it is at delivery. `:refunded` fires for partial and full refunds alike.
- **Guest payers (migration V5).** An invoice's payer is either a user or a
  billing email: `phoenix_kit_invoices.user_uuid` and
  `phoenix_kit_transactions.user_uuid` become nullable, guarded by the
  `phoenix_kit_invoices_payer_check` CHECK and the changeset. Invoice, receipt,
  credit-note and payment-confirmation emails go to the billing email; the
  admin list, detail and print views show it. Rolling back below V5 refuses
  while guest rows exist. Run `mix phoenix_kit.update` to apply.
- `Invoice.payer_email/1` and `Invoice.payer_name/1`.

### Fixed

- EveryPay payments failed to record (`"everypay"` was missing from the
  transaction payment-method whitelist): the customer was charged and the
  invoice stayed unpaid. EveryPay now also displays as "EveryPay".
- A provider-confirmed payment that settles an invoice now broadcasts
  `{:invoice_paid, _}` (only the admin *Mark paid* action did), and
  `record_payment/3` broadcasts after commit instead of inside the transaction.

## 0.16.0 - 2026-09-16

Free-typed decimal form fields via core's `<.decimal_input>` (PR #42).

### Changed

- **Requires `phoenix_kit ~> 2.26`** (was `~> 2.0`). `<.decimal_input>` and
  `PhoenixKit.Utils.Number.parse_decimal/2` first shipped in core 2.26.0 and the
  component is imported at compile time, so an older core cannot compile this
  release. Hosts on core 2.0–2.25 must upgrade core first.
- Tax rate (settings), exchange rate (currencies), subscription type price,
  invoice payment and refund amounts, and order line-item unit price now use
  `<.decimal_input>`: a comma or a dot both work, nothing is rounded, and the
  browser no longer blocks a submit over `step`/locale mismatches.
- `record_payment/3`, `record_refund/3` and the order form parse amounts with
  `Number.parse_decimal/2`, so `"12,50"` is 12.50 instead of 12.

### Fixed

- A default tax rate outside 0–100 is rejected with a flash instead of saved
  (the browser's `min`/`max` guard went away with `type="number"`), and the rest
  of the submitted settings form stays as typed.
- A garbage subscription type price shows "is invalid" instead of crashing the
  LiveView (`Decimal.new/1` raised).
- The subscription type form's Name, Slug and Price labels showed two required
  asterisks.

## 0.15.1 - 2026-09-09

Fail-closed PayPal webhook signature verification (PR #41).

### Fixed

- **Security:** `PhoenixKitBilling.Providers.PayPal.verify_webhook_signature/3`
  no longer accepts a PayPal webhook unconditionally when the signature
  argument isn't a headers map. The webhook controller always passes the
  signature as a plain string (same as Stripe/Razorpay), so this catch-all
  was the only path ever exercised in production and used to return `:ok`
  unconditionally — any forged request, signed or not, was accepted and
  processed as a genuine payment event. It now returns
  `{:error, :invalid_signature}` (fail-closed), and the webhook controller
  responds `401`. Full PayPal signature verification (collecting PayPal's
  five `paypal-transmission-*`/`paypal-cert-url` headers into a map) is
  separate, larger work, not included here — until it ships, the PayPal
  webhook endpoint rejects all requests, including genuine ones, which is
  the correct trade-off for a payments webhook.

## 0.15.0 - 2026-09-09

Migration chain hardening plus V4 adoption of the ten remaining
core-baseline tables (PR #39).

### Added

- **V4** adopts `phoenix_kit_billing_profiles`, `phoenix_kit_currencies`,
  `phoenix_kit_invoices`, `phoenix_kit_orders`, `phoenix_kit_transactions`,
  `phoenix_kit_payment_methods`, `phoenix_kit_subscriptions`,
  `phoenix_kit_webhook_events`, `phoenix_kit_payment_options` and
  `phoenix_kit_subscription_types` under core's exact object names — the
  same pure-adoption contract V1 already established for
  `phoenix_kit_payment_provider_configs`. A no-op on any host where core
  already created these tables; creates them on a future baseline that
  doesn't. `current_version/0` is now `4`.

### Fixed

- `up_statements/2`/`down_statements/2` reject an out-of-range `:version`
  target instead of silently clamping it — a hand-written call passing a
  too-high target used to stamp a `pkb_schema:` marker the chain doesn't
  have, permanently hiding every later real version.
- `up/1`/`down/1` now read `:version` from a map `opts` as well as a
  keyword list; a map-shaped call used to silently default to the latest
  (or oldest) version instead of the one requested.
- `up_statements(prefix, 0)` no longer raises `FunctionClauseError` —
  "apply up to version 0" is now a defined no-op.
- The schema-prefix fallback validator (used when core's own
  `validate_prefix!/1` isn't loaded) now matches core's rule byte-for-byte
  (lower-case only, 20-byte cap) instead of a looser, uppercase-permitting,
  unbounded regex.

## 0.14.0 - 2026-09-08

Per-domain currency, stage E5: exchange-rate provider hook and provider
minor units (PR #38, #40).

### Added

- **`PhoenixKitBilling.refresh_rates_from_provider/1`** — an optional
  `:fx_rate_provider` hook (`config :phoenix_kit, :fx_rate_provider, {mod,
  fun}`) for a host that wants to pull exchange rates from an external
  feed. Rates otherwise stay manual, as before. Validates every entry
  before any write and refuses the whole batch on a single bad one
  (unknown currency, non-numeric, non-positive, or more/less precision
  than `phoenix_kit_currencies.exchange_rate`'s `numeric(15,6)` column can
  hold), skips the base currency, and runs inside one transaction with the
  base currency row locked so it cannot straddle a concurrent
  `set_default_currency/1` or `change_base_currency/2`. Ships with `mix
  phoenix_kit_billing.refresh_fx_rates` (dry-run by default, `--apply` to
  write) as the intended trigger — nothing schedules it automatically.
- **`PhoenixKitBilling.Providers.MinorUnits`** — converts between a
  shop-side `Decimal` amount and a payment provider's integer minor unit
  using the currency's own `decimal_places`, the single place this
  conversion now happens.

### Fixed

- **Every payment provider (Stripe, PayPal, Razorpay, EveryPay) converted
  amounts using a hard-coded ×100 factor**, correct only for two-decimal
  currencies. A zero-decimal currency (JPY, KRW) was charged **100×** its
  intended amount; a three-decimal one (BHD, KWD) was silently truncated.
  All four providers' outbound (checkout/charge/refund) and inbound
  (webhook confirmation) amount conversions now go through `MinorUnits`,
  keyed off each currency's actual `decimal_places`.
- **`Transaction.currency` no longer silently defaults to `"EUR"`.** A
  caller that omits it now gets a validation error instead of a
  transaction honestly mislabeled with the wrong currency.

## 0.13.0 - 2026-09-07

Per-domain currency, stages E2 and E3 (PR #33, #34).

### Added

- **`rounding_rule` is now applied by `Currency.present/3`.** Four rules —
  `"exact"` (default), `"charm_99"` (round down to X.99), `"charm_90"`
  (nearest X.90), `"integer"` (whole units) — applied once to the raw
  converted amount, identically on the live and frozen (order/cart snapshot)
  paths, never to the base currency. A charm rule requires a currency with
  exactly two decimal places; the changeset now rejects the combination.
- **`{:currencies_changed, code}` PubSub event** (`Events.subscribe_currencies/0`)
  — broadcast by every currency writer (create/update/set_default/delete/
  change_base_currency) after its cache invalidation is guaranteed applied,
  so a storefront tab can re-render converted prices live instead of on
  reload.
- **`PhoenixKitBilling.change_base_currency/2`** — switches the shop's base
  currency: renormalizes every rate against the new base and promotes it to
  `1.0`, inside one transaction with a caller-supplied `opts[:reprice]`
  callback (for recomputing catalog/shipping prices, which this package does
  not own) run strictly between those two steps. Requires an explicit
  `opts[:catalog_size]` so a non-empty catalog can't be silently re-priced
  by omission.
- **Exchange-rate age tracking.** `rate_updated_at` is now stamped by every
  currency write that actually changes the rate. `Currency.stale?/2` and
  `PhoenixKitBilling.currencies_with_stale_rates/0` flag rates older than
  the `fx_rate_max_age_days` setting (default 30 days) — a stale rate still
  converts, it only surfaces a one-time-per-process log warning and an
  admin banner/badge on the Currencies page.

## 0.12.0 - 2026-09-07

Phase B of retiring the `phoenix_kit_email_templates` table. Plan:
`phoenix_kit/dev_docs/plans/2026-09-06-templates-table-split.md`.

### Added

- **`PhoenixKitBilling.EmailDefaults` — this package now owns the content of
  its own four emails.** Invoice, receipt, credit note and payment
  confirmation were seeded rows in a table belonging to `phoenix_kit_emails`,
  which is why that package hardcoded billing's copy. That table is being
  retired; without this, all four emails would stop sending when it goes.

  The content is passed to core as `:defaults` (a zero-arity function, so core
  evaluates it inside the *recipient's* locale rather than whatever locale a
  background job happens to be in). Resolution order is unchanged: an active
  database template, then a host override file, then this.

  **Nothing changes for an existing install.** A host that customized one of
  these templates keeps its customization, because the database row still
  wins. Requires core ≥ 2.17 to take effect; older cores ignore the option, so
  the pin stays at `~> 2.0`.

- Subjects and bodies are now translated into `et` and `ru`. They were
  English-only for every recipient before, because the seeded rows carried a
  single `"en"` value.

### Fixed

- Ten `et`/`ru` strings were serving a translation matched from a *different*
  msgid — "Manage invoices" read as *manage currencies*, and "Subscription
  extended by %{days} days" had dropped the placeholder and hardcoded 30 days.
  Rewritten by hand.

### Known gap

- **The four emails no longer carry an HTML body once the templates table is
  dropped**, only plain text. The shipped HTML was roughly 200 lines each of
  inline markup with the header and footer copy-pasted between them — the
  duplication the shared layout layer exists to remove — and re-homing it here
  would bake that into a second package immediately before deleting it. The
  layout layer has to land before the table is dropped. Until then nothing
  changes, because the database row still wins.

## 0.11.0 - 2026-09-06

PR #31, PR #32, plus the post-merge review of #32. Full findings in
`dev_docs/pull_requests/2026/31-set-default-currency-repromote/CLAUDE_REVIEW.md`
and `dev_docs/pull_requests/2026/32-currency-e1-display-currency-cache/CLAUDE_REVIEW.md`.

### Added

- **Request-scoped display currency.** `Currency.put_request_currency/1` /
  `get_request_currency/0` let a host set, per request, the currency a
  shopper should see and be charged in, independent of the shop's base
  currency. `get_base_currency/0` (cached), `get_display_currency/0` and
  `resolve_display_currency/1` resolve it with a fail-safe: an unknown,
  disabled, or non-positive-rate code falls back to the base currency and
  logs once per process per offending code, rather than crashing or showing
  a broken price.
- **`Currency.present/3`** — the one place a base-currency amount becomes a
  display-currency amount. Resolves the base and target fresh on every call
  (a rate edit is visible on the next call), or, with `opts[:rate]`, uses a
  caller's own frozen rate (a cart's or order's snapshot) without
  re-checking the target's live usability — a frozen rate must survive the
  target being disabled after the freeze.
- **`Currency.effective_rate/2`** — the `base -> target` multiplier a cart
  freezes at creation, rounded to six decimal places.
- **Currency-table caching (§13).** `get_base_currency/0` and
  `get_currency_by_code/1` are backed by a `PhoenixKit.Cache` instance
  (5 minute TTL), invalidated wholesale by every currency writer. Cuts
  `Currency.present/3`'s per-call query cost from 3 to ~0 once warm — a
  catalog page converting dozens of prices no longer pays for it per price.
- **Migration chain V3** — adds `phoenix_kit_orders.base_currency`,
  `.exchange_rate` and `.base_total` (nullable, no backfill), the columns
  `PhoenixKitBilling.Order` now declares for a later stage's frozen order
  pricing. Added post-merge: PR #32 shipped the schema fields on the
  assumption that a core release would add these columns, but the core
  release in question had not been published, so every `Order` query broke
  on the currently published core. This chain now adds them itself, using
  the same names/types that core release will use, so its own
  `ADD COLUMN IF NOT EXISTS` and backfill still work unchanged once it ships.

### Changed

- **`billing_default_currency` is no longer read.** Every internal reader
  (order/subscription creation, dashboard stats, the order form) now uses
  the `is_default` row of `phoenix_kit_currencies` via `get_base_currency/0`.
  The dead "Default Currency" select on the settings page (it wrote a
  setting nothing read) is removed along with it.

### Fixed

- **`set_default_currency/1`: re-promoting the currency that is already
  default no longer clears `is_default` entirely.** The base-rate
  renormalization added in 0.10.0 demoted the target's own row in the
  database while the caller's in-memory struct still read `is_default:
  true`, so Ecto's changeset diff saw no change and never re-promoted it.
  The function now reloads the row before both the guard check and the
  promoting changeset, and forces `:is_default`/`:exchange_rate` into the
  changeset regardless of what the reload reports.

## 0.10.0 - 2026-09-05

PR #30, plus the post-merge review. Full findings in
`dev_docs/pull_requests/2026/30-currency-hygiene-e0/CLAUDE_REVIEW.md`.

### Added

- **Migration chain V2** — a partial unique index
  `phoenix_kit_currencies_default_uidx ON (is_default) WHERE is_default`, so
  two default currencies can no longer coexist and crash
  `get_default_currency/0`; plus `rounding_rule` and `rate_updated_at`
  columns on `phoenix_kit_currencies` (no readers yet — `"exact"` reproduces
  today's rounding). `up/1` now honours a `:version` target, and `down/1`
  below V2 drops the index and both columns — never the core-created table.
  V2 demotes surplus default rows immediately before creating the index, so
  the migration also repairs a database that is already in the state the
  index forbids.

### Changed

- **The base currency's rate is now an enforced invariant.**
  `set_default_currency/1` renormalizes every `exchange_rate` against the
  incoming base before promoting it at exactly `1.0`. Ratios are preserved,
  so no converted amount moves — only the displayed numbers become honest.
  A nil or non-positive base rate is refused with `{:error, :invalid_base_rate}`.
  The admin currency list always shows the numeric rate and warns when the
  base row's rate is not 1.0.
- **Payment providers require an explicit `:currency`.** The hardcoded
  fallbacks are gone from Stripe, PayPal and Razorpay: a caller that omits
  the currency raises instead of silently charging in euros (or, on
  Razorpay, rupees). EveryPay is exempt — it charges in the currency fixed
  by the processing account. A full refund still needs no currency. The
  `Provider` behaviour documents which calls raise.
- **`Order.currency` and `Invoice.currency` lost their `"EUR"` schema
  default**, so a missing currency is a loud changeset error rather than a
  silent euro. `Transaction.currency` keeps its default until it gets the
  same validation.

### Fixed

- **`Currency.changeset/2` declares the new default-currency constraint**, so
  a second `is_default` row returns `{:error, changeset}` instead of raising
  `Ecto.ConstraintError` out of `create_currency/1` / `update_currency/2`.
- **The test harness applies this module's migration chain.** From V2 on the
  `Currency` schema declares columns only the chain creates; without it every
  DB-backed currency test raised `undefined_column`.

## 0.9.0 - 2026-08-26

PR #29, plus the post-merge review. Full findings in
`dev_docs/pull_requests/2026/29-migration-module-payment-provider-configs/CLAUDE_REVIEW.md`.

### Added

- **`migration_module/0`**, declaring `PhoenixKitBilling.Migrations` — this
  package's first module-owned versioned migration chain, discovered by
  core's `mix phoenix_kit.update`.
- **Adopts `phoenix_kit_payment_provider_configs`.** The table is
  core-created (V135 baseline); this chain's V1 stamps a `pkb_schema:1`
  marker without changing its shape, taking ownership of the table's future
  evolution. No application code reads or writes the table yet — provider
  credentials still live in `phoenix_kit_settings`.

## 0.8.1 - 2026-08-21

### Changed

- **The four billing-settings tab strips are one `<.settings_tabs>`
  component**, rendered through core's `<.nav_tabs>`. daisyUI 4's
  `tabs-boxed` is gone with them. Tabs use `:path` so the strip still
  works against every 2.x core (#26).

### Fixed

- Dropped a duplicate `alias PhoenixKit.Utils.Routes` in
  `provider_settings.ex` that the new import landed between (post-merge).

## 0.8.0 - 2026-08-18

PR #23 (customer-facing "My Orders" screen) and PR #24 (email-fallback
visibility, round 2), plus the post-merge review of both. Full findings in
`dev_docs/pull_requests/2026/23-customer-orders-dashboard/CLAUDE_REVIEW.md`
and `dev_docs/pull_requests/2026/24-fix-email-fallback-visibility/CLAUDE_REVIEW.md`.

### Added

- **Customer-facing "My Orders" dashboard.** `:dashboard_orders` previously
  registered a tab with no `:live_view`, so the tab→route mechanism
  silently produced no route and every customer link to it 404'd. Adds
  `PhoenixKitBilling.Web.UserOrders`: a read-only list of the current
  user's own orders, each with its invoices and each invoice's
  payment/refund transactions. Wired up at `/dashboard/billing-orders` —
  not `/dashboard/orders`, which core hardcodes for `phoenix_kit_ecommerce`'s
  own orders screen and would collide with on a host running both modules
  (#23).
- `list_user_orders/3` gained an opt-in `:preload` option (default `[]`,
  so no existing caller's query shape changes) (#23).

### Fixed

- **⚠️ Breaking:** `send_invoice/2`, `send_receipt/2`, `send_credit_note/3`,
  and `send_payment_confirmation/3` used to discard whether the customer
  was actually emailed and unconditionally return `{:ok, record}`. On an
  install with `phoenix_kit_emails` not installed — a supported, ongoing
  configuration, not a transient error — every send after the first one
  in a boot looked exactly like a real email going out: no return-value
  signal, and the one log line for it had already fired and deduplicated.
  All four now return `{:ok, record, email_result}` — `:skipped` when
  `:send_email` is `false`, otherwise the underlying send result,
  including `{:error, :emails_module_not_installed}` when that's what
  happened. Callers that only care whether the billing operation itself
  succeeded can keep matching `{:ok, record, _}`; callers that care
  whether the customer was actually emailed check the third element. The
  4 admin "send" actions in `InvoiceDetail` now flash an accurate warning
  instead of always claiming success, and the webhook processor logs a
  receipt's email failure distinctly without failing the webhook (#24).
- `send_email_if_available/4` checked `Code.ensure_loaded?(PhoenixKit.Modules.Emails)`
  — the sibling package's namespace module — then called a function on
  `Templates`, a different module one level down that can be absent even
  when the namespace module is loaded (a partial/stale
  `phoenix_kit_emails` install). Now checks `Templates` itself directly
  (#24).
- The 8 `get_dashboard_stats/0` query helpers rescued a real query failure
  (bad connection, a mid-flight migration, a locked table) straight to
  `0` / `Decimal.new(0)` with no log line — indistinguishable on the
  admin dashboard from an actually-empty, healthy system. Now logged as a
  warning before falling back; the fallback values themselves are
  unchanged (#24).
- `Activity.log/2` silently rescued `Postgrex.Error` and
  `DBConnection.OwnershipError` to bare `:ok`. Verified unreachable in
  practice (core's own `PhoenixKit.Activity.log/1` already rescues
  internally and returns `{:error, _}`), but collapsed into the same
  logged-and-returned `{:error, _}` path as every other failure rather
  than relying on an undocumented core internal to keep making it dead
  code (#24).
- Fixed a `mix test` break on `main` left by these two PRs merging in
  parallel: `user_orders_test.exs` (#23) was written against the old
  2-tuple `send_invoice/2` return shape and never saw #24's contract
  change, and its new-file `mix credo --strict` violations were blocking
  `mix precommit`. No production code affected.

## 0.7.4 - 2026-08-17

### Fixed

- Billing print views (`InvoicePrint`, `ReceiptPrint`, `CreditNotePrint`,
  `PaymentConfirmationPrint`) and `InvoiceDetail.Actions.reload_invoice/1`
  never preloaded `:user`, but their templates read
  `@invoice.user.email` — `KeyError: key :email not found in:
  #Ecto.Association.NotLoaded<...>` on every visit. All 8 public
  `send_*_email/2,3` functions in `PhoenixKitBilling` had the same gap in
  their own `ensure_preloaded/2` call. Fixed by adding `:user` to every
  preload list that feeds one of these reads (#22).
- `CreditNotePrint` and `PaymentConfirmationPrint` never mounted: their
  `do_mount` pattern-matched on `"id"`, but the registered route binds
  `:invoice_uuid` (#22).
- `Paths.payment_confirmation/2` built `.../invoices/:id/payment/:txn_uuid`
  instead of the registered `.../payment-confirmation/:txn_uuid` — same bug
  class as the route-param fix above, in the one file PR #22 didn't touch.
  Currently unreferenced by any call site, so it never 404'd in practice.

## 0.7.3 - 2026-08-17

### Fixed

- `PhoenixKitBilling.CoreCompat`'s moduledoc and
  `core_api_contract_test.exs`'s moduledoc claimed `mix.exs` admits
  `phoenix_kit` 1.7.214 up to 3.0.0 — stale, left over from a branch commit
  (PR #21) that was superseded when the branch merged upstream's `~> 2.0`
  pin. The actual requirement (`~> 2.0`, core 1.7 excluded) was already
  correct in `mix.exs`, `AGENTS.md`, and `core_pin_conformance_test.exs`;
  only these two docstrings disagreed with it. No behaviour change.

## 0.7.2 - 2026-08-13

### i18n

- The example placeholders in both billing profile forms now go through
  Gettext. Every label around them already did, so an Estonian or Russian
  user saw fully translated labels with English examples underneath —
  `John`, `Doe`, `Tallinn`, `Harju`, `Acme Corp OÜ`. Added to the `et`, `ru`
  and `en` catalogues. Format-only placeholders (`john@example.com`,
  `+372 5555 5555`, `EE123456789`, `10115`) are deliberately left literal —
  they read the same in every locale (#20).

### Changed

- Dependency updates: `phoenix_kit` 2.3.0.

## 0.7.1 - 2026-08-11

### Changed

- Dependency updates: `phoenix_kit` 2.2.0 and the transitive set it pulls
  (`phoenix` 1.8.10, `hackney` 4.7.3). No source changes in this package.

## [0.7.0] - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved from `~> 1.7.214` to
  `~> 2.0`, so this release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself; there is no behaviour change in billing.

## [0.6.0] - 2026-08-09

PR #18 plus its post-merge review. The PR contributes a **Customer billing** tab
to the `phoenix_kit_projects` hub. The review found the tab's unlinked state
enumerating every billing profile in the installation, and four places where it
reimplemented shared billing UI or skipped conventions the sibling CRM tab
already follows. Full findings in
`dev_docs/pull_requests/2026/18-project-billing-tab/CLAUDE_REVIEW.md`.

### Added
- **`phoenix_kit_project_extensions/0` — the Customer billing tab for the projects hub** (PR #18). A duck-typed catalog entry (plain maps; no dependency on `phoenix_kit_projects`, no FK) that links a project to a billing profile by UUID and renders that customer's recent invoices inside the project page via `PhoenixKitBilling.Web.ProjectBillingLive`. Honestly labeled: the tab is the linked **customer's** money — everything on their profile, across everything they buy — not a per-project P&L. `rate_cents_per_hour` lives on the same extension so the projects-side ledger→invoice bridge and this tab share one money-settings home. `default_enabled: false`.
- **`:limit` filter for the invoice list functions.** `list_invoices/1` and `list_user_invoices/2` now accept `%{limit: n}`, so rollup panels can ask for the most recent few instead of loading a customer's entire invoice history and slicing it in memory.

### Fixed
- **The unlinked Customer billing tab disclosed every billing profile in the installation.** With no profile linked, the tab called `list_billing_profiles/1` with no options — which applies no user, type, search or pagination filter — and rendered every row's display name *and* UUID. Any project member opening the tab saw the identity of every customer of the whole host app, including people with no relationship to that project, and a host with thousands of profiles rendered all of them into the page on every mount. The empty state now links out to Billing › Profiles, matching the sibling CRM tab.
- **Voided and draft invoices rendered the wrong color in the tab.** It defined its own status→badge clauses instead of using `Web.Components.InvoiceStatusBadge`, and two of the five statuses disagreed with the shared component: `void` came out neutral-gray instead of red, and `draft` came out warning-yellow instead of gray. Now uses the shared component, so the two lists cannot drift again.
- **Money in the tab bypassed `Web.Components.CurrencyDisplay`**, rendering `1234.50 EUR` where the rest of billing renders `€1,234.50` — no symbol, no thousand separators, and a hardcoded 2-decimal round that is wrong for the zero-decimal currencies the shared component already handles (JPY, HUF).
- **The tab ignored the hub's locale and used no gettext.** The projects hub passes `"locale"` in the embed session; the tab dropped it and hardcoded English, so the pane rendered untranslated inside otherwise-translated ru/et project pages. All strings are now gettext-backed with `en`/`ru`/`et` translations; the catalogues are back to zero untranslated and zero fuzzy entries.

### Changed
- **The tab's reads moved behind a `connected?/1` guard.** They ran in `mount/3`, which executes twice on a full page load, so every query was paid for twice and the first result discarded. The hub requires contributed tab LVs to be mountable off-router with no `handle_params/3` (it renders them via `live_render`), which rules out the usual `handle_params` split — a new regression test asserts the LV does not export `handle_params/3`, since that failure is otherwise only visible from the projects side.
- The invoice table now fetches one row over its display cap and says "Showing the 15 most recent invoices." when there are more, instead of silently truncating.

## [0.5.3] - 2026-08-06

PR #17 plus its post-merge review. The PR fixed a callback whose absence is
completely silent; the review found the same callback still missing on the
module's other public face, and a drift test structurally unable to catch either.
Full findings in `dev_docs/pull_requests/2026/17-css-sources-callback/CLAUDE_REVIEW.md`.

### Fixed
- **Tailwind purged every class used only in billing's templates from host builds.** This module never implemented `css_sources/0`, so core's `:phoenix_kit_css_sources` compiler — which guards on `function_exported?/3` and emits nothing for a module that doesn't export it — wrote no `@source` line for the package. Nothing errored; the admin billing pages simply rendered without their responsive and variant utilities. Billing was the only PhoenixKit module missing the callback (PR #17).
- **The `PhoenixKit.Modules.Billing` compat shim still had the bug.** The shim re-exports the module surface under the pre-migration namespace, and a host can register it: `ModuleDiscovery` merges beam-scanned modules with `config :phoenix_kit, modules: [...]` — the very fallback core's zero-sources error message recommends. `css_sources/0` was not delegated, so hosts on that path kept the purged bundle. `notification_types/0` was missing for the same reason, which silently dropped billing's whole notification tree (`billing`, `invoices`, `your_billing`) from the registry.

### Changed
- The compat drift test now guards **both** directions. It previously asserted only that nothing the shim delegates has vanished from the target, so a callback *added* to `PhoenixKitBilling` and not re-exported — exactly the two above — could never be flagged. Closes the "no compat-module drift tests" item deferred in AGENTS.md.
- `css_sources/0`'s regression test now also asserts against `Application.get_application/1` rather than only a repeated literal, so a package rename fails the test instead of quietly emitting an `@source` for a directory that isn't there.
- `notification_types/0` carries `@impl PhoenixKit.Module`; it is a declared optional callback, not the duck-typed hook its doc described.
- AGENTS.md's "Tailwind CSS Scanning" section asserted this module implemented `css_sources/0` from the initial scaffolding commit onward, while the code never did — the doc confirmed the callback to anyone who checked it instead of exposing the gap. Rewritten with the real mechanism (a Mix compiler regenerating `assets/css/_phoenix_kit_sources.css`, not the installer writing `app.css`), an explicit note that the callback fails open, and a warning not to copy core's `@source_root` path-dep example here — this module's callback lives one directory shallower, so `Path.join(__DIR__, "../..")` would resolve to `deps/` and emit an `@source` over the entire dependency tree.

## [0.5.2] - 2026-08-05

Post-merge review of PR #15 (permissions, notifications, provider payments) and PR #16 (live subscriptions search). PR #15 fixed `record_payment/3` so provider-driven payments finally insert — which meant both of its production callers executed their success paths for the first time, and neither survived it. Full findings in `dev_docs/pull_requests/2026/15-permissions-notifications-payment-fixes/CLAUDE_REVIEW.md` and `.../16-subscriptions-live-search/CLAUDE_REVIEW.md`.

### Fixed
- **Subscription renewals could charge a customer up to three times.** `SubscriptionRenewalWorker` passes the provider's `%ChargeResult{}` struct as `provider_data`, and Ecto lets a struct through both `cast` and `dump` on a `:map` column — the failure only surfaces in the JSON encoder, as a **raise** from inside the repo transaction, i.e. *after* the card has been charged. The exception escaped `attempt_renewal/2`'s `with` (an `else` clause does not match exceptions), so the Oban job crashed instead of moving the subscription to `past_due`, and each retry created another invoice and charged the card again. `provider_data` is now sanitized to a plain, JSON-safe map at the context boundary, where providers' result structs arrive.
- **Every successful provider webhook payment raised `KeyError`.** `WebhookProcessor` read `.status` off `record_payment/3`'s return value, which is a `%Transaction{}` — a schema with no `:status` field. The payment committed, the webhook then 500'd, no receipt was generated, and the provider retried a charge that had already been recorded. Unreachable until provider payments started inserting at all.
- **The webhook status gate and `Invoice.payable?/1` disagreed.** `validate_invoice_status/1` admitted `"draft"`, which `record_payment/3` now rejects as `:not_payable`, so a draft invoice passed the processor's gate only to have its payment dropped downstream. It now delegates to `Invoice.payable?/1` so the two cannot drift.
- **`mark_invoice_paid/2` could commit a paid status without its ledger row.** A failed settlement insert was discarded with `_ =` rather than rolling the transaction back — the exact inconsistency that transaction exists to close. It now also takes the same `FOR UPDATE` row lock `record_payment/3` relies on, without which a concurrent mark-paid and payment could together record more than the invoice bills.
- **Every customer notification linked to a route that does not exist.** `/dashboard/invoices/<uuid>` is registered nowhere; `user_dashboard_tabs/0` exposes `orders` and `billing-profiles`. Customer invoice and payment notices now link via `Paths.user_orders/0`.
- **`billing.payment_failed` was a registered notification nothing could emit.** Notification sends stopped at the admin LiveView, so the provider paths recorded payments and failures silently. `payment_received/2` and `payment_failed/2` are now emitted from the webhook processor and the renewal worker.
- **A partial payment was announced as the invoice total** — `payment_received` formatted `invoice.total`, so 50-of-500 read as *"Payment received — 500.00 EUR"*. It now reports the amount actually recorded.
- **A decline reason could be truncated mid-codepoint.** `binary_part/3` cuts at a byte offset; a localized provider message split that way is invalid UTF-8 and is rejected by both Postgres and the JSON encoder, so the notification reporting a failed payment failed itself.
- **Back-button behaviour on the orders, invoices and transactions lists.** All three have debounced live search but pushed a history entry per typing pause, so Back walked the query backwards a few characters at a time. They now use the `replace: true` that PR #16 applied to subscriptions.

### Changed
- `Web.Authz`'s moduledoc described the e-commerce module (`"shop"` key, "carts carry customer contact details"); it now describes billing.
- `snapshot_refreshable?/1`'s doc claimed an in-place billing-profile edit refreshes a draft order's snapshot. It does not — only a profile *switch* is reconsidered, at any status or policy. The doc now states the actual scope.
- `mix.lock` pruned of eight unused entries (`igniter`, `sourceror`, `spitfire` and friends) left behind by the dependency refresh in `19525d0`, which had `mix precommit` failing on `deps.unlock --check-unused`.

### Added
- Regression coverage for the two defects above that a DB-backed test could reach: a provider result **struct** recorded as `provider_data`, and mark-paid keeping status and ledger row in one transaction.
- `test/phoenix_kit_billing/notification_contracts_test.exs` — DB-free contract tests: every registered notification action has a producer, every customer link resolves to a tab `user_dashboard_tabs/0` registers, and decline reasons truncate on a character boundary.
- `Paths.user_orders/0` and `Paths.user_billing_profiles/0` for the customer-facing routes this module registers.

## [0.5.1] - 2026-06-08

No consumer-facing changes — the published surface (declared `{:phoenix_kit, "~> 1.7"}` and behaviour) is identical to 0.5.0. This release refreshes dependencies and adds local-development tooling.

### Changed
- **Dependencies refreshed** (`mix.lock`): `phoenix_kit` 1.7.131 → 1.7.133, plus transitive bumps (`bandit` 1.11.1 → 1.12.0, `req` 0.5.18 → 0.6.1, `tesla` 1.18.3 → 1.20.0, `etcher` 0.6.5 → 0.6.6, `fresco` 0.6.3 → 0.7.1, `spitfire` 0.3.12 → 0.3.13). No declared requirement changed; `mix.lock` is not part of the published package.

### Added
- **Local cross-repo development tooling.** A `pk_dep/3` helper in `mix.exs` lets `phoenix_kit*` deps resolve to a local checkout via `<APP>_PATH` (e.g. `PHOENIX_KIT_PATH=../phoenix_kit mix test`) without altering the published Hex pin — unset resolves exactly as before. An exported-but-empty var falls back to the published pin rather than building a broken `path: ""` dep. Documented in `AGENTS.md`.

## [0.5.0] - 2026-06-05

### Security
- **Payment-method ownership is now enforced in the context.** `create_subscription/2` and `update_subscription/2` reject a `payment_method_uuid` that isn't one of the subscription user's own *active* methods (`{:error, :payment_method_not_usable}`), instead of relying on the changeset's foreign-key check alone (which only proves the row exists). Previously the guard lived only in the admin `SubscriptionForm`, so any other caller could attach another user's or an inactive/removed payment method. The form retains a fast UX pre-check.

### Fixed
- **Subscription edit-save dropped payment-method changes.** Edit mode only ran `change_subscription_type/2`, and the payment-method selector was hidden behind `@live_action != :edit` so the field couldn't be changed at all. The selector now renders in edit mode and a changed `payment_method_uuid` is persisted via `update_subscription/2` (type changes still route through `change_subscription_type/2` so its broadcast fires).
- **`list_payment_methods/2` silently ignored the `status:` option.** Callers passing `status: "active"` worked only by the `active_only` default; `status:` was never inspected. It now honours an explicit `status:` (exact-status filter) with `active_only` (default `true`) as the fallback.
- **Invoice-less transaction rows** were `cursor-pointer` and navigated to a broken `/invoices/` URL; rows are now clickable only when an invoice exists.

### Changed
- `format_company_address/1` made pure — dropped the dead `company_info \\ nil` impure default (the argument is now required); the compat delegate's arity matches.
- `permission_metadata` billing icon `💰` → `hero-banknotes` to match the billing tabs.
- DRY'd the 13 `Tab.new!` calls behind a private `billing_tab!/1` helper.

### Tests
- Added `compat_delegate_test` (asserts every `compat/*.ex` delegate is `function_exported?` on its target at the same arity), `list_payment_methods/2` scoping and `status:`-filtering tests, and context-level payment-method guard reject-path tests (these short-circuit before any insert, so they run without the core `subscription_type_uuid` skip).

## [0.4.0] - 2026-06-04

### Added
- **Activity logging** (`PhoenixKitBilling.Activity`) — a guarded LiveView-layer wrapper around `PhoenixKit.Activity.log/1`, invoked on every admin mutation (orders, invoices, currencies, subscriptions, subscription types, billing profiles, and payment/refund/send actions). Logging failures never crash the caller, and only PII-safe metadata (uuids, status strings, amounts, currency codes, counts) is recorded.
- **Centralized error messages** (`PhoenixKitBilling.Errors`) — maps the error atoms returned by contexts, providers, and webhook handlers to gettext-backed, extractable human-readable strings. All admin flash/error messages now route through `Errors.message/1` instead of `inspect/1`, so users no longer see raw atoms like `:has_active_subscriptions`. Also formats `%Ecto.Changeset{}` reasons.
- **Webhook retry cap** — `WebhookProcessor` now stops reprocessing an event once `WebhookEvent.max_retries_exceeded?/1` is true (≥5 attempts) and the controller acknowledges it with HTTP 200 so providers stop redelivering an intentionally-abandoned event.
- Full DB + LiveView test harness (DataCase/LiveCase, test endpoint/router/layouts) and ~230 new tests across schemas, contexts, regressions, activity logging, and LiveView smoke/validation.

### Fixed
- **Webhook processing crashed on every event.** `upsert_webhook_event/1` used `Access` bracket syntax on a `%Providers.Types.WebhookEventData{}` struct (no `Access`), raising `UndefinedFunctionError` so the controller returned 400 and no event was ever processed. Now reads the field via `Map.get/2`.
- **Stripe was unreachable from the admin UI.** The UI saves the secret to `billing_stripe_secret_key` but `Stripe.get_config/0` read `billing_stripe_api_key`, so `available?/0` was always false and checkout returned `:provider_not_available`. Now reads `billing_stripe_secret_key` with a fallback to the legacy key, and `available?/0` always returns a boolean.
- **`unique_constraint` names didn't match the DB indexes** for `webhook_events`, `currencies`, `subscription_types`, and `payment_methods`, so duplicate inserts raised `Ecto.ConstraintError` instead of returning `{:error, changeset}`. For `WebhookEvent` this broke idempotency (a duplicate delivery surfaced as `:processing_error` instead of `:duplicate_event`). Names pinned to the actual indexes.
- **Receipts were never sent after a webhook payment.** The webhook path called `send_receipt/2` on an invoice without a `receipt_number` (the number is stamped only on the struct returned by `generate_receipt/1`), so it always returned `{:error, :receipt_not_generated}`. The processor now sends from the receipt-bearing struct.
- `extend_subscription` crashed (`FunctionClauseError`) when `current_period_end` was nil; it now reports a friendly error instead.
- `extend_subscription` now derives the extension from the subscription type's billing period rather than a hardcoded 30 days; `update_subscription/2` filters to a non-lifecycle field allowlist (status changes go through cancel/pause/resume); subscription status actions update in place instead of redirecting.

### Changed
- Subscription-type, billing-profile, and order forms migrated to core `<.input>`/`<.select>`/`<.textarea>` components with `assign_form/2` so inline errors render on validate.
- `SubscriptionType.billing_period_days/1` and `next_billing_date/2` gained catch-all clauses (fall back to a monthly cadence) instead of raising on an unexpected interval.
- Stripe provider moduledoc corrected to document the real `PhoenixKit.Settings`-based configuration; the provider talks to the Stripe REST API over `Req`.
- Upgraded locked dependencies; added a test-only `lazy_html` dependency for `Phoenix.LiveViewTest`.

## [0.3.2] - 2026-05-25

### Changed
- **Internationalized the billing admin UI.** Every user-visible string across the admin pages (dashboard, billing settings, payment providers, currencies, subscription types & subscriptions, billing profiles, orders, invoices, transactions) now routes through the per-module `PhoenixKitBilling.Gettext` backend, with full English, Russian, and Estonian catalogues. Print templates (invoice/receipt/credit-note/payment-confirmation) intentionally remain on `PhoenixKitWeb.Gettext` due to their legal-formatting concerns.
- Moved page-level filters, search, clear-filters, and refresh controls into the table toolbar row (`:toolbar_title` / `:toolbar_actions`) for Subscriptions, Billing Profiles, Currencies, Transactions, Invoices, and Orders, grouping related controls and freeing vertical space.
- Upgraded locked dependencies (`ecto`/`ecto_sql` 3.14, `phoenix_kit` 1.7.120, `req` 0.5.18, `etcher`, `fresco`, `ex_doc`, `hammer`). No change to declared version requirements.

### Fixed
- `SubscriptionHelpers.format_interval/2` returned hardcoded English ("Monthly", "Every 3 months", …) and is rendered on six already-localized subscription pages, so it leaked English under `ru`/`et`. It now uses `gettext`/`ngettext` with complete en/ru/et plural forms. (The catalogue drift test could not catch this because the strings were never `gettext` msgids.)

## [0.3.1] - 2026-05-18

### Fixed
- `PhoenixKitBilling.create_checkout_session/3` was unusable — every call crashed:
  - It called `Providers.create_checkout_session/2` with a hand-built options map in the invoice position, so the provider received an empty `opts` keyword list and raised `KeyError` on `success_url`. It now forwards the real `%Invoice{}` struct and passes `opts` through, with `:cancel_url` defaulting to `:success_url`. The provider already derives amount, currency, line items and metadata from the invoice.
  - On success it wrote `checkout_session_id` / `checkout_url` via `Ecto.Changeset.change/2`, but neither field exists on the `Invoice` schema, raising `ArgumentError: unknown field`. Checkout session details are now recorded under `invoice.metadata["checkout"]` (`provider_session_id`, `url`, `provider`, `created_at`); persistence is best-effort and a failed update no longer discards the live session URL returned to the caller.

## [0.3.0] - 2026-05-18

### Added
- **EveryPay payment provider** (`PhoenixKitBilling.Providers.EveryPay`) — EveryPay AS (Baltics) gateway, API v4. Supports one-off hosted-page payments, charging saved card tokens for renewals (MIT), and refunds. Registered as the `:everypay` provider and the `everypay` payment-option code.
- EveryPay callback endpoint `POST /webhooks/billing/everypay`. EveryPay v4 callbacks are unsigned, so the handler re-fetches the authoritative payment record from the API and acts only on that — a forged callback body cannot change billing state.
- EveryPay configuration panel on the Payment Providers admin page (API username/secret, processing account name, test/live mode).

## [0.2.0] - 2026-05-12

### Added
- `PhoenixKitBilling.Plugs.CacheBodyReader` — body reader for `Plug.Parsers` that stashes the raw request body on `conn.assigns.raw_body` for `/webhooks/billing/*` paths so provider signatures can be verified. Required for webhook signature verification to function (see install instructions).
- Live updates on the invoice detail page: subscribes to invoice + transaction PubSub events and refreshes when payments or refunds land.
- Line-item validation on the `Invoice` changeset (name, positive quantity, total).
- Per-subscription `unique` key on `SubscriptionRenewalWorker` so concurrent enqueues for the same subscription collapse correctly.

### Changed
- **Webhook processor:** refunds are now actually recorded via `Billing.record_refund/3` (previously just logged), with handling for `:exceeds_paid_amount`. Idempotency now uses an upsert that distinguishes new / retry / already-processed events, and stack traces are formatted with `Exception.format/3`.
- **Subscription renewal worker:** batch runs now fan out into one job per subscription instead of processing inline, so a single bad subscription cannot poison the whole daily run and the per-subscription unique key + row lock apply correctly.
- **Subscription dunning worker:** fixed off-by-one in max-attempts comparison — a subscription is now cancelled when the *next* attempt would exceed the cap, and the next retry is only scheduled when a future attempt is still allowed.
- **LiveView mount/handle_params split:** moved DB reads out of `mount/3` and into `handle_params/3` for `BillingProfileForm`, `OrderForm`, `Subscriptions`, and `InvoiceDetail` (mount runs twice — once for the dead render and once on connect — so queries belong in `handle_params`).
- **Webhook controller:** logs an explicit, actionable error when `raw_body` is missing from `conn.assigns` instead of silently failing.

### Required action for host applications
Wire the new body reader into your `Endpoint`'s `Plug.Parsers` (see `PhoenixKitBilling.Plugs.CacheBodyReader` moduledoc and the updated install task output for the exact snippet). Without it, webhook signature verification cannot run and webhook requests will be rejected.

## [0.1.5] - 2026-05-08

### Added
- Per-module Gettext backend (`PhoenixKitBilling.Gettext`) with `en`/`ru`/`et` catalogues for all admin sidebar tab labels. Requires `phoenix_kit` release that ships the `gettext_backend` Tab API ([BeamLabEU/phoenix_kit#522](https://github.com/BeamLabEU/phoenix_kit/pull/522)); on older releases tabs render raw English (graceful degradation).

## [0.1.4] - 2026-04-06

### Added
- Add `version/0` callback to display package version on modules page
- Add `module_stats/0` for admin module card (orders, invoices, currencies)
- Expand compat module with full delegation list

### Changed
- Migrate `CountryData.get_company_info` / `get_bank_details` to `Organization` module
- Move `format_company_address/1` to own module for better testability
- Updated permission metadata and icon

## [0.1.3] - 2026-03-30

### Added

- Public tax rate API: `tax_enabled?/0`, `get_tax_rate/0`, `get_tax_rate_percent/0` for cross-module use
- Compat delegates for tax rate API and `get_config/0` in `PhoenixKit.Modules.Billing`

### Fixed

- `get_tax_rate_percent/0` now respects `tax_enabled?` flag
- `get_tax_rate/0` handles non-numeric settings values without crashing
- `get_config/0` uses `tax_enabled?/0` instead of inlining the check

## [0.1.2] - 2026-03-30

### Added

- Subscription edit mode with status management (pause/resume/cancel) and plan type change
- Admin detail/form routes via `admin_routes/0` and `admin_locale_routes/0`
- `table_default` component with card/table toggle across all list pages
- Dropdown menus (`table_row_menu`) on all list pages replacing inline action buttons
- Subscription schema fields: `plan_name`, `price`, `currency`, `provider`, `provider_subscription_id`, `last_renewal_error`, `belongs_to :user`
- Backward-compatible compat modules for `PhoenixKit.Modules.Billing.*` namespace
- Shared `SubscriptionHelpers` module for `status_badge_class/1` and `format_interval/2`
- Confirmation dialogs on destructive subscription actions (pause, cancel)

### Fixed

- Webhook routes now use `phoenix_kit_api` pipeline (was `api`)
- PaymentMethod schema field mismatch: `label` → `display_name` to match DB column
- Removed `try/rescue` blocks in subscription form that were masking the schema mismatch
- Hardcoded `"EUR"` fallback in `create_subscription` now uses `billing_default_currency` setting
- Added `last_renewal_error` to subscription changeset cast list
- Cancel flash message in edit form now correctly says "will be cancelled at period end"

### Changed

- Refactored `admin_locale_routes/0` to share `build_admin_routes/1` with `admin_routes/0`
- Removed duplicate `alias Routes` declarations in subscription LiveViews

## [0.1.1] - 2026-03-29

### Changed

- Restructured to flat `lib/phoenix_kit_billing/` layout with `PhoenixKitBilling` namespace
- Added `.gitignore` for clean repository tracking

### Fixed

- Sorted alias declarations alphabetically across 33 files to satisfy Credo strict mode

## [0.1.0] - 2026-03-28

### Added

- Initial billing module with PhoenixKit.Module behaviour
- Multi-currency support with exchange rates
- Billing profiles for individuals and companies
- Order management with line items and status tracking
- Invoice generation with receipt functionality (draft → sent → paid/overdue/void)
- Transaction tracking with refunds and credit notes
- Subscription management with renewal cycles and dunning
- Subscription type definitions (pricing, intervals, trial periods)
- Payment provider architecture (Stripe, PayPal, Razorpay)
- Internal subscription control (subscriptions managed in DB, not by providers)
- Webhook processing for all supported providers
- Oban workers for subscription renewals and dunning
- PubSub events for real-time LiveView updates
- Admin LiveViews: dashboard, orders, invoices, transactions, subscriptions, billing profiles, currencies, settings
- User dashboard: My Orders, Billing Profiles
- Print views: invoice, receipt, credit note, payment confirmation
- Centralized path helpers via Paths module
- Install mix task
