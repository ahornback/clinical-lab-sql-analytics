-- Essential constraint checks for clinical_lab in database lab_operations.
--
-- One psql session and one password prompt. This file does not reconnect.
-- It does not change functions, tables, or committed rows.
--
--   psql -h 127.0.0.1 -p 5432 -U postgres -d lab_operations -v ON_ERROR_STOP=1 -f sql/verification/verify_constraints.sql
--
-- Expected violations are caught in subtransactions, so a rejection does not
-- abort the session. A RESTRICT delete is SQLSTATE 23001. A child row with
-- no matching parent is 23503. The previous script required 23503 for both,
-- and that final assertion failed after PostgreSQL had already rejected the
-- delete with 23001.
--
-- The check list is read before ROLLBACK. A rollback undoes session
-- settings made inside the same transaction, so the pass or fail flag is
-- kept by psql and tested only after the rollback.

\pset pager off
\timing off
\set ON_ERROR_STOP on

SELECT current_database() AS database_name,
       current_user AS connected_user,
       current_setting('server_version') AS server_version;

SELECT c.relname AS table_name
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE n.nspname = 'clinical_lab'
  AND c.relkind = 'r'
  AND c.relname IN (
    'departments',
    'patients',
    'test_catalog',
    'lab_staff',
    'lab_orders',
    'specimens',
    'lab_exceptions'
  )
ORDER BY c.relname;

DO $catalog$
DECLARE
  body text;
  table_count integer;
  future_trigger_count integer;
  deferred_trigger_count integer;
  restrict_action "char";
  generated_count integer;
BEGIN
  IF current_database() IS DISTINCT FROM 'lab_operations' THEN
    RAISE EXCEPTION 'connected to %, expected lab_operations', current_database();
  END IF;

  SELECT count(*)
    INTO table_count
  FROM pg_class AS c
  JOIN pg_namespace AS n ON n.oid = c.relnamespace
  WHERE n.nspname = 'clinical_lab'
    AND c.relkind = 'r'
    AND c.relname IN (
      'departments',
      'patients',
      'test_catalog',
      'lab_staff',
      'lab_orders',
      'specimens',
      'lab_exceptions'
    );

  IF table_count <> 7 THEN
    RAISE EXCEPTION 'expected 7 clinical_lab tables, found %', table_count;
  END IF;

  SELECT pg_get_functiondef(p.oid)
    INTO body
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'clinical_lab'
    AND p.proname = 'reject_future_calendar_dates';

  IF body IS NULL THEN
    RAISE EXCEPTION 'clinical_lab.reject_future_calendar_dates is missing';
  END IF;

  IF position('IF TG_TABLE_NAME = ''patients'' THEN' IN body) = 0
     OR position('ELSIF TG_TABLE_NAME = ''lab_staff'' THEN' IN body) = 0
     OR position('ELSIF TG_TABLE_NAME = ''lab_orders'' THEN' IN body) = 0
     OR position('TG_TABLE_NAME = ''patients'' AND' IN body) > 0
     OR position('TG_TABLE_NAME = ''lab_staff'' AND' IN body) > 0
     OR position('TG_TABLE_NAME = ''lab_orders'' AND' IN body) > 0
     OR position('AND NEW.hired_on' IN body) > 0 THEN
    RAISE EXCEPTION
      'reject_future_calendar_dates still reads another table''s column in one expression';
  END IF;

  SELECT count(*)
    INTO future_trigger_count
  FROM pg_trigger AS t
  JOIN pg_proc AS p ON p.oid = t.tgfoid
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = 'clinical_lab'
    AND p.proname = 'reject_future_calendar_dates'
    AND NOT t.tgisinternal;

  IF future_trigger_count <> 3 THEN
    RAISE EXCEPTION
      'expected 3 future-date triggers, found %',
      future_trigger_count;
  END IF;

  SELECT count(*)
    INTO deferred_trigger_count
  FROM pg_trigger AS t
  JOIN pg_class AS c ON c.oid = t.tgrelid
  JOIN pg_namespace AS n ON n.oid = c.relnamespace
  WHERE n.nspname = 'clinical_lab'
    AND NOT t.tgisinternal
    AND t.tgdeferrable
    AND t.tginitdeferred
    AND t.tgname IN (
      'lab_orders_specimen_consistency',
      'specimens_order_consistency'
    );

  IF deferred_trigger_count <> 2 THEN
    RAISE EXCEPTION
      'expected 2 deferred specimen triggers, found %',
      deferred_trigger_count;
  END IF;

  SELECT c.confdeltype
    INTO restrict_action
  FROM pg_constraint AS c
  JOIN pg_namespace AS n ON n.oid = c.connamespace
  WHERE n.nspname = 'clinical_lab'
    AND c.conname = 'test_catalog_department_fk';

  IF restrict_action IS DISTINCT FROM 'r' THEN
    RAISE EXCEPTION
      'test_catalog_department_fk is not ON DELETE RESTRICT';
  END IF;

  SELECT count(*)
    INTO generated_count
  FROM pg_attribute AS a
  JOIN pg_class AS c ON c.oid = a.attrelid
  JOIN pg_namespace AS n ON n.oid = c.relnamespace
  WHERE n.nspname = 'clinical_lab'
    AND a.attgenerated = 's'
    AND (
      (c.relname = 'lab_orders' AND a.attname = 'turnaround_minutes')
      OR (c.relname = 'lab_exceptions' AND a.attname = 'resolution_minutes')
    );

  IF generated_count <> 2 THEN
    RAISE EXCEPTION
      'expected stored turnaround_minutes and resolution_minutes, found %',
      generated_count;
  END IF;
END
$catalog$;

DROP TABLE IF EXISTS verify_row_counts;

CREATE TEMP TABLE verify_row_counts (
  table_name text PRIMARY KEY,
  rows_before bigint NOT NULL
);

INSERT INTO verify_row_counts (table_name, rows_before)
SELECT 'departments', count(*) FROM clinical_lab.departments
UNION ALL
SELECT 'patients', count(*) FROM clinical_lab.patients
UNION ALL
SELECT 'test_catalog', count(*) FROM clinical_lab.test_catalog
UNION ALL
SELECT 'lab_staff', count(*) FROM clinical_lab.lab_staff
UNION ALL
SELECT 'lab_orders', count(*) FROM clinical_lab.lab_orders
UNION ALL
SELECT 'specimens', count(*) FROM clinical_lab.specimens
UNION ALL
SELECT 'lab_exceptions', count(*) FROM clinical_lab.lab_exceptions;

-- Replaced by the result query when the checks finish. Left in place so a
-- result query that does not run cannot be read as success.
\set verify_status failed
\set failed_checks transaction_did_not_finish
\set verify_ok 0

BEGIN;

DROP TABLE IF EXISTS verify_log;

CREATE TEMP TABLE verify_log (
  check_name text PRIMARY KEY,
  sqlstate text NOT NULL,
  result text NOT NULL,
  detail text NOT NULL
);

DO $verify$
DECLARE
  token text := 'Z' || upper(substr(md5(clock_timestamp()::text || random()::text), 1, 8));
  state text;
  detail text;
  dept_id bigint;
  patient_row bigint;
  kept_dob date;
BEGIN
  -- A valid patient insert must not read lab_staff.hired_on.
  BEGIN
    INSERT INTO clinical_lab.departments (department_code, department_name)
    VALUES (token, 'Verify ' || token)
    RETURNING department_id INTO dept_id;

    INSERT INTO clinical_lab.patients (
      mrn, first_name, last_name, date_of_birth, sex
    ) VALUES (
      token || '-P', 'Verify', 'Patient', DATE '1990-01-01', 'unknown'
    ) RETURNING patient_id INTO patient_row;

    INSERT INTO clinical_lab.test_catalog (
      test_code, test_name, department_id, required_specimen_type,
      routine_turnaround_minutes, urgent_turnaround_minutes, stat_turnaround_minutes
    ) VALUES (
      token || 'T', 'Verify Test', dept_id, 'serum', 120, 60, 20
    );

    INSERT INTO clinical_lab.lab_staff (
      employee_number, first_name, last_name, job_role, department_id,
      shift_code, shift_start_time, shift_end_time, hired_on
    ) VALUES (
      token || 'E', 'Verify', 'Tech', 'technologist', dept_id,
      'day', TIME '07:00', TIME '15:00', DATE '2015-01-01'
    );

    INSERT INTO clinical_lab.lab_orders (
      patient_id, test_id, performing_department_id, priority, order_status
    )
    SELECT patient_row, t.test_id, t.department_id, 'routine', 'incomplete'
    FROM clinical_lab.test_catalog AS t
    WHERE t.test_code = token || 'T';

    IF NOT FOUND THEN
      RAISE EXCEPTION 'valid incomplete order was not inserted';
    END IF;

    state := '00000';
    detail := 'valid rows inserted';
  EXCEPTION
    WHEN OTHERS THEN
      state := SQLSTATE;
      detail := SQLERRM;
  END;
  INSERT INTO verify_log (check_name, sqlstate, result, detail)
  VALUES (
    'valid_rows',
    state,
    CASE WHEN state = '00000' THEN 'pass' ELSE 'fail' END,
    replace(replace(detail, E'\n', ' '), E'\t', ' ')
  );

  state := '';
  detail := '';
  BEGIN
    INSERT INTO clinical_lab.patients (
      mrn, first_name, last_name, date_of_birth, sex
    ) VALUES (
      token || '-F', 'Future', 'Dob', CURRENT_DATE + 1, 'unknown'
    );
    state := 'accepted';
  EXCEPTION
    WHEN OTHERS THEN
      state := SQLSTATE;
      detail := SQLERRM;
  END;
  INSERT INTO verify_log (check_name, sqlstate, result, detail)
  VALUES (
    'patient_future_date',
    state,
    CASE
      WHEN state = 'P0001' AND detail LIKE '%patients.date_of_birth%' THEN 'pass'
      ELSE 'fail'
    END,
    replace(replace(detail, E'\n', ' '), E'\t', ' ')
  );

  state := '';
  detail := '';
  BEGIN
    UPDATE clinical_lab.patients
    SET date_of_birth = CURRENT_DATE + 1
    WHERE mrn = token || '-P';
    state := 'accepted';
  EXCEPTION
    WHEN OTHERS THEN
      state := SQLSTATE;
      detail := SQLERRM;
  END;
  SELECT p.date_of_birth
    INTO kept_dob
  FROM clinical_lab.patients AS p
  WHERE p.mrn = token || '-P';
  INSERT INTO verify_log (check_name, sqlstate, result, detail)
  VALUES (
    'patient_future_update',
    coalesce(state, ''),
    CASE
      WHEN state = 'P0001'
       AND detail LIKE '%patients.date_of_birth%'
       AND kept_dob = DATE '1990-01-01' THEN 'pass'
      ELSE 'fail'
    END,
    replace(replace(detail, E'\n', ' '), E'\t', ' ')
      || ' kept=' || coalesce(kept_dob::text, 'missing')
  );

  state := '';
  detail := '';
  BEGIN
    INSERT INTO clinical_lab.departments (department_code, department_name)
    VALUES (token || 'S', 'Verify Staff Date');
    INSERT INTO clinical_lab.lab_staff (
      employee_number, first_name, last_name, job_role, department_id,
      shift_code, shift_start_time, shift_end_time, hired_on
    )
    SELECT token || 'S', 'Future', 'Hire', 'technologist', d.department_id,
           'night', TIME '23:00', TIME '07:00', CURRENT_DATE + 1
    FROM clinical_lab.departments AS d
    WHERE d.department_code = token || 'S';
    state := 'accepted';
  EXCEPTION
    WHEN OTHERS THEN
      state := SQLSTATE;
      detail := SQLERRM;
  END;
  INSERT INTO verify_log (check_name, sqlstate, result, detail)
  VALUES (
    'staff_future_date',
    state,
    CASE
      WHEN state = 'P0001' AND detail LIKE '%lab_staff.hired_on%' THEN 'pass'
      ELSE 'fail'
    END,
    replace(replace(detail, E'\n', ' '), E'\t', ' ')
  );

  state := '';
  detail := '';
  BEGIN
    INSERT INTO clinical_lab.lab_orders (
      order_status, requisition_date_of_birth
    ) VALUES (
      'incomplete', CURRENT_DATE + 1
    );
    state := 'accepted';
  EXCEPTION
    WHEN OTHERS THEN
      state := SQLSTATE;
      detail := SQLERRM;
  END;
  INSERT INTO verify_log (check_name, sqlstate, result, detail)
  VALUES (
    'order_future_date',
    state,
    CASE
      WHEN state = 'P0001' AND detail LIKE '%requisition_date_of_birth%' THEN 'pass'
      ELSE 'fail'
    END,
    replace(replace(detail, E'\n', ' '), E'\t', ' ')
  );

  state := '';
  detail := '';
  BEGIN
    INSERT INTO clinical_lab.departments (department_code, department_name)
    VALUES ('bad', 'Bad Code');
    state := 'accepted';
  EXCEPTION
    WHEN OTHERS THEN
      state := SQLSTATE;
      detail := SQLERRM;
  END;
  INSERT INTO verify_log (check_name, sqlstate, result, detail)
  VALUES (
    'department_code',
    state,
    CASE
      WHEN state = '23514' AND detail LIKE '%departments_department_code_ck%' THEN 'pass'
      ELSE 'fail'
    END,
    replace(replace(detail, E'\n', ' '), E'\t', ' ')
  );

  state := '';
  detail := '';
  BEGIN
    INSERT INTO clinical_lab.lab_orders (order_status, turnaround_minutes)
    VALUES ('incomplete', 1);
    state := 'accepted';
  EXCEPTION
    WHEN OTHERS THEN
      state := SQLSTATE;
      detail := SQLERRM;
  END;
  INSERT INTO verify_log (check_name, sqlstate, result, detail)
  VALUES (
    'generated_column',
    state,
    CASE WHEN state = '428C9' THEN 'pass' ELSE 'fail' END,
    replace(replace(detail, E'\n', ' '), E'\t', ' ')
  );

  state := '';
  detail := '';
  BEGIN
    INSERT INTO clinical_lab.departments (department_code, department_name)
    VALUES (token || 'D', 'Verify Delete');
    INSERT INTO clinical_lab.test_catalog (
      test_code, test_name, department_id, required_specimen_type,
      routine_turnaround_minutes, urgent_turnaround_minutes, stat_turnaround_minutes
    )
    SELECT token || 'D', 'Verify Delete Test', d.department_id, 'plasma', 90, 45, 15
    FROM clinical_lab.departments AS d
    WHERE d.department_code = token || 'D';
    DELETE FROM clinical_lab.departments
    WHERE department_code = token || 'D';
    state := 'accepted';
  EXCEPTION
    WHEN OTHERS THEN
      state := SQLSTATE;
      detail := SQLERRM;
  END;
  -- RESTRICT raises 23001. 23503 is a child row whose parent is absent.
  INSERT INTO verify_log (check_name, sqlstate, result, detail)
  VALUES (
    'delete_restrict',
    state,
    CASE
      WHEN state = '23001' AND detail LIKE '%test_catalog_department_fk%' THEN 'pass'
      ELSE 'fail'
    END,
    replace(replace(detail, E'\n', ' '), E'\t', ' ')
  );

  state := '';
  detail := '';
  BEGIN
    INSERT INTO clinical_lab.departments (department_code, department_name)
    VALUES (token || 'A', 'Verify Dept A');
    INSERT INTO clinical_lab.departments (department_code, department_name)
    VALUES (token || 'B', 'Verify Dept B');
    INSERT INTO clinical_lab.test_catalog (
      test_code, test_name, department_id, required_specimen_type,
      routine_turnaround_minutes, urgent_turnaround_minutes, stat_turnaround_minutes
    )
    SELECT token || 'A', 'Verify Mismatch', d.department_id, 'serum', 100, 50, 25
    FROM clinical_lab.departments AS d
    WHERE d.department_code = token || 'A';
    INSERT INTO clinical_lab.patients (
      mrn, first_name, last_name, date_of_birth, sex
    ) VALUES (
      token || '-FK', 'Fk', 'Test', DATE '1985-05-05', 'male'
    );
    INSERT INTO clinical_lab.lab_orders (
      accession_number, patient_id, test_id, performing_department_id,
      received_during_shift, priority, order_status, ordered_at, received_at
    )
    SELECT
      token || '-FK',
      p.patient_id,
      t.test_id,
      b.department_id,
      'day',
      'routine',
      'received',
      TIMESTAMPTZ '2024-06-01 12:00:00+00',
      TIMESTAMPTZ '2024-06-01 12:10:00+00'
    FROM clinical_lab.patients AS p
    JOIN clinical_lab.test_catalog AS t ON t.test_code = token || 'A'
    JOIN clinical_lab.departments AS b ON b.department_code = token || 'B'
    WHERE p.mrn = token || '-FK';
    state := 'accepted';
  EXCEPTION
    WHEN OTHERS THEN
      state := SQLSTATE;
      detail := SQLERRM;
  END;
  INSERT INTO verify_log (check_name, sqlstate, result, detail)
  VALUES (
    'composite_foreign_key',
    state,
    CASE
      WHEN state = '23503' AND detail LIKE '%lab_orders_test_department_fk%' THEN 'pass'
      ELSE 'fail'
    END,
    replace(replace(detail, E'\n', ' '), E'\t', ' ')
  );

  state := '';
  detail := '';
  BEGIN
    INSERT INTO clinical_lab.departments (department_code, department_name)
    VALUES (token || 'C', 'Verify Clock');
    INSERT INTO clinical_lab.test_catalog (
      test_code, test_name, department_id, required_specimen_type,
      routine_turnaround_minutes, urgent_turnaround_minutes, stat_turnaround_minutes
    )
    SELECT token || 'C', 'Verify Clock Test', d.department_id, 'serum', 100, 50, 25
    FROM clinical_lab.departments AS d
    WHERE d.department_code = token || 'C';
    INSERT INTO clinical_lab.patients (
      mrn, first_name, last_name, date_of_birth, sex
    ) VALUES (
      token || '-CLK', 'Clock', 'Test', DATE '1988-08-08', 'female'
    );
    INSERT INTO clinical_lab.lab_staff (
      employee_number, first_name, last_name, job_role, department_id,
      shift_code, shift_start_time, shift_end_time, hired_on
    )
    SELECT token || 'C', 'Clock', 'Tech', 'accessioner', d.department_id,
           'day', TIME '07:00', TIME '15:00', DATE '2019-01-01'
    FROM clinical_lab.departments AS d
    WHERE d.department_code = token || 'C';
    INSERT INTO clinical_lab.lab_orders (
      accession_number, patient_id, test_id, performing_department_id,
      received_by_staff_id, received_during_shift, priority, order_status,
      ordered_at, received_at
    )
    SELECT
      token || '-CLK',
      p.patient_id,
      t.test_id,
      t.department_id,
      s.staff_id,
      'day',
      'routine',
      'received',
      clock_timestamp() + interval '2 hours',
      clock_timestamp() + interval '3 hours'
    FROM clinical_lab.patients AS p
    JOIN clinical_lab.test_catalog AS t ON t.test_code = token || 'C'
    JOIN clinical_lab.lab_staff AS s ON s.employee_number = token || 'C'
    WHERE p.mrn = token || '-CLK';
    state := 'accepted';
  EXCEPTION
    WHEN OTHERS THEN
      state := SQLSTATE;
      detail := SQLERRM;
  END;
  INSERT INTO verify_log (check_name, sqlstate, result, detail)
  VALUES (
    'future_order_timestamp',
    state,
    CASE
      WHEN state = 'P0001' AND detail LIKE '%ordered_at%' THEN 'pass'
      ELSE 'fail'
    END,
    replace(replace(detail, E'\n', ' '), E'\t', ' ')
  );

  state := '';
  detail := '';
  BEGIN
    INSERT INTO clinical_lab.departments (department_code, department_name)
    VALUES (token || 'W', 'Verify Window');
    INSERT INTO clinical_lab.test_catalog (
      test_code, test_name, department_id, required_specimen_type,
      routine_turnaround_minutes, urgent_turnaround_minutes, stat_turnaround_minutes
    )
    SELECT token || 'W', 'Verify Window Test', d.department_id, 'serum', 100, 50, 25
    FROM clinical_lab.departments AS d
    WHERE d.department_code = token || 'W';
    INSERT INTO clinical_lab.patients (
      mrn, first_name, last_name, date_of_birth, sex
    ) VALUES (
      token || '-WIN', 'Window', 'Test', DATE '1982-02-02', 'male'
    );
    INSERT INTO clinical_lab.lab_orders (
      accession_number, patient_id, test_id, performing_department_id,
      received_during_shift, priority, order_status, ordered_at, received_at
    )
    SELECT
      token || '-WIN',
      p.patient_id,
      t.test_id,
      t.department_id,
      'day',
      'routine',
      'received',
      TIMESTAMPTZ '2024-06-01 12:00:00+00',
      TIMESTAMPTZ '2024-06-01 12:10:00+00'
    FROM clinical_lab.patients AS p
    JOIN clinical_lab.test_catalog AS t ON t.test_code = token || 'W'
    WHERE p.mrn = token || '-WIN';
    INSERT INTO clinical_lab.specimens (
      lab_order_id, specimen_barcode, specimen_type, specimen_status, collected_at
    )
    SELECT
      o.lab_order_id,
      token || '-WIN',
      'serum',
      'collected',
      TIMESTAMPTZ '2024-06-01 12:00:00+00' - interval '31 days'
    FROM clinical_lab.lab_orders AS o
    WHERE o.accession_number = token || '-WIN';
    state := 'accepted';
  EXCEPTION
    WHEN OTHERS THEN
      state := SQLSTATE;
      detail := SQLERRM;
  END;
  INSERT INTO verify_log (check_name, sqlstate, result, detail)
  VALUES (
    'collection_window',
    state,
    CASE
      WHEN state = 'P0001' AND detail LIKE '%30 days before%' THEN 'pass'
      ELSE 'fail'
    END,
    replace(replace(detail, E'\n', ' '), E'\t', ' ')
  );

  state := '';
  detail := '';
  BEGIN
    INSERT INTO clinical_lab.departments (department_code, department_name)
    VALUES (token || 'R', 'Verify Deferred');
    INSERT INTO clinical_lab.patients (
      mrn, first_name, last_name, date_of_birth, sex
    ) VALUES (
      token || '-DEF', 'Defer', 'Test', DATE '1991-04-04', 'female'
    );
    INSERT INTO clinical_lab.test_catalog (
      test_code, test_name, department_id, required_specimen_type,
      routine_turnaround_minutes, urgent_turnaround_minutes, stat_turnaround_minutes
    )
    SELECT token || 'R', 'Verify Deferred Test', d.department_id, 'serum', 180, 60, 20
    FROM clinical_lab.departments AS d
    WHERE d.department_code = token || 'R';
    INSERT INTO clinical_lab.lab_staff (
      employee_number, first_name, last_name, job_role, department_id,
      shift_code, shift_start_time, shift_end_time, hired_on
    )
    SELECT token || 'R', 'Defer', 'Tech', 'technologist', d.department_id,
           'evening', TIME '15:00', TIME '23:00', DATE '2017-07-07'
    FROM clinical_lab.departments AS d
    WHERE d.department_code = token || 'R';
    INSERT INTO clinical_lab.lab_orders (
      accession_number, patient_id, test_id, performing_department_id,
      received_by_staff_id, received_during_shift, priority, order_status,
      ordered_at, received_at, testing_started_at, completed_at
    )
    SELECT
      token || '-DEF',
      p.patient_id,
      t.test_id,
      t.department_id,
      s.staff_id,
      'evening',
      'stat',
      'completed',
      TIMESTAMPTZ '2024-07-01 14:00:00+00',
      TIMESTAMPTZ '2024-07-01 14:05:00+00',
      TIMESTAMPTZ '2024-07-01 14:10:00+00',
      TIMESTAMPTZ '2024-07-01 14:25:00+00'
    FROM clinical_lab.patients AS p
    JOIN clinical_lab.test_catalog AS t ON t.test_code = token || 'R'
    JOIN clinical_lab.lab_staff AS s ON s.employee_number = token || 'R'
    WHERE p.mrn = token || '-DEF';
    EXECUTE 'SET CONSTRAINTS ALL IMMEDIATE';
    state := 'accepted';
  EXCEPTION
    WHEN OTHERS THEN
      state := SQLSTATE;
      detail := SQLERRM;
  END;
  INSERT INTO verify_log (check_name, sqlstate, result, detail)
  VALUES (
    'deferred_completed_order',
    state,
    CASE
      WHEN state = 'P0001' AND detail LIKE '%accepted specimen%' THEN 'pass'
      ELSE 'fail'
    END,
    replace(replace(detail, E'\n', ' '), E'\t', ' ')
  );
EXCEPTION
  WHEN OTHERS THEN
    INSERT INTO verify_log (check_name, sqlstate, result, detail)
    VALUES (
      'script_error',
      SQLSTATE,
      'fail',
      replace(replace(SQLERRM, E'\n', ' '), E'\t', ' ')
    );
END
$verify$;

SELECT check_name, sqlstate, result, detail
FROM verify_log
ORDER BY check_name;

SELECT CASE
         WHEN count(*) = 12
          AND count(*) FILTER (WHERE result = 'pass') = 12
         THEN 'ok'
         ELSE 'failed'
       END AS verify_status,
       coalesce(
         string_agg(check_name, ', ' ORDER BY check_name)
           FILTER (WHERE result <> 'pass'),
         ''
       ) AS failed_checks
FROM verify_log
\gset

ROLLBACK;

SELECT c.table_name,
       c.rows_before,
       v.rows_after,
       (c.rows_before = v.rows_after) AS unchanged
FROM verify_row_counts AS c
JOIN (
  SELECT 'departments' AS table_name, count(*) AS rows_after
  FROM clinical_lab.departments
  UNION ALL
  SELECT 'patients', count(*) FROM clinical_lab.patients
  UNION ALL
  SELECT 'test_catalog', count(*) FROM clinical_lab.test_catalog
  UNION ALL
  SELECT 'lab_staff', count(*) FROM clinical_lab.lab_staff
  UNION ALL
  SELECT 'lab_orders', count(*) FROM clinical_lab.lab_orders
  UNION ALL
  SELECT 'specimens', count(*) FROM clinical_lab.specimens
  UNION ALL
  SELECT 'lab_exceptions', count(*) FROM clinical_lab.lab_exceptions
) AS v USING (table_name)
ORDER BY c.table_name;

DO $counts$
DECLARE
  mismatched integer;
BEGIN
  SELECT count(*)
    INTO mismatched
  FROM verify_row_counts AS c
  JOIN (
    SELECT 'departments' AS table_name, count(*) AS rows_after
    FROM clinical_lab.departments
    UNION ALL
    SELECT 'patients', count(*) FROM clinical_lab.patients
    UNION ALL
    SELECT 'test_catalog', count(*) FROM clinical_lab.test_catalog
    UNION ALL
    SELECT 'lab_staff', count(*) FROM clinical_lab.lab_staff
    UNION ALL
    SELECT 'lab_orders', count(*) FROM clinical_lab.lab_orders
    UNION ALL
    SELECT 'specimens', count(*) FROM clinical_lab.specimens
    UNION ALL
    SELECT 'lab_exceptions', count(*) FROM clinical_lab.lab_exceptions
  ) AS v USING (table_name)
  WHERE c.rows_before IS DISTINCT FROM v.rows_after;

  IF mismatched <> 0 THEN
    RAISE EXCEPTION 'temporary test rows were not rolled back';
  END IF;
END
$counts$;

SELECT CASE WHEN :'verify_status' = 'ok' THEN '1' ELSE '0' END AS verify_ok
\gset

\if :verify_ok
SELECT 'VERIFY_CONSTRAINTS_COMPLETE' AS verify_status;
\else
DO $verdict$
BEGIN
  RAISE EXCEPTION 'integrity verification failed: %', :'failed_checks';
END
$verdict$;
\endif
