#!/usr/bin/env python3
"""
Standalone verification runner for the StatCan Employment Data Analysis SQL pipeline.

Loads the PostgreSQL schema (01_schema.sql), seed dataset (02_seed_data.sql),
and reporting views (04_views.sql) into an in-memory SQLite instance, validates
the seed rows against data/statcan_lfs_sample.csv, executes all 6 analytical
queries from 03_analytical_queries.sql, and prints formatted ASCII tables.

Usage:
    python scripts/run_analysis.py
"""

import csv
import sqlite3
import sys
from pathlib import Path
from typing import List, Sequence, Tuple

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SQL_DIR = PROJECT_ROOT / "sql"
CSV_PATH = PROJECT_ROOT / "data" / "statcan_lfs_sample.csv"

QUERY_TITLES = [
    "Query 1: 3-Period Moving Average of Provincial Unemployment Rates (Q1 2026)",
    "Query 2: Year-over-Year (YoY) Employment & Wage Growth by NAICS Sector (Mar 2026 vs Mar 2025)",
    "Query 3: Top-Paying NAICS Sectors per Province using DENSE_RANK (Latest Period: 2026-03-01)",
    "Query 4: Provincial Unemployment Rate vs. National Weighted Benchmark (2026-03-01)",
    "Query 5: Job Vacancy-to-Unemployment Tightness Ratio - Tech vs. Traditional (2026-03-01)",
    "Query 6: Multi-Year Net Job Creation & Regional Rollup Summary (Mar 2023 - Mar 2026)",
]


def split_sql_statements(sql_text: str) -> List[str]:
    """Strip full-line SQL comments and split a .sql file into individual statements."""
    cleaned_lines: List[str] = []
    for line in sql_text.splitlines():
        if line.strip().startswith("--"):
            continue
        cleaned_lines.append(line)

    joined = "\n".join(cleaned_lines)
    return [stmt.strip() for stmt in joined.split(";") if stmt.strip()]


def format_ascii_table(headers: Sequence[str], rows: Sequence[Tuple]) -> str:
    """Format query results into a bordered ASCII table with right-aligned numbers."""
    str_rows: List[List[str]] = []
    for row in rows:
        formatted_row: List[str] = []
        for val in row:
            if val is None:
                formatted_row.append("NULL")
            elif isinstance(val, float):
                formatted_row.append(f"{val:.2f}")
            else:
                formatted_row.append(str(val))
        str_rows.append(formatted_row)

    col_widths = [len(h) for h in headers]
    for r in str_rows:
        for idx, cell in enumerate(r):
            if len(cell) > col_widths[idx]:
                col_widths[idx] = len(cell)

    def is_numeric_column(col_idx: int) -> bool:
        for row in rows:
            val = row[col_idx]
            if val is not None:
                return isinstance(val, (int, float))
        return False

    numeric_cols = [is_numeric_column(i) for i in range(len(headers))]

    border = "+-" + "-+-".join("-" * w for w in col_widths) + "-+"
    header_line = "| " + " | ".join(headers[i].ljust(col_widths[i]) for i in range(len(headers))) + " |"

    lines = [border, header_line, border]
    for r in str_rows:
        cells = [
            r[i].rjust(col_widths[i]) if numeric_cols[i] else r[i].ljust(col_widths[i])
            for i in range(len(headers))
        ]
        lines.append("| " + " | ".join(cells) + " |")
    lines.append(border)
    return "\n".join(lines)


def verify_csv_consistency(conn: sqlite3.Connection, csv_path: Path) -> int:
    """Verify that the CSV export matches the seeded SQL fact table row count."""
    with csv_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        csv_rows = list(reader)

    cursor = conn.execute("SELECT COUNT(*) FROM labour_force_monthly;")
    db_count = cursor.fetchone()[0]

    if len(csv_rows) != db_count:
        raise ValueError(
            f"Row count mismatch: CSV has {len(csv_rows)} rows, DB has {db_count} rows."
        )
    return db_count


def main() -> int:
    schema_file = SQL_DIR / "01_schema.sql"
    seed_file = SQL_DIR / "02_seed_data.sql"
    queries_file = SQL_DIR / "03_analytical_queries.sql"
    views_file = SQL_DIR / "04_views.sql"

    for required in (schema_file, seed_file, queries_file, views_file, CSV_PATH):
        if not required.exists():
            print(f"[ERROR] Missing required project file: {required}", file=sys.stderr)
            return 1

    conn = sqlite3.connect(":memory:")
    conn.execute("PRAGMA foreign_keys = ON;")

    try:
        # 1. Execute DDL schema, seed data, and reporting views
        for sql_file in (schema_file, seed_file, views_file):
            sql_script = sql_file.read_text(encoding="utf-8")
            conn.executescript(sql_script)

        # 2. Verify CSV consistency with seeded SQL rows
        row_count = verify_csv_consistency(conn, CSV_PATH)
        prov_count = conn.execute("SELECT COUNT(*) FROM provinces;").fetchone()[0]
        ind_count = conn.execute("SELECT COUNT(*) FROM industries;").fetchone()[0]

        print("=" * 94)
        print(" STATCAN EMPLOYMENT DATA ANALYSIS - SQL PIPELINE VERIFICATION")
        print("=" * 94)
        print(f" Loaded Schema : {schema_file.relative_to(PROJECT_ROOT)}")
        print(f" Loaded Seed   : {seed_file.relative_to(PROJECT_ROOT)} ({prov_count} provinces, {ind_count} NAICS sectors, {row_count} monthly records)")
        print(f" Verified CSV  : {CSV_PATH.relative_to(PROJECT_ROOT)} ({row_count} records matched)")
        print(f" Loaded Views  : {views_file.relative_to(PROJECT_ROOT)} (3 reporting views registered)")
        print("=" * 94)

        # 3. Parse and execute the 6 analytical queries
        analytical_sql = queries_file.read_text(encoding="utf-8")
        statements = split_sql_statements(analytical_sql)

        for idx, stmt in enumerate(statements):
            title = QUERY_TITLES[idx] if idx < len(QUERY_TITLES) else f"Query {idx + 1}"
            cursor = conn.execute(stmt)
            headers = [desc[0] for desc in cursor.description]
            rows = cursor.fetchall()

            print(f"\n[{idx + 1}/{len(statements)}] {title}")
            print(format_ascii_table(headers, rows))
            print(f"({len(rows)} rows returned)")

        # 4. Verify reporting views from 04_views.sql
        print("\n" + "=" * 94)
        print(" VIEW VERIFICATION SAMPLE: vw_tech_vs_traditional_tightness (2026-03-01)")
        print("=" * 94)
        view_cursor = conn.execute(
            """
            SELECT
                report_date,
                sector_group,
                employed_thousands,
                unemployed_thousands,
                total_vacancies,
                vacancy_to_unemployed_ratio,
                weighted_avg_wage
            FROM vw_tech_vs_traditional_tightness
            WHERE report_date = '2026-03-01'
            ORDER BY sector_group DESC;
            """
        )
        view_headers = [desc[0] for desc in view_cursor.description]
        view_rows = view_cursor.fetchall()
        print(format_ascii_table(view_headers, view_rows))

    finally:
        conn.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
