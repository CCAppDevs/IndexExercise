-- =====================================================================
--  SQLite Index Lesson — sample database generator
-- =====================================================================
--
--  Builds a small online-store database large enough that a full table
--  scan is noticeably slow, so the effect of an index is obvious.
--
--    customers    100,000 rows
--    products       1,000 rows
--    orders     2,000,000 rows   (~150 MB database file)
--
--  HOW TO RUN (from a terminal):
--      sqlite3 store.db < create_index_lesson_db.sql
--
--  Build with the sqlite3 command-line tool (3.35 or newer recommended).
--  GUI tools such as DB Browser for SQLite can then open store.db for the
--  lesson; they may refuse this script's BEGIN/COMMIT and PRAGMA lines.
--
--  Build time is typically 3–30 seconds depending on the machine.
--
--  NOTES FOR THE INSTRUCTOR
--  * The data is deterministic pseudo-random: every student who runs this
--    script gets exactly the same rows, so the lesson guide's example
--    values and row counts match everyone's screen.
--  * On purpose, NO secondary indexes are created. The only indexes are
--    the INTEGER PRIMARY KEYs (the rowid). Students create the rest.
--  * The REFERENCES clauses document the relationships but SQLite does
--    NOT automatically index foreign-key columns — a lesson point.
--  * The script is re-runnable: it drops and recreates everything.
-- =====================================================================

-- Faster bulk load. These settings are for building the file only.
PRAGMA journal_mode = OFF;
PRAGMA synchronous  = OFF;
PRAGMA foreign_keys = OFF;

-- Start clean (also removes any indexes, test tables and ANALYZE
-- statistics left over from a previous class run).
DROP TABLE IF EXISTS orders_test;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS sqlite_stat1;
DROP TABLE IF EXISTS sqlite_stat4;

-- ---------------------------------------------------------------------
--  Schema
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    customer_id   INTEGER PRIMARY KEY,   -- alias for the rowid (already indexed)
    first_name    TEXT NOT NULL,
    last_name     TEXT NOT NULL,
    email         TEXT NOT NULL,         -- unique in practice, but no index yet
    city          TEXT NOT NULL,
    state         TEXT NOT NULL,
    signup_date   TEXT NOT NULL,         -- 'YYYY-MM-DD'
    loyalty_tier  TEXT NOT NULL          -- bronze / silver / gold / platinum
);

CREATE TABLE products (
    product_id    INTEGER PRIMARY KEY,
    sku           TEXT NOT NULL,
    product_name  TEXT NOT NULL,
    category      TEXT NOT NULL,
    list_price    REAL NOT NULL
);

CREATE TABLE orders (
    order_id        INTEGER PRIMARY KEY,
    tracking_number TEXT NOT NULL,       -- unique, random-looking, no index yet
    customer_id     INTEGER NOT NULL REFERENCES customers(customer_id),
    product_id      INTEGER NOT NULL REFERENCES products(product_id),
    order_date      TEXT NOT NULL,       -- 'YYYY-MM-DD', 2021-01-01 .. 2025-12-31
    quantity        INTEGER NOT NULL,
    unit_price      REAL NOT NULL,
    status          TEXT NOT NULL        -- heavily skewed: ~80% 'delivered'
);

BEGIN;

-- ---------------------------------------------------------------------
--  Lookup lists used by the generator (temporary, dropped at the end)
-- ---------------------------------------------------------------------
CREATE TEMP TABLE first_names (i INTEGER PRIMARY KEY, name TEXT);
INSERT INTO first_names (i, name) VALUES
 (0,'James'),(1,'Mary'),(2,'Robert'),(3,'Patricia'),(4,'John'),(5,'Jennifer'),
 (6,'Michael'),(7,'Linda'),(8,'David'),(9,'Elizabeth'),(10,'William'),(11,'Barbara'),
 (12,'Richard'),(13,'Susan'),(14,'Joseph'),(15,'Jessica'),(16,'Thomas'),(17,'Sarah'),
 (18,'Carlos'),(19,'Karen'),(20,'Daniel'),(21,'Lisa'),(22,'Matthew'),(23,'Nancy'),
 (24,'Anthony'),(25,'Betty'),(26,'Mark'),(27,'Sandra'),(28,'Wei'),(29,'Ashley'),
 (30,'Steven'),(31,'Emily'),(32,'Andrew'),(33,'Priya'),(34,'Joshua'),(35,'Maria'),
 (36,'Kevin'),(37,'Aisha'),(38,'Brian'),(39,'Sofia');

CREATE TEMP TABLE last_names (i INTEGER PRIMARY KEY, name TEXT);
INSERT INTO last_names (i, name) VALUES
 (0,'Smith'),(1,'Johnson'),(2,'Williams'),(3,'Brown'),(4,'Jones'),(5,'Garcia'),
 (6,'Miller'),(7,'Davis'),(8,'Rodriguez'),(9,'Martinez'),(10,'Hernandez'),(11,'Lopez'),
 (12,'Gonzalez'),(13,'Wilson'),(14,'Anderson'),(15,'Thomas'),(16,'Taylor'),(17,'Moore'),
 (18,'Jackson'),(19,'Martin'),(20,'Lee'),(21,'Perez'),(22,'Thompson'),(23,'White'),
 (24,'Harris'),(25,'Sanchez'),(26,'Clark'),(27,'Ramirez'),(28,'Lewis'),(29,'Robinson'),
 (30,'Walker'),(31,'Young'),(32,'Allen'),(33,'King'),(34,'Wright'),(35,'Scott'),
 (36,'Nguyen'),(37,'Hill'),(38,'Patel'),(39,'Kim');

CREATE TEMP TABLE cities (i INTEGER PRIMARY KEY, city TEXT, state TEXT);
INSERT INTO cities (i, city, state) VALUES
 (0,'Los Angeles','CA'),(1,'San Diego','CA'),(2,'San Jose','CA'),(3,'Sacramento','CA'),
 (4,'Houston','TX'),(5,'Dallas','TX'),(6,'Austin','TX'),(7,'San Antonio','TX'),
 (8,'New York','NY'),(9,'Buffalo','NY'),(10,'Miami','FL'),(11,'Orlando','FL'),
 (12,'Tampa','FL'),(13,'Chicago','IL'),(14,'Phoenix','AZ'),(15,'Tucson','AZ'),
 (16,'Philadelphia','PA'),(17,'Pittsburgh','PA'),(18,'Columbus','OH'),(19,'Cleveland','OH'),
 (20,'Seattle','WA'),(21,'Spokane','WA'),(22,'Denver','CO'),(23,'Boston','MA'),
 (24,'Atlanta','GA'),(25,'Nashville','TN'),(26,'Portland','OR'),(27,'Las Vegas','NV'),
 (28,'Detroit','MI'),(29,'Minneapolis','MN');

CREATE TEMP TABLE categories (i INTEGER PRIMARY KEY, name TEXT, base_price REAL);
INSERT INTO categories (i, name, base_price) VALUES
 (0,'Electronics',120.0),(1,'Books',15.0),(2,'Kitchen',35.0),(3,'Toys',25.0),
 (4,'Garden',40.0),(5,'Sports',55.0),(6,'Clothing',30.0),(7,'Beauty',18.0),
 (8,'Office',22.0),(9,'Pet Supplies',28.0);

CREATE TEMP TABLE adjectives (i INTEGER PRIMARY KEY, word TEXT);
INSERT INTO adjectives (i, word) VALUES
 (0,'Classic'),(1,'Deluxe'),(2,'Compact'),(3,'Premium'),(4,'Eco'),(5,'Ultra'),
 (6,'Smart'),(7,'Travel'),(8,'Pro'),(9,'Mini'),(10,'Heavy-Duty'),(11,'Vintage'),
 (12,'Wireless'),(13,'Organic'),(14,'Portable'),(15,'Essential'),(16,'Family'),
 (17,'Studio'),(18,'Everyday'),(19,'Signature');

-- ---------------------------------------------------------------------
--  Deterministic pseudo-random numbers
--  SQLite's random() can't be seeded, so we derive "random" values from
--  the row number n using modular squaring with a large prime
--  (2147483647). Each generated column uses a different h-value.
-- ---------------------------------------------------------------------

-- Products --------------------------------------------------------------
INSERT INTO products (product_id, sku, product_name, category, list_price)
WITH RECURSIVE seq(n) AS (
    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 1000
),
h AS (
    SELECT n,
           ((n * 7919 + 104729) % 2147483647) * ((n * 7919 + 104729) % 2147483647) % 2147483647 AS h1
    FROM seq
),
h2 AS (
    SELECT n, h1, (h1 + n) * (h1 + n) % 2147483647 AS h2 FROM h
)
SELECT n,
       printf('SKU-%05d', n),
       a.word || ' ' || c.name || ' Item ' || n,
       c.name,
       round(c.base_price * (0.4 + (h2 % 1600) / 1000.0), 2)
FROM h2
JOIN categories c ON c.i = h1 % 10
JOIN adjectives a ON a.i = h2 % 20;

-- Customers -------------------------------------------------------------
INSERT INTO customers (customer_id, first_name, last_name, email, city, state,
                       signup_date, loyalty_tier)
WITH RECURSIVE seq(n) AS (
    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 100000
),
h AS (
    SELECT n,
           ((n * 15485863 + 32452843) % 2147483647) * ((n * 15485863 + 32452843) % 2147483647) % 2147483647 AS h1
    FROM seq
),
hh AS (
    SELECT n, h1,
           (h1 + n) * (h1 + n) % 2147483647 AS h2
    FROM h
),
hhh AS (
    SELECT n, h1, h2,
           (h2 + n) * (h2 + n) % 2147483647 AS h3
    FROM hh
)
SELECT n,
       f.name,
       l.name,
       lower(f.name) || '.' || lower(l.name) || n || '@example.com',
       c.city,
       c.state,
       date('2019-01-01', '+' || (h3 % 2372) || ' days'),          -- 2019-01-01 .. 2025-06-30
       CASE WHEN h3 / 7 % 100 < 60 THEN 'bronze'
            WHEN h3 / 7 % 100 < 85 THEN 'silver'
            WHEN h3 / 7 % 100 < 97 THEN 'gold'
            ELSE 'platinum' END
FROM hhh
JOIN first_names f ON f.i = h1 % 40
JOIN last_names  l ON l.i = h2 % 40
JOIN cities      c ON c.i = (h1 / 40) % 30;

-- Orders (the big one) --------------------------------------------------
INSERT INTO orders (order_id, tracking_number, customer_id, product_id,
                    order_date, quantity, unit_price, status)
WITH RECURSIVE seq(n) AS (
    SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 2000000
),
h AS (
    SELECT n,
           ((n * 48271 + 11) % 2147483647) * ((n * 48271 + 11) % 2147483647) % 2147483647 AS h1
    FROM seq
),
hh AS (
    SELECT n, h1,
           (h1 + n) * (h1 + n) % 2147483647 AS h2
    FROM h
)
SELECT n,
       -- n -> tracking number is a one-to-one mapping, so every value is unique
       printf('TRK%09d', ((n + 123456789) * 7368787) % 999999937),
       h1 % 100000 + 1,
       h2 % 1000 + 1,
       -- dates rise with order_id, like a real store, ~1,100 orders per day
       date('2021-01-01', '+' || ((n - 1) * 1826 / 2000000) || ' days'),
       CASE WHEN h2 / 1000 % 10 < 6 THEN 1
            WHEN h2 / 1000 % 10 < 8 THEN 2
            WHEN h2 / 1000 % 10 < 9 THEN 3
            ELSE 4 + (h1 % 3) END,
       p.list_price,
       CASE WHEN h1 / 100000 % 100 < 80 THEN 'delivered'
            WHEN h1 / 100000 % 100 < 90 THEN 'shipped'
            WHEN h1 / 100000 % 100 < 95 THEN 'processing'
            WHEN h1 / 100000 % 100 < 99 THEN 'cancelled'
            ELSE 'returned' END
FROM hh
JOIN products p ON p.product_id = h2 % 1000 + 1;

DROP TABLE temp.first_names;
DROP TABLE temp.last_names;
DROP TABLE temp.cities;
DROP TABLE temp.categories;
DROP TABLE temp.adjectives;

COMMIT;

-- Back to normal, safe settings for the lesson itself.
PRAGMA journal_mode = DELETE;
PRAGMA synchronous  = FULL;
PRAGMA foreign_keys = ON;

-- Quick sanity check: should print 100000 | 1000 | 2000000
SELECT (SELECT count(*) FROM customers) AS customers,
       (SELECT count(*) FROM products)  AS products,
       (SELECT count(*) FROM orders)    AS orders;
