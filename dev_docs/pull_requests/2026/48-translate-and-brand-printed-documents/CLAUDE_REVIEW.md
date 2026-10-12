# Code Review: PR #48 — Translate the printable billing documents and brand them

**Reviewed:** 2026-10-09
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/48
**Author:** timujinne (Tymofii Shapovalov)
**Head SHA:** 24da9f2
**Status:** Draft — REQUEST CHANGES

## Summary

The four print views (invoice, receipt, credit note, payment confirmation)
move their shared parts into `Web.Components.PrintDocument` (logo bar, seller
and customer blocks, footer, print controls, dates, statuses, payment
methods). Every label goes through `PhoenixKitBilling.Gettext` (en/et/ru),
dates use a translatable pattern with genitive month names, and `<html lang>`
follows the locale. The invoice's swapped parties are fixed (seller under
From, customer under Bill To). `format_company_address/1` writes UA/RU/BY/KZ
addresses postal-code-first on one line and names the country in the reader's
language; it is now used for the customer too. The seller block gains the
registration number; the invoice's bank block gains the account holder and
drops empty rows.

New `PhoenixKitBilling.DocumentBranding` reads two settings,
`billing_document_logo_file_uuid` (media-library file, falling back to
`auth_logo_file_uuid`, then the company name) and `billing_document_footer`.
They are edited in a new "Printed Documents" card under Billing → Settings,
and saving needs `manage_settings`. The four financial emails carry the
footer (`document_footer` for the text body, an escaped `document_footer_html`
paragraph for the HTML body) and, for a PNG/JPEG/GIF billing logo outside a
private library, a `logo_url` that replaces the site logo in the layout
header. The company address in emails is formatted in the recipient's locale.
The new core calls are declared in `CoreCompat`, and AGENTS.md lists the
settings.

The structure is sound. The extraction removes about 700 lines of
copy-pasted markup, the escaping is right on every path, and hosts without
the new settings keep working. One confirmed bug in the settings save path
and one data-loss trap in the new form need fixing before merge.

## Verification

- **Suite:** `MIX_ENV=test PGDATABASE=pkbill_test_uk PGPOOL=10 mix test`
  in the PR worktree gives 702 tests, 0 failures, 4 skipped (the documented
  subscription chain gap).
- **Gate:** `compile --warnings-as-errors`, `format --check-formatted`,
  `credo --strict` and `dialyzer` are clean. I ran them in a scratch copy of
  the worktree; dialyzer shows only the 2 known warnings, both skipped by the
  ignore file.
- **CHANGELOG and @version:** `git diff upstream/main...HEAD --name-only`
  touches neither `CHANGELOG.md` nor `mix.exs`. All 5 commits are authored by
  the owner, with no tool trailers.
- **Gettext:**
  - I ran `mix gettext.extract` in the scratch copy and compared it against the
    PR's `default.pot`. Every msgid the PR adds (and its `msgctxt` "date",
    "invoice status", "receipt status") is in the `.pot`.
  - en/et/ru have no empty and no fuzzy entries. `%{…}` / `{{…}}` placeholders
    match their msgids in all three locales.
  - No existing translation was changed. `pot_drift_test` passes.
  - The `.pot` lags the code by about 80 msgids in files this PR does not touch
    (errors, permissions, email bodies). That drift was already on upstream
    and is not from this PR.
- **Core API at the floor:** I checked each new call against the core
  checkout's tags. `Storage.get_file/1`, `URLSigner.signed_url/2,3` (with
  `version:`), `Routes.base_url/0`, `Storage.Libraries.private_file?/1`,
  `UploadsParentFolder`, and `MediaSelectorModal`'s `lock_file_type` and
  server-side `selectable?/2` all exist in **v2.44.0**, the floor.
- **Authorization:**
  - `save_documents` goes through `Authz.authorize(:manage_settings)`.
  - The other three new handlers (`open_document_logo_selector`,
    `clear_document_logo`, `{:media_selected, _}`) only change assigns.
  - A forged event therefore cannot persist anything without the permission;
    `settings_documents_test` covers the footer side of this.
  - Core caches the tab's `billing.manage_settings` as the view's permission
    (`Registry.auto_register_custom_permission/1`, sub-key branch, present
    from 2.44.0). So on every supported core the page is not even mountable
    without it.
- **Logo safety:**
  - The logo uuid comes only from the picker. Core's picker re-checks every
    uuid the browser sends (`selectable?/2`: live, not system-managed, not in
    a private library, image type when `lock_file_type`).
  - The printed URL carries the permanent token. The file route refuses that
    token for a private-library file, so a private file cannot leak through
    the documents; it shows as a broken image.
  - The email skips private files and non-mail-safe types.
- **Footer escaping:**
  - Print: HEEx-escaped, with `white-space: pre-line`.
  - Email: I rendered an invoice email end to end through
    `PhoenixKit.Email.Content.resolve/5` in a scratch test, with the footer
    `«Acme» <b>bold</b> & Co\r\nLine 2 {{user_email}}`.
  - The HTML body gets
    `<p style="…">«Acme» &lt;b&gt;bold&lt;/b&gt; &amp; Co<br>Line 2 {{user_email}}</p>`:
    escaped, the line break kept, no nested `<p>`, and no second substitution
    of `{{user_email}}`.
  - The text body carries the footer verbatim, inside the company box.
  - The layout header shows the billing logo as an absolute URL.
- **Parties:**
  - Only the invoice had them swapped; it is fixed.
  - Receipt and payment confirmation keep "Received By" = seller and
    "Received From" = customer. Only the column order changed, seller now
    first.
  - Credit note keeps "Issued By (Payer)" = seller.
  - The emails were already right (`Bill To: {{user_name}}`).
- **Address format:**
  - The non-postal-first branch produces exactly the old lines (street, line 2,
    "City Postal", state, country), so EU/US output is unchanged apart from
    the translated country name.
  - The postal-first order for UA/RU/BY/KZ matches the register convention
    (ЄДР / ЕГРЮЛ: "36007, Полтавська обл., м. Полтава, вул. …").
  - Blank and `nil` parts are dropped, and an unknown code prints as itself.
- **Backward compatibility:**
  - A host with no new settings gets the project logo, or the company name, in
    a new top band.
  - The footer no longer repeats the address and VAT; VAT stays in the seller
    block.
  - Emails gain nothing: no footer paragraph, and no `logo_url`, so core keeps
    the site logo.
- **Screenshots** (`/tmp/pw/shots/invoice-*.png`): checked the invoice (screen
  and print media), receipt, email and settings card. The layout holds with
  the longer Ukrainian labels.

## Findings

### BUG - MEDIUM — A footer longer than 1000 characters is silently discarded, with a success flash (open)

`Web.Settings.gated_event("save_documents", …)`
(`lib/phoenix_kit_billing/web/settings.ex:245-257`) ignores both
`Settings.update_setting/2` results. Core's `Setting` changeset validates
`value` to at most 1000 characters (`validate_setting_value/1`, every
non-optional key). A longer footer therefore returns `{:error, changeset}`.
The LiveView still flashes "Document settings saved", and `load_settings/1`
then reloads the old text into the textarea. The operator's text is gone and
they are told it was saved.

Reproduced in a scratch LiveView test: with a 1,120-character footer
submitted, the success flash is shown, the stored value is still
"Old footer", and a direct `update_setting` returns `:error`. The two writes
are also not atomic: the logo can save while the footer fails.

**Fix:**
- Check both results. On error, keep the submitted text in the assign and
  flash an error.
- Add `maxlength="1000"` to the textarea.
- Optionally note the limit in the help text and in AGENTS.md.

A test with a >1000-character footer should assert the error flash and that
the submitted text survives.

### IMPROVEMENT - MEDIUM — Unsaved form state is wiped by the card's own controls (open)

The documents form (`settings.html.heex:257`) has no `phx-change`, so the
server never learns what was typed in the footer textarea (`:297`).

**Lost footer text.** Any round trip that changes an assign re-renders the
form: "Select Image", "Remove", picking a file in the modal, "Save General
Settings", or the tax-rate change event. LiveView 1.2.12's DOM patch then
morphs the non-focused textarea back to the server's `@document_footer`.
This is the `dom_patch` `onBeforeElUpdated` → morphdom `TEXTAREA` handler;
only the focused input is preserved. The natural flow loses the text: type
the footer, then click "Select Image". This follows from the patch code; I
did not click through it in a browser.

**Lost logo pick.** The reverse also happens. A picked but unsaved logo lives
only in `@document_logo_uuid`. "Save General Settings" calls `load_settings/1`,
which reloads it from the database, and the pick silently disappears. The
preview had shown it as set.

No form recovery on reconnect follows from the same cause.

**Fix:** add `phx-change="change_documents"`, keeping `document_footer` in an
assign (it can stay ungated, since it writes nothing). Alternatively, persist
the logo on pick (gated) and keep the footer in an assign.

### IMPROVEMENT - MEDIUM — `MediaSelectorModal` is core API the inventory does not list (open)

`settings.html.heex:319` mounts `PhoenixKitWeb.Live.Components.MediaSelectorModal`.
It relies on the `lock_file_type` / `file_type_filter` attrs and on its
message contract (`{:media_selected, uuids}`, `{:media_selector_closed}`,
`settings.ex:272-283`).

It is a module reference inside a template, not a call. Neither the AST
extractor nor `compile_time_modules/0` sees it, and a core that moves or
renames it breaks the picker only at click time. AGENTS.md calls `CoreCompat`
"the inventory of what core owes this package".

**Fix:** declare it, for example `{PhoenixKitWeb.Live.Components.MediaSelectorModal, :update, 2}`
in `runtime_calls/0` with a comment naming the message contract, or extend
`compile_time_modules/0`.

### IMPROVEMENT - MEDIUM — The email logo is the full-size original, unversioned (open)

`DocumentBranding.email_logo_url/0` (`document_branding.ex:120-128`) always
serves the `"original"` variant (`@logo_variant`, `:36`) with no `version:`.
Core's own email logo (`PhoenixKit.Email.Branding.public_logo_url/1`) picks
the first finished mail-safe variant, small → medium → large → original, and
mints a versioned URL.

A 3000-px, multi-megabyte PNG uploaded as the billing logo is downloaded in
full by every recipient for a 40-px header. An edited image keeps the same
URL and relies on revalidation.

Everything needed exists at the floor (`Storage.list_file_instances/1`,
`URLSigner.signed_url/3` with `version:`). The original is the right file
for print, so only the email path needs this.

### NITPICK — The picker opens without the `manage_settings` check

`open_document_logo_selector` (`settings.ex:101-104`) is ungated, and the
modal it opens can browse the whole site library and **upload** files into
storage. Every supported core mount-gates this page on `billing.manage_settings`,
so this is defence in depth only. AGENTS.md's convention is that bundled-UI
handlers re-check the capability, though, and the page's own test mounts it
with base `"billing"` alone.

**Fix:** wrap the handler in `Authz.authorize(socket, :manage_settings, …)`.

Related parity point: core's branding picker passes
`scope_folder_id: PhoenixKit.UploadsParentFolder.resolve(:branding, Actor.uuid(socket), nil)`.
Billing does not, so on a host with that hook a billing logo upload lands at
the root. The hook exists at the floor.

### NITPICK — `Libraries.private_file?/1` is not "later than the floor"

The comment at `document_branding.ex:145` says libraries arrived after this
module's floor, and `CoreCompat` lists the function under `optional_calls`.
`PhoenixKit.Modules.Storage.Libraries.private_file?/1` is in core v2.44.0.
The guard is harmless, but the comment and the list placement say something
untrue. Either move it to `runtime_calls/0` and call it directly, or reword
the comment as defensive.

### NITPICK — A bare "From" msgid translated as "Поставщик" / "Müüja"

`invoice_print.html.heex:433` uses `gettext("From")`, which ru translates as
"Поставщик" and et as "Müüja". It is the only use today, but the next
`gettext("From")` (a date-range filter, say) inherits "supplier".

**Fix:** use `pgettext("document party", "From")` (and the same for
"Bill To"), as the PR already does for statuses and months.

### NITPICK — The footer paragraph style is duplicated

The preview sample at `email_defaults.ex:355` hard-codes the same inline
style as `DocumentBranding`'s private `@footer_style`. A style change in one
place leaves the preview stale. Build the sample through the same function,
or expose the style.

### NITPICK — `save_documents` crashes on a non-string footer param

`String.trim(params["document_footer"] || "")` (`settings.ex:250`) raises
`FunctionClauseError` for a forged map or list value. Only a
`manage_settings` holder can reach it, and only their own LiveView restarts.
`case params["document_footer"] do text when is_binary(text) -> … end` closes
it.

### NITPICK — An empty logo band when there is neither logo nor company name

`PrintDocument.brand/1` (`print_document.ex:96-106`) always renders the band,
which has `min-height: 56px` plus padding. With no logo and an empty company
name, every document opens with roughly 100 px of blank white.
`:if={@logo_url || @company.name != ""}` avoids it.

### NITPICK — The logo lookup accepts files the file route will not serve

`logo_file/1` (`document_branding.ex:130-143`) checks only `trashed_at`.
Core's file route also refuses `system_managed` files, and refuses a private
file's permanent token. A private **project** logo, reachable through the
`auth_logo_file_uuid` fallback, therefore prints as a broken image instead of
the company name. Rare; mirroring `servable_file/2` plus the email path's
`private_file?/1` check would make print fail over to the name the way email
does.

### NITPICK — The base-locale split is written three times

`PrintDocument.html_lang/0`, `PhoenixKitBilling.base_locale/1` and
`translated_country_name/1` each do `String.split(["-", "_"]) |> hd()`. One
helper would do.

### NITPICK — README's Settings table does not list the new keys

AGENTS.md documents `billing_document_logo_file_uuid` and
`billing_document_footer`, but README's host-facing Settings table does not.
That table is also stale in other ways: `billing_default_currency` is dead.

## Observations (pre-existing, not regressions; for follow-ups)

- **HTML emails flatten the company address.** `{{company_address}}` sits
  inside a `<p>`, so its `\n`s collapse ("Kyiv Ukraine" on one line in the
  scratch render). The PR fixed exactly this for the footer text; the address
  could get the same `<br>` treatment.
- **Email dates are still English** ("Invoice date: Oct 09, 2026."), while
  the print documents are now localized. This was flagged in #46;
  `PrintDocument.format_date/1` could now serve the emails too.
- **Print times are UTC with no zone** (`format_datetime/1`, "08:17" for an
  11:17 Kyiv payment).
- **The street-first order is wrong for most of the EU.** It writes
  "City Postal", but EE/DE/FR write "10117 Tallinn", and the US writes
  "City, ST 12345". The new test and the `format_company_address/1` doc
  example pin "Tallinn 10117" as the expected form.
- **A company customer prints only its VAT number.** The snapshot also has
  `company_registration_number` (the buyer's ЄДРПОУ on a UA B2B invoice),
  which would mirror the seller's new "Reg. No:".
- **The receipt's "Payment Method" is hard-coded to bank transfer**, whatever
  the provider.
- **The footer is one text for every locale**, so an et/ru document carries
  it in the language it was typed in. This is by design, but worth a line in
  the help text.

## Tests

The new tests check behaviour, not markup:
- the Russian/English invoice by element ids;
- the parties under the right headings;
- the bank rows;
- the localized date;
- the footer;
- the receipt, credit note and payment confirmation titles;
- `DocumentBranding` fallbacks (trashed, missing, non-uuid, SVG for email);
- the settings save and its permission gate;
- address formatting for UA, EE and unknown codes.

Gaps worth filling with the fixes:
- a >1000-character footer;
- an end-to-end email render with footer and logo through `Content.resolve/5`
  (I did it as a scratch test, and it passes);
- RU/BY/KZ postal-first;
- the email's private-library exclusion;
- the permission gate on the logo.

## Verdict

**REQUEST CHANGES.** No security problem: authorization, escaping and
private-file handling are all correct, and the CHANGELOG / `@version`
constraint is respected.

Before merge:
1. Fix the silent loss of a >1000-character footer (BUG - MEDIUM).
2. Stop the form's own controls wiping unsaved footer text and logo picks
   (IMPROVEMENT - MEDIUM).

The CoreCompat entry for `MediaSelectorModal` and the email-sized logo are
cheap and worth taking in the same round. The nitpicks are optional.

---

# Round 2

**Reviewed:** 2026-10-09
**Head SHA:** 06f5a5d ("Address the review of the printed-document branding",
on top of 0940d67, which commits round 1 under
`dev_docs/pull_requests/2026/48-translate-and-brand-printed-documents/`)
**Status:** Draft — APPROVE

## Verification

- **Suite:** `MIX_ENV=test PGDATABASE=pkbill_test_uk PGPOOL=10 mix test`
  in the worktree gives 715 tests, 0 failures, 4 skipped.
- **Gate:** `compile --warnings-as-errors`, `format --check-formatted`,
  `credo --strict` and `dialyzer` are clean. I ran them in a scratch copy;
  dialyzer still shows only the 2 known warnings, both skipped by the ignore
  file.
- **Gettext:**
  - `mix gettext.extract` (scratch copy) against the committed `.pot`: every
    round-2 msgid is present.
  - The only gap is the same ~80 untouched-file msgids that were already on
    upstream; the count is unchanged.
  - en/et/ru have no empty or fuzzy entries and no `%{…}` mismatches.
- **CHANGELOG and @version:** `CHANGELOG.md` and `mix.exs` are still not in
  the diff. The new commit is authored by the owner, with no tool trailers.
- **Core API at the floor.** Every new core call exists in core **v2.44.0**:
  - `Settings.update_settings_batch/1,2`, which runs as one `Ecto.Multi`
    through `Queries.transaction/1`, with the same body as 2.52.1;
  - `Storage.list_file_instances/1`;
  - `URLSigner.signed_url/3` with `version:`;
  - `UploadsParentFolder.resolve/3`;
  - `PhoenixKitWeb.Actor.uuid/1`;
  - `MediaSelectorModal.update/2` and its `scope_folder_id` attr;
  - `FileInstance.processing_status`, `variant_name`, `mime_type` and
    `checksum`;
  - `File.trashed_at`, `system_managed` and `library_uuid`.

  So `update_settings_batch` needs no CoreCompat guard. It is declared in
  `runtime_calls/0`, as are the other new calls.

## Round 1 findings

| # | Finding | Status |
|---|---|---|
| 1 | BUG - MEDIUM: footer >1000 characters lost, with a success flash | **Fixed** |
| 2 | IMPROVEMENT - MEDIUM: unsaved card state wiped | **Fixed** |
| 3 | IMPROVEMENT - MEDIUM: `MediaSelectorModal` missing from CoreCompat | **Fixed** |
| 4 | IMPROVEMENT - MEDIUM: email logo full-size and unversioned | **Fixed** |
| — | All nitpicks | **Fixed** |
| — | Pre-existing observations | Unchanged, by design |

**1. Footer longer than 1000 characters: fixed.**
- `gated_event("save_documents", …)` refuses a footer longer than
  `DocumentBranding.footer_max_length/0` (1000) before anything is written.
  The text stays in the form and an error is flashed.
- The textarea carries `maxlength`, and the help text states the limit.
- Logo and footer go through one `update_settings_batch/1`: both are written
  or neither is. Any `{:error, …}` gives "Document settings could not be
  saved" with the text kept.
- Empty values: `document_changes/1` leaves out a `""` for a key that is
  already unset, because core refuses to *create* a setting with an empty
  value (`validate_value_exclusivity/1`). A `""` for a key that is set is
  written, and stored as `NULL`.
- I checked this in a scratch LiveView test:
  - a 1000-grapheme footer whose lines end in `\r\n` (as a browser submits
    them) saves, and stores 1000 characters;
  - 1001 characters is refused with the "too long" flash;
  - clearing a set logo and a set footer together saves both as empty.
- `String.length/1` and Ecto's `validate_length/3` both count graphemes, and
  `\r\n` is one grapheme, so the server check matches core's exactly. The
  browser's `maxlength` counts UTF-16 units, so it is only ever stricter.

**2. Unsaved card state: fixed.**
- The form has `phx-change="change_documents"`, which assigns the typed text
  and writes nothing. The server-rendered textarea therefore always equals
  what was typed, and a re-render no longer morphs it back.
- `load_document_settings/1` is split out of `load_settings/1`, so "Save
  General Settings" no longer reloads the card: a picked logo and typed text
  both survive.
- Covered by two new tests: text typed, then picker, pick, remove and general
  save; and pick, then general save.

**3. CoreCompat: fixed.** `runtime_calls/0` gains:
- `MediaSelectorModal.update/2`, with its attrs and message contract written
  in the comment;
- `Storage.list_file_instances/1`;
- `URLSigner.signed_url/3`;
- `Settings.update_settings_batch/1`;
- `UploadsParentFolder.resolve/3`;
- `Libraries.private_file?/1`, moved from `optional_calls/0` and called
  directly.

**4. Email logo size: fixed.** The email logo is now the smallest *completed*
PNG/JPEG/GIF instance, in core's order (small, medium, large, original), with
`version: instance`. This is the same rule as `PhoenixKit.Email.Branding`.
- Tests cover: a WebP `small` skipped in favour of `medium`, with
  `?v=<checksum16>`; nothing finished yet, so no `logo_url`; and a
  private-library logo, also no `logo_url`.
- A new end-to-end render through `Content.resolve/5` asserts the escaped
  footer, the logo `<img>` with its versioned URL, and the verbatim text body.

**Nitpicks: all fixed.**
- **Picker gating:** `open_document_logo_selector` is gated on
  `manage_settings` and passes
  `scope_folder_id: UploadsParentFolder.resolve(:branding, Actor.uuid(socket), nil)`,
  like core's own picker. Tests cover both the denied and the allowed
  operator.
- **"From" / "Bill To":** both now use `pgettext("document party", …)`, with
  the context carried in the `.pot` and in en/et/ru.
  - No translation was lost. Neither msgid existed upstream, and the invoice
    template is their only use; `grep` finds no other `"From"` or `"Bill To"`
    in `lib/`.
  - The email's `Bill To: {{user_name}}` is a different msgid and is
    untouched.
- **Preview footer:** the preview builds its footer through the now-public
  `DocumentBranding.footer_html/1`.
- **Non-string footer param:** no longer crashes the page. It falls back to
  the card's assign; tested with a forged `render_hook/3`.
- **Empty band:** the logo band is left out when there is neither a logo nor
  a company name; tested.
- **Unservable logo files:** `logo_file/1` now skips system-managed and
  private-library files for both the documents and the email. A private
  project logo therefore prints the company name instead of a broken image;
  tested.
- **Base-locale split:** now lives in one `PhoenixKitBilling.base_locale/1`
  (public, `@doc false`).
- **Docs:** README's Settings table lists both keys, and AGENTS.md records the
  1000-character limit and the single transaction.

## New in round 2

### NITPICK — The "too long" test's flash assertion cannot fail

`settings_documents_test.exs` ("is refused with an error…") checks the error
with `assert html =~ "1000"`. Since this round, the card's own help text
("up to 1000 characters") and `maxlength="1000"` put "1000" on every render.
The other assertions in that test still prove nothing was saved and the text
was kept, but none proves the error flash rather than the success one.

**Fix:** assert on the flash text ("too long") or
`refute html =~ "Document settings saved"`.

### NITPICK — `EmailDefaults` now depends on `DocumentBranding` at compile time

`@sample_company` (`email_defaults.ex`) calls `DocumentBranding.footer_html/1`
inside a module attribute, which runs at compile time.
`mix xref graph --source lib/phoenix_kit_billing/email_defaults.ex --label compile`
shows `document_branding.ex (compile)`. The only cost is that every edit to
`DocumentBranding` recompiles `EmailDefaults`, since `DocumentBranding` has no
compile-time edges of its own. Moving the sample into a function, as
`for_template/2` already is, removes the edge.

## Verdict (round 2)

**APPROVE.** Every round-1 finding is closed and verified in code, in the
suite and in scratch tests, and no regression turned up:
- `update_settings_batch` is at the 2.44.0 floor and is atomic;
- empty values behave correctly;
- the msgctxt move lost no translation;
- the picker is gated on `manage_settings`.

The two new nitpicks are optional.

The `dev_docs/…/CLAUDE_REVIEW.md` committed in 0940d67 holds round 1 only.
If the repo copy should match this file, append round 2 there too.

---

# Round 3

**Reviewed:** 2026-10-09
**Head SHA:** 248c3ec ("Address the round-2 nitpicks on the document branding review")
**Status:** Draft — APPROVE

A targeted check of the two round-2 nitpicks, the only files this commit
touches (`email_defaults.ex`, `settings_documents_test.exs`).

## Verification

- **Suite:** `MIX_ENV=test PGDATABASE=pkbill_test_uk PGPOOL=10 mix test`
  in the worktree gives 715 tests, 0 failures, 4 skipped.
- **Gate:**
  - In a scratch copy: `compile --warnings-as-errors`, `format --check-formatted`
    and `dialyzer` are clean, with the 2 known warnings skipped by the ignore
    file.
  - In the worktree: `credo --strict` finds no issues.
- **CHANGELOG and @version:** `CHANGELOG.md` and `mix.exs` are still not in
  the diff. The commit is authored by the owner, with no tool trailers.

## Round 2 nitpicks

### The "too long" test now proves the error flash — fixed

The test now asserts the exact flash text ("The footer text is too long: at
most 1000 characters.") and refutes "Document settings saved". The help text
no longer satisfies it: "up to 1000 characters" differs from the flash.

I made three mutations of `gated_event("save_documents", …)` in a scratch copy
and ran `settings_documents_test.exs` against each. The worktree was not
touched.

| Mutation | Result |
|---|---|
| None (baseline) | 11 tests, 0 failures |
| M1: error flash removed (text kept, nothing saved) | 1 failure, on the error-text assertion |
| M2: success flash in place of the error | 1 failure |
| M3: length check disabled, so round 1's path returns, now a generic "could not be saved" from the failed batch | 1 failure |

### `EmailDefaults` no longer depends on `DocumentBranding` at compile time — fixed

`document_footer_html` now comes from `defp sample_company/0` at run time.
All four `sample_variables/1` clauses use it, and no remaining reference to
`@sample_company` lacks the key.
`mix xref graph --source lib/phoenix_kit_billing/email_defaults.ex` with
`--label compile` and with `--label compile-connected` both list no
dependencies. Preview output is unchanged; the email-defaults and
email-rendering tests pass.

## Verdict (round 3)

**APPROVE.** Both round-2 nitpicks are closed and verified, with no
regressions and no open findings. The round-1 pre-existing observations
remain follow-up material outside this PR.
