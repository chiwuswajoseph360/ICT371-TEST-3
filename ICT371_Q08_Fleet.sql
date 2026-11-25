-- ICT371 Question 8: Transport Fleet Maintenance (PostgreSQL + pg_cron)
-- Run top to bottom. Trips are loaded at the end of (d), after the trigger exists.
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE SCHEMA IF NOT EXISTS q8;
SET search_path = q8, public;

-- (a) Database and seed data ---------------------------------------------
CREATE TABLE vehicles (
  vehicle_id            INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  registration          VARCHAR(15) NOT NULL UNIQUE,
  current_odometer      INT NOT NULL CHECK (current_odometer >= 0),
  last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
  CONSTRAINT chk_service_le_current CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
  trip_id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vehicle_id     INT NOT NULL REFERENCES vehicles(vehicle_id),
  trip_on        DATE NOT NULL,
  start_odometer INT NOT NULL CHECK (start_odometer >= 0),
  end_odometer   INT NOT NULL CHECK (end_odometer >= 0)
);
CREATE TABLE service_alerts (
  vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
  km_since_service INT NOT NULL,
  flagged_on       DATE NOT NULL
);

INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
 ('BAF 1001', 12000, 11000),     -- 1000 km since service: not due
 ('BAF 2002', 20000, 14000),     -- 6000 km: due
 ('BAF 3003',  8000,  3000);     -- exactly 5000 km: due (boundary)
-- The six trips are loaded at the end of (d).

-- (b) Function -----------------------------------------------------------
CREATE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE v_km INT;
BEGIN
  SELECT current_odometer - last_service_odometer INTO v_km
  FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id; END IF;
  RETURN v_km >= 5000;
END $$;
SELECT vehicle_id, fn_service_due(vehicle_id) FROM vehicles;     -- f, t, t

-- (c) Procedure (does NOT update the odometer; the trigger does) ---------
CREATE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
    RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
  END IF;
  IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
    RAISE EXCEPTION 'End odometer (%) must be greater than start (%)', p_end, p_start;
  END IF;
  INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
  VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END $$;

-- (d) Trigger ------------------------------------------------------------
CREATE FUNCTION trg_fn_trip_odometer() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_cur INT;
BEGIN
  SELECT current_odometer INTO v_cur FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle: %', NEW.vehicle_id; END IF;
  IF NEW.start_odometer <> v_cur THEN
    RAISE EXCEPTION 'Trip must start at current odometer %, got %', v_cur, NEW.start_odometer;
  END IF;
  IF NEW.end_odometer <= NEW.start_odometer THEN
    RAISE EXCEPTION 'Invalid mileage: end % <= start %', NEW.end_odometer, NEW.start_odometer;
  END IF;
  UPDATE vehicles SET current_odometer = NEW.end_odometer     -- exactly once per inserted trip
  WHERE vehicle_id = NEW.vehicle_id;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_fn_trip_odometer();

-- Six trips, loaded through the procedure now that the trigger is installed
CALL pr_record_trip(1, '2026-11-01', 12000, 12300);
CALL pr_record_trip(1, '2026-11-05', 12300, 12800);
CALL pr_record_trip(2, '2026-11-02', 20000, 20400);
CALL pr_record_trip(2, '2026-11-08', 20400, 21000);
CALL pr_record_trip(3, '2026-11-03',  8000,  8500);
CALL pr_record_trip(3, '2026-11-09',  8500,  9000);
SELECT * FROM vehicles;        -- odometers: 12800, 21000, 9000
-- CALL pr_record_trip(1, CURRENT_DATE, 100, 200);     -- ERROR start != current odometer
-- CALL pr_record_trip(1, CURRENT_DATE, 12800, 12700); -- ERROR end <= start

-- (e) View ---------------------------------------------------------------
CREATE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;
SELECT * FROM v_service_due;   -- BAF 2002 (7000), BAF 3003 (6000)

-- (f) Index --------------------------------------------------------------
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);
ANALYZE trips;
SET enable_seqscan = off;
EXPLAIN
SELECT trip_id, start_odometer, end_odometer FROM trips
WHERE vehicle_id = 2 AND trip_on BETWEEN '2026-11-01' AND '2026-11-30';
RESET enable_seqscan;
-- Justification: equality on vehicle_id first, range on trip_on second, so one
-- vehicle's trips in the range are one contiguous, sorted slice of the index.

-- (g) Scheduled job ------------------------------------------------------
CREATE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql SET search_path = q8, public AS $$
BEGIN
  INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
  SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
  FROM vehicles
  WHERE current_odometer - last_service_odometer >= 5000
  ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service;         -- keeps the original flagged_on

  DELETE FROM service_alerts sa                                -- serviced => no longer due
  WHERE NOT EXISTS (SELECT 1 FROM vehicles v
                    WHERE v.vehicle_id = sa.vehicle_id
                      AND v.current_odometer - v.last_service_odometer >= 5000);
END $$;

SELECT cron.schedule('q8_service_alerts', '0 6 * * 1', $$CALL q8.pr_refresh_service_alerts()$$);  -- Mondays 06:00
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;                                  -- vehicles 2 and 3
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;   -- serviced
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;                                  -- only vehicle 3 remains
