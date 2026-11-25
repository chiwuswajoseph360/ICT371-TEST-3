-- ICT371 Question 5: Hostel Room Allocation (PostgreSQL + pg_cron)
-- Run top to bottom. Allocations are loaded at the end of (d).
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE SCHEMA IF NOT EXISTS q5;
SET search_path = q5, public;

-- (a) Database and seed data ---------------------------------------------
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE rooms (
  room_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  room_number VARCHAR(10) NOT NULL UNIQUE,
  capacity    INT NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
  allocation_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id    INT NOT NULL REFERENCES students(student_id),
  room_id       INT NOT NULL REFERENCES rooms(room_id),
  allocated_on  DATE NOT NULL,
  released_on   DATE,
  status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE','ENDED')),
  CONSTRAINT chk_status_release CHECK (
    (status = 'ACTIVE' AND released_on IS NULL) OR
    (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on))
);
CREATE TABLE occupancy_snapshot (
  snapshot_date DATE NOT NULL,
  room_id       INT  NOT NULL REFERENCES rooms(room_id),
  occupied_beds INT  NOT NULL,
  free_beds     INT  NOT NULL,
  PRIMARY KEY (snapshot_date, room_id)                -- one row per date and room
);

INSERT INTO students (student_number, full_name) VALUES
 ('S001','Student A'), ('S002','Student B'), ('S003','Student C'),
 ('S004','Student D'), ('S005','Student E');
INSERT INTO rooms (room_number, capacity) VALUES
 ('R101', 2),     -- will be full
 ('R102', 3),     -- will be partly occupied
 ('R103', 2);     -- stays empty
-- Allocations are loaded at the end of (d).

-- (b) Function -----------------------------------------------------------
CREATE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT LANGUAGE plpgsql STABLE AS $$
DECLARE v_cap INT;
BEGIN
  SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room: %', p_room_id; END IF;
  RETURN v_cap - (SELECT COUNT(*) FROM allocations
                  WHERE room_id = p_room_id AND status = 'ACTIVE');   -- ENDED ignored
END $$;

-- (c) Procedure ----------------------------------------------------------
CREATE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_allocated_on IS NULL THEN RAISE EXCEPTION 'allocated_on is required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
    RAISE EXCEPTION 'Unknown student: %', p_student_id;
  END IF;
  PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;          -- lock the room
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room: %', p_room_id; END IF;
  IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
    RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
  END IF;
  IF fn_free_beds(p_room_id) <= 0 THEN
    RAISE EXCEPTION 'Room % is full', p_room_id;
  END IF;
  INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
  VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END $$;

-- (d) Trigger (also guards direct INSERT / UPDATE) -----------------------
CREATE FUNCTION trg_fn_allocation_rules() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_cap INT; v_used INT;
BEGIN
  IF NEW.status = 'ACTIVE' THEN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
    IF EXISTS (SELECT 1 FROM allocations a
               WHERE a.student_id = NEW.student_id AND a.status = 'ACTIVE'
                 AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id)) THEN
      RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;
    SELECT COUNT(*) INTO v_used FROM allocations a
    WHERE a.room_id = NEW.room_id AND a.status = 'ACTIVE'
      AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id);   -- exclude the row being updated
    IF v_used >= v_cap THEN
      RAISE EXCEPTION 'Room % is at capacity (%)', NEW.room_id, v_cap;
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_allocation_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_fn_allocation_rules();

-- Seed allocations
CALL pr_allocate_room(1, 1, '2026-11-01');     -- R101 now 2/2 after next line
CALL pr_allocate_room(2, 1, '2026-11-01');
CALL pr_allocate_room(3, 2, '2026-11-05');     -- R102 is 1/3
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 2, '2026-08-01', '2026-10-30', 'ENDED');     -- history only, uses no bed
-- Tests:
-- CALL pr_allocate_room(5, 1, CURRENT_DATE);   -- ERROR room full
-- CALL pr_allocate_room(1, 3, CURRENT_DATE);   -- ERROR already ACTIVE
-- INSERT INTO allocations (student_id, room_id, allocated_on, status)
--   VALUES (5, 1, CURRENT_DATE, 'ACTIVE');     -- ERROR full (direct SQL caught)

-- (e) View ---------------------------------------------------------------
CREATE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'   -- keeps empty rooms
GROUP BY r.room_id, r.room_number, r.capacity;
SELECT * FROM v_room_occupancy;

-- (f) Index --------------------------------------------------------------
-- Partial: ENDED history grows forever but is never indexed, so the index
-- holds only current occupants and stays small.
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;
SET enable_seqscan = off;
EXPLAIN SELECT allocation_id, student_id FROM allocations
WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;

-- (g) Scheduled job ------------------------------------------------------
CREATE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql SET search_path = q5, public AS $$
BEGIN
  INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
  SELECT CURRENT_DATE, r.room_id, COUNT(a.allocation_id), r.capacity - COUNT(a.allocation_id)
  FROM rooms r
  LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
  GROUP BY r.room_id, r.capacity
  ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds, free_beds = EXCLUDED.free_beds;
END $$;

SELECT cron.schedule('q5_refresh_occupancy', '55 23 * * *', $$CALL q5.pr_refresh_occupancy()$$);
CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();                   -- rerun replaces, no duplicates
SELECT * FROM occupancy_snapshot ORDER BY room_id;
