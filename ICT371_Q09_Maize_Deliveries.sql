-- ICT371 Question 9: Farmer Cooperative Maize Deliveries (PostgreSQL + pg_cron)
-- Run top to bottom. Deliveries are loaded at the end of (d), after the
-- procedure (c) and the pricing trigger (d) both exist.
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE SCHEMA IF NOT EXISTS q9;
SET search_path = q9, public;

-- (a) Database and seed data ---------------------------------------------
CREATE TABLE farmers (
  farmer_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  farmer_number VARCHAR(20) NOT NULL UNIQUE,
  full_name     VARCHAR(100) NOT NULL
);
CREATE TABLE deliveries (
  delivery_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  farmer_id    INT NOT NULL REFERENCES farmers(farmer_id),
  grade        CHAR(1) NOT NULL CHECK (grade IN ('A','B','C')),
  weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
  unit_rate    NUMERIC(8,2)  NOT NULL,        -- supplied by the trigger
  total_value  NUMERIC(12,2) NOT NULL,        -- supplied by the trigger
  delivered_on DATE NOT NULL,
  is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases (
  purchase_date DATE PRIMARY KEY,
  total_weight  NUMERIC(14,2) NOT NULL,
  total_value   NUMERIC(14,2) NOT NULL
);

INSERT INTO farmers (farmer_number, full_name) VALUES
 ('F001', 'Farmer One'), ('F002', 'Farmer Two'), ('F003', 'Farmer Three');
-- Deliveries are loaded at the end of (d).

-- (b) Function -----------------------------------------------------------
CREATE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_grade IS NULL THEN RAISE EXCEPTION 'Grade is required'; END IF;
  IF p_grade = 'A' THEN RETURN 5;
  ELSIF p_grade = 'B' THEN RETURN 4;
  ELSIF p_grade = 'C' THEN RETURN 3;
  END IF;
  RAISE EXCEPTION 'Unsupported grade: %', p_grade;
END $$;
SELECT fn_maize_rate('A'), fn_maize_rate('B'), fn_maize_rate('C');   -- 5, 4, 3

-- (c) Procedure ----------------------------------------------------------
CREATE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade TEXT, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
    RAISE EXCEPTION 'Unknown farmer: %', p_farmer_id;
  END IF;
  IF p_weight IS NULL OR p_weight <= 0 THEN RAISE EXCEPTION 'Invalid weight: %', p_weight; END IF;
  IF p_date IS NULL THEN RAISE EXCEPTION 'Delivery date is required'; END IF;
  IF p_grade IS NULL OR p_grade NOT IN ('A','B','C') THEN
    RAISE EXCEPTION 'Invalid grade: %', p_grade;
  END IF;
  -- basic fields only; the trigger supplies unit_rate and total_value
  INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
  VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END $$;

-- (d) Trigger ------------------------------------------------------------
CREATE FUNCTION trg_fn_delivery_price() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
    RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
  END IF;
  NEW.unit_rate   := fn_maize_rate(NEW.grade::text);
  NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
  RETURN NEW;                      -- BEFORE trigger: changes to NEW are what get stored
END $$;

CREATE TRIGGER trg_delivery_price
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_fn_delivery_price();

-- Seed data: six deliveries covering grades A, B, C
CALL pr_receive_delivery(1, 'A', 100,  '2026-11-20');
CALL pr_receive_delivery(1, 'B',  50,  '2026-11-20');
CALL pr_receive_delivery(2, 'C',  80,  '2026-11-21');
CALL pr_receive_delivery(2, 'A',  40,  '2026-11-21');
CALL pr_receive_delivery(3, 'B',  60,  '2026-11-22');
CALL pr_receive_delivery(3, 'C',  25.5,'2026-11-22');
UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 3, 5);   -- both payment states
-- Direct SQL follows the same pricing rule:
-- INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on)
--   VALUES (1, 'A', 10, CURRENT_DATE);                  -- priced by the trigger: 5 x 10 = 50
-- INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on)
--   VALUES (1, 'D', 10, CURRENT_DATE);                  -- ERROR (grade check)
SELECT delivery_id, grade, weight_kg, unit_rate, total_value, is_paid FROM deliveries ORDER BY 1;

-- (e) View ---------------------------------------------------------------
CREATE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE NOT d.is_paid), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id     -- keeps farmers with no unpaid deliveries
GROUP BY f.farmer_id, f.farmer_number, f.full_name;
SELECT * FROM v_farmer_amount_due;

-- (f) Index --------------------------------------------------------------
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;
SET enable_seqscan = off;
EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value FROM deliveries
WHERE farmer_id = 1 AND delivered_on BETWEEN '2026-11-20' AND '2026-11-22';
RESET enable_seqscan;
-- Justification: equality on farmer_id first, range on delivered_on second.

-- (g) Scheduled job ------------------------------------------------------
CREATE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql SET search_path = q9, public AS $$
BEGIN
  INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
  SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
  FROM deliveries WHERE delivered_on = p_day
  ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight, total_value = EXCLUDED.total_value;
END $$;

SELECT cron.schedule('q9_refresh_purchases', '30 1 * * *',
                     $$CALL q9.pr_refresh_purchases(CURRENT_DATE - 1)$$);   -- 01:30 daily
CALL pr_refresh_purchases('2026-11-20');
CALL pr_refresh_purchases('2026-11-20');                -- rerun replaces
SELECT * FROM daily_purchases;                          -- 150 kg, 700.00 (100x5 + 50x4)
