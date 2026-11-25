-- ICT371 Question 6: Monthly Payroll Processing (PostgreSQL + pg_cron)
-- Run top to bottom. Payroll months are processed at the end of (d).
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE SCHEMA IF NOT EXISTS q6;
SET search_path = q6, public;

-- (a) Database and seed data ---------------------------------------------
CREATE TABLE employees (
  employee_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name    VARCHAR(100) NOT NULL,
  basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
  allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
  deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
  active       BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE TABLE payroll (
  payroll_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  pay_month   DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),   -- first of month
  gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
  net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
  CONSTRAINT uq_emp_month UNIQUE (employee_id, pay_month)
);
CREATE TABLE salary_audit (
  audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  old_salary  NUMERIC(12,2) NOT NULL,
  new_salary  NUMERIC(12,2) NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction) VALUES
 ('Emp One',   8000, 1000, 1500),
 ('Emp Two',   6000,  500, 1000),
 ('Emp Three', 5000,  400,  800),
 ('Emp Four',  7000,  600, 1200);       -- will become inactive after two months of pay
-- Payroll months are processed at the end of (d).

-- (b) Function -----------------------------------------------------------
CREATE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_net NUMERIC;
BEGIN
  SELECT basic_salary + allowance - deduction INTO v_net
  FROM employees WHERE employee_id = p_employee_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown employee: %', p_employee_id; END IF;
  IF v_net < 0 THEN
    RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
  END IF;
  RETURN v_net;
END $$;

-- (c) Procedure ----------------------------------------------------------
CREATE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql SET search_path = q6, public AS $$
DECLARE rec RECORD;
BEGIN
  IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
    RAISE EXCEPTION 'Month must be a first-of-month date, got %', p_month;
  END IF;
  FOR rec IN SELECT employee_id, basic_salary + allowance AS gross
             FROM employees WHERE active ORDER BY employee_id          -- query FOR loop
  LOOP
    INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
    VALUES (rec.employee_id, p_month, rec.gross, fn_net_pay(rec.employee_id))  -- raises => whole CALL rolls back
    ON CONFLICT (employee_id, pay_month) DO NOTHING;                           -- existing row left unchanged
  END LOOP;
END $$;

-- (d) Trigger ------------------------------------------------------------
CREATE FUNCTION trg_fn_salary_audit() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO salary_audit (employee_id, old_salary, new_salary)
  VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
  RETURN NEW;
END $$;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- Two payroll months, then one employee becomes inactive
CALL pr_process_payroll('2026-09-01');
CALL pr_process_payroll('2026-10-01');
CALL pr_process_payroll('2026-10-01');                     -- rerun: nothing duplicated or changed
UPDATE employees SET active = FALSE WHERE employee_id = 4; -- no audit row
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;   -- one audit row
SELECT * FROM salary_audit;
-- CALL pr_process_payroll('2026-10-15');                  -- ERROR not a month start

-- (e) View ---------------------------------------------------------------
CREATE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p JOIN employees e ON e.employee_id = p.employee_id;   -- no active filter: history kept
SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- (f) Index --------------------------------------------------------------
-- The unique index (employee_id, pay_month) leads with employee_id, so it
-- cannot efficiently answer "WHERE pay_month = ..." across all employees.
-- This index leads with pay_month, so it does not duplicate it.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM v_payroll_report WHERE pay_month = '2026-10-01';
RESET enable_seqscan;

-- (g) Scheduled job ------------------------------------------------------
-- 02:00 on day 1 of each month, passing the first date of the previous month
SELECT cron.schedule('q6_monthly_payroll', '0 2 1 * *',
  $$CALL q6.pr_process_payroll((date_trunc('month', CURRENT_DATE) - interval '1 month')::date)$$);

-- Inspect the job
SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q6_monthly_payroll';
-- Inspect its run history
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'q6_monthly_payroll')
ORDER BY start_time DESC;
-- Remove it: SELECT cron.unschedule('q6_monthly_payroll');
