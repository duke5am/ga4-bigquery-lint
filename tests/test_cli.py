"""Tests for the `ga4-bigquery-lint` CLI.

Run from the repo root:

    python3 -m unittest discover -s tests -v

Every test drives the CLI as a subprocess from a scratch working directory, so
the machine-readable report the tool writes lands in the scratch directory and
never in the repo or in the installed package.

The bad-input cases (missing path, empty directory, a directory with no .sql in
it, a file that is not UTF-8, SQL with real defects) must each exit non-zero
with a clear message and must NOT print a Python traceback.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERIFY = os.path.join(REPO, "verify_pack.py")

if REPO not in sys.path:
    sys.path.insert(0, REPO)

from ga4_bigquery_lint import cli  # noqa: E402

GOOD_SQL = """-- QUESTION IT ANSWERS: how many sessions in the window
-- WHAT IT RETURNS: one row per day
-- COST: scans one month of events_*; filter on _TABLE_SUFFIX is required
select
  _table_suffix as day,
  count(distinct concat(user_pseudo_id, cast(
    (select value.int_value from unnest(event_params) where key = 'ga_session_id') as string
  ))) as sessions
from `myproject.analytics_123.events_*`
where _table_suffix between '20260101' and '20260131'
group by day
"""

# The classic silent-zeroes mistake: ga_session_id is an integer parameter, so
# reading it from value.string_value returns NULL for every row.
WRONG_FIELD_SQL = """-- QUESTION IT ANSWERS: sessions
-- WHAT IT RETURNS: one row
-- COST: one month
select
  (select value.string_value from unnest(event_params) where key = 'ga_session_id') as sid
from `myproject.analytics_123.events_*`
where _table_suffix between '20260101' and '20260131'
"""

BAD_SQL = """select *
from `myproject.analytics_123.events_*`
"""

# Reads the export with no partition filter at all: the classic unbounded scan.
NO_FILTER_SQL = """-- QUESTION IT ANSWERS: how many raw rows are there
-- WHAT IT RETURNS: one row
-- COST: this scans the whole export
select count(*) as n
from `myproject.analytics_123.events_*`
"""


class CliTestCase(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.mkdtemp(dir="/root", prefix="ga4lint-test-")

    def tearDown(self):
        shutil.rmtree(self.scratch, ignore_errors=True)

    def write(self, name, text, encoding="utf-8"):
        path = os.path.join(self.scratch, name)
        with open(path, "w", encoding=encoding) as fh:
            fh.write(text)
        return path

    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, VERIFY, *args],
            cwd=self.scratch, capture_output=True, text=True, timeout=300,
        )

    def assert_no_traceback(self, proc):
        self.assertNotIn("Traceback", proc.stdout + proc.stderr,
                         "the CLI printed a Python traceback:\n"
                         + proc.stdout + proc.stderr)


class TestBundledPositiveCase(CliTestCase):
    """No argument must lint the SQL that ships inside the package."""

    def test_default_run_lints_the_bundled_pack_cleanly(self):
        proc = self.run_cli()
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("sql files found    : 11", proc.stdout)
        self.assertIn("errors             : 0", proc.stdout)
        self.assertIn("warnings           : 0", proc.stdout)

    def test_bundled_queries_are_reachable_as_package_data(self):
        queries = cli.bundled_queries_dir()
        self.assertTrue(os.path.isdir(queries), queries)
        sql = sorted(f for f in os.listdir(queries) if f.endswith(".sql"))
        self.assertEqual(len(sql), 11, sql)
        self.assertIn("00-PARAM-PATTERNS.sql", sql)

    def test_report_is_written_to_the_current_directory(self):
        proc = self.run_cli()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        report_path = os.path.join(self.scratch, "verification-report.json")
        self.assertTrue(os.path.exists(report_path),
                        "the report was not written to the working directory")
        with open(report_path, encoding="utf-8") as fh:
            report = json.load(fh)
        self.assertEqual(report["total_errors"], 0)
        self.assertEqual(len(report["files"]), 11)
        self.assertFalse(report["executed_against_bigquery"])


class TestSingleFileArgument(CliTestCase):
    """`verify_pack.py my-query.sql` is documented in the README.

    It used to be a silent no-op: the argument was walked with os.walk, which
    yields nothing for a plain file, so the tool reported "sql files found: 0"
    and exited 0 while checking nothing at all.
    """

    def test_a_single_good_file_is_linted(self):
        path = self.write("one.sql", GOOD_SQL)
        proc = self.run_cli(path)
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("sql files found    : 1", proc.stdout)
        self.assertIn("files checked      : 1 .sql", proc.stdout)
        self.assertIn("statements parsed  : 1 / 1", proc.stdout)

    def test_a_single_bad_file_is_reported_not_ignored(self):
        path = self.write("bad.sql", BAD_SQL)
        proc = self.run_cli(path)
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("SELECT *", proc.stdout)
        self.assertIn("_TABLE_SUFFIX", proc.stdout)

    def test_lower_case_table_suffix_counts_as_the_filter(self):
        # BigQuery identifiers are case-insensitive. `_table_suffix` used to be
        # reported as "no _TABLE_SUFFIX filter -- unbounded scan", which is a
        # false positive on a query that does filter on it.
        path = self.write("lower.sql", GOOD_SQL)
        proc = self.run_cli(path)
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertNotIn("unbounded scan", proc.stdout)

    def test_a_query_with_no_suffix_filter_at_all_is_still_an_error(self):
        path = self.write("no-filter.sql", NO_FILTER_SQL)
        proc = self.run_cli(path)
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("unbounded scan", proc.stdout)

    def test_a_wrong_event_params_value_field_is_an_error(self):
        # This is the check the tool exists for: it parses fine, it runs fine,
        # and it returns NULL for every row.
        path = self.write("wrong-field.sql", WRONG_FIELD_SQL)
        proc = self.run_cli(path)
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("ga_session_id", proc.stdout)
        self.assertIn("int_value", proc.stdout)
        self.assertIn("NULL for every row", proc.stdout)


class TestBadInput(CliTestCase):
    def test_missing_path(self):
        proc = self.run_cli(os.path.join(self.scratch, "nope.sql"))
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertIn("no such file or directory", proc.stderr)

    def test_empty_directory(self):
        empty = os.path.join(self.scratch, "empty")
        os.makedirs(empty)
        proc = self.run_cli(empty)
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertIn("no .sql files found", proc.stderr)

    def test_directory_without_any_sql(self):
        docs = os.path.join(self.scratch, "docs")
        os.makedirs(docs)
        with open(os.path.join(docs, "notes.md"), "w", encoding="utf-8") as fh:
            fh.write("# nothing to lint here\n")
        proc = self.run_cli(docs)
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertIn("no .sql files found", proc.stderr)

    def test_file_that_is_not_utf8_text(self):
        path = os.path.join(self.scratch, "binary.sql")
        with open(path, "wb") as fh:
            fh.write(b"select 1;\n\xff\xfe\x00garbage")
        proc = self.run_cli(path)
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("could not read this file", proc.stdout)

    def test_unreadable_file_does_not_lose_the_other_files(self):
        # One bad file in a directory must not abort the whole report.
        self.write("good.sql", GOOD_SQL)
        path = os.path.join(self.scratch, "binary.sql")
        with open(path, "wb") as fh:
            fh.write(b"\xff\xfe\x00garbage")
        proc = self.run_cli(self.scratch)
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertIn("files checked      : 2 .sql", proc.stdout)
        self.assertIn("could not read this file", proc.stdout)

    def test_unreadable_report_path_is_reported_not_crashed(self):
        proc = self.run_cli("--report", os.path.join(self.scratch, "no", "such", "dir", "r.json"))
        self.assert_no_traceback(proc)
        self.assertEqual(proc.returncode, 3, proc.stdout + proc.stderr)
        self.assertIn("error:", proc.stderr)


class TestHelpers(CliTestCase):
    def test_collect_sql_files_on_a_file_returns_that_file(self):
        path = self.write("one.sql", GOOD_SQL)
        found = cli.collect_sql_files(path)
        self.assertEqual(found, [(path, "one.sql")])

    def test_collect_sql_files_on_a_tree_finds_only_sql(self):
        self.write("a.sql", GOOD_SQL)
        self.write("b.txt", "not sql")
        nested = os.path.join(self.scratch, "sub")
        os.makedirs(nested)
        with open(os.path.join(nested, "c.sql"), "w", encoding="utf-8") as fh:
            fh.write(GOOD_SQL)
        found = cli.collect_sql_files(self.scratch)
        self.assertEqual([rel for _, rel in found], ["a.sql", os.path.join("sub", "c.sql")])

    def test_default_target_is_the_directory_holding_the_queries(self):
        self.assertEqual(cli.bundled_content_dir(),
                         os.path.dirname(cli.bundled_queries_dir()))

    def test_package_exposes_main(self):
        self.assertTrue(callable(cli.main))


if __name__ == "__main__":
    unittest.main()
