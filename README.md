# PhoenixKitBilling

[![Elixir](https://img.shields.io/badge/Elixir-~%3E_1.18-4B275F)](https://elixir-lang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Billing module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit). Drop-in payments, subscriptions, invoices, orders, and multi-currency support with Stripe, PayPal, Razorpay, and EveryPay integration.

## Features

- **Orders & invoices** — full order-to-invoice-to-receipt workflow with status tracking and print views
- **Multi-provider payments** — Stripe, PayPal, Razorpay, and EveryPay via a unified Provider behaviour with hosted checkout
- **Internal subscription control** — subscriptions managed in your database, not by providers; automatic renewals and dunning
- **Multi-currency** — currency definitions with exchange rates
- **Billing profiles** — individual and company billing details with address, tax ID, and IBAN validation
- **Transactions & refunds** — complete payment ledger with credit notes and partial refunds
- **Real-time updates** — PubSub events for orders, invoices, transactions, subscriptions, and profiles
- **Admin dashboard** — LiveViews for managing all billing entities, settings, and provider configuration
- **User dashboard** — "My Orders" and "Billing Profiles" pages for end users
- **Print views** — invoice, receipt, credit note, and payment confirmation print layouts
- **Auto-discovery** — implements `PhoenixKit.Module` behaviour; PhoenixKit finds it at startup with zero config

## Installation

Add `phoenix_kit_billing` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_kit_billing, "~> 0.3"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

> **Note:** For development or if not yet published to Hex, you can use:
> ```elixir
> {:phoenix_kit_billing, github: "BeamLabEU/phoenix_kit_billing"}
> ```

PhoenixKit auto-discovers the module at startup — no additional configuration needed.

## Quick Start

1. Add the dependency to `mix.exs`
2. Run `mix deps.get`
3. Enable the module in admin settings (`billing_enabled: true`)
4. Configure at least one payment provider in admin settings
5. Orders and invoices are available at `/admin/billing`

## Usage

### Order-to-Invoice Workflow

```elixir
alias PhoenixKitBilling

# Create an order
{:ok, order} = Billing.create_order(user, %{
  line_items: [%{description: "Widget", quantity: 1, unit_price: Decimal.new("29.99")}],
  currency: "EUR"
})

# Confirm the order
{:ok, order} = Billing.confirm_order(order)

# Generate an invoice from the order
{:ok, invoice} = Billing.create_invoice_from_order(order)

# Send the invoice to the customer
{:ok, invoice} = Billing.send_invoice(invoice)

# Mark as paid (generates receipt automatically)
{:ok, invoice} = Billing.mark_invoice_paid(invoice)
```

### Subscriptions

```elixir
# Create a subscription type (plan)
{:ok, type} = Billing.create_subscription_type(%{
  name: "Pro Monthly",
  interval: "month",
  price: Decimal.new("19.99"),
  currency: "EUR"
})

# Create a subscription for a user
{:ok, subscription} = Billing.create_subscription(user, type)
```

Subscription renewals and failed-payment retries (dunning) are handled automatically by Oban workers.

### Payment Providers

Supported payment providers:

| Provider | Code | Notes |
|----------|------|-------|
| Stripe | `:stripe` | Cards and wallets; signed webhooks |
| PayPal | `:paypal` | PayPal and cards; signed webhooks |
| Razorpay | `:razorpay` | India (UPI, cards); signed webhooks |
| EveryPay | `:everypay` | EveryPay AS gateway (Baltics), API v4; callbacks verified by server-side status re-fetch |

Providers are configured in admin settings. The system uses hosted checkout — users are redirected to the provider's payment page:

```elixir
# Create a checkout session for an invoice
{:ok, session} = Billing.create_checkout_session(invoice, :stripe, %{
  success_url: "https://example.com/success",
  cancel_url: "https://example.com/cancel"
})

# Redirect user to session.url
```

Webhooks are handled automatically at `/webhooks/billing/:provider`.

> **Host setup — raw body reader.** Webhook signature verification needs
> the **raw** request body, so your endpoint must wire
> `PhoenixKitBilling.Plugs.CacheBodyReader` into `Plug.Parsers`:
>
> ```elixir
> plug Plug.Parsers,
>   parsers: [:urlencoded, :multipart, :json],
>   body_reader: {PhoenixKitBilling.Plugs.CacheBodyReader, :read_body, []},
>   json_decoder: Phoenix.json_library()
> ```
>
> `mix phoenix_kit_billing.install` does this for you. **Without it,
> webhooks return `400` with `:no_raw_body`** before processing.

### Testing Stripe locally

1. **Configure test keys** at `/admin/settings/billing/providers` (Stripe
   card): paste your `sk_test_…` / `pk_test_…`, tick **Enabled**, Save. The UI
   writes the `billing_stripe_secret_key` / `billing_stripe_publishable_key` /
   `billing_stripe_webhook_secret` settings; "Active Providers: Stripe" then
   confirms `available?/0` is true.

2. **Forward webhooks to localhost** with the Stripe CLI (no `stripe login`
   needed — pass the key directly):

   ```bash
   brew install stripe/stripe-cli/stripe   # once
   stripe listen --api-key sk_test_… \
     --forward-to http://localhost:4000/phoenix_kit/webhooks/billing/stripe
   ```

   It prints `Your webhook signing secret is whsec_…`. Paste **that** value
   into the **Webhook Secret** field on the providers page and Save — it's what
   the controller verifies against (not the dashboard endpoint's secret).
   Adjust the `/phoenix_kit` prefix to your host's mount.

3. **Fire a test event:**

   ```bash
   stripe trigger checkout.session.completed --api-key sk_test_…
   ```

   Success = a `[200]` in the `stripe listen` output, a
   `phoenix_kit_webhook_events` row with `processed=true`, and a
   `Webhook processed successfully` log line. A `400` with `:no_raw_body`
   means the host hasn't wired `CacheBodyReader` (see above).

### Real-Time Events

Subscribe to billing events in your LiveViews:

```elixir
def mount(_params, _session, socket) do
  PhoenixKitBilling.Events.subscribe_orders()
  {:ok, socket}
end

def handle_info({:order_created, order}, socket) do
  # Update UI
  {:noreply, socket}
end
```

### Trash

Orders and draft invoices are not deleted from the admin: they go to a trash
(Orders and Invoices lists have a *Trash* tab) and come back with *Restore*.
Nothing empties it.

```elixir
{:ok, order} = PhoenixKitBilling.trash_order(order, actor_uuid: admin.uuid, reason: "Created by mistake")
{:ok, order} = PhoenixKitBilling.restore_order(order)

{:ok, invoice} = PhoenixKitBilling.trash_invoice(invoice, actor_uuid: admin.uuid)
{:ok, invoice} = PhoenixKitBilling.restore_invoice(invoice)

PhoenixKitBilling.list_orders(%{trashed: :only})    # :include for both
```

- A `draft` or `cancelled` order without an open invoice (neither void nor in
  the trash) can be trashed; its status does not change. An invoice can be
  trashed only while it is a `draft` that was never sent - an issued invoice is
  voided - and its number stays used.
- A document in the trash refuses every change with `{:error, :order_trashed}` /
  `{:error, :invoice_trashed}` until it is restored, and no email goes out.
- An invoice cannot be created for, moved onto or restored onto an order in the
  trash or a cancelled one (`:order_trashed`, `:order_cancelled`). A cancelled
  order stays cancelled, so an invoice trashed from it stays in the trash (its
  number stays used).
- Trashing and restoring leave `updated_at` as it was.
- Restoring a trashed draft invoice puts back its old figures. If the order's
  lines changed meanwhile, the invoice no longer matches them: check it before
  sending.
- A void invoice of a trashed order stays in the invoice lists (it is an issued
  document; only a draft invoice goes to the trash).
- Listings, counts and the dashboard leave the trash out unless asked
  (`trashed: :only | :include`). `get_order/2` and `get_invoice/2` still find it.
- Subscribers of the orders and invoices topics also receive
  `{:order_trashed, order}`, `{:order_restored, order}`, `{:invoice_trashed, invoice}`
  and `{:invoice_restored, invoice}` - and no other event with them.
- Needs migration V8 (`mix phoenix_kit.update`).

### Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `billing_enabled` | boolean | `false` | Enable/disable the billing system |
| `billing_default_currency` | string | `"EUR"` | Default currency for new orders |
| `billing_tax_enabled` | boolean | `false` | Enable tax calculations |
| `billing_company_name` | string | — | Company name on invoices |
| `billing_company_address` | string | — | Company address on invoices |
| `billing_document_logo_file_uuid` | string | — | Media-library file shown at the top of printed documents and in billing emails; unset falls back to the project logo, then the company name |
| `billing_document_footer` | string | — | Text about the company closing every printed document and billing email (at most 1000 characters) |

Provider-specific settings (API keys, webhook secrets) are configured per-provider in the admin panel at `/admin/settings/billing/providers`.

### Invoice Status Workflow

| Status | Description |
|--------|-------------|
| `"draft"` | Invoice created, not yet sent |
| `"sent"` | Invoice sent to customer |
| `"paid"` | Payment received, receipt generated |
| `"overdue"` | Past due date, not yet paid |
| `"void"` | Cancelled / voided |

```
draft → sent → paid
            ↘
           overdue → paid
            ↘
            void
```

### Emails

Billing sends four emails to the customer: `billing_invoice`, `billing_receipt`,
`billing_credit_note` and `billing_payment_confirmation`. They go out through
`phoenix_kit_emails` (`required_modules/0`) and appear in core's email preview
(`/admin/settings/email-sending/preview`) with sample data.

**Language.** A send uses the customer's preferred locale, or the site's content
language for a guest payer or an account without a preference. Billing explicitly
installs that language for its own copy, including when the sender has set a
Gettext backend locale. Dates use core's translated month names and locale-aware
ordering, in both sends and previews. This works from the supported core floor
of 2.44.0.

Each email's built-in copy (`PhoenixKitBilling.EmailDefaults`) has three parts:

| Part | Builds | Line items as |
|------|--------|---------------|
| `subject` | the subject | — |
| `markdown` | the HTML version, inside core's layout | `{{{line_items_table_html}}}` — a ready-made table |
| `text` | the plain-text version | `{{line_items_text}}` — one line per item |

The link to the document online (`{{invoice_url}}`, `{{receipt_url}}`,
`{{credit_note_url}}`, `{{payment_url}}`) is a button. The company's details close
the body; a blank one (an empty VAT number, say) is left out, and so is the
invoice's bank transfer section when there is no IBAN. Both HTML and plain text
omit missing document links, empty bank names and SWIFT codes, and absent company
details. An invoice without a due date omits its payment deadline.

**Overriding.** Put files under `priv/phoenix_kit_templates/<email name>/` in the
host app, as for any email (`subject.txt`, `markdown.md`, `html.html`, `text.txt`,
each optionally per locale: `markdown.et.md`). A part you don't override keeps
billing's default. To keep the line-items table in the HTML version, place
`{{{line_items_table_html}}}` — three braces, because the value is HTML; billing
escapes and styles the table inline — in one of:

- a host `html.html`. Billing's `text` default still builds the plain-text version.
- a host `markdown.md` **and** a host `text.txt` that lists the items with
  `{{line_items_text}}`. A host's `markdown.md` also builds the plain-text version
  when there is no host `text.txt` — it outranks billing's `text` default — and would
  put the table's HTML into it.

A host that overrides only `text.txt` changes the plain-text version, and,
on a core that builds the HTML from a host's text, the HTML version too — then
without the table. `{{{line_items_html}}}` is the older form: bare `<tr>` rows for a
template that wraps them in its own `<table>`.

**Layout group.** Billing emails are sent with `layout: "billing"`, so a host can
give them their own chrome — company details in the footer, say — with
`_layout-billing`, `_header-billing` or `_footer-billing`, each falling back to the
shared `_layout`, `_header` or `_footer`.

An active database template from `phoenix_kit_emails` under the same name still
wins over all of the above.

### Permissions

The module declares permissions via `permission_metadata/0`:

- `"billing"` — access to billing admin dashboard and all sub-pages
- Settings pages require the same `"billing"` permission

Use `Scope.has_module_access?/2` to check permissions in your application.

### CSS Requirements

This module implements `css_sources/0` returning `[:phoenix_kit_billing]`, so PhoenixKit's installer automatically adds the correct `@source` directive to your `app.css` for Tailwind scanning. No manual configuration needed.

## Architecture

```
lib/
├── phoenix_kit_billing.ex                    # Main module (context + PhoenixKit.Module behaviour)
└── phoenix_kit_billing/
    ├── mix_tasks/
    │   └── phoenix_kit_billing.install.ex    # Install mix task
    ├── events.ex                     # PubSub event broadcasts
    ├── paths.ex                      # Centralized URL path helpers
    ├── supervisor.ex                 # OTP Supervisor
    ├── providers/
    │   ├── provider.ex               # Provider behaviour (9 callbacks)
    │   ├── providers.ex              # Provider registry and routing
    │   ├── stripe.ex                 # Stripe implementation
    │   ├── paypal.ex                 # PayPal implementation
    │   ├── razorpay.ex               # Razorpay implementation
    │   └── everypay.ex               # EveryPay implementation
    ├── schemas/
    │   ├── billing_profile.ex        # User billing information
    │   ├── currency.ex               # Currency definitions
    │   ├── invoice.ex                # Invoice with receipt
    │   ├── number_sequence.ex        # Counter behind order/invoice/receipt/transaction numbers
    │   ├── order.ex                  # Order with line items
    │   ├── payment_method.ex         # Saved payment methods
    │   ├── subscription.ex           # Subscription records
    │   ├── subscription_type.ex      # Subscription plan definitions
    │   ├── transaction.ex            # Payment/refund transactions
    │   └── webhook_event.ex          # Provider webhook log
    ├── workers/
    │   ├── subscription_renewal_worker.ex   # Oban: subscription renewals
    │   └── subscription_dunning_worker.ex   # Oban: failed payment retries
    └── web/                          # Admin LiveViews, controllers, components
```

### Database Tables

| Table | Description |
|-------|-------------|
| `phoenix_kit_billing_profiles` | User billing information (UUIDv7 PK) |
| `phoenix_kit_currencies` | Currency definitions |
| `phoenix_kit_orders` | Orders with line items |
| `phoenix_kit_invoices` | Invoices with receipt data |
| `phoenix_kit_transactions` | Payment/refund transaction ledger |
| `phoenix_kit_subscriptions` | Active subscriptions |
| `phoenix_kit_subscription_types` | Subscription plan definitions |
| `phoenix_kit_payment_methods` | Saved payment methods from providers |
| `phoenix_kit_payment_options` | Available payment options |
| `phoenix_kit_webhook_events` | Provider webhook event log |
| `phoenix_kit_billing_number_sequences` | Counter behind order, invoice, receipt and transaction numbers |

## Development

```bash
mix deps.get       # Install dependencies
mix test           # Run tests
mix format         # Format code
mix credo --strict # Static analysis (strict mode)
mix dialyzer       # Type checking
mix docs           # Generate documentation
mix precommit      # Compile + format + credo + dialyzer
mix quality        # Format + credo + dialyzer
```

### Testing

The module ships its own test harness — a `DataCase`/`LiveCase`, a test
`Endpoint` + `Router`, and core's versioned migrations run via
`PhoenixKit.Migration.ensure_current/2` (no parent app required):

```bash
createdb phoenix_kit_billing_test   # one-time: create the test database
mix test                            # run the suite
```

Use `PhoenixKitBilling.DataCase` for schema/context tests and
`PhoenixKitBilling.LiveCase` for admin LiveView tests.

## Troubleshooting

### Billing not appearing in admin
- Verify `billing_enabled` is `true` in settings
- Ensure the module is listed as a dependency in the parent app's `mix.exs`
- Check that `enabled?/0` is not returning `false` (requires database access)

### Webhooks not processing
- If webhooks return `400` with `:no_raw_body`, the host endpoint is
  missing the raw body reader — wire
  `PhoenixKitBilling.Plugs.CacheBodyReader` into `Plug.Parsers`
  (`body_reader:`) as shown under "Payment Providers" above, or re-run
  `mix phoenix_kit_billing.install`
- Verify webhook secrets are configured in provider settings
- Check that webhook URLs are registered with the provider (e.g., `https://yourdomain.com/webhooks/billing/stripe`)
- Review `phoenix_kit_webhook_events` table for received events

### Subscription renewals not running
- Ensure Oban is configured in the parent app with the `billing` queue
- Check Oban dashboard for failed jobs

## License

MIT — see [LICENSE](LICENSE) for details.
