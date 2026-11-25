-- ICT371 Question 2: University Fee Payments (PostgreSQL + pg_cron)
-- Run top to bottom. Payments are loaded at the end of (d), once the
-- procedure (c) and trigger (d) both exist.
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE SCHEMA IF NOT EXISTS q2;
SET search_path = q2, public;

-- (a) Database and seed data ---------------------------------------------
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL,
  fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);
CREATE TABLE payments (
  payment_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  paid_on    TIMESTAMP NOT NULL
);
CREATE TABLE payment_audit (
  audit_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  payment_id INT NOT NULL REFERENCES payments(payment_id),
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL,
  logged_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_collections (
  collection_date DATE PRIMARY KEY,
  payment_count   INT NOT NULL DEFAULT 0,
  total_amount    NUMERIC(14,2) NOT NULL DEFAULT 0
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
 ('S2026001', 'Chanda Mwila',  5000.00),
 ('S2026002', 'Mutale Banda',  3000.00),
 ('S2026003', 'Natasha Phiri', 4000.00);      -- will have NO payments
-- The six payments are loaded through pr_receive_payment at the end of (d).

-- (b) Function -----------------------------------------------------------
CREATE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_fee NUMERIC; v_paid NUMERIC;
BEGIN
  SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student: %', p_student_id;
  END IF;
  SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE student_id = p_student_id;
  RETURN v_fee - v_paid;                       -- no payments => full fee
END $$;

SELECT fn_fee_balance(3);                      -- 4000.00
-- SELECT fn_fee_balance(99);                  -- ERROR: unknown student

-- (c) Procedure ----------------------------------------------------------
-- Never inserts into payment_audit (the trigger does) and never changes fee_due.
CREATE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on TIMESTAMP)
LANGUAGE plpgsql AS $$
DECLARE v_balance NUMERIC;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be positive, got %', p_amount;
  END IF;
  IF p_paid_on IS NULL THEN
    RAISE EXCEPTION 'paid_on is required';
  END IF;

  PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;   -- serialise payments
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student: %', p_student_id;
  END IF;

  v_balance := fn_fee_balance(p_student_id);
  IF p_amount > v_balance THEN
    RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
  END IF;

  INSERT INTO payments (student_id, amount, paid_on)
  VALUES (p_student_id, p_amount, p_paid_on);
END $$;

-- (d) Trigger ------------------------------------------------------------
CREATE FUNCTION trg_fn_payment_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
  VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
  RETURN NULL;                                 -- AFTER trigger: return value is ignored
END $$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_fn_payment_audit();

-- Load the six payments through the procedure (trigger audits each one)
CALL pr_receive_payment(1, 1000, TIMESTAMP '2026-11-23 09:00');
CALL pr_receive_payment(1, 1500, TIMESTAMP '2026-11-23 11:30');
CALL pr_receive_payment(2,  800, TIMESTAMP '2026-11-23 14:00');
CALL pr_receive_payment(1,  500, TIMESTAMP '2026-11-24 09:15');
CALL pr_receive_payment(2,  700, TIMESTAMP '2026-11-24 10:40');
CALL pr_receive_payment(2,  500, TIMESTAMP '2026-11-24 13:05');
SELECT * FROM payment_audit;                   -- 6 rows written by the trigger

-- Rejection tests (nothing is inserted):
-- CALL pr_receive_payment(1, NULL, now());   CALL pr_receive_payment(1, 0, now());
-- CALL pr_receive_payment(1, -5, now());     CALL pr_receive_payment(1, 99999, now());
-- CALL pr_receive_payment(99, 10, now());

-- (e) View ---------------------------------------------------------------
CREATE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id    -- keeps the student with no payments
GROUP BY s.student_id
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;     -- settled students excluded
SELECT * FROM v_fee_balances;                  -- 2000, 1000, 4000

CALL pr_receive_payment(2, 1000, now());       -- settle student 2
SELECT * FROM v_fee_balances;                  -- student 2 no longer listed

-- (f) Index --------------------------------------------------------------
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);
ANALYZE payments;
SET enable_seqscan = off;
EXPLAIN
SELECT payment_id, amount, paid_on FROM payments
WHERE student_id = 1 AND paid_on >= '2026-11-23' AND paid_on < '2026-11-25';
RESET enable_seqscan;
-- Justification: equality column (student_id) first, range column (paid_on)
-- second, so one student's payments in the range form one sorted slice.

-- (g) Scheduled job ------------------------------------------------------
CREATE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql SET search_path = q2, public AS $$
BEGIN
  INSERT INTO daily_collections (collection_date, payment_count, total_amount)
  SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
  FROM payments
  WHERE paid_on >= p_day AND paid_on < p_day + 1
  ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count, total_amount = EXCLUDED.total_amount;
END $$;

SELECT cron.schedule('q2_refresh_collections', '0 1 * * *',
                     $$CALL q2.pr_refresh_collections(CURRENT_DATE - 1)$$);   -- 01:00 daily

CALL pr_refresh_collections('2026-11-23');
CALL pr_refresh_collections('2026-11-23');     -- rerun replaces the row
SELECT * FROM daily_collections;               -- 3 payments, 3300.00
