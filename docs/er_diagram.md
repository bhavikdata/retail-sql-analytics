# Entity-Relationship Diagram

This diagram matches `sql/01_create_schema.sql`. GitHub renders Mermaid
diagrams automatically.

```mermaid
erDiagram
    customers ||--o{ orders : "places"
    orders ||--o{ order_items : "contains"
    products ||--o{ order_items : "is sold on"
    orders ||--o{ payments : "has attempts"
    order_items ||--o{ returns : "is returned via"

    customers {
        integer customer_id PK
        date signup_date
        text region "nullable"
        text customer_segment
    }
    products {
        integer product_id PK
        text product_name UK
        text category
        numeric list_price
        numeric unit_cost
        date launch_date
    }
    orders {
        integer order_id PK
        integer customer_id FK
        date order_date
        text sales_channel
        text order_status
    }
    order_items {
        integer order_item_id PK
        integer order_id FK
        integer product_id FK
        integer quantity
        numeric unit_price
        numeric discount_amount
    }
    payments {
        integer payment_id PK
        integer order_id FK
        date payment_date
        text payment_method
        text payment_status
        numeric amount
    }
    returns {
        integer return_id PK
        integer order_item_id FK
        date return_date
        integer quantity_returned
        text return_reason
        text return_status
        numeric refund_amount
    }
```

## Reading the relationships

- A customer can have zero or many orders (some customers never order).
- An order should have at least one line, but the schema allows zero so that
  the data-quality checks can detect orders that lost their lines.
- An order can have several payment attempts, for example a failed attempt
  followed by a captured one.
- Returns attach to an order line, not an order, because customers return
  specific products and sometimes only some of the units.
- `(order_id, product_id)` is unique in `order_items`: a product appears once
  per order, and `quantity` records multiples.

## Join paths used in the analysis

| From | To | Join |
|---|---|---|
| orders | customers | `orders.customer_id = customers.customer_id` |
| order_items | orders | `order_items.order_id = orders.order_id` |
| order_items | products | `order_items.product_id = products.product_id` |
| payments | orders | `payments.order_id = orders.order_id` |
| returns | order_items | `returns.order_item_id = order_items.order_item_id` |
| returns | orders | via `order_items` |
