-- ============================================================================
-- File: sql/04_views.sql
-- Project: StatCan Employment Data Analysis
-- Description: Reusable reporting views for provincial labour market rollups,
--              national NAICS industry summaries, and sector tightness metrics.
-- ============================================================================

DROP VIEW IF EXISTS vw_tech_vs_traditional_tightness;
DROP VIEW IF EXISTS vw_industry_national_summary;
DROP VIEW IF EXISTS vw_provincial_monthly_summary;

-- ----------------------------------------------------------------------------
-- View 1: vw_provincial_monthly_summary
-- Aggregates sector-level observations to one row per (report_date, province)
-- with labour-force-weighted unemployment rates and employment-weighted wages.
-- ----------------------------------------------------------------------------
CREATE VIEW vw_provincial_monthly_summary AS
SELECT
    lfm.report_date,
    p.province_id,
    p.province_code,
    p.province_name,
    p.region,
    ROUND(SUM(lfm.labour_force_thousands), 1) AS total_labour_force_k,
    ROUND(SUM(lfm.employed_thousands), 1)     AS total_employed_k,
    ROUND(SUM(lfm.unemployed_thousands), 1)   AS total_unemployed_k,
    ROUND(
        SUM(lfm.unemployed_thousands) * 100.0 / SUM(lfm.labour_force_thousands),
        2
    ) AS weighted_unemployment_rate,
    ROUND(
        SUM(lfm.avg_hourly_wage * lfm.employed_thousands) / SUM(lfm.employed_thousands),
        2
    ) AS weighted_avg_hourly_wage,
    SUM(lfm.job_vacancies) AS total_job_vacancies
FROM labour_force_monthly AS lfm
INNER JOIN provinces AS p
    ON lfm.province_id = p.province_id
GROUP BY
    lfm.report_date,
    p.province_id,
    p.province_code,
    p.province_name,
    p.region;

-- ----------------------------------------------------------------------------
-- View 2: vw_industry_national_summary
-- Aggregates provincial rows up to the national NAICS industry level per month.
-- ----------------------------------------------------------------------------
CREATE VIEW vw_industry_national_summary AS
SELECT
    lfm.report_date,
    i.industry_id,
    i.naics_code,
    i.industry_name,
    ROUND(SUM(lfm.labour_force_thousands), 1) AS national_labour_force_k,
    ROUND(SUM(lfm.employed_thousands), 1)     AS national_employed_k,
    ROUND(SUM(lfm.unemployed_thousands), 1)   AS national_unemployed_k,
    ROUND(
        SUM(lfm.unemployed_thousands) * 100.0 / SUM(lfm.labour_force_thousands),
        2
    ) AS national_sector_unemp_rate,
    ROUND(
        SUM(lfm.avg_hourly_wage * lfm.employed_thousands) / SUM(lfm.employed_thousands),
        2
    ) AS national_weighted_wage,
    SUM(lfm.job_vacancies) AS national_job_vacancies
FROM labour_force_monthly AS lfm
INNER JOIN industries AS i
    ON lfm.industry_id = i.industry_id
GROUP BY
    lfm.report_date,
    i.industry_id,
    i.naics_code,
    i.industry_name;

-- ----------------------------------------------------------------------------
-- View 3: vw_tech_vs_traditional_tightness
-- Compares vacancy-to-unemployment tightness between knowledge/tech industries
-- (NAICS 54, 51) and traditional sectors (NAICS 31-33, 62, 23) over time.
-- ----------------------------------------------------------------------------
CREATE VIEW vw_tech_vs_traditional_tightness AS
SELECT
    lfm.report_date,
    CASE
        WHEN i.naics_code IN ('54', '51') THEN 'Tech & Knowledge Sectors'
        ELSE 'Traditional & Essential Sectors'
    END AS sector_group,
    ROUND(SUM(lfm.employed_thousands), 1)   AS employed_thousands,
    ROUND(SUM(lfm.unemployed_thousands), 1) AS unemployed_thousands,
    SUM(lfm.job_vacancies)                  AS total_vacancies,
    ROUND(
        SUM(lfm.job_vacancies) * 1.0 / (SUM(lfm.unemployed_thousands) * 1000.0),
        2
    ) AS vacancy_to_unemployed_ratio,
    ROUND(
        SUM(lfm.avg_hourly_wage * lfm.employed_thousands) / SUM(lfm.employed_thousands),
        2
    ) AS weighted_avg_wage
FROM labour_force_monthly AS lfm
INNER JOIN industries AS i
    ON lfm.industry_id = i.industry_id
GROUP BY
    lfm.report_date,
    CASE
        WHEN i.naics_code IN ('54', '51') THEN 'Tech & Knowledge Sectors'
        ELSE 'Traditional & Essential Sectors'
    END;
