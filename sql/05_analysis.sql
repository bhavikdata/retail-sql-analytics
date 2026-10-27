-- =============================================================================
-- 05_analysis.sql
-- Purpose : Answer the project's business questions using the views in
--           04_views.sql.
-- Run     : psql -d retail_analytics -f sql/05_analysis.sql
--           (or run one query at a time in psql, pgAdmin or DBeaver)
--
-- Every analysis block states: the question, the metric and its assumptions,
-- how to read the result, and at least one caveat.
--
-- Global reminders
--   * Data is synthetic. Patterns reflect rules written into
--     scripts/generate_data.py (see data/README.md), not real customers.
--   * Window: 2024-01-01 to 2025-06-30. Sales scope and revenue definitions
--     are documented at the top of 04_views.sql.
--   * All customers sign up inside the window, so early months have a small
--     customer base. Growth over time is partly an artefact of that.
-- =============================================================================

\set ON_ERROR_STOP on
SET search_path TO retail;


-- =============================================================================
-- ANALYSIS 1: Monthly sales and order trends
-- -----------------------------------------------------------------------------
-- Question : How do orders, gross sales, discounts, refunds and net sales
--            change month to month?
-- Metric   : Monthly totals from v_monthly_sales. Month-on-month growth uses
--            LAG; cumulative net sales uses a running SUM window; a 3-month
--            moving average smooths noise.
-- Read it  : Compare net_sales with gross_sales to see how much discounts and
--            refunds erode revenue each month. mom_growth_pct is NULL for the
--            first month because there is no prior month.
-- Caveat   : Refunds sit in the original order month, so the latest months
--            may be understated until late returns arrive. Growth in 2024 is
--            partly because the customer base starts at zero.
-- =============================================================================
SELECT order_month,
       orders,
       items,
       gross_sales,
       discount_amount,
       refunded_amount,
       net_sales,
       LAG(net_sales) OVER w                                        AS prev_month_net_sales,
       ROUND(100.0 * (net_sales - LAG(net_sales) OVER w)
             / NULLIF(LAG(net_sales) OVER w, 0), 1)                 AS mom_growth_pct,
       ROUND(AVG(net_sales) OVER (ORDER BY order_month
                                  ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)
                                                                    AS net_sales_3m_avg,
       SUM(net_sales) OVER (ORDER BY order_month
                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                                                    AS cumulative_net_sales
FROM v_monthly_sales
WINDOW w AS (ORDER BY order_month)
ORDER BY order_month;

-- 1b. Order status mix by month (all statuses, from the raw orders table).
-- Cancelled and pending orders are not sales but show demand lost or delayed.
SELECT date_trunc('month', o.order_date)::date                          AS order_month,
       COUNT(*)                                                         AS all_orders,
       COUNT(*) FILTER (WHERE o.order_status = 'completed')             AS completed_orders,
       COUNT(*) FILTER (WHERE o.order_status = 'cancelled')             AS cancelled_orders,
       COUNT(*) FILTER (WHERE o.order_status = 'pending')               AS pending_orders,
       ROUND(100.0 * COUNT(*) FILTER (WHERE o.order_status = 'cancelled')
             / NULLIF(COUNT(*), 0), 1)                                  AS cancellation_rate_pct
FROM orders AS o
CROSS JOIN v_analysis_window AS w
WHERE o.order_date BETWEEN w.window_start AND w.window_end
GROUP BY date_trunc('month', o.order_date)::date
ORDER BY order_month;

-- 1c. New versus returning customer revenue by month.
-- "New" = the order falls in the customer's first purchase month.
-- This separates growth from acquisition and growth from repeat buying.
SELECT o.order_month,
       COUNT(*) FILTER (WHERE o.order_month =  cs.cohort_month)         AS orders_new_customers,
       COUNT(*) FILTER (WHERE o.order_month >  cs.cohort_month)         AS orders_returning_customers,
       COALESCE(SUM(o.net_sales) FILTER (WHERE o.order_month =  cs.cohort_month), 0)
                                                                        AS net_sales_new_customers,
       COALESCE(SUM(o.net_sales) FILTER (WHERE o.order_month >  cs.cohort_month), 0)
                                                                        AS net_sales_returning_customers
FROM v_orders AS o
JOIN v_customer_summary AS cs ON cs.customer_id = o.customer_id
GROUP BY o.order_month
ORDER BY o.order_month;


-- =============================================================================
-- ANALYSIS 2: Category and product performance
-- -----------------------------------------------------------------------------
-- Question : Which categories and products contribute most to net revenue?
-- Metric   : Net sales by category with share of total (SUM(...) OVER ()),
--            ranked with RANK. Products ranked within category with DENSE_RANK.
--            A Pareto view shows cumulative share of net sales by product.
-- Read it  : A small number of products holding a large cumulative share
--            signals concentration risk. Compare category share of net sales
--            with share of units: cheap, high-volume categories can rank high on
--            units but low on revenue.
-- Caveat   : Net sales is not profit. unit_cost exists but margin analysis is
--            out of scope (see Next steps in README). Product popularity is
--            randomly assigned by the generator.
-- =============================================================================
SELECT category,
       COUNT(DISTINCT order_id)                                        AS orders_containing_category,
       SUM(quantity)                                                   AS units_sold,
       SUM(gross_sales)                                                AS gross_sales,
       SUM(discount_amount)                                            AS discount_amount,
       SUM(refunded_amount)                                            AS refunded_amount,
       SUM(net_sales)                                                  AS net_sales,
       ROUND(100.0 * SUM(net_sales) / NULLIF(SUM(SUM(net_sales)) OVER (), 0), 1)
                                                                       AS net_sales_share_pct,
       ROUND(100.0 * SUM(quantity) / NULLIF(SUM(SUM(quantity)) OVER (), 0), 1)
                                                                       AS units_share_pct,
       RANK() OVER (ORDER BY SUM(net_sales) DESC)                      AS net_sales_rank
FROM v_order_lines
GROUP BY category
ORDER BY net_sales_rank;

-- 2b. Top 3 products in each category by net sales.
WITH product_sales AS (
    SELECT category,
           product_id,
           product_name,
           SUM(quantity)  AS units_sold,
           SUM(net_sales) AS net_sales
    FROM v_order_lines
    GROUP BY category, product_id, product_name
),
ranked AS (
    SELECT ps.*,
           DENSE_RANK() OVER (PARTITION BY category ORDER BY net_sales DESC) AS rank_in_category
    FROM product_sales AS ps
)
SELECT category, rank_in_category, product_name, units_sold, net_sales
FROM ranked
WHERE rank_in_category <= 3
ORDER BY category, rank_in_category, product_name;

-- 2c. Pareto: cumulative share of net sales across all products.
-- Starts from products (LEFT JOIN) so a product with no sales still appears.
WITH product_sales AS (
    SELECT p.product_id,
           p.product_name,
           p.category,
           COALESCE(SUM(l.net_sales), 0) AS net_sales
    FROM products AS p
    LEFT JOIN v_order_lines AS l ON l.product_id = p.product_id
    GROUP BY p.product_id, p.product_name, p.category
)
SELECT RANK() OVER (ORDER BY net_sales DESC)                         AS overall_rank,
       product_name,
       category,
       net_sales,
       ROUND(100.0 * SUM(net_sales) OVER (ORDER BY net_sales DESC, product_id
                                          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
             / NULLIF(SUM(net_sales) OVER (), 0), 1)                 AS cumulative_share_pct
FROM product_sales
ORDER BY overall_rank, product_id;


-- =============================================================================
-- ANALYSIS 3: Average order value (AOV)
-- -----------------------------------------------------------------------------
-- Question : What is the average order value, and how does it vary by month
--            and category?
-- Metric   : AOV = checkout_value / orders (after discounts, before refunds).
--            Median order value is shown too, because a few large baskets can
--            pull the mean up. Net AOV subtracts refunds.
-- Read it  : A gap between mean and median points to a skewed distribution.
--            For categories, compare what customers spend on the category with
--            the value of the whole basket it appears in.
-- Caveat   : An order can contain several categories, so category AOV figures
--            overlap and do not add up to the overall AOV.
-- =============================================================================
SELECT order_month,
       COUNT(*)                                                            AS orders,
       ROUND(AVG(checkout_value), 2)                                       AS avg_order_value,
       ROUND((percentile_cont(0.5) WITHIN GROUP (ORDER BY checkout_value))::numeric, 2)
                                                                           AS median_order_value,
       ROUND(AVG(net_sales), 2)                                            AS avg_net_order_value,
       ROUND(AVG(item_count), 2)                                           AS avg_items_per_order
FROM v_orders
GROUP BY order_month
ORDER BY order_month;

-- 3b. AOV by category.
--   avg_category_spend_per_order : checkout value of that category's lines
--   avg_full_basket_value        : checkout value of the whole order
WITH order_category AS (
    SELECT order_id,
           category,
           SUM(checkout_value) AS category_checkout_value
    FROM v_order_lines
    GROUP BY order_id, category
)
SELECT oc.category,
       COUNT(*)                                  AS orders_with_category,
       ROUND(AVG(oc.category_checkout_value), 2) AS avg_category_spend_per_order,
       ROUND(AVG(o.checkout_value), 2)           AS avg_full_basket_value
FROM order_category AS oc
JOIN v_orders AS o ON o.order_id = oc.order_id
GROUP BY oc.category
ORDER BY avg_full_basket_value DESC;


-- =============================================================================
-- ANALYSIS 4: Repeat-purchase rate
-- -----------------------------------------------------------------------------
-- Question : What share of customers make a repeat purchase?
-- Metric   : repeat_rate = customers with 2+ orders / customers with 1+ order.
--            ROLLUP adds an all-customer total row.
--            4b uses a fixed 90-day window and only customers whose first order
--            was at least 90 days before the window end, so every customer has
--            had the same chance to return.
-- Read it  : 4a is easy to explain but favours customers who joined early.
--            4b is the fairer comparison.
-- Caveat   : Right-censoring: customers who joined late have had less time to
--            return, so 4a understates their eventual repeat rate.
-- =============================================================================
SELECT COALESCE(customer_segment, 'all_customers')                        AS customer_segment,
       COUNT(*)                                                           AS purchasing_customers,
       COUNT(*) FILTER (WHERE order_count >= 2)                           AS repeat_customers,
       ROUND(100.0 * COUNT(*) FILTER (WHERE order_count >= 2)
             / NULLIF(COUNT(*), 0), 1)                                    AS repeat_rate_pct,
       ROUND(AVG(order_count), 2)                                         AS avg_orders_per_customer
FROM v_customer_summary
WHERE order_count > 0
GROUP BY ROLLUP (customer_segment)
ORDER BY GROUPING(customer_segment), customer_segment;

-- 4b. Repeat purchase within 90 days of the first order.
WITH ordered AS (
    SELECT customer_id,
           order_date,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date, order_id) AS order_number
    FROM v_orders
),
first_orders AS (
    SELECT customer_id, order_date AS first_order_date
    FROM ordered
    WHERE order_number = 1
),
second_orders AS (
    SELECT customer_id, order_date AS second_order_date
    FROM ordered
    WHERE order_number = 2
)
SELECT COUNT(*)                                                              AS eligible_customers,
       COUNT(*) FILTER (WHERE so.second_order_date <= fo.first_order_date + 90) AS repeat_within_90_days,
       ROUND(100.0 * COUNT(*) FILTER (WHERE so.second_order_date <= fo.first_order_date + 90)
             / NULLIF(COUNT(*), 0), 1)                                       AS repeat_within_90_days_pct,
       ROUND(AVG(so.second_order_date - fo.first_order_date), 1)             AS avg_days_to_second_order_all_repeaters
FROM first_orders AS fo
LEFT JOIN second_orders AS so ON so.customer_id = fo.customer_id
CROSS JOIN v_analysis_window AS w
WHERE fo.first_order_date <= w.window_end - 90;


-- =============================================================================
-- ANALYSIS 5: Cohort retention
-- -----------------------------------------------------------------------------
-- Question : How does retention change by first-purchase cohort?
-- Metric   : Cohort = month of a customer's first order in scope.
--            month_number = months between cohort month and order month.
--            Retention in month k = customers in the cohort who ordered in
--            month k / cohort size. Month 0 is 100% by definition.
-- Read it  : Read across a row to see how a cohort decays; read down a column
--            to compare cohorts at the same age. NULL means the cohort is not
--            yet old enough to measure that month (not zero retention).
-- Caveat   : Later cohorts are small and have few observable months. Retention
--            here means "placed an order in that month", so customers who buy
--            every other month show as gaps.
-- =============================================================================
WITH customer_cohort AS (
    SELECT customer_id, cohort_month
    FROM v_customer_summary
    WHERE order_count > 0
),
activity AS (
    SELECT DISTINCT
           o.customer_id,
           cc.cohort_month,
           ((EXTRACT(YEAR  FROM o.order_month) - EXTRACT(YEAR  FROM cc.cohort_month)) * 12
          +  EXTRACT(MONTH FROM o.order_month) - EXTRACT(MONTH FROM cc.cohort_month))::int
               AS month_number
    FROM v_orders AS o
    JOIN customer_cohort AS cc ON cc.customer_id = o.customer_id
),
cohort_size AS (
    SELECT cohort_month, COUNT(*) AS cohort_customers
    FROM customer_cohort
    GROUP BY cohort_month
),
last_month AS (
    SELECT date_trunc('month', window_end)::date AS last_observed_month
    FROM v_analysis_window
)
SELECT cs.cohort_month,
       cs.cohort_customers,
       CASE WHEN cs.cohort_month + INTERVAL '1 month' <= lm.last_observed_month
            THEN ROUND(100.0 * COUNT(DISTINCT a.customer_id) FILTER (WHERE a.month_number = 1)
                       / cs.cohort_customers, 1) END  AS m1_pct,
       CASE WHEN cs.cohort_month + INTERVAL '2 months' <= lm.last_observed_month
            THEN ROUND(100.0 * COUNT(DISTINCT a.customer_id) FILTER (WHERE a.month_number = 2)
                       / cs.cohort_customers, 1) END  AS m2_pct,
       CASE WHEN cs.cohort_month + INTERVAL '3 months' <= lm.last_observed_month
            THEN ROUND(100.0 * COUNT(DISTINCT a.customer_id) FILTER (WHERE a.month_number = 3)
                       / cs.cohort_customers, 1) END  AS m3_pct,
       CASE WHEN cs.cohort_month + INTERVAL '6 months' <= lm.last_observed_month
            THEN ROUND(100.0 * COUNT(DISTINCT a.customer_id) FILTER (WHERE a.month_number = 6)
                       / cs.cohort_customers, 1) END  AS m6_pct,
       CASE WHEN cs.cohort_month + INTERVAL '12 months' <= lm.last_observed_month
            THEN ROUND(100.0 * COUNT(DISTINCT a.customer_id) FILTER (WHERE a.month_number = 12)
                       / cs.cohort_customers, 1) END  AS m12_pct
FROM cohort_size AS cs
CROSS JOIN last_month AS lm
LEFT JOIN activity AS a ON a.cohort_month = cs.cohort_month
GROUP BY cs.cohort_month, cs.cohort_customers, lm.last_observed_month
ORDER BY cs.cohort_month;


-- =============================================================================
-- ANALYSIS 6: RFM segmentation
-- -----------------------------------------------------------------------------
-- Question : Which customer groups have the highest recency, frequency and
--            monetary value?
-- Metric   : v_customer_rfm scores each purchasing customer 1-5 on R, F and M
--            (method documented in 04_views.sql) and assigns a rule-based
--            rfm_segment.
-- Read it  : 6a shows how many customers and how much revenue sit in each
--            RFM segment. 6b compares the marketing segments and regions.
-- Caveat   : Segment rules are a judgement call; different thresholds give
--            different groups. Recency is measured at 2025-07-01, so customers
--            who joined recently look "recent" by construction. Small regions
--            have few customers, so their averages are unstable.
-- =============================================================================
SELECT rfm_segment,
       COUNT(*)                                                         AS customers,
       ROUND(100.0 * COUNT(*) / NULLIF(SUM(COUNT(*)) OVER (), 0), 1)    AS customer_share_pct,
       ROUND(AVG(recency_days), 0)                                      AS avg_recency_days,
       ROUND(AVG(frequency), 2)                                         AS avg_orders,
       ROUND(AVG(monetary), 2)                                          AS avg_net_sales,
       SUM(monetary)                                                    AS total_net_sales,
       ROUND(100.0 * SUM(monetary) / NULLIF(SUM(SUM(monetary)) OVER (), 0), 1)
                                                                        AS net_sales_share_pct
FROM v_customer_rfm
GROUP BY rfm_segment
ORDER BY total_net_sales DESC;

-- 6b. Average R, F, M scores by marketing segment and by region.
SELECT 'customer_segment'           AS dimension,
       customer_segment             AS dimension_value,
       COUNT(*)                     AS customers,
       ROUND(AVG(r_score), 2)       AS avg_r_score,
       ROUND(AVG(f_score), 2)       AS avg_f_score,
       ROUND(AVG(m_score), 2)       AS avg_m_score,
       ROUND(AVG(monetary), 2)      AS avg_net_sales
FROM v_customer_rfm
GROUP BY customer_segment
UNION ALL
SELECT 'region', region, COUNT(*),
       ROUND(AVG(r_score), 2), ROUND(AVG(f_score), 2), ROUND(AVG(m_score), 2),
       ROUND(AVG(monetary), 2)
FROM v_customer_rfm
GROUP BY region
ORDER BY dimension, avg_net_sales DESC;


-- =============================================================================
-- ANALYSIS 7: Discounts, order value and net revenue
-- -----------------------------------------------------------------------------
-- Question : How do discounts relate to order value and net revenue?
-- Metric   : Discounted orders (any line discount) vs full-price orders; orders
--            grouped by effective discount rate; monthly correlation between
--            the share of discounted orders and net sales (CORR).
-- Read it  : Compare avg_gross_value (basket before discount) with
--            avg_checkout_value (what customers paid). Larger baskets on
--            discounted orders do not mean the discount caused them.
-- Caveat   : ASSOCIATION IS NOT CAUSATION. Discounts are not randomly
--            assigned: they cluster in November and among budget customers,
--            both of which affect basket size independently. Also, the
--            generator explicitly makes promo orders slightly larger, so any
--            link found here is partly a rule of the simulation. A controlled
--            experiment (A/B test) would be needed to measure a causal effect.
-- =============================================================================
SELECT CASE WHEN has_discount THEN 'discounted' ELSE 'full_price' END   AS order_type,
       COUNT(*)                                                         AS orders,
       ROUND(AVG(gross_sales), 2)                                       AS avg_gross_value,
       ROUND(AVG(checkout_value), 2)                                    AS avg_checkout_value,
       ROUND(AVG(item_count), 2)                                        AS avg_items,
       ROUND(AVG(line_count), 2)                                        AS avg_lines,
       SUM(discount_amount)                                             AS total_discount,
       SUM(net_sales)                                                   AS total_net_sales,
       ROUND(100.0 * SUM(refunded_amount) / NULLIF(SUM(checkout_value), 0), 2)
                                                                        AS refund_rate_pct
FROM v_orders
GROUP BY has_discount
ORDER BY order_type;

-- 7b. Orders by effective discount band.
WITH banded AS (
    SELECT o.*,
           CASE
               WHEN discount_rate = 0     THEN '0: none'
               WHEN discount_rate < 0.125 THEN '1: under 12.5%'
               WHEN discount_rate < 0.175 THEN '2: 12.5% to 17.5%'
               ELSE                            '3: 17.5% or more'
           END AS discount_band
    FROM v_orders AS o
)
SELECT discount_band,
       COUNT(*)                        AS orders,
       ROUND(AVG(gross_sales), 2)      AS avg_gross_value,
       ROUND(AVG(checkout_value), 2)   AS avg_checkout_value,
       ROUND(AVG(net_sales), 2)        AS avg_net_value,
       SUM(net_sales)                  AS total_net_sales
FROM banded
GROUP BY discount_band
ORDER BY discount_band;

-- 7c. Same comparison within each customer segment, a simple control for one
-- known confounder (budget customers use promo codes more often).
SELECT customer_segment,
       ROUND(AVG(checkout_value) FILTER (WHERE has_discount), 2)        AS avg_checkout_discounted,
       ROUND(AVG(checkout_value) FILTER (WHERE NOT has_discount), 2)    AS avg_checkout_full_price,
       COUNT(*) FILTER (WHERE has_discount)                             AS discounted_orders,
       COUNT(*) FILTER (WHERE NOT has_discount)                         AS full_price_orders
FROM v_orders
GROUP BY customer_segment
ORDER BY customer_segment;

-- 7d. Monthly correlation. Only 18 data points, and November is an outlier by
-- design, so treat the coefficient as descriptive only.
WITH monthly AS (
    SELECT order_month,
           AVG(CASE WHEN has_discount THEN 1.0 ELSE 0.0 END) AS share_discounted,
           COUNT(*)                                          AS orders,
           SUM(net_sales)                                    AS net_sales
    FROM v_orders
    GROUP BY order_month
)
SELECT COUNT(*)                                                             AS months,
       ROUND(CORR(share_discounted::float8, net_sales::float8)::numeric, 3) AS corr_discount_share_net_sales,
       ROUND(CORR(share_discounted::float8, orders::float8)::numeric, 3)    AS corr_discount_share_orders
FROM monthly;


-- =============================================================================
-- ANALYSIS 8: Returns
-- -----------------------------------------------------------------------------
-- Question : Which products have high sales but also high return rates?
-- Metric   : return_rate = units_returned / units_sold (all return requests,
--            refunded or rejected, capped per line). Sales ranking uses
--            checkout value (before refunds) via PERCENT_RANK. A product is
--            flagged when it is in the top half by sales, its return rate is at
--            least 1.5x the overall rate, and it sold at least 30 units.
-- Read it  : Flagged products lose the most revenue to returns and are the
--            first candidates for quality or listing-description reviews.
-- Caveat   : The 1.5x and 30-unit thresholds are judgement calls. Returns
--            arriving after 2025-06-30 are missing, so recent sales look
--            better than they will. Three products have high return rates by
--            design in the generator.
-- =============================================================================
WITH product_returns AS (
    SELECT p.product_id,
           p.product_name,
           p.category,
           COALESCE(SUM(l.quantity), 0)        AS units_sold,
           COALESCE(SUM(l.units_returned), 0)  AS units_returned,
           COALESCE(SUM(l.checkout_value), 0)  AS checkout_value,
           COALESCE(SUM(l.refunded_amount), 0) AS refunded_amount,
           COALESCE(SUM(l.net_sales), 0)       AS net_sales
    FROM products AS p
    LEFT JOIN v_order_lines AS l ON l.product_id = p.product_id
    GROUP BY p.product_id, p.product_name, p.category
),
overall AS (
    SELECT SUM(units_returned)::numeric / NULLIF(SUM(units_sold), 0) AS overall_return_rate
    FROM product_returns
),
scored AS (
    SELECT pr.*,
           pr.units_returned::numeric / NULLIF(pr.units_sold, 0) AS return_rate,
           PERCENT_RANK() OVER (ORDER BY pr.checkout_value)      AS sales_percentile
    FROM product_returns AS pr
)
SELECT s.product_name,
       s.category,
       s.units_sold,
       s.units_returned,
       ROUND(100 * s.return_rate, 1)                  AS return_rate_pct,
       ROUND(100 * o.overall_return_rate, 1)          AS overall_return_rate_pct,
       s.checkout_value,
       s.refunded_amount,
       s.net_sales,
       ROUND((100 * s.sales_percentile)::numeric, 0)  AS sales_percentile,
       CASE
           WHEN s.sales_percentile >= 0.5
            AND s.return_rate >= 1.5 * o.overall_return_rate
            AND s.units_sold >= 30
           THEN 'high sales, high returns'
           ELSE ''
       END                                            AS flag
FROM scored AS s
CROSS JOIN overall AS o
ORDER BY s.return_rate DESC NULLS LAST, s.checkout_value DESC;

-- 8b. Return reasons by category (return requests on in-scope order lines).
-- Uses raw return records, so the over-quantity data issue is included here.
SELECT l.category,
       r.return_reason,
       COUNT(*)                                                         AS return_requests,
       SUM(r.quantity_returned)                                         AS units_requested,
       SUM(r.refund_amount)                                             AS refunded_amount,
       ROUND(100.0 * COUNT(*) / NULLIF(SUM(COUNT(*)) OVER (PARTITION BY l.category), 0), 1)
                                                                        AS share_of_category_returns_pct
FROM returns AS r
JOIN v_order_lines AS l ON l.order_item_id = r.order_item_id
GROUP BY l.category, r.return_reason
ORDER BY l.category, return_requests DESC;


-- =============================================================================
-- ANALYSIS 9: Sales channel, region and customer segment
-- -----------------------------------------------------------------------------
-- Question : How do sales differ by sales channel, region and customer segment?
-- Metric   : GROUPING SETS produce all three breakdowns in one pass. Shares are
--            calculated within each dimension. 9b pivots net sales by channel
--            and segment with FILTER.
-- Read it  : Look for dimensions where the share of orders and share of net
--            sales differ; that means AOV differs.
-- Caveat   : Region 'Unknown' holds customers with a missing region.
--            Channel is recorded per order, so one customer can appear in
--            several channels. Channel mix is set by generator weights.
-- =============================================================================
WITH by_dimension AS (
    SELECT CASE
               WHEN GROUPING(sales_channel) = 0 THEN 'sales_channel'
               WHEN GROUPING(region) = 0        THEN 'region'
               ELSE 'customer_segment'
           END                                     AS dimension,
           COALESCE(sales_channel, region, customer_segment) AS dimension_value,
           COUNT(*)                                AS orders,
           COUNT(DISTINCT customer_id)             AS customers,
           SUM(net_sales)                          AS net_sales,
           ROUND(AVG(checkout_value), 2)           AS avg_order_value
    FROM v_orders
    GROUP BY GROUPING SETS ((sales_channel), (region), (customer_segment))
)
SELECT dimension,
       dimension_value,
       orders,
       customers,
       net_sales,
       avg_order_value,
       ROUND(100.0 * orders    / NULLIF(SUM(orders)    OVER (PARTITION BY dimension), 0), 1) AS order_share_pct,
       ROUND(100.0 * net_sales / NULLIF(SUM(net_sales) OVER (PARTITION BY dimension), 0), 1) AS net_sales_share_pct
FROM by_dimension
ORDER BY dimension, net_sales DESC;

-- 9b. Net sales by channel (rows) and customer segment (columns).
SELECT sales_channel,
       COALESCE(SUM(net_sales) FILTER (WHERE customer_segment = 'budget'), 0)     AS budget,
       COALESCE(SUM(net_sales) FILTER (WHERE customer_segment = 'mainstream'), 0) AS mainstream,
       COALESCE(SUM(net_sales) FILTER (WHERE customer_segment = 'premium'), 0)    AS premium,
       SUM(net_sales)                                                             AS total
FROM v_orders
GROUP BY sales_channel
ORDER BY total DESC;


-- =============================================================================
-- ANALYSIS 10: How data-quality issues could affect the conclusions
-- -----------------------------------------------------------------------------
-- Question : How much of the reported revenue is touched by known data issues?
-- Metric   : Value of each issue, and its share of total in-scope net sales.
-- Read it  : Small shares mean conclusions are robust to the issue. Large
--            shares mean the issue must be fixed at source before reporting.
-- Caveat   : Only issues detected by 03_data_quality_checks.sql are measured;
--            undetected problems cannot be sized.
-- =============================================================================
WITH totals AS (
    SELECT SUM(net_sales) AS total_net_sales FROM v_orders
),
issues AS (
    SELECT 1 AS sort_key,
           'completed orders with no captured payment (kept in sales)' AS issue,
           COUNT(*) AS records,
           COALESCE(SUM(o.net_sales), 0) AS value_gbp
    FROM v_orders AS o
    WHERE NOT EXISTS (SELECT 1 FROM payments AS p
                      WHERE p.order_id = o.order_id AND p.payment_status = 'captured')
    UNION ALL
    SELECT 2,
           'refund amount above line value (excess removed by cap)',
           COUNT(*),
           COALESCE(SUM(rt.refunded_raw - l.checkout_value), 0)
    FROM (SELECT order_item_id,
                 SUM(refund_amount) FILTER (WHERE return_status = 'refunded') AS refunded_raw
          FROM returns
          GROUP BY order_item_id) AS rt
    JOIN v_order_lines AS l ON l.order_item_id = rt.order_item_id
    WHERE rt.refunded_raw > l.checkout_value
    UNION ALL
    SELECT 3,
           'net sales from customers with unknown region',
           COUNT(*),
           COALESCE(SUM(net_sales), 0)
    FROM v_orders
    WHERE region = 'Unknown'
    UNION ALL
    SELECT 4,
           'captured payments on completed orders with no lines (excluded)',
           COUNT(*),
           COALESCE(SUM(p.amount), 0)
    FROM payments AS p
    JOIN orders AS o ON o.order_id = p.order_id
    WHERE p.payment_status = 'captured'
      AND o.order_status = 'completed'
      AND NOT EXISTS (SELECT 1 FROM order_items AS oi WHERE oi.order_id = o.order_id)
)
SELECT i.issue,
       i.records,
       i.value_gbp,
       ROUND(100.0 * i.value_gbp / NULLIF(t.total_net_sales, 0), 2) AS pct_of_net_sales
FROM issues AS i
CROSS JOIN totals AS t
ORDER BY i.sort_key;
