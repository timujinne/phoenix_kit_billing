# PR #60 — Check billing detail and form sub-permissions on mount

Reviewed: 2026-10-27 by Codex. Author: mdon.
PR: https://github.com/BeamLabEU/phoenix_kit_billing/pull/60
Merge: `a9ed0a843aa12aa9677edaae55fdb8bcfd28481f`.
Review baseline: `dd38bb2`.

The new detail/form guards use the capabilities of their corresponding list
tabs and run before loading records. Existing mutation checks remain in place.
The dashboard correctly restricts order and invoice sections and action links.

## Findings

### BUG - MEDIUM — Dashboard currency records bypass the settings capability

The Active Currencies section was still fetched and rendered for any base
`billing` holder. Only its Manage link checked `manage_settings`, although
currency records are gated by that capability elsewhere and the repository
requires dashboard sections to follow their records' permission.

Restricted both the currency query and the entire section to settings holders.
Extended the base-only and sibling-capability tests to reject the section;
added a settings-holder test covering initial rendering and Refresh.

### IMPROVEMENT - MEDIUM — Load dashboard records on navigation

The dashboard loaded its data in mount and ignored handle_params, leaving
figures and recent records stale after a patch within the same LiveView.
Moved the project title and dashboard reads into handle_params; mount keeps
capabilities, initial assigns and the module-availability gate. Refresh still
reloads the records. A regression creates a new order after mount and verifies
that subsequent navigation reloads it. Billing links in the changed dashboard
now use `Paths`, following the repository's URL-helper convention.

## Validation

The currency-section assertions fail on the review baseline. The existing
base-only, sibling-denial and successful-mount cases still pass, along with the
new settings and navigation checks. Combined focused run: 96 tests, 0 failures.
Full-suite and gate results are recorded in `FOLLOW_UP.md`.
