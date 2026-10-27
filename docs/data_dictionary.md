# Data Dictionary

All data is synthetic. Money is GBP, VAT-inclusive, stored as `numeric(12,2)`.
Shipping is not modelled. The analysis window is 2024-01-01 to 2025-06-30.

## customers

One row per registered customer account. No names or contact details are stored.

| Column | Type | Constraints | Definition |
|---|---|---|---|
| customer_id | integer | PK | Surrogate identifier for the customer. |
| signup_date | date | NOT NULL | Date the account was created. |
| region | text | nullable; one of 9 UK regions | Customer's UK region. NULL means unknown; analyses show it as 'Unknown'. |
| customer_segment | text | NOT NULL; budget, mainstream, premium | Marketing segment assigned at signup. |

## products

One row per catalogue product (45 products in 6 categories).

| Column | Type | Constraints | Definition |
|---|---|---|---|
| product_id | integer | PK | Surrogate identifier for the product. |
| product_name | text | NOT NULL, UNIQUE | Display name. |
| category | text | NOT NULL; kitchen, home_cleaning, stationery, pet_supplies, electronics_accessories, snacks_beverages | Product category. |
| list_price | numeric(12,2) | NOT NULL, > 0 | Base catalogue price before the 2025 price increase applied to some products. The price actually charged is `order_items.unit_price`. |
| unit_cost | numeric(12,2) | NOT NULL, >= 0 | Standard cost per unit. Not used in the core analysis. |
| launch_date | date | NOT NULL | Date the product was first offered. |

## orders

One row per checkout (order header).

| Column | Type | Constraints | Definition |
|---|---|---|---|
| order_id | integer | PK | Identifier; increases with order date. |
| customer_id | integer | NOT NULL, FK → customers | Customer who placed the order. |
| order_date | date | NOT NULL | Date the order was placed. Used for all time-based sales analysis. |
| sales_channel | text | NOT NULL; web, mobile_app, marketplace | Where the order was placed. |
| order_status | text | NOT NULL; completed, cancelled, pending | `completed` = paid and fulfilled (the only status counted as a sale). `cancelled` = cancelled before fulfilment. `pending` = placed but payment not captured when the data was extracted. |

## order_items

One row per product line in an order.

| Column | Type | Constraints | Definition |
|---|---|---|---|
| order_item_id | integer | PK | Identifier for the line. |
| order_id | integer | NOT NULL, FK → orders | Parent order. |
| product_id | integer | NOT NULL, FK → products | Product purchased. |
| quantity | integer | NOT NULL, > 0 | Units purchased on this line. |
| unit_price | numeric(12,2) | NOT NULL, > 0 | Price per unit charged at order time, before discount. |
| discount_amount | numeric(12,2) | NOT NULL, default 0, between 0 and quantity × unit_price | Total discount on the line (not per unit). |

Unique constraint: `(order_id, product_id)`.

## payments

One row per payment attempt. An order can have several.

| Column | Type | Constraints | Definition |
|---|---|---|---|
| payment_id | integer | PK | Identifier for the attempt. |
| order_id | integer | NOT NULL, FK → orders | Order being paid for. |
| payment_date | date | NOT NULL | Date of the attempt. |
| payment_method | text | NOT NULL; card, paypal, gift_card | Payment method. |
| payment_status | text | NOT NULL; captured, failed, voided | `captured` = money taken. `failed` = declined. `voided` = authorisation cancelled because the order was cancelled. |
| amount | numeric(12,2) | NOT NULL, >= 0 | Amount attempted. Used only for reconciliation, never as revenue. |

## returns

One row per return request against an order line.

| Column | Type | Constraints | Definition |
|---|---|---|---|
| return_id | integer | PK | Identifier for the return. |
| order_item_id | integer | NOT NULL, FK → order_items | Order line being returned. |
| return_date | date | NOT NULL | Date the return was received. |
| quantity_returned | integer | NOT NULL, > 0 | Units returned. Should not exceed the line quantity (tested, not enforced). |
| return_reason | text | NOT NULL; damaged, not_as_described, wrong_item, changed_mind | Customer-stated reason. |
| return_status | text | NOT NULL; refunded, rejected | Outcome of the return. |
| refund_amount | numeric(12,2) | NOT NULL, >= 0; must be 0 when rejected | Amount refunded. |

## Derived measures (defined in `sql/04_views.sql`)

| Measure | Definition |
|---|---|
| Sales scope | `completed` orders dated in the window that have at least one line. |
| gross_sales | quantity × unit_price |
| discount_amount | sum of line discounts |
| checkout_value | gross_sales − discount_amount |
| refunded_amount | refunds on `refunded` returns, capped at the line's checkout_value |
| net_sales | gross_sales − discount_amount − refunded_amount |
| units_returned | units on all return requests, capped at the quantity purchased |
| order count | distinct in-scope orders |
| item count | sum of quantity |
| line count | number of order lines |
| avg_order_value (AOV) | checkout_value ÷ order count |
| avg_net_order_value | net_sales ÷ order count |
| return_rate | units_returned ÷ units sold |
| cohort_month | month of the customer's first in-scope order |

Refunds are attributed to the month of the original order.

## Views

| View | Grain | Purpose |
|---|---|---|
| v_analysis_window | one row | Window start, end and RFM reference date. |
| v_order_lines | order line | Revenue measures plus customer and product attributes. |
| v_orders | order | Order-level totals, discount flag and rate. |
| v_monthly_sales | month | Monthly totals and AOV, including empty months. |
| v_customer_summary | customer | First and last order, order count, net sales; includes non-buyers. |
| v_customer_rfm | purchasing customer | R, F, M scores and rule-based RFM segment. |
