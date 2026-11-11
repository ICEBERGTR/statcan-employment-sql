-- ============================================================================
-- File: sql/03_analytical_queries.sql
-- Project: StatCan Employment Data Analysis
-- Description: Six analytical PostgreSQL queries using Common Table Expressions
--              (CTEs), window frames, positional lag functions, ranking, and
--              hierarchical rollup aggregations.
-- ============================================================================

-- ============================================================================
-- QUERY 1: 3-Period Moving Average of Provincial Unemployment Rates
-- Aggregates sector-level observations to the provincial monthly grain first,
-- then applies a 3-row sliding window frame (2 preceding + current row)
-- partitioned by province_id to smooth short-term rate volatility.
-- ============================================================================
WITH provincial_monthly AS (
    SELECT
        p.province_id,
        p.province_code,
        p.province_name,
        lfm.report_date,
        ROUND(SUM(lfm.labour_force_thousands), 1) AS total_labour_force_k,
        ROUND(SUM(lfm.unemployed_thousands), 1)   AS total_unemployed_k,
        ROUND(
            SUM(lfm.unemployed_thousands) * 100.0 / SUM(lfm.labour_force_thousands),
            2
        ) AS unemployment_rate
    FROM labour_force_monthly AS lfm
    INNER JOIN provinces AS p
        ON lfm.province_id = p.province_id
    GROUP BY
        p.province_id,
        p.province_code,
        p.province_name,
        lfm.report_date
),
moving_avg_calc AS (
    SELECT
        province_id,
        province_code,
        province_name,
        report_date,
        total_labour_force_k,
        unemployment_rate,
        ROUND(
            AVG(unemployment_rate) OVER (
                PARTITION BY province_id
                ORDER BY report_date
                ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
            ),
            2
        ) AS moving_avg_3m_unemp_rate
    FROM provincial_monthly
)
SELECT
    province_code,
    province_name,
    report_date,
    total_labour_force_k,
    unemployment_rate,
    moving_avg_3m_unemp_rate,
    ROUND(unemployment_rate - moving_avg_3m_unemp_rate, 2) AS rate_vs_3m_trend
FROM moving_avg_calc
WHERE report_date >= '2026-01-01'
ORDER BY province_id, report_date;


-- ============================================================================
-- QUERY 2: Year-over-Year (YoY) Employment & Wage Growth by NAICS Sector
-- Filters to annual March reference periods (12-month intervals: 2023-03 to
-- 2026-03) so LAG(..., 1) compares each sector against the exact same month
-- one year prior without seasonal distortion.
-- ============================================================================
WITH annual_industry_benchmarks AS (
    SELECT
        i.industry_id,
        i.naics_code,
        i.industry_name,
        lfm.report_date,
        ROUND(SUM(lfm.employed_thousands), 1) AS national_employed_k,
        ROUND(
            SUM(lfm.avg_hourly_wage * lfm.employed_thousands) / SUM(lfm.employed_thousands),
            2
        ) AS weighted_avg_wage
    FROM labour_force_monthly AS lfm
    INNER JOIN industries AS i
        ON lfm.industry_id = i.industry_id
    WHERE lfm.report_date IN ('2023-03-01', '2024-03-01', '2025-03-01', '2026-03-01')
    GROUP BY
        i.industry_id,
        i.naics_code,
        i.industry_name,
        lfm.report_date
),
industry_yoy_lag AS (
    SELECT
        industry_id,
        naics_code,
        industry_name,
        report_date,
        national_employed_k,
        LAG(national_employed_k, 1) OVER (
            PARTITION BY industry_id
            ORDER BY report_date
        ) AS prev_year_employed_k,
        weighted_avg_wage,
        LAG(weighted_avg_wage, 1) OVER (
            PARTITION BY industry_id
            ORDER BY report_date
        ) AS prev_year_wage
    FROM annual_industry_benchmarks
)
SELECT
    naics_code,
    industry_name,
    report_date,
    national_employed_k,
    prev_year_employed_k,
    ROUND(
        (national_employed_k - prev_year_employed_k) * 100.0 / prev_year_employed_k,
        2
    ) AS yoy_employment_growth_pct,
    weighted_avg_wage,
    ROUND(
        (weighted_avg_wage - prev_year_wage) * 100.0 / prev_year_wage,
        2
    ) AS yoy_wage_growth_pct
FROM industry_yoy_lag
WHERE prev_year_employed_k IS NOT NULL
  AND report_date = '2026-03-01'
ORDER BY yoy_employment_growth_pct DESC;


-- ============================================================================
-- QUERY 3: Industry Wage Ranking per Province (Latest Period)
-- Uses DENSE_RANK() partitioned by province_id and ordered by avg_hourly_wage
-- descending so tied hourly wages receive identical ranks without gaps.
-- ============================================================================
WITH latest_period AS (
    SELECT MAX(report_date) AS max_date
    FROM labour_force_monthly
),
ranked_sectors AS (
    SELECT
        p.province_id,
        p.province_code,
        p.province_name,
        i.naics_code,
        i.industry_name,
        lfm.report_date,
        lfm.avg_hourly_wage,
        lfm.employed_thousands,
        lfm.job_vacancies,
        DENSE_RANK() OVER (
            PARTITION BY lfm.province_id
            ORDER BY lfm.avg_hourly_wage DESC
        ) AS wage_rank_in_province
    FROM labour_force_monthly AS lfm
    INNER JOIN latest_period AS lp
        ON lfm.report_date = lp.max_date
    INNER JOIN provinces AS p
        ON lfm.province_id = p.province_id
    INNER JOIN industries AS i
        ON lfm.industry_id = i.industry_id
)
SELECT
    province_code,
    province_name,
    wage_rank_in_province,
    naics_code,
    industry_name,
    avg_hourly_wage,
    employed_thousands,
    job_vacancies
FROM ranked_sectors
WHERE wage_rank_in_province <= 3
ORDER BY province_id, wage_rank_in_province;


-- ============================================================================
-- QUERY 4: Provincial Unemployment Rate vs. National Weighted Benchmark
-- Computes each province's monthly unemployment rate alongside the national
-- labour-force-weighted benchmark for the same report_date, then classifies
-- each province relative to the national average.
-- ============================================================================
WITH provincial_rates AS (
    SELECT
        lfm.report_date,
        p.province_id,
        p.province_code,
        p.province_name,
        SUM(lfm.labour_force_thousands) AS prov_labour_force_k,
        SUM(lfm.unemployed_thousands)   AS prov_unemployed_k,
        ROUND(
            SUM(lfm.unemployed_thousands) * 100.0 / SUM(lfm.labour_force_thousands),
            2
        ) AS prov_unemployment_rate
    FROM labour_force_monthly AS lfm
    INNER JOIN provinces AS p
        ON lfm.province_id = p.province_id
    GROUP BY
        lfm.report_date,
        p.province_id,
        p.province_code,
        p.province_name
),
national_benchmark AS (
    SELECT
        report_date,
        ROUND(
            SUM(prov_unemployed_k) * 100.0 / SUM(prov_labour_force_k),
            2
        ) AS national_unemployment_rate
    FROM provincial_rates
    GROUP BY report_date
)
SELECT
    pr.report_date,
    pr.province_code,
    pr.province_name,
    pr.prov_unemployment_rate,
    nb.national_unemployment_rate,
    ROUND(pr.prov_unemployment_rate - nb.national_unemployment_rate, 2) AS spread_bps_pct,
    CASE
        WHEN pr.prov_unemployment_rate > nb.national_unemployment_rate THEN 'Above National Avg'
        WHEN pr.prov_unemployment_rate < nb.national_unemployment_rate THEN 'Below National Avg'
        ELSE 'At National Avg'
    END AS benchmark_status
FROM provincial_rates AS pr
INNER JOIN national_benchmark AS nb
    ON pr.report_date = nb.report_date
WHERE pr.report_date = '2026-03-01'
ORDER BY pr.prov_unemployment_rate ASC;


-- ============================================================================
-- QUERY 5: Job Vacancy-to-Unemployment Tightness Ratio (Tech vs. Traditional)
-- Measures labour market tightness as job_vacancies divided by total unemployed
-- persons (unemployed_thousands * 1000). A higher ratio signals fewer available
-- unemployed workers per open position.
-- ============================================================================
WITH sector_classification AS (
    SELECT
        lfm.report_date,
        i.naics_code,
        i.industry_name,
        CASE
            WHEN i.naics_code IN ('54', '51') THEN 'Tech & Knowledge Sectors'
            ELSE 'Traditional & Essential Sectors'
        END AS sector_category,
        SUM(lfm.job_vacancies)               AS total_vacancies,
        SUM(lfm.unemployed_thousands) * 1000 AS total_unemployed_persons,
        ROUND(
            SUM(lfm.avg_hourly_wage * lfm.employed_thousands) / SUM(lfm.employed_thousands),
            2
        ) AS weighted_hourly_wage
    FROM labour_force_monthly AS lfm
    INNER JOIN industries AS i
        ON lfm.industry_id = i.industry_id
    WHERE lfm.report_date = '2026-03-01'
    GROUP BY
        lfm.report_date,
        i.naics_code,
        i.industry_name
)
SELECT
    sector_category,
    naics_code,
    industry_name,
    total_vacancies,
    CAST(ROUND(total_unemployed_persons, 0) AS INT) AS unemployed_persons,
    ROUND(total_vacancies * 1.0 / total_unemployed_persons, 2) AS vacancy_to_unemployed_ratio,
    ROUND(total_unemployed_persons * 1.0 / total_vacancies, 2) AS unemployed_per_vacancy,
    weighted_hourly_wage
FROM sector_classification
ORDER BY sector_category DESC, vacancy_to_unemployed_ratio DESC;


-- ============================================================================
-- QUERY 6: Multi-Year Cumulative Employment Shift & Regional Rollup Summary
-- Calculates net job creation between March 2023 and March 2026 by region and
-- industry, and appends regional subtotals plus a national grand total
-- (portable relational equivalent of GROUP BY ROLLUP (region, industry_name)).
-- ============================================================================
WITH endpoints AS (
    SELECT
        p.region,
        i.naics_code,
        i.industry_name,
        SUM(CASE WHEN lfm.report_date = '2023-03-01' THEN lfm.employed_thousands ELSE 0 END) AS emp_2023_k,
        SUM(CASE WHEN lfm.report_date = '2026-03-01' THEN lfm.employed_thousands ELSE 0 END) AS emp_2026_k
    FROM labour_force_monthly AS lfm
    INNER JOIN provinces AS p
        ON lfm.province_id = p.province_id
    INNER JOIN industries AS i
        ON lfm.industry_id = i.industry_id
    WHERE lfm.report_date IN ('2023-03-01', '2026-03-01')
    GROUP BY
        p.region,
        i.naics_code,
        i.industry_name
),
rollup_union AS (
    -- Detail rows: Region x Industry
    SELECT
        1 AS sort_group,
        region,
        naics_code,
        industry_name,
        ROUND(emp_2023_k, 1) AS emp_2023_k,
        ROUND(emp_2026_k, 1) AS emp_2026_k,
        ROUND(emp_2026_k - emp_2023_k, 1) AS net_jobs_created_k,
        ROUND((emp_2026_k - emp_2023_k) * 100.0 / emp_2023_k, 2) AS growth_pct_2023_2026
    FROM endpoints

    UNION ALL

    -- Regional Subtotals
    SELECT
        2 AS sort_group,
        region,
        'SUBTOTAL' AS naics_code,
        '[Regional Subtotal]' AS industry_name,
        ROUND(SUM(emp_2023_k), 1) AS emp_2023_k,
        ROUND(SUM(emp_2026_k), 1) AS emp_2026_k,
        ROUND(SUM(emp_2026_k - emp_2023_k), 1) AS net_jobs_created_k,
        ROUND(SUM(emp_2026_k - emp_2023_k) * 100.0 / SUM(emp_2023_k), 2) AS growth_pct_2023_2026
    FROM endpoints
    GROUP BY region

    UNION ALL

    -- National Grand Total
    SELECT
        3 AS sort_group,
        'ALL REGIONS' AS region,
        'TOTAL' AS naics_code,
        '[National Grand Total]' AS industry_name,
        ROUND(SUM(emp_2023_k), 1) AS emp_2023_k,
        ROUND(SUM(emp_2026_k), 1) AS emp_2026_k,
        ROUND(SUM(emp_2026_k - emp_2023_k), 1) AS net_jobs_created_k,
        ROUND(SUM(emp_2026_k - emp_2023_k) * 100.0 / SUM(emp_2023_k), 2) AS growth_pct_2023_2026
    FROM endpoints
)
SELECT
    region,
    naics_code,
    industry_name,
    emp_2023_k,
    emp_2026_k,
    net_jobs_created_k,
    growth_pct_2023_2026
FROM rollup_union
ORDER BY
    CASE WHEN region = 'ALL REGIONS' THEN 1 ELSE 0 END,
    region,
    sort_group,
    net_jobs_created_k DESC;
