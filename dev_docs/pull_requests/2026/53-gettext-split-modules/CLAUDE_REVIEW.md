# PR #53 — Split the Gettext backend by locale and domain

**Reviewed:** 2026-10-21
**Reviewer:** Claude (Sonnet 5.5)
**PR:** #53 — `mdon:main` → `main`, merged as `1b82e09`
**Author:** mdon
**Status:** Merged. No defects found.

## Summary

`use Gettext.Backend` gains `split_module_by: [:locale, :domain]` so the large
catalogues compile as parallel modules. The option needs `gettext ~> 1.0`, which
`mix.exs` already requires. Lookups are unchanged; `pot_drift_test.exs` and the
localization tests exercise them.

## Findings

None.
