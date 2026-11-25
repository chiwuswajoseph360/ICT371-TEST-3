-- ICT371 Question 1: Pharmacy Stock and Daily Sales (PostgreSQL + pg_cron)
-- Run top to bottom. Sales are loaded at the end of (d), once the
-- procedure (c) and trigger (d) both exist.
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE SCHEMA IF NOT EXISTS q1;
SET search_path = q1, public;

-- (a) Database and seed data ---------------------------------------------
CREATE TABLE medicines (
  medicine_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  medicine_name VARCHAR(100) NOT NULL,
  unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  stock_qty     INT NOT NULL CHECK (stock_qty >= 0)
);
CREATE TABLE sales (
  sale_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
  quantity    INT NOT NULL CHECK (quantity > 0),
  unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  sold_on     TIMESTAMP NOT NULL
);
CREATE TABLE stock_audit (
  audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
  old_qty     INT NOT NULL,
  new_qty     INT NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_sales (
  sales_date   DATE PRIMARY KEY,
  total_qty    INT NOT NULL DEFAULT 0,
  total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
 ('Paracetamol 500mg', 2.50, 50),
 ('Amoxicillin 250mg', 8.00, 30),
 ('Ibuprofen 400mg',   4.25, 12),
 ('Cetirizine 10mg',   3.00, 20);
-- The six sales are loaded through pr_record_sale at the end of (d).

-- (b) Function -----------------------------------------------------------
CREATE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_price NUMERIC;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
  END IF;
  SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine: %', p_medicine_id;
  END IF;
  RETURN ROUND(v_price * p_quantity, 2);
END $$;

SELECT fn_sale_value(1, 4);        -- 10.00
-- SELECT fn_sale_value(99, 4);    -- ERROR: unknown medicine
-- SELECT fn_sale_value(1, 0);     -- ERROR: invalid quantity

-- (c) Procedure ----------------------------------------------------------
-- A CALL is atomic: any RAISE EXCEPTION rolls back everything it did.
CREATE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT, p_sold_on TIMESTAMP)
LANGUAGE plpgsql AS $$
DECLARE v_stock INT; v_price NUMERIC;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
  END IF;
  IF p_sold_on IS NULL THEN
    RAISE EXCEPTION 'sold_on is required';
  END IF;

  SELECT stock_qty, unit_price INTO v_stock, v_price
  FROM medicines WHERE medicine_id = p_medicine_id
  FOR UPDATE;                                   -- lock: stops concurrent overselling
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine: %', p_medicine_id;
  END IF;
  IF v_stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock: have %, need %', v_stock, p_quantity;
  END IF;

  INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
  VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);   -- current price stored

  UPDATE medicines SET stock_qty = stock_qty - p_quantity   -- deducted exactly once
  WHERE medicine_id = p_medicine_id;
END $$;

-- (d) Trigger ------------------------------------------------------------
CREATE FUNCTION trg_fn_stock_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
  VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
  RETURN NEW;
END $$;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)   -- only real stock changes
EXECUTE FUNCTION trg_fn_stock_audit();

-- Load the six valid sales through the procedure (trigger audits each one)
CALL pr_record_sale(1, 5,  TIMESTAMP '2026-11-23 09:30');
CALL pr_record_sale(2, 10, TIMESTAMP '2026-11-23 10:15');
CALL pr_record_sale(3, 4,  TIMESTAMP '2026-11-23 11:00');
CALL pr_record_sale(1, 3,  TIMESTAMP '2026-11-23 14:20');
CALL pr_record_sale(4, 2,  TIMESTAMP '2026-11-24 08:45');
CALL pr_record_sale(2, 5,  TIMESTAMP '2026-11-24 09:10');

-- Tests: invalid sales leave both tables unchanged
-- CALL pr_record_sale(1, 1000, now());   -- Insufficient stock
-- CALL pr_record_sale(99, 1, now());     -- Unknown medicine
-- CALL pr_record_sale(1, -2, now());     -- Invalid quantity
UPDATE medicines SET unit_price = 2.75 WHERE medicine_id = 1;   -- no audit row
SELECT * FROM stock_audit;                                      -- 6 rows

-- (e) View ---------------------------------------------------------------
CREATE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

CALL pr_record_sale(3, 1, now());      -- a further sale
SELECT * FROM v_low_stock;             -- Ibuprofen: 12 - 4 - 1 = 7

-- (f) Index --------------------------------------------------------------
-- Equality column first (medicine_id), range column second (sold_on).
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);
ANALYZE sales;
SET enable_seqscan = off;    -- demo only: a tiny table would otherwise use Seq Scan
EXPLAIN
SELECT sale_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on >= '2026-11-23' AND sold_on < '2026-11-25';
RESET enable_seqscan;
-- Justification: the index jumps to one medicine's entries, then reads only
-- the date range, already sorted. An index on sold_on alone scans every
-- medicine; an index on medicine_id alone must filter dates row by row.

-- (g) Scheduled job ------------------------------------------------------
CREATE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql SET search_path = q1, public AS $$
BEGIN
  INSERT INTO daily_sales (sales_date, total_qty, total_amount)
  SELECT p_day, COALESCE(SUM(quantity), 0), COALESCE(SUM(quantity * unit_price), 0)
  FROM sales
  WHERE sold_on >= p_day AND sold_on < p_day + 1
  ON CONFLICT (sales_date) DO UPDATE            -- REPLACE, never add: rerun-safe
    SET total_qty = EXCLUDED.total_qty, total_amount = EXCLUDED.total_amount;
END $$;

SELECT cron.schedule('q1_refresh_sales', '15 0 * * *',
                     $$CALL q1.pr_refresh_sales(CURRENT_DATE - 1)$$);   -- 00:15 daily

CALL pr_refresh_sales('2026-11-23');
CALL pr_refresh_sales('2026-11-23');            -- rerun: totals unchanged
SELECT * FROM daily_sales;                      -- 22 units, 117.00
