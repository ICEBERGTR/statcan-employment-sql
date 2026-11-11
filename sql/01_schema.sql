-- ============================================================================
-- File: sql/01_schema.sql
-- Project: StatCan Employment Data Analysis (Labour Force Survey & JVWS)
-- Description: Relational schema definition (DDL) for provincial and NAICS
--              industry employment, wage, and job vacancy tracking.
-- Target DBMS: PostgreSQL 14+ (compatible with SQLite 3.35+ for local testing)
-- ============================================================================

-- Drop views and tables in reverse dependency order for clean re-runs
DROP VIEW IF EXISTS vw_tech_vs_traditional_tightness;
DROP VIEW IF EXISTS vw_industry_national_summary;
DROP VIEW IF EXISTS vw_provincial_monthly_summary;

DROP TABLE IF EXISTS labour_force_monthly;
DROP TABLE IF EXISTS industries;
DROP TABLE IF EXISTS provinces;

-- ----------------------------------------------------------------------------
-- 1. Dimension Table: provinces
-- Stores Canadian provinces and their broader Statistics Canada economic region.
-- ----------------------------------------------------------------------------
CREATE TABLE provinces (
    province_id   INTEGER      PRIMARY KEY,
    province_code CHAR(2)     NOT NULL UNIQUE,
    province_name VARCHAR(60) NOT NULL UNIQUE,
    region        VARCHAR(40) NOT NULL,
    CONSTRAINT chk_province_code_format
        CHECK (province_code IN ('ON', 'QC', 'BC', 'AB', 'MB', 'SK', 'NS', 'NB', 'NL', 'PE'))
);

-- ----------------------------------------------------------------------------
-- 2. Dimension Table: industries
-- Stores North American Industry Classification System (NAICS) 2-digit sectors.
-- ----------------------------------------------------------------------------
CREATE TABLE industries (
    industry_id   INTEGER      PRIMARY KEY,
    naics_code    VARCHAR(10)  NOT NULL UNIQUE,
    industry_name VARCHAR(100) NOT NULL UNIQUE
);

-- ----------------------------------------------------------------------------
-- 3. Fact Table: labour_force_monthly
-- Monthly observation grain: one row per (report_date, province_id, industry_id).
-- Combines core Labour Force Survey (LFS) counts (in thousands) with average
-- hourly wages and Job Vacancy and Wage Survey (JVWS) vacancy counts.
-- ----------------------------------------------------------------------------
CREATE TABLE labour_force_monthly (
    record_id              INTEGER       PRIMARY KEY,
    report_date            DATE          NOT NULL,
    province_id            INTEGER       NOT NULL,
    industry_id            INTEGER       NOT NULL,
    labour_force_thousands NUMERIC(8, 1) NOT NULL,
    employed_thousands     NUMERIC(8, 1) NOT NULL,
    unemployed_thousands   NUMERIC(8, 1) NOT NULL,
    unemployment_rate      NUMERIC(5, 2) NOT NULL,
    avg_hourly_wage        NUMERIC(6, 2) NOT NULL,
    job_vacancies          INT           NOT NULL,

    -- Referential integrity to dimension tables
    CONSTRAINT fk_lfm_province
        FOREIGN KEY (province_id) REFERENCES provinces (province_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_lfm_industry
        FOREIGN KEY (industry_id) REFERENCES industries (industry_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,

    -- Prevent duplicate monthly entries for the same province and NAICS sector
    CONSTRAINT uq_lfm_date_province_industry
        UNIQUE (report_date, province_id, industry_id),

    -- Domain integrity constraints
    CONSTRAINT chk_lfm_counts_non_negative
        CHECK (
            labour_force_thousands > 0
            AND employed_thousands >= 0
            AND unemployed_thousands >= 0
            AND job_vacancies >= 0
        ),
    CONSTRAINT chk_lfm_unemployment_rate_bounds
        CHECK (unemployment_rate >= 0.00 AND unemployment_rate <= 100.00),
    CONSTRAINT chk_lfm_hourly_wage_positive
        CHECK (avg_hourly_wage > 0.00)
);

-- ----------------------------------------------------------------------------
-- 4. Composite Indexes for Analytical & Window Queries
-- Key order matches PARTITION BY <id> ORDER BY report_date so PostgreSQL can
-- satisfy window sorting and date-range scans via index-ordered reads.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_lfm_province_date
    ON labour_force_monthly (province_id, report_date);

CREATE INDEX idx_lfm_industry_date
    ON labour_force_monthly (industry_id, report_date);
