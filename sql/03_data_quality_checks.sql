-- =============================================================================
-- 03_data_quality_checks.sql
-- Purpose : Test the loaded data before trusting any analysis built on it.
-- Run     : psql -d retail_analytics -f sql/03_data_quality_checks.sql
--
-- How to read the output
--   Part A returns one row per check:
--     failing_rows       rows (or groups) that break the rule
--     expected_seed_42   count expected for the default dataset (seed 42).
--                        These were computed independently from the CSV files
--                        with Python, not from this SQL. If your numbers differ,
--                        investigate before continuing.
--     result             'pass', 'known issue' (matches a deliberately injected
--                        problem) or 'investigate'.
--   Part B lists the individual records behind each known issue.
--
-- Why run checks the constraints already prevent?
--   Duplicate keys, orphaned foreign keys and negative values cannot load into
--   this schema, so those checks should always pass. They stay in the script
--   because the same checks are needed when data sits in a platform that does
--   not enforce keys (for example, Snowflake declares but does not enforce
--   primary and foreign keys), or if constraints are ever relaxed.
--
-- Analysis window assumption: 2024-01-01 to 2025-06-30 (see v_analysis_window
-- in 04_views.sql; repeated here as literals because views are created later).
-- =============================================================================

\set ON_ERROR_STOP on
SET search_path TO retail;

-- =============================================================================
-- PART A: summary of all checks
-- =============================================================================
WITH
line_totals AS (
    -- value at checkout per order, from order lines
    SELECT order_id,
           SUM(quantity * unit_price - discount_amount) AS line_checkout_value
    FROM order_items
    GROUP BY order_id
),
captured_payments AS (
    SELECT order_id,
           COUNT(*)    AS captured_count,
           SUM(amount) AS captured_amount
    FROM payments
    WHERE payment_status = 'captured'
    GROUP BY order_id
),
return_totals AS (
    SELECT order_item_id,
           SUM(quantity_returned) AS units_returned,
           COALESCE(SUM(refund_amount) FILTER (WHERE return_status = 'refunded'), 0) AS refunded_amount
    FROM returns
    GROUP BY order_item_id
),
checks AS (
    -- ---------------------------------------------------------------- duplicates
    SELECT 1 AS check_id, 'duplicates' AS category, 'duplicate customer_id' AS check_name,
           (SELECT COUNT(*) FROM (SELECT customer_id FROM customers GROUP BY customer_id HAVING COUNT(*) > 1) AS d) AS failing_rows,
           0 AS expected_seed_42
    UNION ALL
    SELECT 2, 'duplicates', 'duplicate product_id',
           (SELECT COUNT(*) FROM (SELECT product_id FROM products GROUP BY product_id HAVING COUNT(*) > 1) AS d), 0
    UNION ALL
    SELECT 3, 'duplicates', 'duplicate order_id',
           (SELECT COUNT(*) FROM (SELECT order_id FROM orders GROUP BY order_id HAVING COUNT(*) > 1) AS d), 0
    UNION ALL
    SELECT 4, 'duplicates', 'duplicate order_item_id',
           (SELECT COUNT(*) FROM (SELECT order_item_id FROM order_items GROUP BY order_item_id HAVING COUNT(*) > 1) AS d), 0
    UNION ALL
    SELECT 5, 'duplicates', 'duplicate payment_id',
           (SELECT COUNT(*) FROM (SELECT payment_id FROM payments GROUP BY payment_id HAVING COUNT(*) > 1) AS d), 0
    UNION ALL
    SELECT 6, 'duplicates', 'duplicate return_id',
           (SELECT COUNT(*) FROM (SELECT return_id FROM returns GROUP BY return_id HAVING COUNT(*) > 1) AS d), 0
    UNION ALL
    SELECT 7, 'duplicates', 'duplicate product_name',
           (SELECT COUNT(*) FROM (SELECT product_name FROM products GROUP BY product_name HAVING COUNT(*) > 1) AS d), 0
    UNION ALL
    SELECT 8, 'duplicates', 'same product on more than one line of an order',
           (SELECT COUNT(*) FROM (SELECT order_id, product_id FROM order_items GROUP BY order_id, product_id HAVING COUNT(*) > 1) AS d), 0

    -- ---------------------------------------------------------- missing values
    UNION ALL
    SELECT 9, 'missing values', 'customers with NULL region (optional field)',
           (SELECT COUNT(*) FROM customers WHERE region IS NULL), 6
    UNION ALL
    SELECT 10, 'missing values', 'customers missing a required value',
           (SELECT COUNT(*) FROM customers
            WHERE customer_id IS NULL OR signup_date IS NULL OR customer_segment IS NULL), 0
    UNION ALL
    SELECT 11, 'missing values', 'products missing a required value',
           (SELECT COUNT(*) FROM products
            WHERE product_name IS NULL OR category IS NULL OR list_price IS NULL
               OR unit_cost IS NULL OR launch_date IS NULL), 0
    UNION ALL
    SELECT 12, 'missing values', 'orders missing a required value',
           (SELECT COUNT(*) FROM orders
            WHERE customer_id IS NULL OR order_date IS NULL
               OR sales_channel IS NULL OR order_status IS NULL), 0
    UNION ALL
    SELECT 13, 'missing values', 'order_items missing a required value',
           (SELECT COUNT(*) FROM order_items
            WHERE order_id IS NULL OR product_id IS NULL OR quantity IS NULL
               OR unit_price IS NULL OR discount_amount IS NULL), 0
    UNION ALL
    SELECT 14, 'missing values', 'payments missing a required value',
           (SELECT COUNT(*) FROM payments
            WHERE order_id IS NULL OR payment_date IS NULL OR payment_method IS NULL
               OR payment_status IS NULL OR amount IS NULL), 0
    UNION ALL
    SELECT 15, 'missing values', 'returns missing a required value',
           (SELECT COUNT(*) FROM returns
            WHERE order_item_id IS NULL OR return_date IS NULL OR quantity_returned IS NULL
               OR return_reason IS NULL OR return_status IS NULL OR refund_amount IS NULL), 0

    -- ------------------------------------------------------------ invalid dates
    UNION ALL
    SELECT 16, 'dates', 'orders outside the analysis window',
           (SELECT COUNT(*) FROM orders
            WHERE order_date NOT BETWEEN DATE '2024-01-01' AND DATE '2025-06-30'), 0
    UNION ALL
    SELECT 17, 'dates', 'orders placed before the customer signed up',
           (SELECT COUNT(*) FROM orders AS o
            JOIN customers AS c ON c.customer_id = o.customer_id
            WHERE o.order_date < c.signup_date), 5
    UNION ALL
    SELECT 18, 'dates', 'orders containing a product before its launch date',
           (SELECT COUNT(DISTINCT o.order_id) FROM orders AS o
            JOIN order_items AS oi ON oi.order_id = o.order_id
            JOIN products AS p ON p.product_id = oi.product_id
            WHERE o.order_date < p.launch_date), 0
    UNION ALL
    SELECT 19, 'dates', 'payments dated before the order',
           (SELECT COUNT(*) FROM payments AS pay
            JOIN orders AS o ON o.order_id = pay.order_id
            WHERE pay.payment_date < o.order_date), 0
    UNION ALL
    SELECT 20, 'dates', 'payments more than 7 days after the order',
           (SELECT COUNT(*) FROM payments AS pay
            JOIN orders AS o ON o.order_id = pay.order_id
            WHERE pay.payment_date > o.order_date + 7), 0
    UNION ALL
    SELECT 21, 'dates', 'returns dated before the order',
           (SELECT COUNT(*) FROM returns AS r
            JOIN order_items AS oi ON oi.order_item_id = r.order_item_id
            JOIN orders AS o ON o.order_id = oi.order_id
            WHERE r.return_date < o.order_date), 0
    UNION ALL
    SELECT 22, 'dates', 'returns more than 60 days after the order',
           (SELECT COUNT(*) FROM returns AS r
            JOIN order_items AS oi ON oi.order_item_id = r.order_item_id
            JOIN orders AS o ON o.order_id = oi.order_id
            WHERE r.return_date > o.order_date + 60), 0
    UNION ALL
    SELECT 23, 'dates', 'any date later than today',
           (SELECT (SELECT COUNT(*) FROM customers WHERE signup_date > CURRENT_DATE)
                 + (SELECT COUNT(*) FROM orders    WHERE order_date   > CURRENT_DATE)
                 + (SELECT COUNT(*) FROM payments  WHERE payment_date > CURRENT_DATE)
                 + (SELECT COUNT(*) FROM returns   WHERE return_date  > CURRENT_DATE)), 0

    -- ------------------------------------------------------- orphaned foreign keys
    UNION ALL
    SELECT 24, 'orphans', 'orders with unknown customer_id',
           (SELECT COUNT(*) FROM orders AS o
            WHERE NOT EXISTS (SELECT 1 FROM customers AS c WHERE c.customer_id = o.customer_id)), 0
    UNION ALL
    SELECT 25, 'orphans', 'order_items with unknown order_id',
           (SELECT COUNT(*) FROM order_items AS oi
            WHERE NOT EXISTS (SELECT 1 FROM orders AS o WHERE o.order_id = oi.order_id)), 0
    UNION ALL
    SELECT 26, 'orphans', 'order_items with unknown product_id',
           (SELECT COUNT(*) FROM order_items AS oi
            WHERE NOT EXISTS (SELECT 1 FROM products AS p WHERE p.product_id = oi.product_id)), 0
    UNION ALL
    SELECT 27, 'orphans', 'payments with unknown order_id',
           (SELECT COUNT(*) FROM payments AS pay
            WHERE NOT EXISTS (SELECT 1 FROM orders AS o WHERE o.order_id = pay.order_id)), 0
    UNION ALL
    SELECT 28, 'orphans', 'returns with unknown order_item_id',
           (SELECT COUNT(*) FROM returns AS r
            WHERE NOT EXISTS (SELECT 1 FROM order_items AS oi WHERE oi.order_item_id = r.order_item_id)), 0

    -- ------------------------------------------- negative or implausible values
    UNION ALL
    SELECT 29, 'implausible values', 'line quantity outside 1 to 20',
           (SELECT COUNT(*) FROM order_items WHERE quantity < 1 OR quantity > 20), 0
    UNION ALL
    SELECT 30, 'implausible values', 'unit_price zero or negative',
           (SELECT COUNT(*) FROM order_items WHERE unit_price <= 0), 0
    UNION ALL
    SELECT 31, 'implausible values', 'unit_price more than 20% away from list_price',
           (SELECT COUNT(*) FROM order_items AS oi
            JOIN products AS p ON p.product_id = oi.product_id
            WHERE ABS(oi.unit_price - p.list_price) / NULLIF(p.list_price, 0) > 0.20), 0
    UNION ALL
    SELECT 32, 'implausible values', 'line discount above 50% of gross value',
           (SELECT COUNT(*) FROM order_items
            WHERE discount_amount > 0.5 * quantity * unit_price), 0
    UNION ALL
    SELECT 33, 'implausible values', 'products with unit_cost at or above list_price',
           (SELECT COUNT(*) FROM products WHERE unit_cost >= list_price), 0
    UNION ALL
    SELECT 34, 'implausible values', 'captured payments of zero or less',
           (SELECT COUNT(*) FROM payments WHERE payment_status = 'captured' AND amount <= 0), 0

    -- ---------------------------------------------- orders without items or payments
    UNION ALL
    SELECT 35, 'order completeness', 'orders with no order_items (any status)',
           (SELECT COUNT(*) FROM orders AS o
            WHERE NOT EXISTS (SELECT 1 FROM order_items AS oi WHERE oi.order_id = o.order_id)), 3
    UNION ALL
    SELECT 36, 'order completeness', 'completed orders with no captured payment',
           (SELECT COUNT(*) FROM orders AS o
            LEFT JOIN captured_payments AS cp ON cp.order_id = o.order_id
            WHERE o.order_status = 'completed' AND cp.order_id IS NULL), 4
    UNION ALL
    SELECT 37, 'order completeness', 'completed orders where captured amount differs from line total',
           (SELECT COUNT(*) FROM orders AS o
            JOIN captured_payments AS cp ON cp.order_id = o.order_id
            LEFT JOIN line_totals AS lt ON lt.order_id = o.order_id
            WHERE o.order_status = 'completed'
              AND cp.captured_amount <> COALESCE(lt.line_checkout_value, 0)), 3
    UNION ALL
    SELECT 38, 'order completeness', 'orders with more than one captured payment',
           (SELECT COUNT(*) FROM captured_payments WHERE captured_count > 1), 0

    -- --------------------------------------------------------------- returns
    UNION ALL
    SELECT 39, 'returns', 'order lines with more units returned than purchased',
           (SELECT COUNT(*) FROM return_totals AS rt
            JOIN order_items AS oi ON oi.order_item_id = rt.order_item_id
            WHERE rt.units_returned > oi.quantity), 3
    UNION ALL
    SELECT 40, 'returns', 'order lines refunded more than their checkout value',
           (SELECT COUNT(*) FROM return_totals AS rt
            JOIN order_items AS oi ON oi.order_item_id = rt.order_item_id
            WHERE rt.refunded_amount > oi.quantity * oi.unit_price - oi.discount_amount), 3
    UNION ALL
    SELECT 41, 'returns', 'returns recorded against orders that are not completed',
           (SELECT COUNT(*) FROM returns AS r
            JOIN order_items AS oi ON oi.order_item_id = r.order_item_id
            JOIN orders AS o ON o.order_id = oi.order_id
            WHERE o.order_status <> 'completed'), 0

    -- -------------------------------------------------- status consistency
    UNION ALL
    SELECT 42, 'status consistency', 'cancelled orders with a captured payment',
           (SELECT COUNT(*) FROM orders AS o
            JOIN captured_payments AS cp ON cp.order_id = o.order_id
            WHERE o.order_status = 'cancelled'), 0
    UNION ALL
    SELECT 43, 'status consistency', 'pending orders with a captured payment',
           (SELECT COUNT(*) FROM orders AS o
            JOIN captured_payments AS cp ON cp.order_id = o.order_id
            WHERE o.order_status = 'pending'), 0
    UNION ALL
    SELECT 44, 'status consistency', 'rejected returns with a refund',
           (SELECT COUNT(*) FROM returns WHERE return_status = 'rejected' AND refund_amount > 0), 0
)
SELECT check_id,
       category,
       check_name,
       failing_rows,
       expected_seed_42,
       CASE
           WHEN failing_rows = 0                THEN 'pass'
           WHEN failing_rows = expected_seed_42 THEN 'known issue'
           ELSE 'investigate'
       END AS result
FROM checks
ORDER BY check_id;

-- Informational (not a defect): customers who signed up but never placed an order.
-- Expected with seed 42: 98.
SELECT COUNT(*) AS customers_without_orders
FROM customers AS c
WHERE NOT EXISTS (SELECT 1 FROM orders AS o WHERE o.customer_id = c.customer_id);

-- =============================================================================
-- PART B: records behind each known issue
-- =============================================================================

-- B1. Customers with no region. Analyses label them 'Unknown'.
SELECT customer_id, signup_date, customer_segment
FROM customers
WHERE region IS NULL
ORDER BY customer_id;

-- B2. Orders placed before the recorded signup date. Likely a signup-date
-- recording error; the orders themselves look normal, so they stay in the
-- analysis. Cohorts use first order month, not signup date, so they are unaffected.
SELECT o.order_id, o.customer_id, o.order_date, c.signup_date,
       c.signup_date - o.order_date AS days_before_signup
FROM orders AS o
JOIN customers AS c ON c.customer_id = o.customer_id
WHERE o.order_date < c.signup_date
ORDER BY o.customer_id, o.order_date;

-- B3. Orders with no line items. They cannot contribute sales, so the views
-- exclude them from order counts and AOV.
SELECT o.order_id, o.order_status, o.order_date,
       COALESCE(SUM(pay.amount) FILTER (WHERE pay.payment_status = 'captured'), 0) AS captured_amount
FROM orders AS o
LEFT JOIN payments AS pay ON pay.order_id = o.order_id
WHERE NOT EXISTS (SELECT 1 FROM order_items AS oi WHERE oi.order_id = o.order_id)
GROUP BY o.order_id, o.order_status, o.order_date
ORDER BY o.order_id;

-- B4. Completed orders with no captured payment. They remain in sales (order
-- status is the source of truth for fulfilment); analysis 10 in 05_analysis.sql
-- measures how much revenue they represent.
SELECT o.order_id, o.order_date, o.order_status,
       STRING_AGG(pay.payment_status, ', ' ORDER BY pay.payment_id) AS payment_attempts
FROM orders AS o
LEFT JOIN payments AS pay ON pay.order_id = o.order_id
WHERE o.order_status = 'completed'
  AND NOT EXISTS (SELECT 1 FROM payments AS p2
                  WHERE p2.order_id = o.order_id AND p2.payment_status = 'captured')
GROUP BY o.order_id, o.order_date, o.order_status
ORDER BY o.order_id;

-- B5. Order lines with more units returned (or more money refunded) than
-- purchased. The views cap returned units at the purchased quantity and refunds
-- at the line's checkout value.
SELECT oi.order_item_id, oi.order_id, oi.quantity AS units_purchased,
       SUM(r.quantity_returned) AS units_returned,
       oi.quantity * oi.unit_price - oi.discount_amount AS line_checkout_value,
       SUM(r.refund_amount) FILTER (WHERE r.return_status = 'refunded') AS refunded_amount
FROM order_items AS oi
JOIN returns AS r ON r.order_item_id = oi.order_item_id
GROUP BY oi.order_item_id, oi.order_id, oi.quantity, oi.unit_price, oi.discount_amount
HAVING SUM(r.quantity_returned) > oi.quantity
ORDER BY oi.order_item_id;
