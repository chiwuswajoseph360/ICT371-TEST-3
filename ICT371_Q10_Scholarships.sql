-- ICT371 Question 10: Scholarship Application Assessment (PostgreSQL + pg_cron)
-- Run top to bottom.
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE SCHEMA IF NOT EXISTS q10;
SET search_path = q10, public;

-- (a) Database and seed data ---------------------------------------------
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
  application_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id         INT NOT NULL REFERENCES students(student_id),
  age_at_application INT NOT NULL CHECK (age_at_application > 0),
  monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
  average_mark       NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
  submitted_on       DATE NOT NULL,
  status             VARCHAR(10) NOT NULL DEFAULT 'PENDING'
                     CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);
CREATE TABLE decision_audit (
  audit_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  application_id INT NOT NULL REFERENCES applications(application_id),
  old_status     VARCHAR(10) NOT NULL,
  new_status     VARCHAR(10) NOT NULL,
  changed_at     TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
 ('S001', 'Student One'), ('S002', 'Student Two'), ('S003', 'Student Three');
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
 (1, 20, 2000.00, 80.00, '2026-11-01'),   -- qualifies
 (1, 17, 1000.00, 90.00, '2026-11-02'),   -- too young
 (2, 18, 3000.00, 70.00, '2026-11-03'),   -- boundary on all three limits: qualifies
 (2, 25, 3000.01, 75.00, '2026-11-04'),   -- income just over
 (3, 22, 1500.00, 69.99, '2026-11-05'),   -- mark just under
 (3, 25, 3000.00, 70.00, '2026-11-06');   -- upper age boundary: qualifies

-- (b) Function -----------------------------------------------------------
CREATE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
    RAISE EXCEPTION 'Inputs must not be NULL';
  END IF;
  IF p_age <= 0 THEN RAISE EXCEPTION 'Age must be positive: %', p_age; END IF;
  IF p_income < 0 THEN RAISE EXCEPTION 'Income cannot be negative: %', p_income; END IF;
  IF p_mark < 0 OR p_mark > 100 THEN RAISE EXCEPTION 'Mark must be 0 to 100: %', p_mark; END IF;
  RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END $$;
SELECT fn_scholarship_eligible(18, 3000, 70), fn_scholarship_eligible(26, 100, 90);   -- t, f

-- (c) Procedure ----------------------------------------------------------
CREATE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE r applications%ROWTYPE;
BEGIN
  SELECT * INTO r FROM applications WHERE application_id = p_application_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown application: %', p_application_id;
  END IF;
  IF r.status <> 'PENDING' THEN
    RAISE EXCEPTION 'Application % already assessed (%)', p_application_id, r.status;
  END IF;
  UPDATE applications
  SET status = CASE WHEN fn_scholarship_eligible(r.age_at_application, r.monthly_income, r.average_mark)
                    THEN 'APPROVED' ELSE 'REJECTED' END
  WHERE application_id = p_application_id;
END $$;

-- (d) Trigger ------------------------------------------------------------
CREATE FUNCTION trg_fn_decision_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
  VALUES (OLD.application_id, OLD.status, NEW.status, now());
  RETURN NEW;
END $$;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)      -- unchanged status => no audit row
EXECUTE FUNCTION trg_fn_decision_audit();

CALL pr_assess_application(1);                     -- APPROVED, one audit row
-- CALL pr_assess_application(1);                  -- ERROR already assessed
-- CALL pr_assess_application(99);                 -- ERROR unknown application

-- (e) View ---------------------------------------------------------------
CREATE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status     -- income deliberately omitted
FROM applications a JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Index --------------------------------------------------------------
CREATE INDEX idx_app_status_submitted ON applications (status, submitted_on);
ANALYZE applications;
SET enable_seqscan = off;
EXPLAIN
SELECT application_id, student_id FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN '2026-11-01' AND '2026-11-30';
RESET enable_seqscan;
-- Justification: equality on status first, range on submitted_on second.

-- (g) Scheduled job ------------------------------------------------------
CREATE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql SET search_path = q10, public AS $$
DECLARE rec RECORD;
BEGIN
  FOR rec IN SELECT application_id FROM applications
             WHERE status = 'PENDING' ORDER BY application_id       -- only PENDING rows
  LOOP
    CALL pr_assess_application(rec.application_id);
  END LOOP;
END $$;

SELECT cron.schedule('q10_assess_pending', '0 8 * * 1', $$CALL q10.pr_assess_pending()$$);  -- Mondays 08:00
CALL pr_assess_pending();
CALL pr_assess_pending();                          -- rerun: nothing PENDING, no new audit rows
SELECT application_id, status FROM applications ORDER BY 1;   -- 1, 3, 6 APPROVED; 2, 4, 5 REJECTED
SELECT * FROM decision_audit;                      -- exactly one row per application
SELECT * FROM v_approved_applicants;
