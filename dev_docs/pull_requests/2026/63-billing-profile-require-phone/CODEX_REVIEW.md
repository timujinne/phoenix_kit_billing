# PR #63 — Add a require_phone option to billing profile fields

Reviewed: 2026-10-29 by Codex. Author: timujinne.
PR: https://github.com/BeamLabEU/phoenix_kit_billing/pull/63
Merge: `69a84eba6c5490d1173ae87d7e5b781e0e691835`.
Review baseline: `04353c5`.

No actionable findings. The changeset adds `phone` to the required fields only
when requested. The component forwards the option to both individual and
company forms and uses the existing input component's required marker.

The tests cover both profile types, missing and whitespace-only phone values,
the optional default, required HTML attributes, and independence from the email
and address options. No new gettext message is introduced.

Validation for this review batch is recorded in `FOLLOW_UP.md`.
