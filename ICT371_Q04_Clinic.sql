-- ICT371 Question 4: Clinic Appointment Scheduling (PostgreSQL + pg_cron)
-- Run top to bottom.
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE SCHEMA IF NOT EXISTS q4;
SET search_path = q4, public;

-- (a) Database and seed data ---------------------------------------------
CREATE TABLE patients (
  patient_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name  VARCHAR(100) NOT NULL
);
CREATE TABLE doctors (
  doctor_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name VARCHAR(100) NOT NULL
);
CREATE TABLE appointments (
  appointment_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  patient_id      INT NOT NULL REFERENCES patients(patient_id),
  doctor_id       INT NOT NULL REFERENCES doctors(doctor_id),
  appointment_day DATE NOT NULL,
  slot_time       TIME NOT NULL CHECK (slot_time IN ('09:00','10:00','11:00','12:00')),
  status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
                  CHECK (status IN ('BOOKED','ATTENDED','CANCELLED'))
);
CREATE TABLE clinic_summary (
  summary_date    DATE PRIMARY KEY,
  booked_count    INT NOT NULL DEFAULT 0,
  attended_count  INT NOT NULL DEFAULT 0,
  cancelled_count INT NOT NULL DEFAULT 0
);

INSERT INTO patients (full_name) VALUES ('Patient One'), ('Patient Two'), ('Patient Three');
INSERT INTO doctors  (full_name) VALUES ('Dr Lungu'), ('Dr Sakala'), ('Dr Kasonde');
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
 (1, 1, CURRENT_DATE,     '09:00', 'BOOKED'),
 (2, 1, CURRENT_DATE,     '10:00', 'BOOKED'),
 (3, 2, CURRENT_DATE,     '09:00', 'BOOKED'),
 (1, 3, CURRENT_DATE - 1, '09:00', 'ATTENDED'),
 (2, 2, CURRENT_DATE - 1, '10:00', 'CANCELLED'),
 (3, 3, CURRENT_DATE + 1, '11:00', 'BOOKED');       -- no slot clashes

-- (b) Function -----------------------------------------------------------
CREATE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
    RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id;
  END IF;
  RETURN (SELECT COUNT(*) FROM appointments           -- COUNT returns 0 for an empty day
          WHERE doctor_id = p_doctor_id AND appointment_day = p_day
            AND status <> 'CANCELLED');
END $$;
SELECT fn_daily_load(1, CURRENT_DATE);                -- 2

-- (c) Procedure ----------------------------------------------------------
CREATE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
    RAISE EXCEPTION 'Unknown patient: %', p_patient_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
    RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id;
  END IF;
  IF p_day IS NULL OR p_day < CURRENT_DATE THEN
    RAISE EXCEPTION 'Date % is in the past or missing', p_day;
  END IF;
  IF p_slot IS NULL OR p_slot NOT IN ('09:00','10:00','11:00','12:00') THEN
    RAISE EXCEPTION 'Unsupported slot: %', p_slot;
  END IF;
  INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
  VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');    -- clashes caught by trigger
END $$;

-- (d) Trigger ------------------------------------------------------------
-- PostgreSQL allows INSERT OR UPDATE in ONE trigger; TG_OP tells them apart.
CREATE FUNCTION trg_fn_slot_clash() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status <> 'CANCELLED' AND EXISTS (
       SELECT 1 FROM appointments a
       WHERE a.doctor_id = NEW.doctor_id
         AND a.appointment_day = NEW.appointment_day
         AND a.slot_time = NEW.slot_time
         AND a.status <> 'CANCELLED'
         AND (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id)  -- exclude self on UPDATE
     ) THEN
    RAISE EXCEPTION 'Slot clash: doctor % on % at %',
                    NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_slot_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_fn_slot_clash();

-- Optional safety net against two simultaneous sessions:
-- CREATE UNIQUE INDEX uq_active_slot ON appointments (doctor_id, appointment_day, slot_time)
--   WHERE status <> 'CANCELLED';

CALL pr_book_appointment(1, 2, CURRENT_DATE + 2, '12:00');          -- OK
-- CALL pr_book_appointment(2, 1, CURRENT_DATE, '09:00');           -- ERROR clash
-- CALL pr_book_appointment(2, 1, CURRENT_DATE - 1, '09:00');       -- ERROR past date
-- CALL pr_book_appointment(2, 1, CURRENT_DATE + 1, '13:00');       -- ERROR unsupported slot
-- UPDATE appointments SET doctor_id = 1, slot_time = '09:00', appointment_day = CURRENT_DATE
--   WHERE appointment_id = 3;                                      -- ERROR clash on UPDATE

-- (e) View ---------------------------------------------------------------
CREATE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED';
SELECT * FROM v_today_appointments;

-- (f) Index --------------------------------------------------------------
CREATE INDEX idx_appt_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;
SET enable_seqscan = off;
EXPLAIN
SELECT appointment_id, slot_time, status FROM appointments
WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
RESET enable_seqscan;
-- Non-unique because many rows share a day and doctor. Day first also serves
-- "everything on one day" queries such as the summary job.

-- (g) Scheduled job ------------------------------------------------------
CREATE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql SET search_path = q4, public AS $$
BEGIN
  INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
  SELECT p_day,
         COUNT(*) FILTER (WHERE status = 'BOOKED'),
         COUNT(*) FILTER (WHERE status = 'ATTENDED'),
         COUNT(*) FILTER (WHERE status = 'CANCELLED')
  FROM appointments WHERE appointment_day = p_day
  ON CONFLICT (summary_date) DO UPDATE
    SET booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END $$;

SELECT cron.schedule('q4_refresh_clinic', '0 1 * * *',
                     $$CALL q4.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);   -- 01:00 daily
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);       -- rerun replaces
SELECT * FROM clinic_summary;
