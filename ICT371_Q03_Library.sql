-- ICT371 Question 3: Library Returns and Overdue Fines (PostgreSQL + pg_cron)
-- Run top to bottom. The two returns are processed at the end of (d).
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE SCHEMA IF NOT EXISTS q3;
SET search_path = q3, public;

-- (a) Database and seed data ---------------------------------------------
CREATE TABLE books (
  book_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title   VARCHAR(150) NOT NULL
);
CREATE TABLE loans (
  loan_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  book_id       INT NOT NULL REFERENCES books(book_id),
  borrower_name VARCHAR(100) NOT NULL,
  borrowed_on   DATE NOT NULL,
  due_on        DATE NOT NULL,
  returned_on   DATE,                                    -- NULL = still out
  fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
  CONSTRAINT chk_due_after_borrow CHECK (due_on >= borrowed_on)
);
CREATE TABLE loan_audit (
  audit_id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  loan_id         INT NOT NULL REFERENCES loans(loan_id),
  old_returned_on DATE,
  new_returned_on DATE,
  changed_at      TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE overdue_summary (
  snapshot_date DATE PRIMARY KEY,
  overdue_count INT NOT NULL,
  total_fine    NUMERIC(12,2) NOT NULL
);

INSERT INTO books (title) VALUES ('Database Systems'), ('Operating Systems'), ('Networks');
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
 (1, 'Mulenga',  '2026-10-01', '2026-10-15'),   -- open, overdue
 (2, 'Chilufya', '2026-11-15', '2026-11-29'),   -- open, on time
 (3, 'Bwalya',   '2026-10-05', '2026-10-19'),   -- will be returned on time
 (1, 'Zulu',     '2026-10-20', '2026-11-03'),   -- will be returned late
 (2, 'Tembo',    '2026-11-10', '2026-11-24'),   -- due today: no fine
 (3, 'Daka',     '2026-11-01', '2026-11-15');   -- open, overdue

-- (b) Function -----------------------------------------------------------
CREATE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_due DATE; v_ret DATE; v_end DATE;
BEGIN
  IF p_as_of IS NULL THEN RAISE EXCEPTION 'as-of date is required'; END IF;
  SELECT due_on, returned_on INTO v_due, v_ret FROM loans WHERE loan_id = p_loan_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan: %', p_loan_id; END IF;
  v_end := CASE WHEN v_ret IS NOT NULL THEN LEAST(p_as_of, v_ret) ELSE p_as_of END;
  RETURN 2 * GREATEST(v_end - v_due, 0);        -- K2 per day, minimum 0
END $$;

SELECT loan_id, fn_loan_fine(loan_id, DATE '2026-11-24') FROM loans ORDER BY loan_id;

-- (c) Procedure ----------------------------------------------------------
CREATE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_returned DATE;
BEGIN
  SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
  FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan: %', p_loan_id; END IF;
  IF v_returned IS NOT NULL THEN RAISE EXCEPTION 'Loan % already returned', p_loan_id; END IF;
  IF p_returned_on IS NULL OR p_returned_on < v_borrowed THEN
    RAISE EXCEPTION 'Invalid return date % (borrowed %)', p_returned_on, v_borrowed;
  END IF;
  -- one UPDATE stores the return date and the final fine together
  UPDATE loans
  SET returned_on = p_returned_on,
      fine_amount = fn_loan_fine(p_loan_id, p_returned_on)
  WHERE loan_id = p_loan_id;
END $$;

-- (d) Trigger ------------------------------------------------------------
CREATE FUNCTION trg_fn_loan_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
  VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
  RETURN NEW;
END $$;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)   -- NULL-safe "changed" test
EXECUTE FUNCTION trg_fn_loan_audit();

-- Return two loans (the trigger now audits them)
CALL pr_return_loan(3, '2026-10-19');   -- on time: fine 0
CALL pr_return_loan(4, '2026-11-08');   -- 5 days late: fine 10
-- CALL pr_return_loan(3, '2026-11-01');   -- ERROR already returned
-- CALL pr_return_loan(99, CURRENT_DATE);  -- ERROR unknown loan
-- CALL pr_return_loan(1, '2026-09-01');   -- ERROR before borrowed_on
SELECT * FROM loan_audit;

-- (e) View ---------------------------------------------------------------
CREATE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;
SELECT * FROM v_overdue_loans;

-- (f) Index --------------------------------------------------------------
-- Partial index: only unreturned loans are indexed, so it stays small.
CREATE INDEX idx_loans_book_open ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;
SET enable_seqscan = off;
EXPLAIN
SELECT loan_id, borrower_name, due_on FROM loans
WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;

-- (g) Scheduled job ------------------------------------------------------
-- Assumption: "still unreturned as of that date" = not yet returned on p_as_of.
CREATE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql SET search_path = q3, public AS $$
BEGIN
  INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
  SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
  FROM loans
  WHERE borrowed_on <= p_as_of
    AND (returned_on IS NULL OR returned_on > p_as_of)
  ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count, total_fine = EXCLUDED.total_fine;
END $$;

SELECT cron.schedule('q3_refresh_overdue', '10 0 * * *',
                     $$CALL q3.pr_refresh_overdue(CURRENT_DATE)$$);   -- 00:10 daily
CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);          -- rerun replaces the row
SELECT * FROM overdue_summary;
