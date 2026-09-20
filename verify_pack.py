#!/usr/bin/env python3
"""
verify_pack.py -- lint GA4 BigQuery SQL from a clone.

This wrapper exists so `python3 verify_pack.py` and
`python3 verify_pack.py my-query.sql` keep working exactly as documented. The
same CLI is installed as the `ga4-bigquery-lint` console script; the
implementation lives in `ga4_bigquery_lint/cli.py` so that the installed package
and the checkout are the same code, not two versions of it.

Usage:  python3 verify_pack.py [PATH]     # a .sql file, or a directory of them
        python3 verify_pack.py            # the queries bundled in this repo
Exit codes: 0 no errors, 1 at least one error, 2 nothing to check, 3 internal failure.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ga4_bigquery_lint.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
