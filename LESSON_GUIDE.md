# SQLite Indexes — Lesson Guide

## Lesson overview

Students finish able to read a query plan, pick the right index for a query, and explain when an index does not help. The lesson runs 75–90 minutes. Every plan and timing in this guide was measured on the database the script builds.

**Learning goals**

- Read `EXPLAIN QUERY PLAN` output: SCAN vs SEARCH, COVERING INDEX, TEMP B-TREE.
- Index a lookup column, a foreign key and a multi-column filter.
- Choose the column order of a composite index (the leftmost-prefix rule).
- Spot query patterns that cannot use an index.
- Weigh faster reads against disk space and slower writes.

### Before class

1. Build the database: `sqlite3 store.db < create_index_lesson_db.sql`. It takes 3–30 seconds and makes a file of about 127 MB. The last line printed should be `100000|1000|2000000`.
2. Use the sqlite3 command-line tool, version 3.35 or newer. Plans in this guide were captured on 3.53. Versions before 3.36 print `SCAN TABLE orders` where this guide shows `SCAN orders`; the meaning is the same.
3. Have every student build their own copy. The data is deterministic, so everyone sees the same rows, IDs and counts.

### Shell setup

```
sqlite3 store.db
.timer on
.headers on
.mode box
```

`.timer on` prints `Run Time: real 0.084 user … sys …` after each statement; read the `real` value, in seconds. Prefix any query with `EXPLAIN QUERY PLAN` to see the plan without running it, or turn on `.eqp on` to print the plan before every query. Use `.mode column` if `.mode box` is not available.

### Notes on timing

- Run each slow query twice. The first run includes reading the file from disk.
- Reference times here come from a Linux cloud machine. Student laptops may be 0.5–3× different; the ratios are what to teach.
- To reset at any point, rerun the build script. It drops every table, index and statistic, then rebuilds.

## Part 1 — Meet the data (5 min)

The store has three tables and no secondary indexes, so any lookup that is not on a primary key reads the whole table.

| Table | Rows | Columns worth noticing |
| --- | --- | --- |
| `customers` | 100,000 | `email` (unique), `city`, `state`, `loyalty_tier` |
| `products` | 1,000 | `category`, `list_price` |
| `orders` | 2,000,000 | `tracking_number` (unique), `customer_id`, `product_id`, `order_date` (2021–2025), `status` |

```sql
.tables
.schema orders
SELECT * FROM orders LIMIT 5;
SELECT name, tbl_name FROM sqlite_master WHERE type = 'index';
```

The last query returns nothing: there are no indexes yet.

**Talking points**

- `INTEGER PRIMARY KEY` is an alias for the rowid. The table itself is stored as a B-tree sorted by it, so primary-key lookups are already fast.
- `REFERENCES customers(customer_id)` documents the relationship but does not create an index. Part 3 shows what that costs.

## Part 2 — Full scan vs index (10 min)

Finding one order by tracking number reads all 2 million rows (about 80 ms); one `CREATE INDEX` makes it effectively instant.

**Step 1 — Primary-key baseline.**

```sql
EXPLAIN QUERY PLAN SELECT * FROM orders WHERE order_id = 1234567;
SELECT * FROM orders WHERE order_id = 1234567;
```

Plan: `SEARCH orders USING INTEGER PRIMARY KEY (rowid=?)`. Time: about 0 ms. The row's tracking number is `TRK100991084`.

**Step 2 — Same row, unindexed column.**

```sql
EXPLAIN QUERY PLAN SELECT * FROM orders WHERE tracking_number = 'TRK100991084';
SELECT * FROM orders WHERE tracking_number = 'TRK100991084';
```

Plan: `SCAN orders`. Time: about 80 ms. Same single row, but SQLite had to read every row to be sure there was no second match.

**Step 3 — Build the index.**

```sql
CREATE INDEX idx_orders_tracking ON orders(tracking_number);
```

Takes about 0.8 s. Point out that building an index is a one-time cost paid up front.

**Step 4 — Rerun Step 2.** Plan: `SEARCH orders USING INDEX idx_orders_tracking (tracking_number=?)`. Time: about 0 ms.

**Talking points**

- An index is a separate B-tree of (value, rowid) pairs kept in sorted order. Finding a value takes about 21 comparisons for 2 million entries, instead of 2 million.
- 80 ms sounds small. At 100 lookups a second, it is 8 seconds of work every second, and the server falls behind.
- Ask the class: why did `order_id` never need an index?

## Part 3 — Foreign keys and joins (15 min)

SQLite does not index foreign keys for you, and an unindexed join column turns a 20-row answer into a 1.8-second query. This is the biggest win of the lesson: about 90,000×.

**Step 1 — One customer's order history.**

```sql
SELECT order_id, order_date, status
FROM orders
WHERE customer_id = 42424
ORDER BY order_date;
```

Plan: `SCAN orders` then `USE TEMP B-TREE FOR ORDER BY`. Time: about 80 ms for 20 rows.

**Step 2 — The same history, found by email.**

```sql
SELECT c.first_name, c.last_name, o.order_id, o.order_date, o.status
FROM customers AS c
JOIN orders AS o ON o.customer_id = c.customer_id
WHERE c.email = 'ashley.moore42424@example.com';
```

Plan: `SCAN o`, then `SEARCH c USING INTEGER PRIMARY KEY (rowid=?)`. Time: about 1.8 s. The planner walks all 2 million orders and, for each one, looks up its customer to test the email: 2 million lookups.

**Step 3 — Ask students to predict, then run.**

```sql
SELECT c.customer_id, c.first_name,
       (SELECT count(*) FROM orders AS o
        WHERE o.customer_id = c.customer_id) AS order_count
FROM customers AS c
WHERE c.customer_id <= 20;
```

Plan: `CORRELATED SCALAR SUBQUERY 1` with `SCAN o` inside it. Time: about 1.85 s, because 20 customers means 20 full scans of `orders`.

**Step 4 — Index the foreign key.**

```sql
CREATE INDEX idx_orders_customer ON orders(customer_id);
```

Takes about 1 s. Rerun Steps 1–3:

| Query | New plan | Before | After |
| --- | --- | --- | --- |
| Step 1 history | `SEARCH orders USING INDEX idx_orders_customer (customer_id=?)` + TEMP B-TREE | 80 ms | 0.02 ms |
| Step 2 by email | `SCAN c`, then `SEARCH o USING INDEX idx_orders_customer` | 1.8 s | 4 ms |
| Step 3 counts | `SEARCH o USING COVERING INDEX idx_orders_customer` | 1.85 s | 0.02 ms |

**Step 5 — Index the other side of the join.**

```sql
CREATE INDEX idx_customers_email ON customers(email);
```

Rerun Step 2. Plan: `SEARCH c USING INDEX idx_customers_email (email=?)`, then `SEARCH o USING INDEX idx_orders_customer`. Time: about 0.02 ms.

**Talking points**

- The plan for Step 2 flipped: once `orders` had a usable index, the planner started from `customers` instead. The planner reorders joins based on which indexes exist.
- Step 3 says COVERING. Leave that word on the board; Part 5 explains it.
- Rule for any schema: index every foreign-key column you join or filter on.

## Part 4 — Composite indexes and the leftmost-prefix rule (10 min)

A two-column index serves a filter on its first column, or on both columns, but not on the second column alone.

**Step 1 — Filter on customer and date.**

```sql
SELECT order_id, order_date, status
FROM orders
WHERE customer_id = 42424 AND order_date >= '2024-01-01'
ORDER BY order_date;
```

Plan: `SEARCH orders USING INDEX idx_orders_customer (customer_id=?)` + `USE TEMP B-TREE FOR ORDER BY`. Fast already (10 rows), but SQLite still filters dates and sorts by hand.

**Step 2 — Build the composite.**

```sql
CREATE INDEX idx_orders_customer_date ON orders(customer_id, order_date);
```

Rerun Step 1. Plan: `SEARCH orders USING INDEX idx_orders_customer_date (customer_id=? AND order_date>?)`. The TEMP B-TREE line is gone: within each customer, the index is already sorted by date.

**Step 3 — Second column alone.**

```sql
SELECT * FROM orders WHERE order_date = '2024-03-15';
```

Plan: `SCAN orders`. Time: about 70 ms for 1,095 rows. The composite cannot help.

**Step 4 — Remove the now-redundant index.**

```sql
DROP INDEX idx_orders_customer;
```

Rerun the Part 3 queries. The history query now uses `idx_orders_customer_date (customer_id=?)` with no TEMP B-TREE, and the counts query uses `COVERING INDEX idx_orders_customer_date`.

**Talking points**

- Phone-book analogy: sorted by last name, then first name. Finding every "Smith" is easy; finding every "Priya" means reading every page.
- Column order rule of thumb: equality columns first, then the range or sort column.
- An index on `(a, b)` makes a separate index on `(a)` redundant. Keeping both just costs disk space and write time.
- SQLite can sometimes skip-scan the first column after `ANALYZE`, but only when it has few distinct values. With 100,000 customers, do not count on it.

## Part 5 — Covering indexes (10 min)

An index that holds every column a query needs answers it without touching the table. An index that does not hold them can be slower than no index at all: here, 3× slower than a full scan.

All three queries cover customers 1–10,000, which is 200,586 orders (10% of the table).

```sql
-- A: needs only customer_id and order_date
SELECT count(*), max(order_date)
FROM orders WHERE customer_id BETWEEN 1 AND 10000;

-- B: also needs quantity and unit_price
SELECT round(sum(quantity * unit_price), 2) AS revenue
FROM orders WHERE customer_id BETWEEN 1 AND 10000;

-- C: same as B, index disabled with a unary +
SELECT round(sum(quantity * unit_price), 2) AS revenue
FROM orders WHERE +customer_id BETWEEN 1 AND 10000;
```

| Query | Plan | Time |
| --- | --- | --- |
| A | `SEARCH orders USING COVERING INDEX idx_orders_customer_date` | 8 ms |
| B | `SEARCH orders USING INDEX idx_orders_customer_date` | 300 ms |
| C | `SCAN orders` | 95 ms |

B is slowest because each of the 200,586 index entries sends SQLite to a different place in the table to fetch the row. C reads the table once, front to back. The unary `+` makes the column an expression, which hides it from the planner; it is a diagnostic trick, not something to ship.

**Make B covering:**

```sql
CREATE INDEX idx_orders_customer_spend ON orders(customer_id, quantity, unit_price);
```

Rerun B. Plan: `SEARCH orders USING COVERING INDEX idx_orders_customer_spend`. Time: about 8 ms, down from 300 ms.

Then drop it before moving on: `DROP INDEX idx_orders_customer_spend;`. It serves one query shape, and Part 9 shows what every extra index costs. Exercise 1 brings it back.

**Talking points**

- COVERING in a plan means "answered from the index alone". It is the fastest kind of index use.
- The Part 3 counts query was covering for free: counting needs only `customer_id`, which is in the index.

## Part 6 — Ranges, sorting and LIMIT (5 min)

An index on `order_date` turns "latest 10 orders" and "this month's revenue" from full scans into reads of a few pages.

```sql
-- Latest 10 orders
SELECT * FROM orders ORDER BY order_date DESC LIMIT 10;

-- December 2025 revenue
SELECT count(*) AS orders, round(sum(quantity * unit_price), 2) AS revenue
FROM orders
WHERE order_date BETWEEN '2025-12-01' AND '2025-12-31';
```

Before: the first plan is `SCAN orders` + `USE TEMP B-TREE FOR ORDER BY` (about 110 ms). The second is `SCAN orders` (about 85 ms; 33,953 orders, revenue 2,818,005.15).

```sql
CREATE INDEX idx_orders_date ON orders(order_date);
```

After (index build about 0.5 s):

- Latest 10: `SCAN orders USING INDEX idx_orders_date`, about 0.01 ms. This SCAN walks the index backward and stops after 10 rows, so it is cheap.
- December: `SEARCH orders USING INDEX idx_orders_date (order_date>? AND order_date<?)`, about 3 ms.

**Talking points**

- `SCAN … USING INDEX` plus a LIMIT is fine. The same plan without a LIMIT still reads everything.
- Rows with the same date can come back in a different order once the index exists. Add a tiebreaker such as `order_id` if order matters.

## Part 7 — Things that silently disable an index (10 min)

Wrapping an indexed column in a function or arithmetic, or searching with a leading wildcard, hides the column from the planner. The query still works; it just falls back to a full scan.

```sql
-- 1. Function on the column
SELECT count(*), round(sum(quantity * unit_price), 2) FROM orders
WHERE strftime('%Y-%m', order_date) = '2025-12';

-- 2. Case-folding the column
SELECT * FROM customers WHERE lower(email) = 'ashley.moore42424@example.com';

-- 3. LIKE with a prefix
SELECT * FROM orders WHERE tracking_number LIKE 'TRK1009910%';

-- 4. LIKE with a leading wildcard
SELECT * FROM orders WHERE tracking_number LIKE '%991084';

-- 5. Arithmetic on the column
SELECT * FROM orders WHERE order_id + 0 = 1234567;
```

| # | Plan | Time | Fix | Fixed plan |
| --- | --- | --- | --- | --- |
| 1 | `SCAN orders` | 370 ms | Compare the bare column: `order_date BETWEEN '2025-12-01' AND '2025-12-31'` | SEARCH, 3 ms (Part 6) |
| 2 | `SCAN customers` | 10 ms | Expression index: `CREATE INDEX idx_customers_email_lower ON customers(lower(email));` | `SEARCH … idx_customers_email_lower (<expr>=?)`, 0 ms |
| 3 | `SCAN orders` | 100 ms | `GLOB 'TRK1009910*'`, or `>= 'TRK1009910' AND < 'TRK1009911'` | `SEARCH … idx_orders_tracking (tracking_number>? AND tracking_number<?)`, 0 ms |
| 4 | `SCAN orders` | 150 ms | No B-tree fix. Use full-text search (FTS5) or store a reversed copy of the value | — |
| 5 | `SCAN orders` | 60 ms | Keep the column bare: `order_id = 1234567` | SEARCH, 0 ms |

**Talking points**

- Query 1 is slower than a plain scan because `strftime` runs 2 million times. It returns the same 33,953 orders as the Part 6 range query, 100× slower.
- Query 3 surprises people. `LIKE` is case-insensitive by default, while the index is sorted case-sensitively, so SQLite will not use it. `GLOB` is case-sensitive, so it can.
- An expression index only helps when the query uses exactly the same expression.

## Part 8 — Selectivity: when an index hurts (10 min)

An index on `status` makes the rare value (`returned`, 1% of rows) about 7× faster and the common value (`delivered`, 80%) about 35% slower.

**Step 1 — Look at the distribution.**

```sql
SELECT status, count(*) AS n, round(100.0 * count(*) / 2000000, 1) AS pct
FROM orders GROUP BY status ORDER BY n DESC;
```

| status | n | pct |
| --- | --- | --- |
| delivered | 1,601,229 | 80.1 |
| shipped | 199,407 | 10.0 |
| processing | 99,976 | 5.0 |
| cancelled | 79,415 | 4.0 |
| returned | 19,973 | 1.0 |

**Step 2 — Time both values, then index, then time again.**

```sql
SELECT count(*), round(sum(quantity * unit_price), 2) FROM orders WHERE status = 'returned';
SELECT count(*), round(sum(quantity * unit_price), 2) FROM orders WHERE status = 'delivered';

CREATE INDEX idx_orders_status ON orders(status);

-- rerun both, then compare with the index switched off:
SELECT count(*), round(sum(quantity * unit_price), 2) FROM orders WHERE +status = 'delivered';
```

| Value | Before (SCAN) | After (SEARCH … idx_orders_status) | Index off (`+status`) |
| --- | --- | --- | --- |
| returned | 120 ms | 18 ms | — |
| delivered | 160 ms | 210 ms | 160 ms |

**Step 3 — Will statistics fix it?**

```sql
ANALYZE;
SELECT tbl, idx, stat FROM sqlite_stat1 WHERE tbl = 'orders';
```

The row for `idx_orders_status` reads `2000000 400000`: 2 million rows, about 400,000 per value on average. The average hides the skew, so the plan for `delivered` stays on the index. Builds compiled with the optional STAT4 feature can see skew; most standard builds do not have it.

**Talking points**

- A non-covering index pays off only when a query touches a small fraction of the table. Part 5 showed 10% already losing to a scan here.
- Low-cardinality columns (status, booleans, tiers) rarely deserve an index alone. Pair them with a selective or sort column instead; Exercise 2 does exactly that.

## Part 9 — The price of indexes (5 min)

The four indexes on `orders` now take 154 MB, more than the 113 MB table itself, and they make a bulk insert about 17× slower.

**Step 1 — Disk space.**

```sql
SELECT name, round(sum(pgsize) / 1048576.0, 1) AS mb
FROM dbstat GROUP BY name ORDER BY mb DESC;
```

| name | MB |
| --- | --- |
| orders (table) | 113.3 |
| idx_orders_customer_date | 43.5 |
| idx_orders_tracking | 40.3 |
| idx_orders_date | 36.3 |
| idx_orders_status | 34.1 |
| customers (table) | 7.9 |
| idx_customers_email | 3.7 |
| idx_customers_email_lower | 3.7 |

The file grew from about 127 MB to about 283 MB. If the shell reports `no such table: dbstat`, check the file size instead, or run `PRAGMA page_count;` and multiply by `PRAGMA page_size;`.

**Step 2 — Write cost.**

```sql
CREATE TABLE orders_test AS SELECT * FROM orders LIMIT 0;
INSERT INTO orders_test SELECT * FROM orders WHERE order_id <= 500000;   -- ~0.16 s

DELETE FROM orders_test;
CREATE INDEX t_tracking  ON orders_test(tracking_number);
CREATE INDEX t_cust_date ON orders_test(customer_id, order_date);
CREATE INDEX t_date      ON orders_test(order_date);
CREATE INDEX t_status    ON orders_test(status);
INSERT INTO orders_test SELECT * FROM orders WHERE order_id <= 500000;   -- ~2.8 s

DROP TABLE orders_test;
```

**Talking points**

- Every INSERT, and every UPDATE or DELETE touching an indexed column, must update every index on the table.
- Tracking numbers are random, so each new entry lands on a different index page. Random writes are the expensive kind.
- Common pattern for big imports: drop the indexes, load the data, recreate the indexes.

## Wrap-up (5 min)

Index what you filter, join and sort on, prove it with `EXPLAIN QUERY PLAN`, and drop what no query uses.

1. Index every foreign-key column you join or filter on. SQLite will not do it for you.
2. In a composite index, put equality columns first, then the range or sort column.
3. An index on `(a, b)` makes one on `(a)` redundant.
4. Make an index covering only for queries that run often.
5. Keep indexed columns bare in WHERE: no functions, arithmetic or leading wildcards. Otherwise, index the expression.
6. Skip indexes on low-selectivity columns unless they are paired with a selective or sort column.
7. Every index costs disk space and write time.

**Plan vocabulary for the board**

| Plan text | Meaning | Verdict |
| --- | --- | --- |
| `SCAN t` | Reads every row | Slow on big tables |
| `SEARCH t USING INTEGER PRIMARY KEY` | Rowid lookup | Fastest |
| `SEARCH t USING INDEX i (col=?)` | Index lookup, then fetch each row | Fast when few rows match |
| `SEARCH t USING COVERING INDEX i` | Answered from the index alone | Fastest index use |
| `SCAN t USING INDEX i` | Walks the index in order | Fine with LIMIT |
| `USE TEMP B-TREE FOR ORDER BY` | SQLite sorts the results itself | An index could remove it |
| `MULTI-INDEX OR` | One index per OR branch | Fine |
| `AUTOMATIC COVERING INDEX` | SQLite built a throwaway index for this one query | Add a real index |

## Exercises

For each query: run it, read the plan, design an index, and measure again. Run them in this order, after Part 9.

**Exercise 1 — Top 5 spenders in Sacramento.**

```sql
SELECT c.customer_id, c.first_name, c.last_name,
       round(sum(o.quantity * o.unit_price), 2) AS spend
FROM customers AS c
JOIN orders AS o ON o.customer_id = c.customer_id
WHERE c.city = 'Sacramento'
GROUP BY c.customer_id
ORDER BY spend DESC
LIMIT 5;
```

**Exercise 2 — The 20 most recent returned orders.**

```sql
SELECT * FROM orders WHERE status = 'returned' ORDER BY order_date DESC LIMIT 20;
```

**Exercise 3 — Find customers by name.** Write and index a query for `last_name = 'Patel' AND first_name = 'Priya'`. Then predict whether `WHERE first_name = 'Priya'` alone can use your index.

**Exercise 4 — Predict the plan** before running it:

```sql
SELECT order_id, status FROM orders
WHERE customer_id = 42424 OR tracking_number = 'TRK100991084';
```

### Answer key

| # | Starting point | Index to add | Result |
| --- | --- | --- | --- |
| 1 | `SCAN c`, `SEARCH o USING INDEX idx_orders_customer_date`; about 140 ms (it was 1.75 s before Part 3) | `customers(city)`, then `orders(customer_id, quantity, unit_price)` | City index: `SEARCH c USING INDEX idx_customers_city`, about 90 ms. Adding the covering index: about 11 ms |
| 2 | `SEARCH orders USING INDEX idx_orders_status` + TEMP B-TREE; about 22 ms | `orders(status, order_date)` | `SEARCH orders USING INDEX idx_orders_status_date (status=?)`, no TEMP B-TREE; about 0.03 ms |
| 3 | `SCAN customers`; 57 rows, about 5 ms | `customers(last_name, first_name)` | `SEARCH … (last_name=? AND first_name=?)`, about 0.04 ms. `first_name` alone still scans: leftmost-prefix rule |
| 4 | — | None needed | `MULTI-INDEX OR`: one index search per branch, 21 rows, about 0.04 ms |

Notes for discussion:

- Exercise 1 gains most from the covering index, because each Sacramento customer has about 20 orders to sum.
- Exercise 2 is the fix for Part 8: the low-selectivity `status` column becomes useful once it leads a composite whose second column serves the sort.
- In Exercise 4, the customer branch may use whichever index starts with `customer_id`. After Exercise 1 that is `idx_orders_customer_spend`.

## Appendix — Reference timings and troubleshooting

Use this to preview what students should see: most demos speed up by 1,000× or more, and the two "slower" rows are the Part 5 and Part 8 teaching moments.

Measured on the generated `store.db` with SQLite 3.53.1, median of 3–5 runs, November 2026. Times under 0.01 ms are shown as 0.01 ms.

| Part | Query | No index | With index | Change |
| --- | --- | --- | --- | --- |
| 2 | Lookup by tracking number | 84 ms | 0.01 ms | 8,400× faster |
| 3 | Customer order history | 84 ms | 0.02 ms | 4,200× faster |
| 3 | Join: customer by email | 1,809 ms | 0.02 ms | 90,450× faster |
| 3 | Order counts, 20 customers | 1,853 ms | 0.02 ms | 92,650× faster |
| 5 | Revenue, 10k customers (plain index) | 96 ms | 305 ms | 3.2× slower |
| 5 | Revenue, 10k customers (covering index) | 96 ms | 8.4 ms | 11× faster |
| 6 | Latest 10 orders | 110 ms | 0.01 ms | 11,000× faster |
| 6 | December revenue (date range) | 86 ms | 2.9 ms | 30× faster |
| 7 | `lower(email)` lookup (expression index) | 10.6 ms | 0.01 ms | 1,060× faster |
| 8 | status = 'returned' (1%) | 121 ms | 18.7 ms | 6.5× faster |
| 8 | status = 'delivered' (80%) | 158 ms | 212 ms | 1.3× slower |

**Troubleshooting**

- Plan says `SCAN TABLE orders` or `SEARCH TABLE …`: the SQLite version is older than 3.36. The meaning is the same.
- The first run is much slower than the second: the file is still being read from disk. Time the second run.
- A plan does not match the guide: list the indexes with `SELECT name FROM sqlite_master WHERE type = 'index';`. A skipped or extra step changes what the planner can choose. Rebuild to reset.
- `no such table: dbstat`: use `PRAGMA page_count;` × `PRAGMA page_size;`, or the file size.
- The build script fails in a GUI tool: build with the sqlite3 command line, then open `store.db` in the GUI.
