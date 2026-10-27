-- =============================================================================
-- 01_create_schema.sql
-- Retail Revenue, Customer Retention, and Product Performance Analysis
--
-- Purpose : Create the relational schema for the fictional online retailer.
-- Run     : psql -d retail_analytics -f sql/01_create_schema.sql   (from repo root)
-- Warning : Drops and recreates the "retail" schema. All loaded data is removed.
--
-- Design notes
--   * All objects live in a dedicated schema ("retail") so the project never
--     touches the default "public" schema.
--   * Surrogate integer keys come from the synthetic CSV files, so they are
--     plain integer primary keys rather than identity columns.
--   * Money is numeric(12,2), never float, to avoid rounding drift.
--   * Status and category columns use CHECK constraints instead of enum types
--     so that allowed values are easy to read and change.
--   * Structural rules (keys, NOT NULL, non-negative values) are enforced here.
--     Cross-row business rules (for example "a return cannot exceed the
--     quantity purchased") are NOT enforced by constraints; they are tested in
--     03_data_quality_checks.sql, mirroring how analysts often receive data.
--   * No personal data (names, emails, addresses) is stored; it is not needed
--     for the analysis.
-- =============================================================================

\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS retail CASCADE;
CREATE SCHEMA retail;
SET search_path TO retail;

-- -----------------------------------------------------------------------------
-- customers: one row per registered customer account
-- -----------------------------------------------------------------------------
CREATE TABLE customers (
    customer_id       integer     PRIMARY KEY,
    signup_date       date        NOT NULL,   -- date the account was created
    region            text,                   -- UK region; NULL means unknown
    customer_segment  text        NOT NULL,   -- marketing segment assigned at signup
    CONSTRAINT chk_customers_region CHECK (
        region IN ('London', 'South East', 'Midlands', 'North West', 'Yorkshire',
                   'South West', 'Scotland', 'Wales', 'Northern Ireland')
    ),
    CONSTRAINT chk_customers_segment CHECK (
        customer_segment IN ('budget', 'mainstream', 'premium')
    )
);

-- -----------------------------------------------------------------------------
-- products: one row per product in the catalogue
-- -----------------------------------------------------------------------------
CREATE TABLE products (
    product_id    integer        PRIMARY KEY,
    product_name  text           NOT NULL UNIQUE,
    category      text           NOT NULL,
    list_price    numeric(12,2)  NOT NULL,    -- base catalogue price, GBP incl. VAT (before any 2025 increase)
    unit_cost     numeric(12,2)  NOT NULL,    -- standard cost per unit, GBP
    launch_date   date           NOT NULL,    -- date first offered for sale
    CONSTRAINT chk_products_category CHECK (
        category IN ('kitchen', 'home_cleaning', 'stationery', 'pet_supplies',
                     'electronics_accessories', 'snacks_beverages')
    ),
    CONSTRAINT chk_products_list_price CHECK (list_price > 0),
    CONSTRAINT chk_products_unit_cost  CHECK (unit_cost >= 0)
);

-- -----------------------------------------------------------------------------
-- orders: one row per checkout (order header)
-- -----------------------------------------------------------------------------
CREATE TABLE orders (
    order_id       integer  PRIMARY KEY,
    customer_id    integer  NOT NULL REFERENCES customers (customer_id),
    order_date     date     NOT NULL,         -- date the customer placed the order
    sales_channel  text     NOT NULL,
    order_status   text     NOT NULL,
    CONSTRAINT chk_orders_channel CHECK (
        sales_channel IN ('web', 'mobile_app', 'marketplace')
    ),
    -- completed : paid and fulfilled; the only status counted as a sale
    -- cancelled : cancelled before fulfilment; excluded from sales
    -- pending   : placed but payment not captured when the data was extracted
    CONSTRAINT chk_orders_status CHECK (
        order_status IN ('completed', 'cancelled', 'pending')
    )
);

-- -----------------------------------------------------------------------------
-- order_items: one row per product line within an order
-- -----------------------------------------------------------------------------
CREATE TABLE order_items (
    order_item_id    integer        PRIMARY KEY,
    order_id         integer        NOT NULL REFERENCES orders (order_id),
    product_id       integer        NOT NULL REFERENCES products (product_id),
    quantity         integer        NOT NULL,  -- units purchased on this line
    unit_price       numeric(12,2)  NOT NULL,  -- price per unit charged at order time, before discount
    discount_amount  numeric(12,2)  NOT NULL DEFAULT 0,  -- total discount on the line, GBP
    CONSTRAINT chk_order_items_quantity   CHECK (quantity > 0),
    CONSTRAINT chk_order_items_unit_price CHECK (unit_price > 0),
    CONSTRAINT chk_order_items_discount   CHECK (
        discount_amount >= 0 AND discount_amount <= quantity * unit_price
    ),
    -- a product appears at most once per order; quantity captures multiples
    CONSTRAINT uq_order_items_order_product UNIQUE (order_id, product_id)
);

-- -----------------------------------------------------------------------------
-- payments: one row per payment attempt (an order can have several)
-- -----------------------------------------------------------------------------
CREATE TABLE payments (
    payment_id      integer        PRIMARY KEY,
    order_id        integer        NOT NULL REFERENCES orders (order_id),
    payment_date    date           NOT NULL,
    payment_method  text           NOT NULL,
    payment_status  text           NOT NULL,
    amount          numeric(12,2)  NOT NULL,   -- amount attempted, GBP
    CONSTRAINT chk_payments_method CHECK (
        payment_method IN ('card', 'paypal', 'gift_card')
    ),
    -- captured : money taken
    -- failed   : attempt declined; no money taken
    -- voided   : authorisation cancelled because the order was cancelled
    CONSTRAINT chk_payments_status CHECK (
        payment_status IN ('captured', 'failed', 'voided')
    ),
    CONSTRAINT chk_payments_amount CHECK (amount >= 0)
);

-- -----------------------------------------------------------------------------
-- returns: one row per return request against an order line
-- -----------------------------------------------------------------------------
CREATE TABLE returns (
    return_id          integer        PRIMARY KEY,
    order_item_id      integer        NOT NULL REFERENCES order_items (order_item_id),
    return_date        date           NOT NULL,  -- date the return was received
    quantity_returned  integer        NOT NULL,
    return_reason      text           NOT NULL,
    return_status      text           NOT NULL,
    refund_amount      numeric(12,2)  NOT NULL,  -- amount refunded, GBP; 0 if rejected
    CONSTRAINT chk_returns_quantity CHECK (quantity_returned > 0),
    CONSTRAINT chk_returns_reason CHECK (
        return_reason IN ('damaged', 'not_as_described', 'wrong_item', 'changed_mind')
    ),
    CONSTRAINT chk_returns_status CHECK (
        return_status IN ('refunded', 'rejected')
    ),
    CONSTRAINT chk_returns_refund_amount CHECK (refund_amount >= 0),
    CONSTRAINT chk_returns_rejected_no_refund CHECK (
        return_status = 'refunded' OR refund_amount = 0
    )
);

-- -----------------------------------------------------------------------------
-- Indexes
-- PostgreSQL does not index foreign-key columns automatically. These support
-- the joins and date filters used throughout the analysis.
-- order_items(order_id) is already covered by the leading column of
-- uq_order_items_order_product, so it is not indexed separately.
-- -----------------------------------------------------------------------------
CREATE INDEX idx_orders_customer_id       ON orders (customer_id);
CREATE INDEX idx_orders_order_date        ON orders (order_date);
CREATE INDEX idx_order_items_product_id   ON order_items (product_id);
CREATE INDEX idx_payments_order_id        ON payments (order_id);
CREATE INDEX idx_returns_order_item_id    ON returns (order_item_id);
