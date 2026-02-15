-- Computes FAF-based weighted distance distributions for truck food commodities.
-- Food commodity set: SCTG2 01-08.
-- Weighting defaults to tons_2024; can be switched to tmiles_2024 via {{WEIGHT_COL}}.

WITH base AS (
  SELECT
    CAST(dms_mode AS STRING) AS dms_mode,
    LPAD(CAST(sctg2 AS STRING), 2, '0') AS sctg2,
    CAST(dist_band AS INT64) AS dist_band,
    CAST({{WEIGHT_COL}} AS FLOAT64) AS weight
  FROM `{{TABLE_FQN}}`
  WHERE {{WEIGHT_COL}} IS NOT NULL
    AND {{WEIGHT_COL}} > 0
),
filtered AS (
  SELECT
    sctg2,
    dist_band,
    weight,
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
  WHERE dms_mode = '1'
    AND sctg2 IN ('01','02','03','04','05','06','07','08')
    AND dist_band BETWEEN 1 AND 9
),
scenario_rows AS (
  SELECT 'CENTRALIZED' AS scenario_id, distance_miles, weight FROM filtered
  UNION ALL
  SELECT 'REGIONALIZED' AS scenario_id, distance_miles, weight FROM filtered WHERE dist_band <= 4
),
ordered AS (
  SELECT
    scenario_id,
    distance_miles,
    weight,
    SUM(weight) OVER (
      PARTITION BY scenario_id
      ORDER BY distance_miles
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) / SUM(weight) OVER (PARTITION BY scenario_id) AS cum_w
  FROM scenario_rows
),
quantiles AS (
  SELECT
    scenario_id,
    MIN(IF(cum_w >= 0.05, distance_miles, NULL)) AS p05_miles,
    MIN(IF(cum_w >= 0.50, distance_miles, NULL)) AS p50_miles,
    MIN(IF(cum_w >= 0.95, distance_miles, NULL)) AS p95_miles
  FROM ordered
  GROUP BY scenario_id
),
moments AS (
  SELECT
    scenario_id,
    SUM(distance_miles * weight) / SUM(weight) AS mean_miles,
    MIN(distance_miles) AS min_miles,
    MAX(distance_miles) AS max_miles,
    COUNT(*) AS n_records,
    SUM(weight) AS weight_total
  FROM scenario_rows
  GROUP BY scenario_id
)
SELECT
  m.scenario_id,
  q.p05_miles,
  q.p50_miles,
  q.p95_miles,
  m.mean_miles,
  m.min_miles,
  m.max_miles,
  m.n_records,
  m.weight_total
FROM moments m
JOIN quantiles q USING (scenario_id)
ORDER BY scenario_id;
