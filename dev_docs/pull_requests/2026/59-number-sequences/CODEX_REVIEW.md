# PR #59 — Number orders, invoices, receipts and transactions from a counter

Reviewed: 2026-10-27 by Codex. Author: timujinne.
PR: https://github.com/BeamLabEU/phoenix_kit_billing/pull/59
Merge: `f162d4bfc39fd43f288650ab6a005ef0e2e4ff91`.
Review baseline: `dd38bb2`.

The counter updates, first-use upserts, savepoint retries and receipt row locks
address the original deletion and concurrency failures. The review followed
the create, renumber, payment and receipt paths, their migration, and the
generated schema manifest.

## Findings

### BUG - HIGH — Imported receipt numbers do not advance the receipt counter

`create_invoice/2` accepts `receipt_number`, but only advanced the invoice
counter. Once a receipt counter existed, importing the next receipt number
left it unchanged. The next generated receipt could therefore duplicate the
imported number; receipts have no unique index to catch it. Updating an
invoice already advanced both counters, so the create path was inconsistent.

Fixed numbered inserts to advance any additional document counters after a
successful insert, inside the same transaction and using the operation's
year. Invoices declare their receipt number as an additional counter. This
keeps the invoice-before-receipt lock order and does not query receipt settings
for an invoice without a receipt number. The regression covers imports with
both generated and supplied invoice numbers, followed by a real payment that
must receive a later receipt number.

### BUG - MEDIUM — Blank invoice-number options bypass generation

`create_invoice_from_order/2` treated the presence of the option as a supplied
number, including `nil`, an empty string or whitespace. In particular, `nil`
reached the database and raised a NOT NULL violation. Other create entry points
already normalize blank numbers before choosing a source.

Applied the same blank-number predicate to the order-to-invoice entry point.
Tests cover all three blank forms and consecutive generated numbers.

### BUG - MEDIUM — The schema manifest omits V7's counter table

The merged migration adds `phoenix_kit_billing_number_sequences`, but the
generated `ExpectedSchema` still described eleven tables. A missing counter
table could escape the manifest's doctor/repair checks even though every
numbered create needs it. The existing manifest integration tests are excluded
with the pinned Hex core because they require newer core test helpers.

Regenerated the manifest using core's documented generator against the V7
chain. It now includes the twelfth table, its four columns, composite primary
key and updated fingerprint. Added an always-running inventory test comparing
the migration chain's CREATE TABLE statements with manifest tables, so this
omission is caught even with the pinned core.

## Existing limitation retained

The PR already documents that subscription renewal holds the invoice counter
through its provider charge, serializing other invoice creates behind that
call. This review retains that documented follow-up: shortening that transaction
requires a separate renewal ownership and retry design so moving the charge
cannot introduce duplicate charges or partially committed renewals.

## Validation

The receipt-import, blank-option and manifest-inventory regressions fail on
the review baseline. The combined numbering, concurrency, manifest-inventory
and permission run passes: 96 tests, 0 failures. The manifest was regenerated
from a real scratch-schema build of all twelve tables. Full-suite and gate
results are recorded in `FOLLOW_UP.md`.
