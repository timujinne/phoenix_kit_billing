# PR #47 (phoenix_kit_billing): Add Ukrainian (uk) translations

**Author:** @timujinne (Tymofii Shapovalov) · **Branch:** `add-uk-locale` → `main` · head `10c0908` · up to date with `main` (`a350afb`), mergeable · **Files:** 3 (+3,262 / −2)

## Summary

Adds `priv/gettext/uk/LC_MESSAGES/default.po`, which covers every msgid of the hand-maintained `default.pot`:
675 entries, 13 of them plural. It also adds `uk` to `@locales` in `pot_drift_test.exs` and lists `uk` in the
AGENTS.md gettext note. `mix.exs` and `CHANGELOG.md` are untouched, which is correct here: AGENTS.md:490 says
version bumps and CHANGELOG entries land with the release commit.

## Overall verdict

**REQUEST CHANGES (small).** This is the cleanest of the three companion PRs: no placeholder or plural
defects, and the four financial emails render correctly in `uk`. Three things need fixing before merge:

1. The catalogue was not produced by `mix gettext.merge`. All 669 `#,` flags are missing, so the next merge
   rewrites 669 lines in someone else's diff.
2. Three wording errors on customer-facing surfaces: the invoice bank block, the customer's own «Мої
   платіжні профілі» page, and the receipt email.
3. The email translation tests, which already iterate `et`/`ru`, were not extended to `uk`.

## Verified

The checks below were run on all entries, not a sample, with a standalone `.po` parser (`python3 -I`). The
parser was self-tested against a deliberately broken file first.

- **Header.** `Language: uk`. The `Plural-Forms` header has three forms, evaluated for n = 0…10,000 against
  the Ukrainian rule.
- **Coverage.** 675/675 against `default.pot`. No extras, duplicates, obsolete entries, empty `msgstr` or
  `fuzzy`. All 13 plural entries have `msgstr[0..2]`, and every form carries `%{count}`.
- **Placeholders.** `%{…}` and `{{…}}` match, including the triple-brace `{{{line_items_table_html}}}`.
  Markdown `**`/links/`##`, the `\n` structure of the plain-text emails and edge whitespace also match.
- **Email runtime check.** The assertions of `email_defaults_test.exs` ("every part of every email is
  translated", "the preview's labels and descriptions are translated", "missing optional values are omitted
  in every translation") were re-run for `uk` through `mix run`. All passed: no untranslated part, identical
  placeholder sets, the line-items table paragraph intact, no optional variable left behind.
- **Glossary.** рахунок (invoice), квитанція (receipt), кредит-нота, повернення коштів, платіжний профіль,
  адреса для рахунку, банківський переказ, Білінг (module), ПДВ.
- **Tests.** `MIX_ENV=test PGDATABASE=pkbill_test_uk PGPOOL=10 mix test
  test/phoenix_kit_billing/pot_drift_test.exs` → 5 tests, 0 failures.

## Findings

### IMPROVEMENT — MEDIUM

#### Not the output of `mix gettext.merge`: all 669 flags are missing

The PR says the file was "created with `mix gettext.merge priv/gettext --locale uk --no-fuzzy`". However:

- `default.pot` and the `en`/`et`/`ru` catalogues each have 669 `#, elixir-autogen[, elixir-format]` lines.
  `uk/default.po` has 0.
- Re-running that exact merge on a copy reports "0 new, 0 removed, 675 unchanged".
- Its output differs from the committed file **only** by the 669 flag lines.

**Fix:** run the merge and commit the result. The translations do not change (verified).

#### Invoice bank block: "Account:" is the account *holder's name*, not «Рахунок»

`default.po:563` `Account:` → «Рахунок:». At `web/invoice_detail.html.heex:399` the value printed after it is
`bank_details["account_name"]`, i.e. the beneficiary (e.g. «Acme Corp OÜ»). The invoice therefore shows
«Рахунок: Acme Corp OÜ». Here «рахунок» reads as "invoice" or "bank account number", and the module already
uses «рахунок» for "invoice".

| msgid | current | proposed |
|---|---|---|
| Account: | Рахунок: | Отримувач: |

#### "Set Default" on the customer's billing profiles has the wrong gender

`default.pot` shares `Set Default` / `Set as Default` between currencies (feminine, «валюта») and billing
profiles (masculine, «профіль»): `web/user_billing_profiles.ex:209` is the customer's own «Мої платіжні
профілі» page. «Зробити типовою» is feminine, so the customer sees a grammatically wrong button next to every
non-default profile. It is also the only place that uses «типовою»; everywhere else this module says «за
замовчуванням» (`:1111`, `:2260`, `:2457`).

| line | msgid | current | proposed |
|---|---|---|---|
| 400 | Set Default | Зробити типовою | Встановити за замовчуванням |
| 405 | Set as Default | Зробити типовою | Встановити за замовчуванням |
| 2448 | …Use “Set as default” on it to renormalize. | …Натисніть для неї «Зробити типовою»… | …Натисніть для неї «Встановити за замовчуванням»… |
| 2444 | …setting a currency as default renormalizes… | …якщо зробити валюту типовою… | …якщо встановити валюту за замовчуванням… |

#### The receipt email reads the payment date as the invoice date

`default.po:2949`: «…Ми отримали {{paid_amount}} {{currency}} за рахунком {{invoice_number}} **від
{{payment_date}}**.» In Ukrainian business language «рахунок № … від <дата>» means "invoice No. … *dated*
<date>". A customer reading «за рахунком INV-0042 від 08.10.2026» takes the date as the invoice date, not the
day the money arrived.

| msgid | current | proposed |
|---|---|---|
| …We received {{paid_amount}} {{currency}} for invoice {{invoice_number}} on {{payment_date}}. | …Ми отримали {{paid_amount}} {{currency}} за рахунком {{invoice_number}} від {{payment_date}}. | …{{payment_date}} ми отримали {{paid_amount}} {{currency}} за рахунком {{invoice_number}}. |

#### The email translation tests do not cover `uk`

`test/phoenix_kit_billing/email_defaults_test.exs:168` (`for locale <- ~w(et ru)`, "every part of every
email is translated into #{locale}") and `:194` (preview labels) skip `uk`. So do `:285` and `:301`
(`["en", "et", "ru"]`, optional values omitted). Only `pot_drift_test.exs` was extended. The `uk` emails pass
these assertions today (re-run by hand, see above), but nothing keeps them passing. **Fix:** add `uk` to the
four lists.

### NITPICK

**Customer-facing wording**

| line | msgid | current | proposed |
|---|---|---|---|
| 3019, 2593 | VAT: {{company_vat}} / VAT: | ПДВ: … | Номер ПДВ: … («ПДВ: EE123…» reads as a tax amount; `:2585` already has «Номер ПДВ») |
| 2929, 3049 | Total paid (email) | Всього сплачено | Усього сплачено (`:455`, `:459` use «Усього»; «у» at the start before a consonant) |
| 3105 | REFUND DETAILS plain-text block | «Початковий рахунок: {{invoice_number}}» | the label is one character wider than the 19-column grid; use «Рахунок-оригінал:» or re-pad |

**Admin wording**

| line | msgid | current | proposed |
|---|---|---|---|
| 2616 | Void | Анулювати | The msgid is both the button (`invoice_detail.html.heex:88`) and a status filter option (`invoices.html.heex:84`), so the filter lists a verb among «Чернетка / Надіслано / Оплачено / Анулювати / Прострочено». Prefer «Анульовано» if one string must serve both, or ask upstream for a `pgettext` split. |
| 1429 | Inactive (subscription-type card badge) | Неактивна | Неактивний (тип підписки / тариф) |
| 575 | Active (also the subscription-type form checkbox, `subscription_type_form.html.heex:176`) | Активна | shared with subscription status (feminine is right there); a `pgettext` split upstream would allow «Активний» on the plan form |
| 709 vs 1915, 2461 | Billing Period | Розрахунковий період vs «платіжний період» elsewhere | one term, e.g. «розрахунковий період» |
| 1957 | Pricing | Ціноутворення ("price formation") | Ціни |
| 2768 | Customer billing — …not a per-project total. | …а не підсумок по проєкту. | …а не підсумок за проєктом. |
| 1417 | Import %{count} Currencies (button) | Імпортувати валют: %{count} | Імпортувати валюти (%{count}) |
| 340 | Paid Revenue | Оплачений дохід | Отриманий дохід |
| 1243 | Exchange Rate | Курс обміну | Обмінний курс (glossary: «курс») |
| 2037 | Record Payment | Записати оплату | Внести оплату |
| 1865 | Payment overdue — renewal will be retried automatically | …продовження буде повторено автоматично | …спробу продовження буде повторено автоматично |
| 1561 | Manually create a subscription for a customer (page subtitle) | Створіть підписку для клієнта вручну | Створення підписки для клієнта вручну (the sibling subtitles are noun phrases: `:975`, `:983`, `:987`) |
| 847 vs 1381; 1501 vs 1385; 2624 vs 913 | Client ID / "Get Client ID and Secret"; Key ID / "Get Key ID…"; Webhook ID / "Copy Webhook ID" | label «Ідентифікатор клієнта» but the instruction says «Client ID»; label «Webhook ID» but the button says «ID вебхука» | make each label match its instruction, e.g. «Ідентифікатор клієнта (Client ID)» |
| 2797–2821 | placeholders John / Doe / Acme Corp OÜ / Tallinn / Harju | left as is | optional: Іван / Петренко / ТОВ «Приклад» / Київ / Київська обл. (`ru` keeps them too; core localised its address example to «вул. Торгова, 123») |

**Docs:** `AGENTS.md:166` still says a new tab "renders in raw English under `ru`/`et`". Make it
`ru`/`et`/`uk`, like the line this PR edited at :97.

**Consistency with core and ecommerce:**
- Order status "Pending": here «В очікуванні» (`:346`), ecommerce «Очікує».
- "Street address": here «Адреса» (`:2306`), ecommerce checkout «Вулиця, будинок».
- "Email Address": here «Адреса електронної пошти» (`:1204`), core «Адреса email».
- "Company Information": here «Реквізити компанії» (`:871`), core «Інформація про компанію».
- Default/base currency: here «валюта за замовчуванням» / «базова»; ecommerce uses «основна валюта» for both.
- Client ID / Client Secret / Callback URL are translated here (`:847`, `:851`, `:746`) but left in English in
  core.

## Not flagged (checked)

The four email bodies (Markdown and plain text) read like real Ukrainian business correspondence: «Дякуємо,
що обрали нас», «Призначення: {{invoice_number}}» for the transfer reference, «Платник:» for "Bill To". The
interval plurals («за %{count} день/дні/днів», «Кожні %{count} тижні») and «Пробний період: %{count} днів»
are right, and so is the status vocabulary for orders, invoices and subscriptions.

---

## Round 2 (2026-10-09): head `eeb40b8`

**Verdict: REQUEST CHANGES (one line).** Everything from round 1 is closed except "Void". There the round-1
suggestion, which was mine, led to a regression: the invoice page's destructive *action* button now reads
like a *status*. The fix is to revert that one `msgstr`; an optional one-line code change below makes the
status filter right as well.

### Verified

- **Branch.** It is up to date with `main` (`a350afb`). The diff against `main` is the declared files plus
  `dev_docs/pull_requests/2026/47-add-ukrainian-translations/CLAUDE_REVIEW.md` (the round-1 review).
- **Literal `mix gettext.merge` output.** Re-running the merge on a copy reports "0 new, 0 removed, 675
  unchanged" and produces a byte-identical file.
- **Full checker re-run.** 675/675 entries, 0 errors. The language heuristics show no new hits.
- **Tests.** `MIX_ENV=test PGDATABASE=pkbill_test_uk PGPOOL=10 mix test
  test/phoenix_kit_billing/pot_drift_test.exs test/phoenix_kit_billing/email_defaults_test.exs` → 41 tests,
  0 failures. `uk` is now included at `:168`, `:194`, `:285` and `:301`.
- **Emails.** The receipt reads «Дякуємо за оплату. {{payment_date}} ми отримали … за рахунком
  {{invoice_number}}.» The payment confirmation and the plain-text balance use «Усього сплачено». The
  REFUND DETAILS block is re-padded to a common 21-column label width.

### Round-1 findings

| finding | status |
|---|---|
| IMPROVEMENT: `#,` flags stripped | **closed** |
| IMPROVEMENT: "Account:" on the invoice bank block | **closed:** «Отримувач:» |
| IMPROVEMENT: "Set Default" gender on billing profiles | **closed:** «Встановити за замовчуванням» for both msgids, and the two currency help texts quote it |
| IMPROVEMENT: receipt email date | **closed** |
| IMPROVEMENT: email tests skip `uk` | **closed** |
| NITPICK tables | **applied:** «Номер ПДВ:», «Усього», «Неактивний», «розрахунковий період» throughout, «Ціни», «за проєктом», «Імпортувати валюти (%{count})», «Отриманий дохід», «Обмінний курс», «Внести оплату», «спробу продовження», noun-phrase subtitle, localised placeholders (Іван / Петренко / ТОВ «Приклад» / Київ / Київська обл.), console terms consistently in English (Client ID, Key ID, Callback URL, Webhook ID), `AGENTS.md:166` |
| Consistency with core and ecommerce | **aligned:** "Pending" «Очікує», "Street address" «Вулиця, будинок», "Email Address" «Адреса email» |

**The executor's disagreements, assessed:**
- **Set Default, neutral:** this is what round 1 proposed. Agreed.
- **«Реквізити компанії» kept:** justified. The section is the company and bank details printed on invoices,
  which is exactly «реквізити»; core's general settings page keeps «Інформація про компанію».
- **"Active" «Активна» untouched:** justified. The msgid is shared, and most uses label subscriptions
  (feminine). Only the plan-form checkbox would want «Активний», and that needs a `pgettext` split upstream.

### IMPROVEMENT - MEDIUM: "Void" → «Анульовано» now labels the action button too

`default.po:3165`. `gettext("Void")` is both the destructive action button on the invoice page
(`web/invoice_detail.html.heex:88`, red outline, x-mark icon, confirm «Ви впевнені, що хочете анулювати
цей рахунок?») and a status filter option (`web/invoices.html.heex:84`). With «Анульовано», an admin
looking at a live invoice sees a red «Анульовано» next to «Надіслати рахунок» / «Друк», which reads as "this
invoice is void". On a financial document that is worse than a verb in a filter list. `ru` («Аннулировать»)
and `et` («Tühista arve») both translate the action.

**Fix:**
1. Revert: `Void` → «Анулювати».
2. Optional, one line, recommended: in `web/invoices.html.heex:84` use the existing `gettext("Voided")`
   (`default.pot:3169`, already translated: ru «Аннулирован», et «Tühistatud», uk «Анульовано»), then
   re-run `mix gettext.extract --merge`. Every locale gets a correct status filter, with no new msgid to
   translate.

### NITPICK: the dashboard stat "Pending" now reads «Очікує» above an amount

`web/index.html.heex:64` shows `gettext("Pending")` over the pending revenue figure. «Очікує» reads
acceptably there, and the msgid is shared with the order status, where «Очікує» is right. Leave it.

---

## Round 3 (2026-10-09): head `e223398`

**Verdict: APPROVE.** The round-2 "Void" regression is fixed the way round 2 proposed, including the
optional code line, and the status filter now renders correctly in every locale.

- **`cde932b`.** `web/invoices.html.heex:84` uses `gettext("Voided")`; `uk` "Void" → «Анулювати» again
  (`default.po:3164`). The `#:` reference for `invoices.html.heex:84` moved from "Void" to "Voided" in
  `default.pot` and in `en`/`et`/`ru`/`uk` (two lines each, nothing else).
- **The hand edit matches what extraction produces.** `mix gettext.extract` was run on scratch copies of
  both the PR tree and `main` (`a350afb`), with a separate build path. The two diffs against the committed
  `.pot` are identical, so the PR adds no drift and the moved reference is exactly what extraction writes.
  (Extraction against `main` itself shows 756 lines of older drift: stale line numbers and hand-kept
  entries. That predates this PR and is out of scope.) `mix gettext.merge` on a copy reports 675 unchanged
  for all four locales, each byte-identical.
- **Rendered.** The `PhoenixKitBilling.Web.Invoices` template was rendered with a seeded invoice, from a
  temporary test file outside the repo (the test router mirrors only `/en`, so the locale was set in
  process). The status `<select>` reads:
  - uk: «Усі статуси / Чернетка / Надіслано / Оплачено / Анульовано / Прострочено»
  - ru: «… / Аннулирован / …»
  - et: «… / Tühistatud / …»
  - en: «… / Voided / …»

  The invoice-page action stays «Анулювати» / «Аннулировать» / «Tühista arve» / «Void».
- **Tests:** `MIX_ENV=test PGDATABASE=pkbill_test_uk PGPOOL=10 mix test
  test/phoenix_kit_billing/pot_drift_test.exs test/phoenix_kit_billing/email_defaults_test.exs` → 41
  tests, 0 failures. Checker: 675/675, 0 errors.
- **Diff against `main`:** the declared files, this one-line template change, and the review file
  (byte-identical to rounds 1–2). GitHub reports `MERGEABLE`.
