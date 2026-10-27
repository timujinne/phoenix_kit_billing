# PR #59 — follow-up

## Codex — 2026-10-27

Resolved all three findings in `CODEX_REVIEW.md`:

- Imported receipt numbers advance the receipt counter atomically with the
  invoice insert, for both generated and supplied invoice numbers.
- Nil, empty and whitespace invoice-number options use generated numbers.
- Regenerated the V7 manifest and added an inventory guard that runs without
  newer core integration helpers.

Validation:

- Original focused baseline: 83 tests, 0 failures. Adding the receipt-import,
  blank-option and dashboard regression checks produced 4 failing tests;
  the standalone manifest-inventory regression also failed on the baseline.
- Combined numbering, real concurrency, inventory and permission tests:
  96 tests, 0 failures.
- Full `mix test`: 985 tests, 0 failures, 5 excluded because the pinned Hex
  core lacks the newer module-chain/manifest helpers.
- After extracting the counter-floor helper for Credo, reran numbering and
  inventory tests: 81 tests, 0 failures.
- Generated the manifest with local core's documented generator, using a
  scratch schema on `phoenix_kit_billing_test`: twelve tables. An additional
  local-core scratch-schema check verified a clean manifest, removed the
  counter's `last_value` column, confirmed its missing-column finding, repaired
  it and verified a clean manifest again. Scratch schemas were dropped.
- `mix format` and `mix precommit` passed. The gate included compilation with
  warnings as errors, the unused-dependency check, Hex audit, formatting,
  strict Credo and Dialyzer with the existing third-party exclusions.

The documented renewal/provider-call transaction limitation remains a separate
follow-up, with its reason recorded in the review.
