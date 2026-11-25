-- ICT371 Question 7: Water Meter Readings and Billing (PostgreSQL + pg_cron)
-- Run top to bottom. Readings and bills are loaded at the end of (d),
-- once the procedure (c) and the trigger (d) both exist.
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE SCHEMA IF NOT EXISTS q7;
SET search_path = q7, public;

-- (a) Database and seed data ---------------------------------------------
CREATE TABLE customers (
  customer_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name   VARCHAR(100) NOT NULL
);
CREATE TABLE readings (
  reading_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id      INT NOT NULL REFERENCES customers(customer_id),
  reading_month    DATE NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),   -- month start
  previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
  current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
  CONSTRAINT uq_cust_month UNIQUE (customer_id, reading_month)
);
CREATE TABLE bills (
  bill_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reading_id  INT NOT NULL UNIQUE REFERENCES readings(reading_id),
  charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
  amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
  due_on      DATE NOT NULL,
  CONSTRAINT chk_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);
CREATE TABLE receivable_snapshot (
  snapshot_date DATE PRIMARY KEY,
  total_due     NUMERIC(14,2) NOT NULL
);

INSERT INTO customers (full_name) VALUES ('Customer One'), ('Customer Two'), ('Customer Three');
-- The six readings and their bills are loaded at the end of (d).

-- (b) Function -----------------------------------------------------------
CREATE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_units IS NULL OR p_units < 0 THEN
    RAISE EXCEPTION 'Invalid consumption: %', p_units;
  END IF;
  IF p_units <= 10 THEN
    RETURN ROUND(p_units * 5, 2);                      -- first 10 units at K5 (0 => 0)
  END IF;
  RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);        -- units above 10 at K8
END $$;

SELECT fn_water_charge(0), fn_water_charge(10), fn_water_charge(15);   -- 0.00, 50.00, 90.00

-- (c) Procedure ----------------------------------------------------------
CREATE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_units NUMERIC;
BEGIN
  IF p_due_on IS NULL THEN RAISE EXCEPTION 'due_on is required'; END IF;
  SELECT current_reading - previous_reading INTO v_units
  FROM readings WHERE reading_id = p_reading_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown reading: %', p_reading_id; END IF;
  IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
    RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
  END IF;
  INSERT INTO bills (reading_id, charge, amount_paid, due_on)
  VALUES (p_reading_id, fn_water_charge(v_units), 0, p_due_on);
END $$;

-- (d) Trigger ------------------------------------------------------------
CREATE FUNCTION trg_fn_reading_check() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.current_reading < NEW.previous_reading THEN
    RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
                    NEW.current_reading, NEW.previous_reading;     -- row is never stored
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_reading_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_fn_reading_check();

-- Seed data: six readings (0, exactly 10, above 10 units)
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
 (1, '2026-09-01', 100, 100),    -- 0 units
 (1, '2026-10-01', 100, 110),    -- exactly 10 units
 (2, '2026-09-01',  50,  65),    -- 15 units
 (2, '2026-10-01',  65,  75),    -- 10 units
 (3, '2026-09-01',   0,   4),    -- 4 units
 (3, '2026-10-01',   4,  30);    -- 26 units
-- INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
--   VALUES (1, '2026-11-01', 200, 150);     -- ERROR, row not stored

-- Seed bills through the procedure
CALL pr_generate_bill(1, '2026-11-10');
CALL pr_generate_bill(2, '2026-11-10');
CALL pr_generate_bill(3, '2026-11-10');
CALL pr_generate_bill(4, '2026-12-10');
CALL pr_generate_bill(5, '2026-12-10');
CALL pr_generate_bill(6, '2026-12-10');
UPDATE bills SET amount_paid = 50 WHERE bill_id = 2;     -- fully paid
UPDATE bills SET amount_paid = 40 WHERE bill_id = 3;     -- part paid (charge 90)
-- CALL pr_generate_bill(1, CURRENT_DATE);               -- ERROR already billed
-- CALL pr_generate_bill(99, CURRENT_DATE);              -- ERROR unknown reading

-- (e) View ---------------------------------------------------------------
CREATE VIEW v_overdue_bills AS
SELECT c.full_name, b.due_on, b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;
SELECT * FROM v_overdue_bills;                           -- Customer Two, outstanding 50.00

-- (f) Index --------------------------------------------------------------
-- Partial index on unpaid bills only, ordered by due date.
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;
SET enable_seqscan = off;
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE amount_paid < charge AND due_on < CURRENT_DATE
ORDER BY due_on;
RESET enable_seqscan;
-- Justification: paid bills (the majority over time) are not in the index, so
-- it stays small, and the due_on range is read in order. The query repeats the
-- index predicate so the planner can use it.

-- (g) Scheduled job ------------------------------------------------------
CREATE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql SET search_path = q7, public AS $$
BEGIN
  INSERT INTO receivable_snapshot (snapshot_date, total_due)
  SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0) FROM bills
  ON CONFLICT (snapshot_date) DO UPDATE SET total_due = EXCLUDED.total_due;
END $$;

SELECT cron.schedule('q7_refresh_receivables', '30 0 * * *', $$CALL q7.pr_refresh_receivables()$$);  -- 00:30 daily
CALL pr_refresh_receivables();
CALL pr_refresh_receivables();                           -- rerun replaces today's row
SELECT * FROM receivable_snapshot;                       -- 298.00 = 0+0+50+50+20+178
