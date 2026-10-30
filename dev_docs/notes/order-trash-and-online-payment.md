# Order trash (V8) meets the online payment of an order

Status: open, noted 2026-10-30 after merging upstream main (`start_order_payment/2`) into this
branch. Matters only while an online payment option is active.

## What happens

`PhoenixKitBilling.OrderPayment.find_or_create_invoice/1` (`lib/phoenix_kit_billing/order_payment.ex`)
picks the order's latest open invoice by status alone (`draft`, `sent`, `overdue`, `paid`). It does
not skip an invoice in the trash (`trashed_at` set, this branch's V8).

When an admin has moved an order's draft invoice to the trash:

1. `start_order_payment/2` finds that trashed draft as the order's open invoice;
2. `make_payable/2` calls `send_invoice/2`, which refuses it with `{:error, :invoice_trashed}`;
3. the online payment of the order does not start: the shopper is told the payment could not be
   started, until the invoice is restored.

`ensure_payable/1` does not look at the order's own `trashed_at` either. A new invoice is still
refused for a trashed order (`create_invoice_from_order/1` answers `:order_trashed`), so a trashed
order cannot be paid online, which is the intended outcome, but the error is a generic one.

## Options

- Skip trashed invoices in `find_or_create_invoice/1` (`is_nil(i.trashed_at)`), so a new invoice
  is made for the order when its only open one is in the trash.
- Refuse a trashed order early in `ensure_payable/1` with its own error (`:order_trashed`), so
  the shopper and the log say why.

Both need a test: an order whose draft invoice is in the trash starts its payment on a new invoice;
a trashed order is refused with `:order_trashed`.
