#!/usr/bin/env python3
"""
generate_data.py

Generates a deterministic, fully synthetic dataset for a fictional UK online
retailer ("Northfield Goods"). Nothing here describes real customers, real
products, or real company performance.

Standard library only. Python's job is data generation; all analysis happens
in PostgreSQL.

Usage (from the repository root):
    python scripts/generate_data.py                 # seed 42, writes to ./data
    python scripts/generate_data.py --seed 7 --out data

The same seed produces identical CSV files on the same Python version.
"""

import argparse
import csv
from datetime import date, timedelta
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path
import random

# ---------------------------------------------------------------------------
# Business assumptions (all fictional, all explicit)
# ---------------------------------------------------------------------------
WINDOW_START = date(2024, 1, 1)       # first day of the analysis window
WINDOW_END = date(2025, 6, 30)        # last day of the analysis window (18 months)
LAST_SIGNUP = date(2025, 5, 31)       # latest customer signup date
PRICE_INCREASE_DATE = date(2025, 1, 1)
PRICE_INCREASE_PCT = Decimal("0.05")  # applied to roughly one third of products
N_CUSTOMERS = 1000
NEVER_PURCHASE_RATE = 0.08            # customers who sign up but never order

REGIONS = [
    ("London", 22), ("South East", 16), ("Midlands", 15), ("North West", 12),
    ("Yorkshire", 9), ("South West", 9), ("Scotland", 9), ("Wales", 5),
    ("Northern Ireland", 3),
]

# segment: (weight, mean days between orders, churn probability after each order,
#           probability an order uses a promo code)
SEGMENTS = {
    "budget":     (40, 60, 0.38, 0.40),
    "mainstream": (45, 45, 0.28, 0.28),
    "premium":    (15, 35, 0.18, 0.15),
}

CHANNELS = [("web", 50), ("mobile_app", 35), ("marketplace", 15)]
PAYMENT_METHODS = [("card", 65), ("paypal", 28), ("gift_card", 7)]
PROMO_PCTS = [Decimal("0.10"), Decimal("0.15"), Decimal("0.20")]
RETURN_REASONS = [
    ("damaged", 25), ("not_as_described", 25), ("wrong_item", 15), ("changed_mind", 35),
]

# category: list of (product_name, list_price). Unit cost is derived later.
CATALOGUE = {
    "kitchen": [
        ("Nonstick Frying Pan 28cm", "24.99"), ("Stainless Saucepan Set", "59.99"),
        ("Bamboo Chopping Board", "14.50"), ("Glass Food Storage Set", "22.00"),
        ("Electric Kettle 1.7L", "29.99"), ("Silicone Utensil Set", "16.99"),
        ("Chef Knife 20cm", "34.00"), ("Insulated Travel Mug", "12.99"),
    ],
    "home_cleaning": [
        ("Microfibre Cloth Pack", "7.99"), ("Multi-Surface Spray 750ml", "3.49"),
        ("Laundry Liquid 2L", "9.99"), ("Dishwasher Tablets x60", "11.49"),
        ("Cordless Handheld Vacuum", "79.99"), ("Spin Mop and Bucket", "27.50"),
        ("Scrubbing Sponges x10", "4.29"), ("Bin Bags Roll x40", "5.99"),
    ],
    "stationery": [
        ("A5 Hardback Notebook", "8.99"), ("Gel Pen Pack x12", "6.49"),
        ("Desk Organiser", "18.00"), ("Sticky Notes Bundle", "5.49"),
        ("Ring Binder Set", "9.99"), ("Highlighter Set x6", "4.99"),
        ("Weekly Desk Planner", "12.50"),
    ],
    "pet_supplies": [
        ("Dry Dog Food 5kg", "24.99"), ("Cat Litter 10L", "8.99"),
        ("Chew Toy Bundle", "11.99"), ("Pet Bed Medium", "32.00"),
        ("Stainless Pet Bowl Pair", "10.49"), ("Cat Scratching Post", "26.99"),
        ("Dog Lead and Collar Set", "15.99"),
    ],
    "electronics_accessories": [
        ("USB-C Charging Cable 2m", "9.99"), ("Wireless Earbuds", "49.99"),
        ("Power Bank 10000mAh", "24.99"), ("Bluetooth Speaker Mini", "34.99"),
        ("Phone Stand Adjustable", "11.99"), ("Wireless Mouse", "17.99"),
        ("Laptop Sleeve 14in", "19.99"), ("Smart Plug Twin Pack", "22.99"),
    ],
    "snacks_beverages": [
        ("Ground Coffee 1kg", "14.99"), ("Loose Leaf Tea 250g", "6.99"),
        ("Mixed Nuts 500g", "7.49"), ("Dark Chocolate Bar Pack", "5.99"),
        ("Sparkling Water 12 Pack", "6.49"), ("Granola 750g", "4.99"),
        ("Oat Biscuits Multipack", "3.99"),
    ],
}

# Categories that are bought in larger quantities per line.
BULK_CATEGORIES = {"home_cleaning", "snacks_beverages", "pet_supplies", "stationery"}

# Products deliberately given high return rates so the return analysis has signal.
HIGH_RETURN_PRODUCTS = {"Wireless Earbuds", "Cordless Handheld Vacuum", "Pet Bed Medium"}

# ---------------------------------------------------------------------------
# Deliberately injected data-quality issues (documented in data/README.md).
# They exist so that sql/03_data_quality_checks.sql has something real to find.
# ---------------------------------------------------------------------------
N_NULL_REGION = 6            # customers.region left NULL
N_FAILED_ONLY_COMPLETED = 4  # completed orders whose only payment attempt failed
N_ORDERS_NO_ITEMS = 3        # completed orders whose line items were lost
N_OVER_RETURNS = 3           # returns with quantity_returned > quantity purchased
N_SIGNUP_AFTER_ORDER = 5     # customers whose signup_date is after their first order

CENT = Decimal("0.01")


def money(value):
    """Round a Decimal to pence using half-up rounding."""
    return Decimal(value).quantize(CENT, rounding=ROUND_HALF_UP)


def weighted(rng, pairs):
    """Pick one value from a list of (value, weight) pairs."""
    values = [p[0] for p in pairs]
    weights = [p[1] for p in pairs]
    return rng.choices(values, weights=weights, k=1)[0]


def random_date(rng, start, end):
    return start + timedelta(days=rng.randint(0, (end - start).days))


def build_products(rng):
    products = []
    product_id = 101
    for category, items in CATALOGUE.items():
        for name, price in items:
            list_price = Decimal(price)
            cost_ratio = Decimal(str(round(rng.uniform(0.40, 0.65), 4)))
            if name in HIGH_RETURN_PRODUCTS:
                return_rate = rng.uniform(0.20, 0.28)
            elif category == "electronics_accessories":
                return_rate = rng.uniform(0.06, 0.12)
            elif category == "snacks_beverages":
                return_rate = rng.uniform(0.01, 0.03)
            else:
                return_rate = rng.uniform(0.02, 0.07)
            products.append({
                "product_id": product_id,
                "product_name": name,
                "category": category,
                "list_price": list_price,
                "unit_cost": money(list_price * cost_ratio),
                "launch_date": random_date(rng, date(2022, 1, 1), date(2023, 12, 31)),
                # generator-only attributes (not written to CSV)
                "_popularity": rng.uniform(0.5, 3.0),
                "_return_rate": return_rate,
                "_price_increase": rng.random() < 0.33,
            })
            product_id += 1
    return products


def build_customers(rng):
    customers = []
    for customer_id in range(1, N_CUSTOMERS + 1):
        segment = weighted(rng, [(s, v[0]) for s, v in SEGMENTS.items()])
        customers.append({
            "customer_id": customer_id,
            "signup_date": random_date(rng, WINDOW_START, LAST_SIGNUP),
            "region": weighted(rng, REGIONS),
            "customer_segment": segment,
            "_preferred_channel": weighted(rng, CHANNELS),
        })
    return customers


def order_dates_for(rng, customer):
    """Simulate one customer's purchase dates inside the analysis window."""
    if rng.random() < NEVER_PURCHASE_RATE:
        return []
    _, mean_gap, churn, _ = SEGMENTS[customer["customer_segment"]]
    current = customer["signup_date"] + timedelta(days=rng.randint(0, 14))
    dates = []
    while current <= WINDOW_END:
        dates.append(current)
        if rng.random() < churn:
            break
        gap = rng.expovariate(1.0 / mean_gap) + 3
        # Seasonal assumption: customers buy more often from October to December.
        if current.month in (10, 11, 12):
            gap *= 0.6
        current = current + timedelta(days=int(gap))
    return dates


def pick_products(rng, products, n_lines):
    weights = [p["_popularity"] for p in products]
    chosen = []
    while len(chosen) < n_lines:
        candidate = rng.choices(products, weights=weights, k=1)[0]
        if candidate not in chosen:
            chosen.append(candidate)
    return chosen


def build_orders(rng, customers, products):
    raw_orders = []
    for customer in customers:
        for order_date in order_dates_for(rng, customer):
            raw_orders.append((order_date, customer))
    # Order IDs increase with order date, as they would in a real system.
    raw_orders.sort(key=lambda pair: (pair[0], pair[1]["customer_id"]))

    orders, items, payments, returns = [], [], [], []
    order_item_id = payment_id = return_id = 1

    for index, (order_date, customer) in enumerate(raw_orders):
        order_id = 100001 + index
        segment = customer["customer_segment"]
        promo_prob = SEGMENTS[segment][3]
        if order_date.month == 11:          # assumption: November promotional event
            promo_prob = min(promo_prob + 0.25, 0.9)

        if order_date > WINDOW_END - timedelta(days=7) and rng.random() < 0.35:
            status = "pending"              # payment not yet captured at extract time
        elif rng.random() < 0.05:
            status = "cancelled"
        else:
            status = "completed"

        channel = customer["_preferred_channel"] if rng.random() < 0.7 else weighted(rng, CHANNELS)
        promo_pct = rng.choice(PROMO_PCTS) if rng.random() < promo_prob else Decimal("0")

        n_lines = weighted(rng, [(1, 45), (2, 30), (3, 15), (4, 7), (5, 3)])
        if promo_pct > 0 and rng.random() < 0.3:
            n_lines = min(n_lines + 1, 6)   # assumption: promos nudge basket size up
        if segment == "premium" and rng.random() < 0.25:
            n_lines = min(n_lines + 1, 6)

        order_total = Decimal("0")
        order_lines = []
        for product in pick_products(rng, products, n_lines):
            if product["category"] in BULK_CATEGORIES:
                quantity = weighted(rng, [(1, 50), (2, 30), (3, 12), (4, 6), (6, 2)])
            else:
                quantity = weighted(rng, [(1, 80), (2, 15), (3, 5)])
            unit_price = product["list_price"]
            if product["_price_increase"] and order_date >= PRICE_INCREASE_DATE:
                unit_price = money(unit_price * (1 + PRICE_INCREASE_PCT))
            gross = unit_price * quantity
            discount = money(gross * promo_pct)
            line = {
                "order_item_id": order_item_id,
                "order_id": order_id,
                "product_id": product["product_id"],
                "quantity": quantity,
                "unit_price": unit_price,
                "discount_amount": discount,
                "_product": product,
            }
            order_lines.append(line)
            order_total += gross - discount
            order_item_id += 1

        items.extend(order_lines)
        orders.append({
            "order_id": order_id,
            "customer_id": customer["customer_id"],
            "order_date": order_date,
            "sales_channel": channel,
            "order_status": status,
        })

        # Payments ---------------------------------------------------------
        method = weighted(rng, PAYMENT_METHODS)
        if status == "completed":
            if rng.random() < 0.06:         # a failed first attempt, then success
                payments.append({"payment_id": payment_id, "order_id": order_id,
                                 "payment_date": order_date, "payment_method": method,
                                 "payment_status": "failed", "amount": order_total})
                payment_id += 1
            payments.append({"payment_id": payment_id, "order_id": order_id,
                             "payment_date": order_date + timedelta(days=rng.choice([0, 0, 0, 1])),
                             "payment_method": method, "payment_status": "captured",
                             "amount": order_total})
            payment_id += 1
        elif status == "cancelled":
            payments.append({"payment_id": payment_id, "order_id": order_id,
                             "payment_date": order_date, "payment_method": method,
                             "payment_status": "voided", "amount": order_total})
            payment_id += 1
        elif rng.random() < 0.5:            # pending: half have a failed attempt, half none
            payments.append({"payment_id": payment_id, "order_id": order_id,
                             "payment_date": order_date, "payment_method": method,
                             "payment_status": "failed", "amount": order_total})
            payment_id += 1

        # Returns (completed orders only) ------------------------------------
        if status != "completed":
            continue
        for line in order_lines:
            if rng.random() >= line["_product"]["_return_rate"]:
                continue
            qty_returned = rng.randint(1, line["quantity"])
            return_status = "refunded" if rng.random() < 0.9 else "rejected"
            line_net = line["unit_price"] * line["quantity"] - line["discount_amount"]
            if return_status == "refunded":
                refund = money(line_net / line["quantity"] * qty_returned)
            else:
                refund = Decimal("0.00")
            returns.append({
                "return_id": return_id,
                "order_item_id": line["order_item_id"],
                "return_date": order_date + timedelta(days=rng.randint(3, 30)),
                "quantity_returned": qty_returned,
                "return_reason": weighted(rng, RETURN_REASONS),
                "return_status": return_status,
                "refund_amount": refund,
            })
            return_id += 1

    return orders, items, payments, returns


def inject_quality_issues(rng, customers, orders, items, payments, returns):
    """Introduce a small, documented set of data problems."""
    log = {}

    # 1. Missing region
    null_region = rng.sample(customers, N_NULL_REGION)
    for customer in null_region:
        customer["region"] = None
    log["customers with NULL region"] = sorted(c["customer_id"] for c in null_region)

    completed_ids = [o["order_id"] for o in orders if o["order_status"] == "completed"]
    chosen = rng.sample(completed_ids, N_FAILED_ONLY_COMPLETED + N_ORDERS_NO_ITEMS)
    failed_only = set(chosen[:N_FAILED_ONLY_COMPLETED])
    no_items = set(chosen[N_FAILED_ONLY_COMPLETED:])

    # 2. Completed orders whose only payment attempt failed
    payments[:] = [p for p in payments
                   if not (p["order_id"] in failed_only and p["payment_status"] == "failed")]
    for p in payments:
        if p["order_id"] in failed_only:
            p["payment_status"] = "failed"
    log["completed orders with no captured payment"] = sorted(failed_only)

    # 3. Completed orders whose line items were lost (payment still exists)
    lost_item_ids = {i["order_item_id"] for i in items if i["order_id"] in no_items}
    items[:] = [i for i in items if i["order_id"] not in no_items]
    returns[:] = [r for r in returns if r["order_item_id"] not in lost_item_ids]
    log["completed orders with no order_items"] = sorted(no_items)

    # 4. Returns with more units than were purchased
    items_by_id = {i["order_item_id"]: i for i in items}
    refunded = [r for r in returns if r["return_status"] == "refunded"]
    over = rng.sample(refunded, N_OVER_RETURNS)
    for r in over:
        line = items_by_id[r["order_item_id"]]
        r["quantity_returned"] = line["quantity"] + 1
        line_net = line["unit_price"] * line["quantity"] - line["discount_amount"]
        r["refund_amount"] = money(line_net / line["quantity"] * r["quantity_returned"])
    log["returns exceeding purchased quantity"] = sorted(r["return_id"] for r in over)

    # 5. Signup date recorded after the customer's first order
    first_order = {}
    for o in orders:
        first_order.setdefault(o["customer_id"], o["order_date"])
    eligible = sorted(cid for cid, d in first_order.items()
                      if d <= LAST_SIGNUP - timedelta(days=20))
    shifted = rng.sample(eligible, N_SIGNUP_AFTER_ORDER)
    by_id = {c["customer_id"]: c for c in customers}
    for cid in shifted:
        by_id[cid]["signup_date"] = first_order[cid] + timedelta(days=rng.randint(5, 20))
    log["customers with signup_date after first order"] = sorted(shifted)

    return log


def write_csv(path, rows, columns):
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(columns)
        for row in rows:
            # None becomes an empty unquoted field, which PostgreSQL CSV COPY reads as NULL.
            writer.writerow(["" if row[c] is None else row[c] for c in columns])


def main():
    parser = argparse.ArgumentParser(description="Generate synthetic retail CSV files.")
    parser.add_argument("--seed", type=int, default=42, help="random seed (default 42)")
    parser.add_argument("--out", default="data", help="output directory (default: data)")
    args = parser.parse_args()

    rng = random.Random(args.seed)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    products = build_products(rng)
    customers = build_customers(rng)
    orders, items, payments, returns = build_orders(rng, customers, products)
    issues = inject_quality_issues(rng, customers, orders, items, payments, returns)

    write_csv(out_dir / "customers.csv", customers,
              ["customer_id", "signup_date", "region", "customer_segment"])
    write_csv(out_dir / "products.csv", products,
              ["product_id", "product_name", "category", "list_price", "unit_cost", "launch_date"])
    write_csv(out_dir / "orders.csv", orders,
              ["order_id", "customer_id", "order_date", "sales_channel", "order_status"])
    write_csv(out_dir / "order_items.csv", items,
              ["order_item_id", "order_id", "product_id", "quantity", "unit_price",
               "discount_amount"])
    write_csv(out_dir / "payments.csv", payments,
              ["payment_id", "order_id", "payment_date", "payment_method", "payment_status",
               "amount"])
    write_csv(out_dir / "returns.csv", returns,
              ["return_id", "order_item_id", "return_date", "quantity_returned",
               "return_reason", "return_status", "refund_amount"])

    print(f"Seed: {args.seed}  Output: {out_dir.resolve()}")
    for name, rows in [("customers", customers), ("products", products), ("orders", orders),
                       ("order_items", items), ("payments", payments), ("returns", returns)]:
        print(f"  {name:<12} {len(rows):>6} rows")
    print("Injected data-quality issues (for sql/03_data_quality_checks.sql):")
    for label, ids in issues.items():
        print(f"  {label}: {ids}")


if __name__ == "__main__":
    main()
