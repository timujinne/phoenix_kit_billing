# PR #64 — Start an order's invoice and checkout session in one call

Reviewed: 2026-10-29 by Codex. Author: timujinne.
PR: https://github.com/BeamLabEU/phoenix_kit_billing/pull/64
Merge: `3839e349b92e30b62e63aeec3228a7fef3b1f30d`.
Review baseline: `04353c5`.

## Findings

### BUG - HIGH — Non-Stripe provider paths fail or charge the full total again

The API accepts all registered providers and forwards a real `%Invoice{}`.
PayPal and Razorpay use Access syntax on that struct, which raises because the
schema does not implement Access. Both also derive the checkout amount from
the full total. EveryPay accepts the struct but charges the full total too:
a EUR 25 invoice with EUR 10 already paid is charged EUR 25 again.

PayPal and Razorpay now normalize structs to maps before reading their fields.
All three providers derive checkout amounts from `total - paid_amount`, matching
Stripe, and refuse non-positive balances with `:nothing_to_pay`. Request-level
tests use each real provider implementation with a stubbed transport, verifying
EUR 15 reaches its API and settled invoices produce no payment request. Existing
currency conversion tests continue to cover unknown and fractional currencies.

### BUG - MEDIUM — Reusing a session ignores currency and request options

The reuse predicate compares provider, numeric amount and age. A different
currency with the same numeric amount reuses the old currency's checkout.
Changed success/cancel URLs and customer email also return the previous
checkout, so a buyer can be sent back to the wrong flow or shown an old email.

The stored reuse context now includes currency, both return URLs and the
customer email option. A mismatch opens a new session on the same invoice.
Regressions exercise each option and an EUR-to-USD change at the same amount.
Older records lacking the context are refreshed once.

### BUG - MEDIUM — The legacy namespace omits the new public entry point

`PhoenixKit.Modules.Billing` re-exports the surrounding payment APIs but not
`start_order_payment/2`, causing an undefined-function error for legacy callers.
Added the delegate and exercised it through the same real order-payment path.

## Limits

The PR's documented requirement for session pooling and a connection held during
the provider call remains. Checkout URLs previously issued for an older amount
remain subject to the provider's lifecycle; opening a replacement does not
cancel those URLs. Resolving that requires a provider session cancellation and
settlement design beyond this review.

Validation and regressions are recorded in `FOLLOW_UP.md`.
