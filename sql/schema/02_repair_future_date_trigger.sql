-- Repair clinical_lab.reject_future_calendar_dates on an existing database.
--
-- The original function tested TG_TABLE_NAME and a table-specific NEW column
-- in one boolean expression. PL/pgSQL can resolve every NEW.column reference
-- in that expression, so inserting a patient raised:
--   record "new" has no field "hired_on"
--
-- This script replaces that function with one branch per table. It does not
-- drop, truncate, or update tables, and it does not insert rows. Triggers
-- already point at this function, so they are left in place.
--
-- Safe to run more than once. Run it with the clinical_lab schema already
-- installed, in database lab_operations:
--   psql -h 127.0.0.1 -p 5432 -U postgres -d lab_operations -f sql/schema/02_repair_future_date_trigger.sql

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_namespace
    WHERE nspname = 'clinical_lab'
  ) THEN
    RAISE EXCEPTION 'schema clinical_lab does not exist; migration was not applied';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
    WHERE n.nspname = 'clinical_lab'
      AND p.proname = 'reject_future_calendar_dates'
  ) THEN
    RAISE EXCEPTION
      'function clinical_lab.reject_future_calendar_dates does not exist; migration was not applied';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION clinical_lab.reject_future_calendar_dates()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $func$
BEGIN
  -- Choose the table before reading NEW. PL/pgSQL can resolve a column
  -- from another table when several terms share one boolean expression.
  -- The patient branch reads only the birth date. The staff branch reads
  -- only the hire date. The order branch reads only the requisition date.
  IF TG_TABLE_NAME = 'patients' THEN
    IF NEW.date_of_birth > CURRENT_DATE THEN
      RAISE EXCEPTION 'patients.date_of_birth % is in the future', NEW.date_of_birth;
    END IF;
  ELSIF TG_TABLE_NAME = 'lab_staff' THEN
    IF NEW.hired_on > CURRENT_DATE THEN
      RAISE EXCEPTION 'lab_staff.hired_on % is in the future', NEW.hired_on;
    END IF;
  ELSIF TG_TABLE_NAME = 'lab_orders' THEN
    IF NEW.requisition_date_of_birth IS NOT NULL
       AND NEW.requisition_date_of_birth > CURRENT_DATE THEN
      RAISE EXCEPTION
        'lab_orders.requisition_date_of_birth % is in the future',
        NEW.requisition_date_of_birth;
    END IF;
  END IF;
  RETURN NEW;
END;
$func$;

DO $$
DECLARE
  body text;
  trigger_count integer;
BEGIN
  SELECT pg_get_functiondef(p.oid)
    INTO body
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'clinical_lab'
    AND p.proname = 'reject_future_calendar_dates';

  IF body IS NULL THEN
    RAISE EXCEPTION 'reject_future_calendar_dates was not replaced';
  END IF;

  IF position('TG_TABLE_NAME = ''patients'' AND' IN body) > 0
     OR position('TG_TABLE_NAME = ''lab_staff'' AND' IN body) > 0
     OR position('TG_TABLE_NAME = ''lab_orders'' AND' IN body) > 0 THEN
    RAISE EXCEPTION
      'future-date function still combines a table test with another table column';
  END IF;

  SELECT count(*)
    INTO trigger_count
  FROM pg_trigger AS t
  JOIN pg_proc AS p ON p.oid = t.tgfoid
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'clinical_lab'
    AND p.proname = 'reject_future_calendar_dates'
    AND NOT t.tgisinternal;

  IF trigger_count <> 3 THEN
    RAISE EXCEPTION
      'expected 3 triggers on reject_future_calendar_dates, found %',
      trigger_count;
  END IF;
END $$;

COMMIT;
