-- Computes top truck-food OD flows from FAF.
-- Food commodity set uses SCTG2 01-08.
-- Weighting fields are tons_2024 and tmiles_2024.

WITH base AS (
  SELECT
    LPAD(CAST(dms_orig AS STRING), 3, '0') AS origin_id,
    LPAD(CAST(dms_dest AS STRING), 3, '0') AS dest_id,
    CAST(dms_mode AS STRING) AS mode_code,
    LPAD(CAST(sctg2 AS STRING), 2, '0') AS sctg2,
    CAST(dist_band AS INT64) AS dist_band,
    CAST(tons_2024 AS FLOAT64) AS tons,
    CAST(tmiles_2024 AS FLOAT64) AS ton_miles
  FROM `{{TABLE_FQN}}`
  WHERE tons_2024 IS NOT NULL
    AND tons_2024 > 0
),
filtered AS (
  SELECT
    origin_id,
    dest_id,
    tons,
    IFNULL(ton_miles, 0) AS ton_miles,
    CASE dist_band
      WHEN 1 THEN 25
      WHEN 2 THEN 75
      WHEN 3 THEN 175
      WHEN 4 THEN 375
      WHEN 5 THEN 625
      WHEN 6 THEN 875
      WHEN 7 THEN 1250
      WHEN 8 THEN 1750
      WHEN 9 THEN 2250
      ELSE NULL
    END AS distance_miles
  FROM base
  WHERE mode_code = '1'
    AND sctg2 IN ('01','02','03','04','05','06','07','08')
    AND dist_band BETWEEN 1 AND 9
),
scenario_rows AS (
  SELECT origin_id, dest_id, tons, ton_miles, distance_miles, 'CENTRALIZED' AS scenario_id FROM filtered
  UNION ALL
  SELECT origin_id, dest_id, tons, ton_miles, distance_miles, 'REGIONALIZED' AS scenario_id FROM filtered WHERE distance_miles <= 375
),
agg AS (
  SELECT
    origin_id,
    dest_id,
    scenario_id,
    SUM(tons) AS tons,
    SUM(ton_miles) AS ton_miles,
    SAFE_DIVIDE(SUM(distance_miles * tons), SUM(tons)) AS distance_miles
  FROM scenario_rows
  GROUP BY origin_id, dest_id, scenario_id
),
ranked AS (
  SELECT
    *,
    ROW_NUMBER() OVER (PARTITION BY scenario_id ORDER BY tons DESC, ton_miles DESC) AS rn
  FROM agg
)
SELECT
  origin_id,
  dest_id,
  tons,
  ton_miles,
  distance_miles,
  'food_sctg_01_08' AS commodity_group,
  'truck' AS mode,
  2024 AS year,
  scenario_id
FROM ranked
WHERE rn <= {{TOP_N}}
ORDER BY scenario_id, tons DESC, ton_miles DESC;
