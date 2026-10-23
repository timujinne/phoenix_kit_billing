# PR #44 — Actor and activity logging through core

**Reviewed:** 2026-10-21
**Reviewer:** Claude (Sonnet 5.5)
**PR:** #44 — `mdon:main` → `main`, merged as `f327caf`
**Author:** mdon
**Status:** Merged. No defects found.

## Summary

`Activity` now delegates to core's `PhoenixKit.Activity.log/3` and
`PhoenixKitWeb.Actor`, dropping the local `rescue`/`catch` (core guarantees the
call never raises). Adds `Web.Trail` and moves every admin page onto core's
header-trail assigns (`page_section`, `page_crumbs`, `page_title`). Raises the
core floor to 2.38.0.

## Findings

- **NITPICK** — `order_form.ex` sets the trail title `"New order"` while the
  page `<h1>` still renders `"New Order"`; both msgids now exist in
  `default.pot`. Harmless, but one string would serve. Not changed: the `.po`
  files carry both translations.
- Checked and fine: the pre-`handle_params` mount branches no longer assign
  `page_title`, but they are only reached before `handle_params` assigns the
  trail or on the `push_navigate` branch. The `build_metadata/1` change
  (`|| %{}`) correctly tolerates an explicit `metadata: nil`. The pin guard test
  was updated in the same commit, as AGENTS.md requires.
