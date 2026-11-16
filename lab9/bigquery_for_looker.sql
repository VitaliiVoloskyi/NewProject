-- Part 4, Looker Studio demo: a small table to chart (sandbox tables expire after 60 days).
-- First: BigQuery Explorer -> your project -> Create dataset -> ID spry_lab9, location US.
CREATE OR REPLACE TABLE spry_lab9.taxi_payments_monthly AS
SELECT
  DATE_TRUNC(DATE(trip_start_timestamp), MONTH) AS month,
  payment_type,
  COUNT(*)                  AS trips,
  ROUND(SUM(trip_total), 2) AS total_usd
FROM `bigquery-public-data.chicago_taxi_trips.taxi_trips`
WHERE trip_start_timestamp >= TIMESTAMP '2023-01-01'
  AND trip_start_timestamp <  TIMESTAMP '2024-01-01'
GROUP BY month, payment_type;
