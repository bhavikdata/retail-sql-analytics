-- =============================================================================
-- 02_load_data.sql
-- Purpose : Load the synthetic CSV files into the retail schema.
-- Run     : psql -d retail_analytics -f sql/02_load_data.sql   (from repo root)
-- Requires: sql/01_create_schema.sql has been run, and the CSV files exist in
--           data/ (create them with: python scripts/generate_data.py).
--
-- Notes
--   * \copy is a psql client command. It reads files from YOUR machine relative
--     to the directory psql was started in, so no server file permissions or
--     superuser rights are needed. Each \copy must stay on a single line.
--   * Tables load parent-first so foreign keys are satisfied.
--   * TRUNCATE makes the script safe to re-run after regenerating the data.
--   * The whole load runs in one transaction: it either fully succeeds or
--     leaves the tables unchanged.
-- =============================================================================

\set ON_ERROR_STOP on
SET search_path TO retail;

BEGIN;

TRUNCATE TABLE returns, payments, order_items, orders, products, customers;

\copy customers (customer_id, signup_date, region, customer_segment) FROM 'data/customers.csv' WITH (FORMAT csv, HEADER true)
\copy products (product_id, product_name, category, list_price, unit_cost, launch_date) FROM 'data/products.csv' WITH (FORMAT csv, HEADER true)
\copy orders (order_id, customer_id, order_date, sales_channel, order_status) FROM 'data/orders.csv' WITH (FORMAT csv, HEADER true)
\copy order_items (order_item_id, order_id, product_id, quantity, unit_price, discount_amount) FROM 'data/order_items.csv' WITH (FORMAT csv, HEADER true)
\copy payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) FROM 'data/payments.csv' WITH (FORMAT csv, HEADER true)
\copy returns (return_id, order_item_id, return_date, quantity_returned, return_reason, return_status, refund_amount) FROM 'data/returns.csv' WITH (FORMAT csv, HEADER true)

COMMIT;

-- Refresh planner statistics after a bulk load.
ANALYZE customers;
ANALYZE products;
ANALYZE orders;
ANALYZE order_items;
ANALYZE payments;
ANALYZE returns;

-- Row counts: compare these with the counts printed by generate_data.py.
SELECT 'customers'   AS table_name, COUNT(*) AS row_count FROM customers
UNION ALL SELECT 'products',    COUNT(*) FROM products
UNION ALL SELECT 'orders',      COUNT(*) FROM orders
UNION ALL SELECT 'order_items', COUNT(*) FROM order_items
UNION ALL SELECT 'payments',    COUNT(*) FROM payments
UNION ALL SELECT 'returns',     COUNT(*) FROM returns;
