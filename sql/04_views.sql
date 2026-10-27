-- =============================================================================
-- 04_views.sql
-- Purpose : Define the project's revenue logic once, as reusable views.
-- Run     : psql -d retail_analytics -f sql/04_views.sql
--
-- Revenue definitions (used by every analysis)
--   sales scope      only orders with order_status = 'completed', dated inside
--                    the analysis window, that have at least one order line.
--                    cancelled and pending (unpaid) orders are excluded.
--   gross_sales      quantity * unit_price, before discounts and returns
--   discount_amount  order_items.discount_amount
--   checkout_value   gross_sales - discount_amount (what the customer paid)
--   refunded_amount  refunds on returns with return_status = 'refunded',
--                    capped at the line's checkout_value (guards against the
--                    over-refund data issue found in 03_data_quality_checks.sql)
--   net_sales        gross_sales - discount_amount - refunded_amount
--   units_returned   units on all return requests (refunded or rejected),
--                    capped at the quantity purchased
--
-- Timing: refunds are attributed to the month of the ORIGINAL ORDER, not the
-- month the return was received. Net sales for recent months can therefore
-- still fall as late returns arrive.
--
-- Partially returned lines keep their sale minus the refund. Fully returned
-- lines net to zero, but their order still counts as an order.
-- =============================================================================

\set ON_ERROR_STOP on
SET search_path TO retail;

DROP VIEW IF EXISTS
    v_customer_rfm,
    v_customer_summary,
    v_monthly_sales,
    v_orders,
    v_order_lines,
    v_analysis_window
CASCADE;

-- -----------------------------------------------------------------------------
-- v_analysis_window: the single place where the date range is defined.
-- rfm_reference_date is the "as of" date used to measure recency.
-- -----------------------------------------------------------------------------
CREATE VIEW v_analysis_window AS
SELECT DATE '2024-01-01' AS window_start,
       DATE '2025-06-30' AS window_end,
       DATE '2025-07-01' AS rfm_reference_date;

-- -----------------------------------------------------------------------------
-- v_order_lines: one row per order line in sales scope, with revenue measures
-- and the customer and product attributes needed for slicing.
-- -----------------------------------------------------------------------------
CREATE VIEW v_order_lines AS
WITH return_totals AS (
    SELECT r.order_item_id,
           SUM(r.quantity_returned) AS units_returned_raw,
           COALESCE(SUM(r.refund_amount) FILTER (WHERE r.return_status = 'refunded'), 0)
               AS refunded_raw
    FROM returns AS r
    GROUP BY r.order_item_id
),
lines AS (
    SELECT oi.order_item_id,
           o.order_id,
           o.customer_id,
           o.order_date,
           date_trunc('month', o.order_date)::date                 AS order_month,
           o.sales_channel,
           COALESCE(c.region, 'Unknown')                           AS region,
           c.customer_segment,
           p.product_id,
           p.product_name,
           p.category,
           oi.quantity,
           oi.unit_price,
           oi.quantity * oi.unit_price                             AS gross_sales,
           oi.discount_amount,
           oi.quantity * oi.unit_price - oi.discount_amount        AS checkout_value,
           LEAST(COALESCE(rt.units_returned_raw, 0), oi.quantity)  AS units_returned,
           LEAST(COALESCE(rt.refunded_raw, 0),
                 oi.quantity * oi.unit_price - oi.discount_amount) AS refunded_amount,
           COALESCE(rt.refunded_raw, 0)
               > oi.quantity * oi.unit_price - oi.discount_amount  AS refund_was_capped
    FROM order_items AS oi
    JOIN orders      AS o  ON o.order_id    = oi.order_id
    JOIN customers   AS c  ON c.customer_id = o.customer_id
    JOIN products    AS p  ON p.product_id  = oi.product_id
    LEFT JOIN return_totals AS rt ON rt.order_item_id = oi.order_item_id
    CROSS JOIN v_analysis_window AS w
    WHERE o.order_status = 'completed'
      AND o.order_date BETWEEN w.window_start AND w.window_end
)
SELECT lines.*,
       lines.checkout_value - lines.refunded_amount AS net_sales
FROM lines;

-- -----------------------------------------------------------------------------
-- v_orders: one row per order in sales scope.
-- line_count = number of distinct products; item_count = total units.
-- -----------------------------------------------------------------------------
CREATE VIEW v_orders AS
SELECT order_id,
       customer_id,
       order_date,
       order_month,
       sales_channel,
       region,
       customer_segment,
       COUNT(*)                   AS line_count,
       SUM(quantity)              AS item_count,
       SUM(gross_sales)           AS gross_sales,
       SUM(discount_amount)       AS discount_amount,
       SUM(checkout_value)        AS checkout_value,
       SUM(refunded_amount)       AS refunded_amount,
       SUM(net_sales)             AS net_sales,
       SUM(units_returned)        AS units_returned,
       SUM(discount_amount) > 0   AS has_discount,
       ROUND(SUM(discount_amount) / NULLIF(SUM(gross_sales), 0), 4) AS discount_rate
FROM v_order_lines
GROUP BY order_id, customer_id, order_date, order_month,
         sales_channel, region, customer_segment;

-- -----------------------------------------------------------------------------
-- v_monthly_sales: one row per calendar month in the window, including any
-- month with no sales (generate_series + LEFT JOIN), so gaps are visible.
-- avg_order_value     = checkout_value / orders (value at checkout)
-- avg_net_order_value = net_sales / orders (after refunds)
-- -----------------------------------------------------------------------------
CREATE VIEW v_monthly_sales AS
WITH months AS (
    SELECT gs::date AS order_month
    FROM v_analysis_window AS w,
         generate_series(date_trunc('month', w.window_start),
                         date_trunc('month', w.window_end),
                         INTERVAL '1 month') AS gs
),
monthly AS (
    SELECT order_month,
           COUNT(*)                    AS orders,
           COUNT(DISTINCT customer_id) AS active_customers,
           SUM(item_count)             AS items,
           SUM(gross_sales)            AS gross_sales,
           SUM(discount_amount)        AS discount_amount,
           SUM(checkout_value)         AS checkout_value,
           SUM(refunded_amount)        AS refunded_amount,
           SUM(net_sales)              AS net_sales
    FROM v_orders
    GROUP BY order_month
)
SELECT m.order_month,
       COALESCE(mo.orders, 0)           AS orders,
       COALESCE(mo.active_customers, 0) AS active_customers,
       COALESCE(mo.items, 0)            AS items,
       COALESCE(mo.gross_sales, 0)      AS gross_sales,
       COALESCE(mo.discount_amount, 0)  AS discount_amount,
       COALESCE(mo.refunded_amount, 0)  AS refunded_amount,
       COALESCE(mo.net_sales, 0)        AS net_sales,
       ROUND(mo.checkout_value / NULLIF(mo.orders, 0), 2) AS avg_order_value,
       ROUND(mo.net_sales      / NULLIF(mo.orders, 0), 2) AS avg_net_order_value
FROM months AS m
LEFT JOIN monthly AS mo ON mo.order_month = m.order_month;

-- -----------------------------------------------------------------------------
-- v_customer_summary: one row per customer, INCLUDING customers with no orders
-- in sales scope (order_count = 0). cohort_month = month of first order in scope.
-- -----------------------------------------------------------------------------
CREATE VIEW v_customer_summary AS
SELECT c.customer_id,
       c.signup_date,
       COALESCE(c.region, 'Unknown')                  AS region,
       c.customer_segment,
       MIN(o.order_date)                              AS first_order_date,
       MAX(o.order_date)                              AS last_order_date,
       date_trunc('month', MIN(o.order_date))::date   AS cohort_month,
       COUNT(o.order_id)                              AS order_count,
       COALESCE(SUM(o.checkout_value), 0)             AS checkout_value,
       COALESCE(SUM(o.net_sales), 0)                  AS net_sales
FROM customers AS c
LEFT JOIN v_orders AS o ON o.customer_id = c.customer_id
GROUP BY c.customer_id, c.signup_date, c.region, c.customer_segment;

-- -----------------------------------------------------------------------------
-- v_customer_rfm: recency, frequency and monetary scores for purchasing customers.
--   recency_days  days from last order to rfm_reference_date (lower is better)
--   frequency     number of orders in scope
--   monetary      net sales in scope
-- Scores run 1 (weakest) to 5 (strongest).
--   r_score, m_score: quintiles via NTILE(5). Ties are split by customer_id,
--                     so equal customers can land in adjacent quintiles.
--   f_score: fixed thresholds, because most customers have 1-2 orders and
--            quintiles would split identical order counts arbitrarily.
-- -----------------------------------------------------------------------------
CREATE VIEW v_customer_rfm AS
WITH base AS (
    SELECT cs.customer_id,
           cs.region,
           cs.customer_segment,
           w.rfm_reference_date - cs.last_order_date AS recency_days,
           cs.order_count                            AS frequency,
           cs.net_sales                              AS monetary
    FROM v_customer_summary AS cs
    CROSS JOIN v_analysis_window AS w
    WHERE cs.order_count > 0
),
scored AS (
    SELECT base.*,
           NTILE(5) OVER (ORDER BY recency_days DESC, customer_id) AS r_score,
           CASE
               WHEN frequency >= 6 THEN 5
               WHEN frequency >= 4 THEN 4
               WHEN frequency = 3  THEN 3
               WHEN frequency = 2  THEN 2
               ELSE 1
           END                                                     AS f_score,
           NTILE(5) OVER (ORDER BY monetary, customer_id)          AS m_score
    FROM base
)
SELECT scored.*,
       CONCAT(r_score, f_score, m_score) AS rfm_code,
       CASE
           WHEN r_score >= 4 AND f_score >= 4 THEN 'champions'
           WHEN r_score >= 3 AND f_score >= 3 THEN 'loyal'
           WHEN r_score >= 4 AND f_score <= 2 THEN 'recent_low_frequency'
           WHEN r_score <= 2 AND f_score >= 3 THEN 'at_risk'
           WHEN r_score <= 2 AND f_score <= 2 THEN 'hibernating'
           ELSE 'needs_attention'
       END AS rfm_segment
FROM scored;

-- -----------------------------------------------------------------------------
-- Reconciliation check: run after creating the views.
-- Expected values for the default dataset (seed 42) were computed independently
-- from the CSV files with Python, applying the same definitions. If your
-- results differ, the load or the views need investigating before any analysis.
--   in_scope_orders      2307      units_sold        7905
--   purchasing_customers  884      units_returned     383
--   gross_sales     131780.16      refunded_amount   10737.96
--   discount_amount   6837.70      net_sales        114204.50
--   customers_with_no_in_scope_orders  116
-- -----------------------------------------------------------------------------
SELECT COUNT(DISTINCT order_id)    AS in_scope_orders,
       COUNT(DISTINCT customer_id) AS purchasing_customers,
       SUM(quantity)               AS units_sold,
       SUM(units_returned)         AS units_returned,
       SUM(gross_sales)            AS gross_sales,
       SUM(discount_amount)        AS discount_amount,
       SUM(refunded_amount)        AS refunded_amount,
       SUM(net_sales)              AS net_sales,
       (SELECT COUNT(*) FROM v_customer_summary WHERE order_count = 0)
                                   AS customers_with_no_in_scope_orders
FROM v_order_lines;
