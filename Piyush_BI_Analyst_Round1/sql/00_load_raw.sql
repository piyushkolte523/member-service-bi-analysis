/* =====================================================================
   00_load_raw.sql  -  Land the source data exactly as delivered
   Engine : DuckDB (1.x)        Run from the project root folder.
   ---------------------------------------------------------------------
   Design choice: the RAW layer is loaded as all-VARCHAR. Nothing is
   typed, trimmed or de-duplicated here, so profiling in 01 can detect
   bad casts, stray casing/whitespace and duplicates instead of having
   them silently "fixed" (or rejected) by the loader.
   Layers:  raw_*  (as delivered)  ->  stg_*  (clean, typed)  ->  analysis_*
   ===================================================================== */

CREATE OR REPLACE TABLE raw_members AS
SELECT * FROM read_csv('data/members_raw.csv',
                       header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw_interactions AS
SELECT * FROM read_csv('data/interactions_raw.csv',
                       header = true, all_varchar = true);

CREATE OR REPLACE TABLE raw_targets AS
SELECT * FROM read_csv('data/targets_raw.csv',
                       header = true, all_varchar = true);

-- Load check: row counts must match the workbook (400 / 4004 / 24)
SELECT 'raw_members'      AS table_name, COUNT(*) AS row_count FROM raw_members
UNION ALL
SELECT 'raw_interactions',               COUNT(*)              FROM raw_interactions
UNION ALL
SELECT 'raw_targets',                    COUNT(*)              FROM raw_targets;
