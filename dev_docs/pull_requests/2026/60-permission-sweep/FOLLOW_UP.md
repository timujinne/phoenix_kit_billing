# PR #60 — follow-up

- The base Dashboard still shows the latest orders/invoices to any `billing` holder (low; columns are summary only).

## Codex — 2026-10-27

The earlier note above no longer describes the merged implementation: order
and invoice sections already require their respective capabilities, and the
existing tests verify that base-only holders cannot see them.

Resolved the remaining dashboard findings in `CODEX_REVIEW.md`:

- The currency query and section require `manage_settings`, with base-only,
  sibling-capability and successful settings-holder coverage.
- Dashboard data reloads in `handle_params/3`; navigation and Refresh are
  covered. Billing links use `Paths`.

The combined focused run passed (96 tests), followed by the full suite:
985 tests, 0 failures, 5 exclusions for APIs absent from the pinned Hex core.
`mix format` and `mix precommit` passed, including compilation with warnings
as errors, unused-dependency and Hex audit checks, strict Credo and Dialyzer.
