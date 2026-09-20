# ga4-bigquery-lint

[![PyPI](https://img.shields.io/pypi/v/ga4-bigquery-lint)](https://pypi.org/project/ga4-bigquery-lint/)

Lint GA4 BigQuery SQL for the mistakes that make queries **fail, double-count or
silently disagree with the GA4 UI** — without a GCP account. Uses a real BigQuery
grammar, not a regex.

```bash
pip install ga4-bigquery-lint     # from PyPI, Python 3.9+
ga4-bigquery-lint                 # lint the SQL that ships with it
ga4-bigquery-lint my-query.sql    # lint your own file
ga4-bigquery-lint ./my-sql-dir    # or a whole directory of .sql files
```

The eleven bundled queries ship **inside the package**, so the installed tool
lints them with no checkout and no extra download.

Or from a clone — the same code either way:

```bash
git clone https://github.com/duke5am/ga4-bigquery-lint
cd ga4-bigquery-lint
python3 verify_pack.py              # lint the bundled queries
python3 verify_pack.py my-query.sql # lint your own
python3 verify_pack.py .            # also grammar-checks the SQL in the docs
```

```
files checked      : 11 .sql
statements parsed  : 16 / 16
md sql blocks      : 0 complete parsed, 0 fragments skipped, 0 failed
errors             : 0
warnings           : 0
```

Exit codes: `0` no errors · `1` at least one error found · `2` nothing to check
(a missing path, or a directory with no `.sql` in it) · `3` internal failure.

The machine-readable report is written to `verification-report.json` in the
current directory.

## Why GA4 SQL goes wrong

GA4's BigQuery export is an **event log, not a report**. Sessions do not exist in
it — you have to derive them. Almost every discrepancy between your SQL and the
GA4 UI traces back to one of these:

- **`event_params` is a repeated record.** Read it wrong and you drop integer
  values, or a naive join multiplies rows.
- **`event_timestamp` is microseconds**, not seconds. Off by 1000×.
- **Sessions split across daily tables.** A session that crosses midnight is
  stored in two `events_YYYYMMDD` tables, so a per-day query silently breaks it.
- **`user_pseudo_id` is per-device, not per-person.** Cross-device identity is lost.
- **A missing `_TABLE_SUFFIX` filter scans every partition** — and you pay for it.
- **`ga_session_id` is only unique within a user.** Combining it without
  `user_pseudo_id` merges unrelated sessions.

`SCHEMA-TRAPS.md` covers these with the symptom the analyst actually sees and the
fix, including one field path that is documented in some places but does not
exist in the export.

## What the linter checks

| Check | |
|---|---|
| Real grammar | every statement parsed with **sqlglot's `bigquery` dialect** |
| Cost safety | no `SELECT *`, `_TABLE_SUFFIX` present on every `events_*` read |
| `event_params` | exactly one value field per key, no mixed-type `COALESCE` |
| Types | GA4's built-in parameter value types respected; no unsafe numeric `CAST` of `string_value` |
| Timestamps | `TIMESTAMP_MICROS`, not `TIMESTAMP_SECONDS`, for `event_timestamp` |
| Known-wrong paths | documented-but-absent field paths rejected (e.g. `manual_campaign.name`, and dotted paths through `collected_traffic_source.manual_campaign`) |
| Contract | header comment present on every query |

**What it does NOT check**, stated by the tool itself: execution, column existence
in *your* dataset (only your `INFORMATION_SCHEMA` can show that), numerical
correctness, bytes scanned, or cost.

## The bundled queries

Eleven files answering one question each — sessionisation, sessions per user,
engaged sessions, landing page per session, conversions by channel, a funnel,
retention by first-touch, channel grouping, events-per-session, midnight-crossing
sessions, and the reusable `event_params` extraction patterns.

They are written against the documented GA4 export schema and **have not been run
against BigQuery** — no account was available. The linter proves they parse and
respect the schema; you must validate against your own property.

## The full pack

The paid pack adds `SESSIONISATION.md` (the 30-minute rule, session-key
construction, reconciling against the UI), `COST-CONTROL.md`, `VALIDATION.md` (how
to prove a query is right before trusting it), the materialised session-table
setup, and a schema audit that checks **244 documented field paths**.

<!-- RELATED:START -->

## Related tools

- **[bank-csv-reconcile](https://github.com/duke5am/bank-csv-reconcile)** — Turn a bank CSV or Excel export into one clean table and reconcile the running balance, so a dropped row shows up instead of silently changing totals.
  *(if you were searching for "bank statement csv to excel")*
- **[cur-athena-lint](https://github.com/duke5am/cur-athena-lint)** — Lint AWS Cost and Usage Report Athena SQL for partition pruning and column mistakes, with the schema reference and a FinOps playbook.
  *(if you were searching for "aws cur athena query")*

All 28 tools in this set, grouped by what they check: **[dev-tools-index](https://duke5am.github.io/dev-tools-index/)**

If you arrived here searching for one of these, this is the tool: **ga4 bigquery queries** · **sessionisation 30 minute rule** · **ga4 event_params unnest** · **bigquery cost control query**

<!-- RELATED:END -->

→ **[GA4 BigQuery Session & Funnel SQL Pack](https://duke5am.gumroad.com/l/23-ga4-bigquery-sql)** — $39 on Gumroad <!-- GUMROAD-LINK -->
