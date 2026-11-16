-- Part 4, BigQuery demo: the Lab 8 question (payments per method) over a public dataset.
-- Run in the BigQuery console (sandbox is enough) and note "Bytes processed" in Job information.
-- Chicago taxi trips, 2023: trips and money per payment type.
SELECT
  payment_type,
  COUNT(*)                                  AS trips,
  ROUND(SUM(trip_total), 2)                 AS total_usd,
  ROUND(AVG(tips), 2)                       AS avg_tip_usd,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS share_pct
FROM `bigquery-public-data.chicago_taxi_trips.taxi_trips`
WHERE trip_start_timestamp >= TIMESTAMP '2023-01-01'
  AND trip_start_timestamp <  TIMESTAMP '2024-01-01'
GROUP BY payment_type
ORDER BY trips DESC;
