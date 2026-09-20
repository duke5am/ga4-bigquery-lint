"""Lint GA4 BigQuery SQL without a GCP account.

A real sqlglot `bigquery` grammar parse of every statement, plus the structural
checks that catch SQL which parses cleanly but returns wrong numbers or scans
every partition:

  * no `SELECT *`
  * `_TABLE_SUFFIX` filter on every `events_*` read
  * exactly one `event_params` value field per key, matching the type GA4 writes
  * no mixed-type `COALESCE`, no unsafe numeric `CAST` of `string_value`
  * `TIMESTAMP_MICROS` for `event_timestamp`
  * documented-but-absent field paths rejected

The eleven bundled queries ship inside this package as package data, so the
default `ga4-bigquery-lint` run lints the same SQL from an installed wheel as it
does from a checkout.
"""
