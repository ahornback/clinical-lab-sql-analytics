-- Read-only check of the synthetic clinical_lab load.
--
-- Confirms counts, required statuses, the twelve-month window, specimen
-- rules, and that quality flags match exception rows.
--
-- Run after scripts/02_generate_data.sql, in its own session:
--   psql -h 127.0.0.1 -p 5432 -U postgres -d lab_operations -v ON_ERROR_STOP=1 -f scripts/03_validate_data.sql
--
-- An empty database fails this check. The file does not insert or update rows.

BEGIN READ ONLY;

SET LOCAL timezone = 'America/New_York';

DO $validate$
DECLARE
  problems text := '';
  n_found bigint;
BEGIN
  SELECT count(*) INTO n_found FROM clinical_lab.departments;
  IF n_found <> 6 THEN
    problems := problems || format('departments expected 6 actual %s; ', n_found);
  END IF;

  SELECT count(*) INTO n_found FROM clinical_lab.test_catalog;
  IF n_found <> 25 THEN
    problems := problems || format('tests expected 25 actual %s; ', n_found);
  END IF;

  SELECT count(*) INTO n_found FROM clinical_lab.lab_staff;
  IF n_found <> 40 THEN
    problems := problems || format('staff expected 40 actual %s; ', n_found);
  END IF;

  SELECT count(*) INTO n_found FROM clinical_lab.patients;
  IF n_found <> 10000 THEN
    problems := problems || format('patients expected 10000 actual %s; ', n_found);
  END IF;

  SELECT count(*) INTO n_found FROM clinical_lab.lab_orders;
  IF n_found <> 50000 THEN
    problems := problems || format('orders expected 50000 actual %s; ', n_found);
  END IF;

  SELECT count(*) INTO n_found FROM clinical_lab.specimens;
  IF n_found < 50000 THEN
    problems := problems || format('specimens expected at least 50000 actual %s; ', n_found);
  END IF;

  IF EXISTS (
    SELECT 1
    FROM clinical_lab.lab_orders AS o
    WHERE NOT EXISTS (
      SELECT 1
      FROM clinical_lab.specimens AS s
      WHERE s.lab_order_id = o.lab_order_id
    )
  ) THEN
    problems := problems || 'order without specimen; ';
  END IF;

  SELECT count(*) INTO n_found
  FROM (
    SELECT order_status
    FROM clinical_lab.lab_orders
    WHERE order_status IN (
      'completed', 'in_progress', 'received', 'incomplete', 'cancelled', 'rejected'
    )
    GROUP BY order_status
  ) AS present;
  IF n_found <> 6 THEN
    problems := problems || format('order statuses expected 6 actual %s; ', n_found);
  END IF;

  SELECT count(*) INTO n_found
  FROM (
    SELECT priority
    FROM clinical_lab.lab_orders
    WHERE priority IN ('routine', 'urgent', 'stat')
    GROUP BY priority
  ) AS present;
  IF n_found <> 3 THEN
    problems := problems || format('priorities expected 3 actual %s; ', n_found);
  END IF;

  SELECT count(*) INTO n_found
  FROM (
    SELECT record_status
    FROM clinical_lab.patients
    WHERE record_status IN (
      'active', 'inactive', 'incomplete', 'merged', 'duplicate_suspected'
    )
    GROUP BY record_status
  ) AS present;
  IF n_found <> 5 THEN
    problems := problems || format('patient statuses expected 5 actual %s; ', n_found);
  END IF;

  IF EXISTS (
    SELECT 1
    FROM clinical_lab.patients
    WHERE record_status = 'merged'
      AND merged_into_patient_id IS NULL
  ) THEN
    problems := problems || 'merged patient without survivor; ';
  END IF;

  SELECT count(*) INTO n_found
  FROM (
    SELECT exception_type
    FROM clinical_lab.lab_exceptions
    WHERE exception_type IN (
      'incorrect_test_order',
      'patient_record_discrepancy',
      'incorrect_specimen_type',
      'specimen_rejection',
      'labeling_error',
      'missing_information'
    )
    GROUP BY exception_type
  ) AS present;
  IF n_found <> 6 THEN
    problems := problems || format('exception types expected 6 actual %s; ', n_found);
  END IF;

  SELECT count(*) INTO n_found
  FROM (
    SELECT severity
    FROM clinical_lab.lab_exceptions
    WHERE severity IN ('low', 'moderate', 'high', 'critical')
    GROUP BY severity
  ) AS present;
  IF n_found <> 4 THEN
    problems := problems || format('severities expected 4 actual %s; ', n_found);
  END IF;

  SELECT count(*) INTO n_found
  FROM (
    SELECT resolution_status
    FROM clinical_lab.lab_exceptions
    WHERE resolution_status IN ('open', 'in_progress', 'resolved', 'cancelled')
    GROUP BY resolution_status
  ) AS present;
  IF n_found <> 4 THEN
    problems := problems || format('resolution statuses expected 4 actual %s; ', n_found);
  END IF;

  SELECT count(*) INTO n_found
  FROM (
    SELECT date_trunc(
      'month',
      ordered_at AT TIME ZONE 'America/New_York'
    ) AS order_month
    FROM clinical_lab.lab_orders
    GROUP BY order_month
  ) AS present;
  IF n_found <> 12 THEN
    problems := problems || format('order months expected 12 actual %s; ', n_found);
  END IF;

  SELECT count(*) INTO n_found
  FROM clinical_lab.lab_orders
  WHERE ordered_at IS NULL
    OR (ordered_at AT TIME ZONE 'America/New_York') < TIMESTAMP '2025-11-01 00:00:00'
    OR (ordered_at AT TIME ZONE 'America/New_York') >= TIMESTAMP '2026-11-01 00:00:00';
  IF n_found <> 0 THEN
    problems := problems || format('orders outside 2025-11-01 through 2026-10-31: %s; ', n_found);
  END IF;

  SELECT count(*) INTO n_found
  FROM clinical_lab.lab_orders
  WHERE order_status = 'completed'
    AND (
      completed_at IS NULL
      OR completed_at >= TIMESTAMPTZ '2026-11-12 00:00:00-05'
      OR turnaround_minutes IS NULL
      OR turnaround_minutes < 0
    );
  IF n_found <> 0 THEN
    problems := problems || format('completed orders with an unusable timeline: %s; ', n_found);
  END IF;

  SELECT count(*) INTO n_found
  FROM (
    SELECT received_during_shift
    FROM clinical_lab.lab_orders
    WHERE received_during_shift IN ('day', 'evening', 'night')
    GROUP BY received_during_shift
  ) AS present;
  IF n_found <> 3 THEN
    problems := problems || format('receipt shifts expected 3 actual %s; ', n_found);
  END IF;

  IF EXISTS (
    SELECT 1
    FROM clinical_lab.lab_orders
    WHERE order_status = 'completed'
      AND NOT EXISTS (
        SELECT 1
        FROM clinical_lab.specimens AS s
        WHERE s.lab_order_id = lab_orders.lab_order_id
          AND s.specimen_status = 'accepted'
      )
  ) THEN
    problems := problems || 'completed order without accepted specimen; ';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM clinical_lab.lab_orders AS o
    JOIN clinical_lab.specimens AS s ON s.lab_order_id = o.lab_order_id
    WHERE o.order_status = 'rejected'
      AND s.specimen_status = 'accepted'
  ) THEN
    problems := problems || 'rejected order has accepted specimen; ';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM clinical_lab.lab_orders AS o
    WHERE o.order_status = 'in_progress'
      AND NOT EXISTS (
        SELECT 1
        FROM clinical_lab.specimens AS s
        WHERE s.lab_order_id = o.lab_order_id
          AND s.specimen_status IN ('received', 'accepted')
      )
  ) THEN
    problems := problems || 'in-progress order without received specimen; ';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM clinical_lab.lab_orders AS o
    JOIN clinical_lab.specimens AS s ON s.lab_order_id = o.lab_order_id
    WHERE o.order_status = 'incomplete'
      AND s.specimen_status NOT IN ('pending_collection', 'cancelled')
  ) THEN
    problems := problems || 'incomplete order has a collected specimen; ';
  END IF;

  SELECT count(*) INTO n_found
  FROM clinical_lab.specimens AS s
  JOIN clinical_lab.lab_orders AS o ON o.lab_order_id = s.lab_order_id
  WHERE s.collected_at IS NOT NULL
    AND (
      s.collected_at < o.ordered_at - interval '30 days'
      OR s.collected_at > o.ordered_at + interval '30 days'
    );
  IF n_found <> 0 THEN
    problems := problems || format('collections outside the 30-day window: %s; ', n_found);
  END IF;

  IF EXISTS (
    SELECT 1
    FROM clinical_lab.lab_orders AS o
    WHERE o.order_is_incorrect
      AND NOT EXISTS (
        SELECT 1
        FROM clinical_lab.lab_exceptions AS e
        WHERE e.lab_order_id = o.lab_order_id
          AND e.exception_type = 'incorrect_test_order'
          AND e.specimen_id IS NULL
      )
  ) OR EXISTS (
    SELECT 1
    FROM clinical_lab.lab_exceptions AS e
    JOIN clinical_lab.lab_orders AS o ON o.lab_order_id = e.lab_order_id
    WHERE e.exception_type = 'incorrect_test_order'
      AND (
        NOT o.order_is_incorrect
        OR o.corrected_test_id IS NULL
        OR o.corrected_test_id = o.test_id
      )
  ) THEN
    problems := problems || 'incorrect test flag; ';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM clinical_lab.specimens AS s
    WHERE s.labeling_error
      AND NOT EXISTS (
        SELECT 1
        FROM clinical_lab.lab_exceptions AS e
        WHERE e.specimen_id = s.specimen_id
          AND e.exception_type = 'labeling_error'
      )
  ) OR EXISTS (
    SELECT 1
    FROM clinical_lab.lab_exceptions AS e
    LEFT JOIN clinical_lab.specimens AS s ON s.specimen_id = e.specimen_id
    WHERE e.exception_type = 'labeling_error'
      AND (s.specimen_id IS NULL OR NOT s.labeling_error)
  ) THEN
    problems := problems || 'labeling flag; ';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM clinical_lab.specimens AS s
    WHERE s.specimen_status = 'rejected'
      AND NOT EXISTS (
        SELECT 1
        FROM clinical_lab.lab_exceptions AS e
        WHERE e.specimen_id = s.specimen_id
          AND e.exception_type = 'specimen_rejection'
      )
  ) OR EXISTS (
    SELECT 1
    FROM clinical_lab.lab_exceptions AS e
    LEFT JOIN clinical_lab.specimens AS s ON s.specimen_id = e.specimen_id
    WHERE e.exception_type = 'specimen_rejection'
      AND (s.specimen_id IS NULL OR s.specimen_status <> 'rejected')
  ) THEN
    problems := problems || 'specimen rejection flag; ';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM clinical_lab.specimens AS s
    JOIN clinical_lab.lab_orders AS o ON o.lab_order_id = s.lab_order_id
    JOIN clinical_lab.test_catalog AS t ON t.test_id = o.test_id
    WHERE s.specimen_type <> t.required_specimen_type
      AND NOT EXISTS (
        SELECT 1
        FROM clinical_lab.lab_exceptions AS e
        WHERE e.specimen_id = s.specimen_id
          AND e.exception_type = 'incorrect_specimen_type'
      )
  ) OR EXISTS (
    SELECT 1
    FROM clinical_lab.lab_exceptions AS e
    JOIN clinical_lab.specimens AS s ON s.specimen_id = e.specimen_id
    JOIN clinical_lab.lab_orders AS o ON o.lab_order_id = s.lab_order_id
    LEFT JOIN clinical_lab.test_catalog AS t ON t.test_id = o.test_id
    WHERE e.exception_type = 'incorrect_specimen_type'
      AND (
        o.test_id IS NULL
        OR s.specimen_type = t.required_specimen_type
      )
  ) THEN
    problems := problems || 'specimen type flag; ';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM clinical_lab.lab_orders AS o
    WHERE o.missing_information
      AND NOT EXISTS (
        SELECT 1
        FROM clinical_lab.lab_exceptions AS e
        WHERE e.lab_order_id = o.lab_order_id
          AND e.specimen_id IS NULL
          AND e.exception_type = 'missing_information'
      )
  ) OR EXISTS (
    SELECT 1
    FROM clinical_lab.lab_exceptions AS e
    JOIN clinical_lab.lab_orders AS o ON o.lab_order_id = e.lab_order_id
    WHERE e.exception_type = 'missing_information'
      AND e.specimen_id IS NULL
      AND NOT o.missing_information
  ) OR EXISTS (
    SELECT 1
    FROM clinical_lab.specimens AS s
    WHERE s.missing_information
      AND NOT EXISTS (
        SELECT 1
        FROM clinical_lab.lab_exceptions AS e
        WHERE e.specimen_id = s.specimen_id
          AND e.exception_type = 'missing_information'
      )
  ) OR EXISTS (
    SELECT 1
    FROM clinical_lab.lab_exceptions AS e
    LEFT JOIN clinical_lab.specimens AS s ON s.specimen_id = e.specimen_id
    WHERE e.exception_type = 'missing_information'
      AND e.specimen_id IS NOT NULL
      AND (s.specimen_id IS NULL OR NOT s.missing_information)
  ) THEN
    problems := problems || 'missing information flag; ';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM clinical_lab.lab_orders AS o
    JOIN clinical_lab.patients AS p ON p.patient_id = o.patient_id
    WHERE (
        o.requisition_patient_name IS DISTINCT FROM (p.first_name || ' ' || p.last_name)
        OR o.requisition_date_of_birth IS DISTINCT FROM p.date_of_birth
      )
      AND NOT EXISTS (
        SELECT 1
        FROM clinical_lab.lab_exceptions AS e
        WHERE e.lab_order_id = o.lab_order_id
          AND e.exception_type = 'patient_record_discrepancy'
      )
  ) OR EXISTS (
    SELECT 1
    FROM clinical_lab.lab_exceptions AS e
    JOIN clinical_lab.lab_orders AS o ON o.lab_order_id = e.lab_order_id
    LEFT JOIN clinical_lab.patients AS p ON p.patient_id = o.patient_id
    WHERE e.exception_type = 'patient_record_discrepancy'
      AND NOT (
        o.requisition_patient_name IS DISTINCT FROM (p.first_name || ' ' || p.last_name)
        OR o.requisition_date_of_birth IS DISTINCT FROM p.date_of_birth
      )
  ) THEN
    problems := problems || 'requisition discrepancy; ';
  END IF;

  IF problems <> '' THEN
    RAISE EXCEPTION 'synthetic data validation failed: %', problems;
  END IF;
END
$validate$;

SELECT 'SYNTHETIC_DATA_VALID' AS data_status;

COMMIT;
