# StatCan Employment Data Analysis (PostgreSQL)

A relational database and analytical SQL project modeling Statistics Canada Labour Force Survey (LFS) and Job Vacancy and Wage Survey (JVWS) data across Canadian provinces and North American Industry Classification System (NAICS) sectors from 2023 to 2026.

The repository includes a normalized 3NF PostgreSQL schema, 120 monthly province-by-sector observations (`sql/02_seed_data.sql` and `data/statcan_lfs_sample.csv`), six analytical queries built with Common Table Expressions (CTEs) and window functions, reusable reporting views, and a zero-dependency Python verification script (`scripts/run_analysis.py`) that executes the full pipeline in memory.

---

## Dataset Background

Statistics Canada publishes monthly labour market indicators through the **Labour Force Survey (LFS, Tables 14-10-0023-01 & 14-10-0064-01)** and quarterly/monthly vacancy and wage metrics through the **Job Vacancy and Wage Survey (JVWS, Table 14-10-0326-01)**.

Each record in the fact table (`labour_force_monthly`) represents a single `(report_date, province_id, industry_id)` observation across:
- **4 Provinces (`provinces`)**: Ontario (`ON`), Quebec (`QC`), British Columbia (`BC`), and Alberta (`AB`), grouped by Statistics Canada economic region (`Central Canada`, `Western Canada`, `Prairie Provinces`).
- **5 NAICS Sectors (`industries`)**:
  - `54` — Professional, scientific and technical services
  - `51` — Information and cultural industries
  - `31-33` — Manufacturing
  - `62` — Health care and social assistance
  - `23` — Construction
- **6 Reporting Periods (2023–2026)**: Annual March reference benchmarks (`2023-03-01`, `2024-03-01`, `2025-03-01`, `2026-03-01`) to measure non-seasonal Year-over-Year (YoY) shifts, alongside consecutive Q1 2026 monthly releases (`2026-01-01`, `2026-02-01`, `2026-03-01`) to evaluate 3-month moving averages.

---

## Project Structure

```text
statcan-employment-sql/
├── sql/
│   ├── 01_schema.sql               # DDL statements: tables, primary/foreign keys, check constraints, indexes
│   ├── 02_seed_data.sql            # Realistic StatCan LFS dataset (2023-2026 across provinces & NAICS sectors)
│   ├── 03_analytical_queries.sql   # 6 advanced analytical SQL queries using CTEs and Window Functions
│   └── 04_views.sql                # Reusable SQL views for provincial and sector reporting
├── data/
│   └── statcan_lfs_sample.csv      # Raw CSV export of the labor market dataset
├── scripts/
│   └── run_analysis.py             # Standalone Python script to run the SQL pipeline and print formatted results
├── .gitignore                      # SQL, Python, and IDE ignore rules
└── README.md                       # Student-style documentation with schema details and sample query outputs
```

---

## Relational Schema Overview

```text
+-------------------------+       +------------------------------------+       +-------------------------+
|        provinces        |       |        labour_force_monthly        |       |       industries        |
+-------------------------+       +------------------------------------+       +-------------------------+
| PK province_id (INT)    |<---+  | PK record_id (INT)                 |  +--->| PK industry_id (INT)    |
| UQ province_code CHAR(2)|    |  |    report_date (DATE)              |  |    | UQ naics_code VARCHAR   |
| UQ province_name VARCHAR|    +--| FK province_id (INT)               |  |    | UQ industry_name VARCHAR|
|    region VARCHAR       |       | FK industry_id (INT)               |--+    +-------------------------+
+-------------------------+       |    labour_force_thousands NUMERIC  |
                                  |    employed_thousands NUMERIC      |
                                  |    unemployed_thousands NUMERIC    |
                                  |    unemployment_rate NUMERIC(5,2)  |
                                  |    avg_hourly_wage NUMERIC(6,2)    |
                                  |    job_vacancies INT               |
                                  +------------------------------------+
```

### Integrity Constraints & Indexing (`sql/01_schema.sql`)
- **Candidate Key Constraint**: `UNIQUE (report_date, province_id, industry_id)` prevents duplicate monthly sector observations.
- **Domain `CHECK` Constraints**:
  - `unemployment_rate >= 0.00 AND unemployment_rate <= 100.00`
  - `labour_force_thousands > 0`, `employed_thousands >= 0`, `unemployed_thousands >= 0`, `job_vacancies >= 0`
  - `avg_hourly_wage > 0.00`
- **Composite B-Tree Indexes**:
  - `idx_lfm_province_date ON labour_force_monthly (province_id, report_date)`
  - `idx_lfm_industry_date ON labour_force_monthly (industry_id, report_date)`
  - Leading column order matches the `PARTITION BY province_id ORDER BY report_date` and `PARTITION BY industry_id ORDER BY report_date` clauses used in the analytical window functions.

---

## SQL Techniques & Analytical Queries (`sql/03_analytical_queries.sql`)

1. **Query 1 — 3-Month Moving Average (`ROWS BETWEEN 2 PRECEDING AND CURRENT ROW`)**:
   - First aggregates the sector-grain fact table up to one row per `(province_id, report_date)` in a CTE using labour-force-weighted unemployment (`SUM(unemployed_thousands) * 100.0 / SUM(labour_force_thousands)`), then applies `AVG(unemployment_rate) OVER (PARTITION BY province_id ORDER BY report_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)` so the 3-row frame spans three consecutive periods rather than three industry rows.
2. **Query 2 — Year-over-Year (YoY) Employment & Wage Growth (`LAG`)**:
   - Filters to annual March reference periods (`2023-03-01` through `2026-03-01`) and uses `LAG(national_employed_k, 1) OVER (PARTITION BY industry_id ORDER BY report_date)` and employment-weighted hourly wages to compute 12-month percentage growth by NAICS industry.
3. **Query 3 — Industry Wage Ranking per Province (`DENSE_RANK`)**:
   - Joins against a `MAX(report_date)` CTE and applies `DENSE_RANK() OVER (PARTITION BY province_id ORDER BY avg_hourly_wage DESC)` to isolate the top 3 highest-paying sectors in each province without rank gaps on ties.
4. **Query 4 — Provincial vs. National Weighted Benchmark (`WITH` CTEs & `CASE WHEN`)**:
   - Computes provincial unemployment rates in one CTE and the national weighted benchmark in a second CTE, joining on `report_date` to calculate the basis-point spread and classify provinces as `'Above National Avg'` or `'Below National Avg'`.
5. **Query 5 — Job Vacancy-to-Unemployment Tightness Ratio**:
   - Compares open `job_vacancies` against total unemployed headcount (`unemployed_thousands * 1000`) across Tech & Knowledge sectors (`NAICS 54`, `NAICS 51`) vs. Traditional & Essential sectors (`NAICS 31-33`, `NAICS 62`, `NAICS 23`).
6. **Query 6 — Cumulative Employment Shift & Regional Rollup Summary**:
   - Aggregates net job creation between March 2023 and March 2026 by economic region and NAICS sector, combining detail rows with regional subtotals and a national grand total.

---

## Running the Project

### Option 1: Standalone Python Verification Runner (Windows / macOS / Linux)

No external database server or `pip` packages are required. The runner uses Python's standard library (`sqlite3` and `csv`) to build the schema in memory, verify `data/statcan_lfs_sample.csv`, and execute all queries:

```bash
python scripts/run_analysis.py
```

### Option 2: PostgreSQL (`psql` CLI)

To run the scripts against a local PostgreSQL database (`statcan_lfs`):

```bash
createdb statcan_lfs
psql -d statcan_lfs -f sql/01_schema.sql
psql -d statcan_lfs -f sql/02_seed_data.sql
psql -d statcan_lfs -f sql/04_views.sql
psql -d statcan_lfs -f sql/03_analytical_queries.sql
```

---

## Sample Output (`python scripts/run_analysis.py`)

```text
==============================================================================================
 STATCAN EMPLOYMENT DATA ANALYSIS - SQL PIPELINE VERIFICATION
==============================================================================================
 Loaded Schema : sql\01_schema.sql
 Loaded Seed   : sql\02_seed_data.sql (4 provinces, 5 NAICS sectors, 120 monthly records)
 Verified CSV  : data\statcan_lfs_sample.csv (120 records matched)
 Loaded Views  : sql\04_views.sql (3 reporting views registered)
==============================================================================================

[1/6] Query 1: 3-Period Moving Average of Provincial Unemployment Rates (Q1 2026)
+---------------+------------------+-------------+----------------------+-------------------+--------------------------+------------------+
| province_code | province_name    | report_date | total_labour_force_k | unemployment_rate | moving_avg_3m_unemp_rate | rate_vs_3m_trend |
+---------------+------------------+-------------+----------------------+-------------------+--------------------------+------------------+
| ON            | Ontario          | 2026-01-01  |              3584.50 |              5.02 |                     4.99 |             0.03 |
| ON            | Ontario          | 2026-02-01  |              3596.20 |              4.91 |                     5.02 |            -0.11 |
| ON            | Ontario          | 2026-03-01  |              3608.00 |              4.78 |                     4.90 |            -0.12 |
| QC            | Quebec           | 2026-01-01  |              2113.00 |              4.43 |                     4.42 |             0.01 |
| QC            | Quebec           | 2026-02-01  |              2119.00 |              4.34 |                     4.44 |            -0.10 |
| QC            | Quebec           | 2026-03-01  |              2125.00 |              4.24 |                     4.34 |            -0.10 |
| BC            | British Columbia | 2026-01-01  |              1296.20 |              4.57 |                     4.57 |             0.00 |
| BC            | British Columbia | 2026-02-01  |              1301.30 |              4.45 |                     4.57 |            -0.12 |
| BC            | British Columbia | 2026-03-01  |              1306.50 |              4.34 |                     4.45 |            -0.11 |
| AB            | Alberta          | 2026-01-01  |              1073.00 |              5.29 |                     5.37 |            -0.08 |
| AB            | Alberta          | 2026-02-01  |              1077.60 |              5.16 |                     5.32 |            -0.16 |
| AB            | Alberta          | 2026-03-01  |              1082.00 |              5.02 |                     5.16 |            -0.14 |
+---------------+------------------+-------------+----------------------+-------------------+--------------------------+------------------+
(12 rows returned)

[2/6] Query 2: Year-over-Year (YoY) Employment & Wage Growth by NAICS Sector (Mar 2026 vs Mar 2025)
+------------+-------------------------------------------------+-------------+---------------------+----------------------+---------------------------+-------------------+---------------------+
| naics_code | industry_name                                   | report_date | national_employed_k | prev_year_employed_k | yoy_employment_growth_pct | weighted_avg_wage | yoy_wage_growth_pct |
+------------+-------------------------------------------------+-------------+---------------------+----------------------+---------------------------+-------------------+---------------------+
| 54         | Professional, scientific and technical services | 2026-03-01  |             1916.40 |              1852.80 |                      3.43 |             52.43 |                3.97 |
| 51         | Information and cultural industries             | 2026-03-01  |              428.90 |               415.70 |                      3.18 |             48.90 |                3.78 |
| 62         | Health care and social assistance               | 2026-03-01  |             2423.90 |              2354.40 |                      2.95 |             38.41 |                3.28 |
| 23         | Construction                                    | 2026-03-01  |             1396.90 |              1361.30 |                      2.62 |             41.77 |                3.29 |
| 31-33      | Manufacturing                                   | 2026-03-01  |             1582.00 |              1565.40 |                      1.06 |             36.56 |                3.28 |
+------------+-------------------------------------------------+-------------+---------------------+----------------------+---------------------------+-------------------+---------------------+
(5 rows returned)

[3/6] Query 3: Top-Paying NAICS Sectors per Province using DENSE_RANK (Latest Period: 2026-03-01)
+---------------+------------------+-----------------------+------------+-------------------------------------------------+-----------------+--------------------+---------------+
| province_code | province_name    | wage_rank_in_province | naics_code | industry_name                                   | avg_hourly_wage | employed_thousands | job_vacancies |
+---------------+------------------+-----------------------+------------+-------------------------------------------------+-----------------+--------------------+---------------+
| ON            | Ontario          |                     1 | 54         | Professional, scientific and technical services |           53.40 |             877.50 |         29900 |
| ON            | Ontario          |                     2 | 51         | Information and cultural industries             |           49.80 |             185.80 |          5850 |
| ON            | Ontario          |                     3 | 23         | Construction                                    |           41.60 |             578.80 |         22300 |
| QC            | Quebec           |                     1 | 54         | Professional, scientific and technical services |           49.50 |                455 |         16700 |
| QC            | Quebec           |                     2 | 51         | Information and cultural industries             |           46.40 |             113.40 |          3650 |
| QC            | Quebec           |                     3 | 23         | Construction                                    |           40.50 |             317.70 |         12700 |
| BC            | British Columbia |                     1 | 54         | Professional, scientific and technical services |           52.60 |                328 |         12600 |
| BC            | British Columbia |                     2 | 51         | Information and cultural industries             |           50.40 |              85.30 |          3050 |
| BC            | British Columbia |                     3 | 23         | Construction                                    |           42.10 |             254.90 |         12100 |
| AB            | Alberta          |                     1 | 54         | Professional, scientific and technical services |           54.10 |             255.90 |          9200 |
| AB            | Alberta          |                     2 | 51         | Information and cultural industries             |           48.60 |              44.40 |          1480 |
| AB            | Alberta          |                     3 | 23         | Construction                                    |           43.50 |             245.50 |         10700 |
+---------------+------------------+-----------------------+------------+-------------------------------------------------+-----------------+--------------------+---------------+
(12 rows returned)

[4/6] Query 4: Provincial Unemployment Rate vs. National Weighted Benchmark (2026-03-01)
+-------------+---------------+------------------+------------------------+----------------------------+----------------+--------------------+
| report_date | province_code | province_name    | prov_unemployment_rate | national_unemployment_rate | spread_bps_pct | benchmark_status   |
+-------------+---------------+------------------+------------------------+----------------------------+----------------+--------------------+
| 2026-03-01  | QC            | Quebec           |                   4.24 |                       4.60 |          -0.36 | Below National Avg |
| 2026-03-01  | BC            | British Columbia |                   4.34 |                       4.60 |          -0.26 | Below National Avg |
| 2026-03-01  | ON            | Ontario          |                   4.78 |                       4.60 |           0.18 | Above National Avg |
| 2026-03-01  | AB            | Alberta          |                   5.02 |                       4.60 |           0.42 | Above National Avg |
+-------------+---------------+------------------+------------------------+----------------------------+----------------+--------------------+
(4 rows returned)

[5/6] Query 5: Job Vacancy-to-Unemployment Tightness Ratio - Tech vs. Traditional (2026-03-01)
+---------------------------------+------------+-------------------------------------------------+-----------------+--------------------+-----------------------------+------------------------+----------------------+
| sector_category                 | naics_code | industry_name                                   | total_vacancies | unemployed_persons | vacancy_to_unemployed_ratio | unemployed_per_vacancy | weighted_hourly_wage |
+---------------------------------+------------+-------------------------------------------------+-----------------+--------------------+-----------------------------+------------------------+----------------------+
| Traditional & Essential Sectors | 62         | Health care and social assistance               |          126900 |              64100 |                        1.98 |                   0.51 |                38.41 |
| Traditional & Essential Sectors | 23         | Construction                                    |           57800 |             108100 |                        0.53 |                   1.87 |                41.77 |
| Traditional & Essential Sectors | 31-33      | Manufacturing                                   |           44450 |              96500 |                        0.46 |                   2.17 |                36.56 |
| Tech & Knowledge Sectors        | 54         | Professional, scientific and technical services |           68400 |              81600 |                        0.84 |                   1.19 |                52.43 |
| Tech & Knowledge Sectors        | 51         | Information and cultural industries             |           14030 |              23100 |                        0.61 |                   1.65 |                48.90 |
+---------------------------------+------------+-------------------------------------------------+-----------------+--------------------+-----------------------------+------------------------+----------------------+
(5 rows returned)

[6/6] Query 6: Multi-Year Net Job Creation & Regional Rollup Summary (Mar 2023 - Mar 2026)
+-------------------+------------+-------------------------------------------------+------------+------------+--------------------+----------------------+
| region            | naics_code | industry_name                                   | emp_2023_k | emp_2026_k | net_jobs_created_k | growth_pct_2023_2026 |
+-------------------+------------+-------------------------------------------------+------------+------------+--------------------+----------------------+
| Central Canada    | 62         | Health care and social assistance               |    1546.30 |    1675.30 |             129.00 |                 8.34 |
| Central Canada    | 54         | Professional, scientific and technical services |    1223.10 |    1332.50 |             109.40 |                 8.94 |
| Central Canada    | 23         | Construction                                    |     851.50 |     896.50 |              45.00 |                 5.28 |
| Central Canada    | 51         | Information and cultural industries             |     280.20 |     299.20 |              19.00 |                 6.78 |
| Central Canada    | 31-33      | Manufacturing                                   |    1258.20 |    1267.10 |               8.90 |                 0.71 |
| Central Canada    | SUBTOTAL   | [Regional Subtotal]                             |    5159.30 |    5470.60 |             311.30 |                 6.03 |
| Prairie Provinces | 62         | Health care and social assistance               |     306.50 |     337.60 |              31.10 |                10.15 |
| Prairie Provinces | 54         | Professional, scientific and technical services |     230.60 |     255.90 |              25.30 |                10.97 |
| Prairie Provinces | 23         | Construction                                    |     226.80 |     245.50 |              18.70 |                 8.25 |
| Prairie Provinces | 31-33      | Manufacturing                                   |     138.00 |     144.30 |               6.30 |                 4.57 |
| Prairie Provinces | 51         | Information and cultural industries             |      40.20 |      44.40 |               4.20 |                10.45 |
| Prairie Provinces | SUBTOTAL   | [Regional Subtotal]                             |     942.10 |    1027.70 |              85.60 |                 9.09 |
| Western Canada    | 62         | Health care and social assistance               |     376.30 |     411.00 |              34.70 |                 9.22 |
| Western Canada    | 54         | Professional, scientific and technical services |     300.50 |     328.00 |              27.50 |                 9.15 |
| Western Canada    | 23         | Construction                                    |     240.40 |     254.90 |              14.50 |                 6.03 |
| Western Canada    | 51         | Information and cultural industries             |      79.10 |      85.30 |               6.20 |                 7.84 |
| Western Canada    | 31-33      | Manufacturing                                   |     167.40 |     170.60 |               3.20 |                 1.91 |
| Western Canada    | SUBTOTAL   | [Regional Subtotal]                             |    1163.70 |    1249.80 |              86.10 |                 7.40 |
| ALL REGIONS       | TOTAL      | [National Grand Total]                          |    7265.10 |    7748.10 |             483.00 |                 6.65 |
+-------------------+------------+-------------------------------------------------+------------+------------+--------------------+----------------------+
(19 rows returned)
```
