#!/usr/bin/env python3
"""
verify_pack.py -- structural + parser verification for the
GA4 BigQuery Session & Funnel SQL Pack.

WHAT THIS DOES
  1. GRAMMAR CHECK. Parses every executable statement in every .sql file with
     sqlglot's `bigquery` dialect (a real BigQuery grammar, not a regex).
     Unbalanced parentheses, malformed CTEs, misplaced UNNEST and mistyped
     function calls all fail here. Statements are split on top-level
     semicolons and reported with their statement index.
  2. STRUCTURAL CHECKS (the ones requested for this pack):
       - balanced parentheses, computed outside comments and string literals
       - no `SELECT *` anywhere (cost and column-width discipline)
       - every statement that reads an events_* table filters on _TABLE_SUFFIX
       - no TABLESAMPLE (would make results non-reproducible)
       - COST MODEL: exactly one value field is read per event_params key, and
         for the GA4 built-in keys the field matches the type GA4 writes
         (ga_session_id -> int_value, page_location -> string_value, ...).
         An extraction that reads the wrong field returns NULL for every row
         and silently yields zeroes; this check is the point of the script.
       - no mixed-type COALESCE across value.string_value and value.int_value
       - no bare CAST(... AS INT64) of a string_value (must be SAFE_CAST)
       - event_timestamp is only converted with TIMESTAMP_MICROS

WHAT THIS DOES NOT DO -- READ THIS BEFORE TRUSTING IT
  - It does NOT execute anything against BigQuery, and neither did the author
    of the pack. No GCP account was available. Nothing in this pack has ever
    been run against a real property.
  - It does NOT verify that column names exist in your export. Only a live
    dataset can do that. Column names were taken from the documented GA4
    BigQuery export schema.
  - It does NOT verify that the numbers are meaningful, or correct, or cheap.
    Only your own property and a dry run can tell you that. See
    docs/VALIDATION.md and docs/COST-CONTROL.md.

Usage:  python3 verify_pack.py [content_dir]
Exit code 0 = no errors, 1 = at least one error.
"""

import json
import os
import re
import sys

CONTENT_DIR = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))

try:
    import sqlglot
    from sqlglot import exp
    HAVE_SQLGLOT = True
    SQLGLOT_VERSION = getattr(sqlglot, "__version__", "unknown")
    SQLGLOT_IMPORT_ERROR = ""
except Exception as _exc:                                   # pragma: no cover
    HAVE_SQLGLOT = False
    SQLGLOT_VERSION = "NOT INSTALLED"
    SQLGLOT_IMPORT_ERROR = repr(_exc)


# ---------------------------------------------------------------------------
# Masking: remove COMMENTS, keep string literals
# ---------------------------------------------------------------------------
def mask_comments(text: str):
    """
    Replace comment characters with spaces (preserving newlines and therefore
    line numbers). String literals and backticked identifiers are preserved
    intact, because:
      - the parameter-key checks need the literal contents ('ga_session_id');
      - sqlglot needs a syntactically valid statement.
    A comment delimiter *inside* a string literal is neutralised by replacing
    only the marker characters, so the literal stays a valid single-line
    string and the rest of the file still parses.
    """
    out = []
    errors = []
    i, n = 0, len(text)
    state = "code"
    balance = 0
    line = 1
    stmt_open_line = 1

    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        if c == "\n":
            line += 1

        if state == "code":
            if c == "-" and nxt == "-":
                state = "line_comment"
                out.append("  ")
                i += 2
                continue
            if c == "/" and nxt == "*":
                state = "block_comment"
                out.append("  ")
                i += 2
                continue
            if c == "'":
                state = "sq"
                out.append(c)
                i += 1
                continue
            if c == '"':
                state = "dq"
                out.append(c)
                i += 1
                continue
            if c == "`":
                state = "bt"
                out.append(c)
                i += 1
                continue
            if c == "(":
                if balance == 0:
                    stmt_open_line = line
                balance += 1
            elif c == ")":
                balance -= 1
                if balance < 0:
                    errors.append(
                        "line %d: more ')' than '(' -- unbalanced parentheses" % line
                    )
                    balance = 0
            out.append(c)
            i += 1
            continue

        if state == "line_comment":
            out.append("\n" if c == "\n" else " ")
            if c == "\n":
                state = "code"
            i += 1
            continue

        if state == "block_comment":
            out.append("\n" if c == "\n" else " ")
            if c == "*" and nxt == "/":
                state = "code"
                out.append(" ")
                i += 2
                continue
            i += 1
            continue

        if state == "sq":
            # Doubled '' is an escaped quote inside a single-quoted literal.
            if c == "'" and nxt == "'":
                out.append("  ")
                i += 2
                continue
            if c == "'":
                state = "code"
                out.append(c)
                i += 1
                continue
            # Neutralise comment markers INSIDE the literal so that the masked
            # text cannot start a comment mid-literal.
            if (c == "-" and nxt == "-") or (c == "/" and nxt == "*"):
                out.append("#")
                out.append("#")
                i += 2
                continue
            out.append("\n" if c == "\n" else c)
            i += 1
            continue

        if state == "dq":
            if c == '"' and nxt == '"':
                out.append("  ")
                i += 2
                continue
            if c == '"':
                state = "code"
                out.append(c)
                i += 1
                continue
            out.append("\n" if c == "\n" else c)
            i += 1
            continue

        if state == "bt":
            if c == "`":
                state = "code"
            out.append("\n" if c == "\n" else c)
            i += 1
            continue

    if balance != 0:
        errors.append(
            "file ends with %d unclosed '(' (last opened near line %d)" % (balance, stmt_open_line)
        )
    if state in ("sq", "dq", "block_comment", "bt"):
        errors.append("file ends inside an unterminated %s at line %d" % (state, line))

    return "".join(out), errors


def split_statements(masked: str):
    """Split on top-level semicolons (paren depth 0). Returns (text, line_no)."""
    stmts = []
    depth = 0
    cur = []
    start_line = 1
    line = 1
    started = False
    for ch in masked:
        if ch == "\n":
            line += 1
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == ";" and depth == 0:
            text = "".join(cur)
            if text.strip():
                stmts.append((text, start_line))
            cur = []
            started = False
            continue
        if not started and not ch.isspace():
            start_line = line
            started = True
        cur.append(ch)
    tail = "".join(cur)
    if tail.strip():
        stmts.append((tail, start_line))
    return stmts


# ---------------------------------------------------------------------------
# GA4 parameter value-type knowledge
# ---------------------------------------------------------------------------
# Taken from the documented GA4 BigQuery export schema. A wrong field here is
# a silent-zeroes bug, which is why it is an ERROR and not a warning.
EXPECTED_VALUE_FIELD = {
    "ga_session_id": "int_value",
    "ga_session_number": "int_value",
    "engagement_time_msec": "int_value",
    "entrances": "int_value",
    "percent_scrolled": "int_value",
    "page_location": "string_value",
    "page_referrer": "string_value",
    "page_title": "string_value",
    "source": "string_value",
    "medium": "string_value",
    "campaign": "string_value",
    "term": "string_value",
    "content": "string_value",
    "session_engaged": "string_value",
}

EVENTS_TABLE_RE = re.compile(r"events_\*")
SUFFIX_RE = re.compile(r"_TABLE_SUFFIX")
SELECT_STAR_RE = re.compile(r"\bSELECT\s+(?:DISTINCT\s+)?\*", re.IGNORECASE)

# A parameter key may legitimately be read from several value fields ONLY in
# the "unknown type" pattern, and only when every non-string read is wrapped in
# SAFE_CAST (so one bad value cannot fail the query). This set lists the keys
# for which that pattern is used deliberately in this pack.
KNOWN_UNKNOWN_TYPE_KEYS = {"my_custom_param"}

EXTRACT_WITH_ALIAS_RE = re.compile(
    r"value\s*\.\s*(string_value|int_value|double_value|float_value)\s*"
    r"FROM\s+UNNEST\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*event_params\s*\)\s*"
    r"WHERE\s+key\s*=\s*'([^']*)'",
    re.IGNORECASE,
)
EXTRACT_BARE_RE = re.compile(
    r"value\s*\.\s*(string_value|int_value|double_value|float_value)\s*"
    r"FROM\s+UNNEST\s*\(\s*event_params\s*\)\s*"
    r"WHERE\s+key\s*=\s*'([^']*)'",
    re.IGNORECASE,
)
MIXED_COALESCE_RE = re.compile(
    r"COALESCE\s*\([^()]*value\s*\.\s*(string_value|double_value)[^()]*"
    r"value\s*\.\s*(int_value)[^()]*\)",
    re.IGNORECASE | re.DOTALL,
)
BAD_CAST_RE = re.compile(
    r"(?<!SAFE_)\bCAST\s*\(\s*[^()]*string_value[^()]*\bAS\s+(?:INT64|FLOAT64|NUMERIC|BIGNUMERIC)\b",
    re.IGNORECASE,
)
TIMESTAMP_SECONDS_BUG_RE = re.compile(
    r"TIMESTAMP_SECONDS\s*\(\s*[A-Za-z_][A-Za-z0-9_]*\s*\.\s*event_timestamp\s*\)",
    re.IGNORECASE,
)

# Documented-but-wrong field paths. These are the shapes a plausible-looking
# query gets wrong, and they fail at runtime (or silently return NULL) rather
# than at parse time, so a grammar check cannot catch them.
#
#   session_traffic_source_last_click.manual_campaign.<x>
#       -> the campaign NAME field is `campaign_name`, NOT `name`.
#   collected_traffic_source.<x>
#       -> this record is FLAT: manual_campaign_name / manual_source /
#          manual_medium, with underscores. There is no nested manual_campaign
#          record inside collected_traffic_source.
BANNED_PATH_RES = [
    (re.compile(r"manual_campaign\s*\.\s*name\b", re.IGNORECASE),
     "manual_campaign.name does not exist -- the documented field is "
     "manual_campaign.campaign_name"),
    (re.compile(r"collected_traffic_source\s*\.\s*manual_campaign\s*\.",
                re.IGNORECASE),
     "collected_traffic_source has no nested manual_campaign record -- it is "
     "FLAT: use collected_traffic_source.manual_campaign_name / "
     ".manual_source / .manual_medium"),
]
# `alias.*` where alias was never defined in the same statement. Recognises
# both CTE definitions (`name AS (`) and inline subquery aliases
# (`FROM ( ... ) AS name` / `) AS name`), because both are internally built
# result sets rather than a raw table.
CTE_NAME_RE = re.compile(
    r"(?:\bWITH\b|,)\s*([A-Za-z_][A-Za-z0-9_]*)\s+AS\s*\(", re.IGNORECASE
)
SUBQUERY_ALIAS_RE = re.compile(
    r"\)\s*AS\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:,|$|\)|\n)", re.IGNORECASE | re.MULTILINE
)


def analyse_statement(stmt_text, stmt_index, stmt_line, all_cte_names):
    errors, warnings, notes = [], [], []

    # ---- SELECT * is banned outright ------------------------------------
    if SELECT_STAR_RE.search(stmt_text):
        errors.append(
            "statement %d: `SELECT *` present -- banned in this pack "
            "(cost and column-width discipline)" % stmt_index
        )

    # ---- _TABLE_SUFFIX on every events_* reader -------------------------
    reads_events = bool(EVENTS_TABLE_RE.search(stmt_text))
    if reads_events and not SUFFIX_RE.search(stmt_text):
        errors.append(
            "statement %d: reads events_* with no _TABLE_SUFFIX filter -- "
            "unbounded scan across every daily table" % stmt_index
        )
    if reads_events and re.search(r"\bTABLESAMPLE\b", stmt_text, re.IGNORECASE):
        errors.append(
            "statement %d: TABLESAMPLE on the export -- results would not be "
            "reproducible" % stmt_index
        )

    # ---- wide struct projections ----------------------------------------
    # A wide projection is only dangerous when the alias resolves to a RAW GA4
    # table. `s.*` where `s` is a CTE defined in the same statement is fine --
    # that is how these queries pass a session row bundle between CTEs without
    # listing 30 columns four times. When sqlglot is available this is decided
    # from the parse tree rather than by regex; the regex below is the fallback.
    star_aliases = []
    if HAVE_SQLGLOT:
        try:
            tree = sqlglot.parse_one(stmt_text, read="bigquery")
            # Aliases that resolve to something built inside this statement:
            # the CTE name itself AND the alias a CTE is referenced under
            # (`FROM session_agg AS s` makes `s` internal too).
            cte_names_ast = {c.alias_or_name.lower() for c in tree.find_all(exp.CTE)}
            internal_aliases = set(cte_names_ast)
            raw_aliases = set()
            for tbl in tree.find_all(exp.Table):
                name = (tbl.name or "").lower()
                alias = (tbl.alias_or_name or "").lower()
                if name in cte_names_ast:
                    internal_aliases.add(alias)      # CTE read via an alias
                elif re.match(r"^events_", name) or name.endswith("events_*"):
                    raw_aliases.add(alias)           # the raw GA4 export
                else:
                    # A physical table you built yourself (ga4_sessions, a
                    # first_seen table, a materialised view). Wide projections
                    # of those are fine and are the whole point of building
                    # them -- the ban is on wide projections of the raw export.
                    internal_aliases.add(alias)
            for col in tree.find_all(exp.Column):
                if isinstance(col.this, exp.Star) and col.table:
                    a = col.table.lower()
                    star_aliases.append((col.table, a in internal_aliases,
                                         a in raw_aliases))
        except Exception as exc:
            # Never fail silently: a crash here would silently downgrade this
            # check to the weaker regex path, which is exactly the kind of
            # quiet degradation this script exists to catch.
            warnings.append(
                "statement %d: AST inspection of wide projections failed (%s) "
                "-- fell back to regex matching" % (stmt_index, repr(exc))
            )
            star_aliases = []
    if not star_aliases:
        for m in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*\*", stmt_text):
            star_aliases.append((m.group(1), m.group(1).lower() in all_cte_names, False))

    for alias, is_cte, is_raw in star_aliases:
        if is_raw:
            errors.append(
                "statement %d: wide projection `%s.*` on a RAW events table -- "
                "use an explicit column list" % (stmt_index, alias)
            )
        elif not is_cte:
            warnings.append(
                "statement %d: wide projection `%s.*` where `%s` is not a CTE "
                "or subquery alias in this statement -- confirm the source"
                % (stmt_index, alias, alias)
            )

    # ---- event_params extraction type consistency ------------------------
    findings = [(m.group(1).lower(), m.group(3))
                for m in EXTRACT_WITH_ALIAS_RE.finditer(stmt_text)]
    findings += [(m.group(1).lower(), m.group(2))
                 for m in EXTRACT_BARE_RE.finditer(stmt_text)]

    per_key = {}
    for field, key in findings:
        per_key.setdefault(key, set()).add(field)

    for key, fields in sorted(per_key.items()):
        if len(fields) > 1:
            # The one legitimate multi-field case is the "unknown parameter
            # type" union, and it is only legitimate if the numeric branches
            # are SAFE_CAST (so a non-numeric string cannot fail the query).
            if key in KNOWN_UNKNOWN_TYPE_KEYS and "string_value" in fields:
                unsafe = re.findall(
                    r"(?<!SAFE_)\bCAST\s*\(\s*value\s*\.\s*(?:int_value|double_value)",
                    stmt_text,
                    re.IGNORECASE,
                )
                if unsafe:
                    errors.append(
                        "statement %d: unknown-type parameter '%s' reads a "
                        "numeric field with a bare CAST -- use SAFE_CAST"
                        % (stmt_index, key)
                    )
                else:
                    notes.append(
                        "%s -> string_value + SAFE_CAST(numeric) (unknown-type "
                        "pattern, type-safe)" % key
                    )
            else:
                errors.append(
                    "statement %d: parameter '%s' is read from more than one "
                    "value field %s -- exactly one field must be chosen"
                    % (stmt_index, key, sorted(fields))
                )
        expected = EXPECTED_VALUE_FIELD.get(key)
        if expected and expected not in fields:
            errors.append(
                "statement %d: parameter '%s' read from %s but the GA4 export "
                "writes it as %s -- this returns NULL for every row"
                % (stmt_index, key, sorted(fields), expected)
            )
        elif expected:
            notes.append("%s -> %s" % (key, expected))

    # ---- mixed-type COALESCE --------------------------------------------
    for m in MIXED_COALESCE_RE.finditer(stmt_text):
        warnings.append(
            "statement %d: COALESCE spanning value.%s and value.int_value -- "
            "confirm a SAFE_CAST keeps the types compatible"
            % (stmt_index, m.group(1).lower())
        )

    # ---- documented-but-wrong field paths --------------------------------
    for pattern, message in BANNED_PATH_RES:
        if pattern.search(stmt_text):
            errors.append("statement %d: %s" % (stmt_index, message))

    # ---- unsafe casts ----------------------------------------------------
    if BAD_CAST_RE.search(stmt_text):
        warnings.append(
            "statement %d: bare CAST of string_value to a numeric type -- one "
            "unparseable value fails the whole query; prefer SAFE_CAST"
            % stmt_index
        )

    # ---- event_timestamp unit discipline ---------------------------------
    if "event_timestamp" in stmt_text:
        if TIMESTAMP_SECONDS_BUG_RE.search(stmt_text):
            errors.append(
                "statement %d: TIMESTAMP_SECONDS applied directly to "
                "event_timestamp -- event_timestamp is MICROSECONDS, use "
                "TIMESTAMP_MICROS" % stmt_index
            )
        elif "TIMESTAMP_MICROS" not in stmt_text and not re.search(
            r"event_timestamp_micros", stmt_text
        ):
            warnings.append(
                "statement %d: selects event_timestamp but never converts it "
                "with TIMESTAMP_MICROS -- it is returned in raw microseconds"
                % stmt_index
            )

    return errors, warnings, notes, findings


def check_file(path, relpath):
    with open(path, "r", encoding="utf-8") as fh:
        raw = fh.read()

    masked, mask_errors = mask_comments(raw)
    stmts = split_statements(masked)

    cte_names = {m.group(1).lower() for m in CTE_NAME_RE.finditer(masked)}
    cte_names |= {m.group(1).lower() for m in SUBQUERY_ALIAS_RE.finditer(masked)}

    res = {
        "path": relpath,
        "bytes": os.path.getsize(path),
        "lines": raw.count("\n") + 1,
        "statements": len(stmts),
        "parsed": 0,
        "param_extractions": 0,
        "errors": list(mask_errors),
        "warnings": [],
        "notes": [],
    }

    for idx, (text, start_line) in enumerate(stmts, start=1):
        e, w, n, findings = analyse_statement(text, idx, start_line, cte_names)
        res["errors"].extend(e)
        res["warnings"].extend(w)
        res["notes"].extend(n)
        res["param_extractions"] += len(findings)

        if HAVE_SQLGLOT:
            try:
                # Capture sqlglot's own logger: when it cannot fully parse a
                # statement it emits a warning and FALLS BACK to wrapping the
                # text in a Command node, which would otherwise look like a
                # successful parse. We must not report success in that case.
                import logging as _logging
                _sink = []

                class _Cap(_logging.Handler):
                    def emit(self, record):
                        _sink.append(record.getMessage())

                _logger = _logging.getLogger("sqlglot")
                _handler = _Cap()
                _prev_level = _logger.level
                _logger.addHandler(_handler)
                _logger.setLevel(_logging.WARNING)
                try:
                    parsed = sqlglot.parse(text, read="bigquery")
                finally:
                    _logger.removeHandler(_handler)
                    _logger.setLevel(_prev_level)

                used_command = any(
                    isinstance(node, exp.Command) for node in parsed
                ) or any(
                    isinstance(n, exp.Command) for node in parsed
                    for n in node.walk()
                )
                if used_command:
                    res["errors"].append(
                        "statement %d: sqlglot could not parse this statement "
                        "and fell back to an unparsed Command node -- the "
                        "grammar check does NOT cover it. %s"
                        % (idx, ("sqlglot said: " + _sink[0][:160]) if _sink else "")
                    )
                elif _sink:
                    res["warnings"].append(
                        "statement %d: sqlglot noted '%s'"
                        % (idx, _sink[0][:160])
                    )
                else:
                    res["parsed"] += 1
            except Exception as exc:
                msg = " ".join(str(exc).split())[:240]
                # sqlglot reports line numbers relative to the statement text,
                # so translate back to a file line.
                mline = re.search(r"Line (\d+)", msg)
                where = ""
                if mline:
                    where = " (file line ~%d)" % (
                        start_line + int(mline.group(1)) - 1
                    )
                res["errors"].append(
                    "statement %d%s: sqlglot(bigquery) parse failed: %s"
                    % (idx, where, msg)
                )

    # ---- header comment contract ----------------------------------------
    # Every query file in this pack must open with a header that states the
    # question, what it returns, and its cost/scan position. A file that loses
    # its header is a file whose caveats have been deleted.
    #
    # Support files (the parameter-pattern reference, the session-table build
    # script) are not "one question, one query" files, so they are held to a
    # different contract: they must still document what they are, what they
    # cost, and that they were not executed.
    SUPPORT_FILES = ("00-PARAM-PATTERNS.sql", "create_session_table.sql")
    is_support = os.path.basename(path) in SUPPORT_FILES

    head = raw.lstrip()
    if not (head.startswith("--") or head.startswith("/*")):
        res["errors"].append("file does not begin with a header comment")
    elif is_support:
        for required in ("WHAT THIS FILE", "COST"):
            if required not in raw:
                res["warnings"].append(
                    "support-file header does not mention '%s'" % required
                )
    else:
        for required in ("QUESTION IT ANSWERS", "WHAT IT RETURNS", "COST"):
            if required not in raw:
                res["warnings"].append(
                    "header does not mention '%s' (the pack's header contract "
                    "asks for the question, the returned columns, and a "
                    "cost/scan warning)" % required
                )

    return res


def check_markdown_sql():
    """
    Parse every ```sql fenced block in every .md file. Blocks that are
    deliberately fragments (a bare WHERE clause, a GROUP BY, a single CTE body)
    are reported as FRAGMENT and skipped -- they are illustrative excerpts, not
    statements. A complete-looking block that does not parse is an ERROR.
    """
    import glob as _glob

    FRAGMENT_STARTS = (
        "where", "group by", "having", "order by", "limit",
        "and ", "or ", "on ", "join ",
    )
    results = []
    md_files = []
    for root, dirs, files in os.walk(CONTENT_DIR):
        dirs.sort()
        for fn in sorted(files):
            if fn.lower().endswith(".md"):
                md_files.append(os.path.join(root, fn))
    md_files.sort()

    for path in md_files:
        rel = os.path.relpath(path, CONTENT_DIR)
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
        for idx, block in enumerate(
            re.findall(r"```sql\s*\n(.*?)```", text, re.DOTALL), start=1
        ):
            stripped = block.strip()
            if not stripped:
                results.append({"file": rel, "block": idx, "status": "EMPTY",
                                "first_line": "", "detail": ""})
                continue
            first = stripped.split("\n")[0].strip().lower()

            # Deliberate partial excerpts. Detected structurally, not by
            # guessing: a block that starts with a bare clause keyword, or that
            # is a lone CTE body (`name AS ( ... )`) with no runnable statement,
            # cannot stand alone and is exempt from the grammar check.
            is_clause = first.startswith(FRAGMENT_STARTS)
            is_cte_body = re.match(r"^[a-z_][a-z0-9_]*\s+as\s*\(", first) is not None
            # A scalar expression or a single CASE/COALESCE, i.e. no statement
            # keyword anywhere in the block.
            has_statement_kw = re.search(
                r"\b(select|insert|create|update|delete|merge)\b", stripped, re.IGNORECASE
            ) is not None

            # A block that is a list of scalar expressions is an excerpt showing
            # the shape of individual columns, not a statement. The reliable
            # test is structural: does any line START with a statement keyword?
            # (Inside a scalar subquery, FROM and WHERE naturally appear on the
            # same line, so keyword-hunting anywhere in the block is wrong.)
            starts_with_statement_kw = any(
                re.match(r"^\s*(select|with|insert|create|update|delete|merge)\b",
                         ln, re.IGNORECASE)
                for ln in stripped.split("\n")
            )
            # An elided excerpt -- `FROM ...`, `AS SELECT ...` -- is
            # illustrative by design. It is still worth checking: substitute a
            # valid placeholder for the hole and verify the SURROUNDING
            # grammar parses. That way an elided block cannot hide a real
            # syntax error, and it is reported as a fragment with a note.
            elided = "..." in stripped
            if elided:
                normalized = re.sub(r"\s*\.\.\.\s*", " 1 ", stripped)
                if HAVE_SQLGLOT:
                    try:
                        sqlglot.parse(normalized, read="bigquery")
                        results.append({
                            "file": rel, "block": idx, "status": "FRAGMENT",
                            "first_line": first[:70],
                            "detail": "elided; surrounding grammar parses",
                        })
                    except Exception as exc:
                        results.append({
                            "file": rel, "block": idx, "status": "FAILED",
                            "first_line": first[:70],
                            "detail": "elided block, but the surrounding grammar "
                                      "is invalid: %s" % " ".join(str(exc).split())[:150],
                        })
                else:
                    results.append({"file": rel, "block": idx, "status": "FRAGMENT",
                                    "first_line": first[:70],
                                    "detail": "elided; sqlglot unavailable"})
                continue

            if (is_clause or is_cte_body or not has_statement_kw
                    or not starts_with_statement_kw):
                status, detail = "FRAGMENT", ""
            elif HAVE_SQLGLOT:
                try:
                    import logging as _logging
                    _sink = []

                    class _Cap(_logging.Handler):
                        def emit(self, record):
                            _sink.append(record.getMessage())

                    _logger = _logging.getLogger("sqlglot")
                    _handler = _Cap()
                    _prev = _logger.level
                    _logger.addHandler(_handler)
                    _logger.setLevel(_logging.WARNING)
                    try:
                        parsed = sqlglot.parse(stripped, read="bigquery")
                    finally:
                        _logger.removeHandler(_handler)
                        _logger.setLevel(_prev)

                    # A Command node means sqlglot did not really parse it.
                    fell_back = any(
                        isinstance(n, exp.Command)
                        for node in parsed for n in node.walk()
                    )
                    if fell_back:
                        status = "FAILED"
                        detail = ("sqlglot fell back to an unparsed Command node "
                                  "-- grammar check does not cover this block. %s"
                                  % (_sink[0][:140] if _sink else ""))
                    else:
                        status, detail = "PARSED", ""
                        if _sink:
                            detail = "sqlglot noted: %s" % _sink[0][:140]
                except Exception as exc:
                    status = "FAILED"
                    detail = " ".join(str(exc).split())[:180]
            else:
                status, detail = "SKIPPED", "sqlglot unavailable"
            results.append({"file": rel, "block": idx, "status": status,
                            "first_line": first[:70], "detail": detail})
    return results


def main():
    sql_files = []
    for root, dirs, files in os.walk(CONTENT_DIR):
        dirs.sort()
        for fn in sorted(files):
            if fn.lower().endswith(".sql"):
                full = os.path.join(root, fn)
                sql_files.append((full, os.path.relpath(full, CONTENT_DIR)))
    sql_files.sort(key=lambda t: t[1])

    line = "=" * 78
    print(line)
    print("GA4 BigQuery Session & Funnel SQL Pack -- verification report")
    print(line)
    print("content dir        : %s" % os.path.abspath(CONTENT_DIR))
    print("sqlglot            : %s (BigQuery dialect %s)"
          % ("available" if HAVE_SQLGLOT else "MISSING", SQLGLOT_VERSION))
    if not HAVE_SQLGLOT:
        print("  !! import error: %s" % SQLGLOT_IMPORT_ERROR)
        print("  !! GRAMMAR CHECKING SKIPPED -- structural checks only.")
    print("sql files found    : %d" % len(sql_files))
    print("")
    print("SCOPE: static analysis of SQL text only. NOTHING in this pack was")
    print("       executed against BigQuery; no GCP account was available.")
    print("")

    rows = [check_file(full, rel) for full, rel in sql_files]

    print("-" * 78)
    print("%-40s %7s %6s %7s %7s" % ("file", "bytes", "stmts", "parsed", "params"))
    print("-" * 78)
    for r in rows:
        print("%-40s %7d %6d %7d %7d"
              % (r["path"], r["bytes"], r["statements"], r["parsed"],
                 r["param_extractions"]))
    print("-" * 78)
    print("")

    for r in rows:
        if not r["errors"] and not r["warnings"]:
            continue
        print("### %s" % r["path"])
        for e in r["errors"]:
            print("  ERROR   : %s" % e)
        for w in r["warnings"]:
            print("  WARNING : %s" % w)
        print("")

    print(line)
    print("event_params value-type mapping verified (GA4 built-in keys)")
    print(line)
    seen = {}
    for r in rows:
        for note in r["notes"]:
            seen[note.split(" -> ")[0]] = note
    if not seen:
        print("  (none found -- check the extraction regexes)")
    for k in sorted(seen):
        print("  %s" % seen[k])
    print("")

    total_errors = sum(len(r["errors"]) for r in rows)
    total_warnings = sum(len(r["warnings"]) for r in rows)

    # ---- fenced SQL blocks inside the markdown docs ----------------------
    md_results = check_markdown_sql()
    md_failed = [m for m in md_results if m["status"] == "FAILED"]
    md_parsed = [m for m in md_results if m["status"] == "PARSED"]
    md_frag = [m for m in md_results if m["status"] == "FRAGMENT"]
    md_empty = [m for m in md_results if m["status"] == "EMPTY"]

    print(line)
    print("SQL blocks embedded in the markdown documentation")
    print(line)
    print("blocks found       : %d" % len(md_results))
    print("complete, parsed   : %d" % len(md_parsed))
    print("intentional fragments (skipped): %d" % len(md_frag))
    print("empty              : %d" % len(md_empty))
    print("failed to parse    : %d" % len(md_failed))
    print("")
    for m in md_results:
        marker = {"PARSED": "ok  ", "FRAGMENT": "frag", "FAILED": "FAIL",
                  "EMPTY": "----", "SKIPPED": "skip"}[m["status"]]
        print("  [%s] %s block %d  %s" % (marker, m["file"], m["block"], m["first_line"]))
        if m["detail"]:
            print("         %s" % m["detail"])
    print("")
    print("A 'frag' block is a deliberately partial excerpt -- a bare WHERE")
    print("clause, a GROUP BY, a lone CTE body, or a single scalar expression --")
    print("which cannot stand alone as a statement. Only complete blocks are")
    print("grammar-checked.")
    print("")

    total_errors += len(md_failed)

    print(line)
    print("SUMMARY")
    print(line)
    print("files checked      : %d .sql" % len(rows))
    print("statements parsed  : %d / %d"
          % (sum(r["parsed"] for r in rows), sum(r["statements"] for r in rows)))
    print("md sql blocks      : %d complete parsed, %d fragments skipped, %d failed"
          % (len(md_parsed), len(md_frag), len(md_failed)))
    print("errors             : %d" % total_errors)
    print("warnings           : %d" % total_warnings)
    print("")
    print("Checked (static):  balanced parens; no SELECT *; _TABLE_SUFFIX on")
    print("                   every events_* read; no TABLESAMPLE; one value")
    print("                   field per event_params key; GA4 built-in")
    print("                   parameter value types; no mixed-type COALESCE;")
    print("                   no unsafe numeric CAST of string_value;")
    print("                   TIMESTAMP_MICROS for event_timestamp;")
    print("                   documented-but-wrong field paths rejected")
    print("                   (manual_campaign.name, and any dotted path")
    print("                   through collected_traffic_source.manual_campaign);")
    print("                   header-comment contract present; and a full")
    print("                   sqlglot BigQuery grammar parse of every statement.")
    print("NOT checked:       execution; column existence in YOUR dataset")
    print("                   (only your own INFORMATION_SCHEMA can show that);")
    print("                   numerical correctness; bytes scanned; cost.")
    print("")

    report = {
        "content_dir": os.path.abspath(CONTENT_DIR),
        "sqlglot_available": HAVE_SQLGLOT,
        "sqlglot_version": SQLGLOT_VERSION,
        "executed_against_bigquery": False,
        "scope": "static analysis of SQL text only",
        "files": rows,
        "markdown_sql_blocks": md_results,
        "total_errors": total_errors,
        "total_warnings": total_warnings,
    }
    out_path = os.path.join(CONTENT_DIR, "verification-report.json")
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)
    print("machine-readable report -> %s" % out_path)

    return 1 if total_errors else 0


if __name__ == "__main__":
    sys.exit(main())
