# Interview Preparation

Likely questions about this project, with answers grounded in what the project
actually contains. Put them in your own words. Replace bracketed items with
results from your own run.

**1. Walk me through the project.**
It's a PostgreSQL analytics project on a synthetic online retailer. I wrote a
standard-library Python script that generates a reproducible dataset (1,000
customers, 45 products, about 2,500 orders over 18 months) with a few
deliberate data problems. I designed the schema with keys and constraints,
wrote 44 data-quality checks, put the revenue definitions into views, and then
answered ten business questions: trends, product mix, AOV, repeat purchase,
cohort retention, RFM, discounts, returns, channel/region, and data-quality
impact.

**2. Why is the data synthetic? Doesn't that weaken it?**
I wanted a project I could publish without confidential data. The trade-off is
that patterns reflect rules I wrote into the generator. I document those rules
in `data/README.md` and treat the findings as evidence that the SQL works, not
as business insight. Being clear about that distinction is part of the point.

**3. How do you define net sales, and why cap refunds?**
Net sales = gross (quantity × unit price) − discounts − refunded returns, for
completed orders only. The quality checks found three lines refunded for more
than their value. Capping the refund at the line's checkout value stops one bad
record from pushing revenue negative. Analysis 10 reports how much the cap
removed.

**4. Why are refunds assigned to the order month rather than the return month?**
It keeps each month's net sales tied to the orders that produced them, which
suits product and cohort analysis. The downside is that recent months change as
late returns arrive. A finance view would book refunds in the return month; I'd
choose based on who the report is for.

**5. How do you handle cancelled, pending and fully returned orders?**
Cancelled and pending orders are excluded from sales but shown in a status
breakdown. A fully returned line nets to zero, but the order still counts as an
order, so returns lower net AOV rather than the order count.

**6. Why run duplicate and orphan checks when constraints already prevent them?**
They always pass in this schema. I keep them because the same checks matter on
platforms that don't enforce keys, such as Snowflake, where primary and foreign
keys are declared but not enforced.

**7. How did you calculate cohort retention?**
Cohort = month of first in-scope order. For each later order I work out months
since the cohort month, then divide distinct active customers in month k by
cohort size. Months a cohort hasn't reached yet show NULL rather than zero, so
young cohorts don't look like they churned.

**8. What's wrong with a simple repeat-purchase rate?**
Right-censoring. Someone who joined last month hasn't had time to come back.
Analysis 4b compares only customers whose first order was at least 90 days
before the window end and measures repeats within 90 days.

**9. Do discounts increase order value?**
The data shows an association: [result from your run]. It doesn't prove
causation. Discounts cluster in November and among budget customers, and the
generator makes promo baskets slightly bigger by design. I split the comparison
by segment as a partial control, but an A/B test would be needed to measure the
effect.

**10. How did you build the RFM scores?**
Recency and monetary use NTILE(5). Frequency uses fixed thresholds because most
customers have one or two orders, and quintiles would split identical counts
arbitrarily. Segments like `champions` and `at_risk` come from simple rules,
which are a judgement call.

**11. Which SQL features did you use, and why?**
CTEs to break logic into steps; LAG for month-on-month growth; running SUM
windows for cumulative sales and Pareto share; RANK, DENSE_RANK, NTILE and
PERCENT_RANK for ranking; FILTER for conditional aggregation and pivots;
GROUPING SETS and ROLLUP for several breakdowns in one query; generate_series
so months with no sales still appear; NULLIF to avoid dividing by zero.

**12. How would you know the views are correct?**
I computed the headline totals independently in Python from the raw CSVs, using
the same definitions, and wrote them into a reconciliation query in
`04_views.sql`. The SQL has to match those numbers before I trust any analysis.

**13. What would you do next?**
Add margin analysis using `unit_cost`, build a Power BI dashboard on the views,
add a date dimension, and test performance with a larger generated dataset
using `EXPLAIN ANALYZE`.

**14. How does this relate to your previous work?**
Answer from your own experience: for example, KPI definition, data validation,
and SQL data modelling from your roles. Be clear that this project itself uses
synthetic data and was built independently.
