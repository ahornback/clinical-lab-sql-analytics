-- Synthetic clinical_lab load for database lab_operations.
--
-- One transaction. A failed statement rolls every insert back.
-- A second run stops when any of the seven tables already has rows.
-- Identity columns are omitted, so gaps left by rolled-back tests are harmless.
--
-- Fixed seed: 0.20241124. The seed is applied before any random() call.
-- Parallel workers are disabled in this transaction so the draw order stays fixed.
-- Run the file by itself, in a new session, with no transaction already open:
--   psql -h 127.0.0.1 -p 5432 -U postgres -d lab_operations -v ON_ERROR_STOP=1 -f scripts/02_generate_data.sql
--
-- Window: 2025-11-01 through 2026-10-31, America/New_York.
-- Counts: 6 departments, 25 tests, 40 employees, 10000 patients, 50000 orders,
-- and at least 50000 specimens. Quality flags and exception rows are written
-- from the same decisions.

BEGIN;

SET LOCAL timezone = 'America/New_York';
SET LOCAL max_parallel_workers = 0;
SET LOCAL max_parallel_workers_per_gather = 0;

SELECT pg_advisory_xact_lock(842024);

DO $guard$
DECLARE
  filled text;
BEGIN
  IF current_date < DATE '2026-11-12' THEN
    RAISE EXCEPTION 'synthetic window is not fully in the past on %', current_date;
  END IF;

  SELECT string_agg(rel, ', ' ORDER BY rel)
    INTO filled
  FROM (
    SELECT 'departments' AS rel WHERE EXISTS (SELECT 1 FROM clinical_lab.departments)
    UNION ALL SELECT 'patients' WHERE EXISTS (SELECT 1 FROM clinical_lab.patients)
    UNION ALL SELECT 'test_catalog' WHERE EXISTS (SELECT 1 FROM clinical_lab.test_catalog)
    UNION ALL SELECT 'lab_staff' WHERE EXISTS (SELECT 1 FROM clinical_lab.lab_staff)
    UNION ALL SELECT 'lab_orders' WHERE EXISTS (SELECT 1 FROM clinical_lab.lab_orders)
    UNION ALL SELECT 'specimens' WHERE EXISTS (SELECT 1 FROM clinical_lab.specimens)
    UNION ALL SELECT 'lab_exceptions' WHERE EXISTS (SELECT 1 FROM clinical_lab.lab_exceptions)
  ) AS present;

  IF filled IS NOT NULL THEN
    RAISE EXCEPTION 'clinical_lab already has rows in %; generation was not started', filled;
  END IF;
END
$guard$;

SELECT setseed(0.20241124);

INSERT INTO clinical_lab.departments (department_code, department_name)
VALUES
  ('CHEM', 'Chemistry'),
  ('HEM', 'Hematology'),
  ('MICRO', 'Microbiology'),
  ('BBANK', 'Blood Bank'),
  ('UA', 'Urinalysis'),
  ('IMM', 'Immunology');

INSERT INTO clinical_lab.test_catalog (
  test_code, test_name, department_id, required_specimen_type,
  routine_turnaround_minutes, urgent_turnaround_minutes, stat_turnaround_minutes
)
SELECT
  v.test_code,
  v.test_name,
  d.department_id,
  v.specimen_type::clinical_lab.specimen_type,
  v.routine_minutes,
  v.urgent_minutes,
  v.stat_minutes
FROM (
  VALUES
    ('BMP', 'Basic Metabolic Panel', 'CHEM', 'serum', 120, 45, 20),
    ('CMP', 'Comprehensive Metabolic Panel', 'CHEM', 'serum', 180, 60, 30),
    ('GLU', 'Glucose', 'CHEM', 'serum', 60, 30, 15),
    ('HBA1C', 'Hemoglobin A1c', 'CHEM', 'whole_blood', 240, 120, 60),
    ('LIPID', 'Lipid Panel', 'CHEM', 'serum', 240, 90, 45),
    ('TSH', 'Thyroid Stimulating Hormone', 'CHEM', 'serum', 480, 180, 90),
    ('TROP', 'Troponin', 'CHEM', 'plasma', 45, 25, 15),
    ('CBC', 'Complete Blood Count', 'HEM', 'whole_blood', 60, 30, 15),
    ('DIFF', 'Manual Differential', 'HEM', 'whole_blood', 120, 45, 20),
    ('RETIC', 'Reticulocyte Count', 'HEM', 'whole_blood', 180, 60, 30),
    ('ESR', 'Erythrocyte Sedimentation Rate', 'HEM', 'whole_blood', 90, 45, 30),
    ('BCULT', 'Blood Culture', 'MICRO', 'whole_blood', 4320, 2880, 1440),
    ('UCULT', 'Urine Culture', 'MICRO', 'urine', 2880, 1440, 720),
    ('COVID', 'SARS-CoV-2 Antigen', 'MICRO', 'swab', 60, 30, 15),
    ('STREP', 'Group A Strep Screen', 'MICRO', 'swab', 45, 20, 10),
    ('ABORH', 'ABO and Rh Type', 'BBANK', 'whole_blood', 45, 20, 10),
    ('ABID', 'Antibody Identification', 'BBANK', 'whole_blood', 240, 90, 45),
    ('XM', 'Crossmatch', 'BBANK', 'whole_blood', 90, 40, 20),
    ('DAT', 'Direct Antiglobulin Test', 'BBANK', 'whole_blood', 60, 30, 15),
    ('UACOMP', 'Urinalysis', 'UA', 'urine', 45, 20, 10),
    ('UMICRO', 'Urine Microscopy', 'UA', 'urine', 60, 30, 15),
    ('UHCG', 'Urine Pregnancy Test', 'UA', 'urine', 20, 10, 5),
    ('ANA', 'Antinuclear Antibody', 'IMM', 'serum', 1440, 480, 240),
    ('CRP', 'C-Reactive Protein', 'IMM', 'serum', 180, 60, 30),
    ('RF', 'Rheumatoid Factor', 'IMM', 'serum', 240, 90, 45)
) AS v(
  test_code, test_name, department_code, specimen_type,
  routine_minutes, urgent_minutes, stat_minutes
)
JOIN clinical_lab.departments AS d
  ON d.department_code = v.department_code;

INSERT INTO clinical_lab.lab_staff (
  employee_number, first_name, last_name, job_role, department_id,
  shift_code, shift_start_time, shift_end_time, hired_on
)
SELECT
  'E' || lpad(i::text, 4, '0'),
  (ARRAY[
    'Avery', 'Blake', 'Casey', 'Devon', 'Ellis', 'Finley', 'Gray', 'Harper',
    'Indy', 'Jules', 'Kelly', 'Logan', 'Morgan', 'Noah', 'Parker', 'Quinn',
    'Reese', 'Shawn', 'Taylor', 'Winter'
  ])[1 + ((i - 1) % 20)],
  (ARRAY[
    'Alden', 'Brooks', 'Carter', 'Diaz', 'Ellison', 'Foster', 'Garcia', 'Hayes',
    'Ibarra', 'Jung', 'Klein', 'Lopez', 'Meyer', 'Nguyen', 'Owens', 'Patel',
    'Quincy', 'Rossi', 'Shah', 'Tran', 'Ueda', 'Voss', 'Walker', 'Young'
  ])[1 + ((i * 5) % 24)],
  CASE
    WHEN i BETWEEN 1 AND 8 THEN 'phlebotomist'
    WHEN i BETWEEN 9 AND 14 THEN 'accessioner'
    WHEN i BETWEEN 15 AND 34 THEN 'technologist'
    WHEN i BETWEEN 35 AND 38 THEN 'supervisor'
    ELSE 'pathologist'
  END,
  d.department_id,
  s.shift_code::clinical_lab.shift_code,
  CASE s.shift_code
    WHEN 'day' THEN TIME '07:00'
    WHEN 'evening' THEN TIME '15:00'
    WHEN 'night' THEN TIME '23:00'
    ELSE TIME '07:00'
  END,
  CASE s.shift_code
    WHEN 'day' THEN TIME '15:00'
    WHEN 'evening' THEN TIME '23:00'
    WHEN 'night' THEN TIME '07:00'
    ELSE TIME '19:00'
  END,
  DATE '2013-06-01' + (i * 80)
FROM generate_series(1, 40) AS g(i)
JOIN (
  SELECT
    i,
    CASE
      WHEN i BETWEEN 1 AND 8 THEN (ARRAY['CHEM', 'HEM', 'CHEM', 'BBANK', 'UA', 'HEM', 'BBANK', 'UA'])[i]
      WHEN i BETWEEN 9 AND 14 THEN (ARRAY['CHEM', 'HEM', 'MICRO', 'BBANK', 'UA', 'IMM'])[i - 8]
      WHEN i BETWEEN 15 AND 34 THEN (ARRAY['CHEM', 'HEM', 'MICRO', 'BBANK', 'UA', 'IMM'])[1 + ((i - 15) % 6)]
      WHEN i BETWEEN 35 AND 38 THEN (ARRAY['CHEM', 'HEM', 'MICRO', 'BBANK'])[i - 34]
      ELSE (ARRAY['MICRO', 'IMM'])[i - 38]
    END AS department_code,
    CASE
      WHEN i BETWEEN 1 AND 8 THEN (ARRAY['day', 'day', 'day', 'evening', 'evening', 'night', 'night', 'rotating'])[i]
      WHEN i BETWEEN 9 AND 14 THEN (ARRAY['day', 'day', 'evening', 'evening', 'night', 'rotating'])[i - 8]
      WHEN i BETWEEN 15 AND 34 THEN (ARRAY['day', 'evening', 'night', 'day', 'evening', 'night', 'day'])[1 + ((i - 15) % 7)]
      ELSE 'day'
    END AS shift_code
  FROM generate_series(1, 40) AS i
) AS s ON s.i = g.i
JOIN clinical_lab.departments AS d
  ON d.department_code = s.department_code;

DO $ref$
DECLARE
  n_dept integer;
  n_test integer;
  n_staff integer;
BEGIN
  SELECT count(*) INTO n_dept FROM clinical_lab.departments;
  SELECT count(*) INTO n_test FROM clinical_lab.test_catalog;
  SELECT count(*) INTO n_staff FROM clinical_lab.lab_staff;
  IF n_dept <> 6 OR n_test <> 25 OR n_staff <> 40 THEN
    RAISE EXCEPTION 'reference load counts were departments %, tests %, staff %', n_dept, n_test, n_staff;
  END IF;
END
$ref$;

CREATE TEMP TABLE gen_patient_draw (
  n integer PRIMARY KEY,
  u_dob double precision NOT NULL,
  u_span double precision NOT NULL,
  u_sex double precision NOT NULL,
  u_phone double precision NOT NULL,
  u_email double precision NOT NULL
);

INSERT INTO gen_patient_draw (n, u_dob, u_span, u_sex, u_phone, u_email)
SELECT n, random(), random(), random(), random(), random()
FROM generate_series(1, 10000) AS g(n)
ORDER BY n;

INSERT INTO clinical_lab.patients (
  mrn, first_name, last_name, date_of_birth, sex,
  phone_number, email, address_line, city, state_code, postal_code,
  record_status, identity_verified
)
SELECT
  'MRN' || lpad(d.n::text, 8, '0'),
  (ARRAY[
    'Amina', 'Bennett', 'Camila', 'Darius', 'Elena', 'Farah', 'Gideon', 'Hana',
    'Idris', 'Jin', 'Keisha', 'Leila', 'Mateo', 'Nadia', 'Omar', 'Priya',
    'Quentin', 'Rosa', 'Soren', 'Talia', 'Uma', 'Victor', 'Willa', 'Xavier',
    'Yara', 'Zola', 'Arthur', 'Bea', 'Cyrus', 'Dina'
  ])[1 + ((d.n - 1) % 30)],
  (ARRAY[
    'Abebe', 'Bauer', 'Cho', 'Diallo', 'Engel', 'Farouk', 'Gupta', 'Haddad',
    'Ito', 'Jensen', 'Khoury', 'Larsen', 'Mensah', 'Nowak', 'Okeke', 'Petrova',
    'Quaye', 'Rahman', 'Silva', 'Tesfaye', 'Ullah', 'Varga', 'Wong', 'Xie',
    'Yilmaz', 'Zimmerman', 'Costa', 'Berg', 'Nwosu', 'Paredes'
  ])[1 + ((d.n * 7) % 30)],
  CASE
    WHEN d.u_dob < 0.15 THEN DATE '2012-01-01' + floor(d.u_span * 4000)::integer
    WHEN d.u_dob < 0.72 THEN DATE '1962-01-01' + floor(d.u_span * 15000)::integer
    ELSE DATE '1930-01-01' + floor(d.u_span * 11000)::integer
  END,
  CASE
    WHEN d.u_sex < 0.505 THEN 'female'
    WHEN d.u_sex < 0.985 THEN 'male'
    WHEN d.u_sex < 0.995 THEN 'intersex'
    ELSE 'unknown'
  END,
  CASE
    WHEN d.u_phone >= 0.10 THEN '555-010-' || lpad((d.n % 10000)::text, 4, '0')
    ELSE NULL
  END,
  CASE
    WHEN d.u_email >= 0.35 THEN 'p' || lpad(d.n::text, 8, '0') || '@example.test'
    ELSE NULL
  END,
  CASE
    WHEN d.u_email >= 0.15 THEN
      (100 + (d.n % 800))::text || ' ' ||
      (ARRAY['Oak Street', 'Maple Avenue', 'River Road', 'Cedar Lane', 'Hillcrest Drive', 'Park Place'])[1 + (d.n % 6)]
    ELSE NULL
  END,
  CASE
    WHEN d.u_email >= 0.15 THEN
      (ARRAY['Riverton', 'Lakeside', 'Maplewood', 'Cedar Falls', 'Brookfield', 'Ashland', 'Fairview', 'Glenwood'])[1 + (d.n % 8)]
    ELSE NULL
  END,
  CASE
    WHEN d.u_email >= 0.15 THEN
      (ARRAY['IN', 'MI', 'WI', 'IA', 'MO', 'KY', 'TN', 'GA'])[1 + (d.n % 8)]
    ELSE NULL
  END,
  CASE
    WHEN d.u_email >= 0.15 THEN
      (ARRAY['46204', '48101', '53703', '50613', '64628', '41101', '37062', '30427'])[1 + (d.n % 8)]
    ELSE NULL
  END,
  'active',
  true
FROM gen_patient_draw AS d;

UPDATE clinical_lab.patients AS p
SET
  record_status = v.status,
  identity_verified = v.verified,
  merged_into_patient_id = CASE
    WHEN v.status = 'merged' THEN parent.patient_id
    ELSE NULL
  END,
  phone_number = CASE WHEN v.status = 'incomplete' THEN NULL ELSE p.phone_number END,
  email = CASE WHEN v.status = 'incomplete' THEN NULL ELSE p.email END
FROM (
  SELECT
    n,
    'MRN' || lpad(n::text, 8, '0') AS mrn,
    CASE
      WHEN n > 400 AND n % 80 = 0 THEN 'merged'
      WHEN n % 90 = 1 THEN 'duplicate_suspected'
      WHEN n % 70 = 2 THEN 'incomplete'
      WHEN n % 50 = 3 THEN 'inactive'
      ELSE 'active'
    END AS status,
    CASE
      WHEN n > 400 AND n % 80 = 0 THEN false
      WHEN n % 90 = 1 THEN false
      WHEN n % 70 = 2 THEN false
      WHEN n % 50 = 3 THEN (n % 2 = 0)
      ELSE (n % 6 <> 0)
    END AS verified,
    CASE
      WHEN n > 400 AND n % 80 = 0 THEN 'MRN' || lpad((n - 400)::text, 8, '0')
      ELSE NULL
    END AS parent_mrn
  FROM generate_series(1, 10000) AS n
) AS v
LEFT JOIN clinical_lab.patients AS parent
  ON parent.mrn = v.parent_mrn
WHERE p.mrn = v.mrn
  AND (
    v.status <> 'active'
    OR v.verified IS FALSE
  );

DO $patients$
BEGIN
  IF (SELECT count(*) FROM clinical_lab.patients) <> 10000 THEN
    RAISE EXCEPTION 'patient load did not produce 10000 rows';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM clinical_lab.patients
    WHERE record_status = 'merged'
      AND merged_into_patient_id IS NULL
  ) THEN
    RAISE EXCEPTION 'a merged patient has no surviving record';
  END IF;
END
$patients$;

CREATE TEMP TABLE gen_month (
  month_index integer PRIMARY KEY,
  month_start date NOT NULL,
  days_in_month integer NOT NULL,
  weight integer NOT NULL,
  cum integer NOT NULL,
  total integer NOT NULL
);

INSERT INTO gen_month (month_index, month_start, days_in_month, weight, cum, total)
SELECT
  v.month_index,
  (DATE '2025-11-01' + (v.month_index || ' months')::interval)::date,
  extract(
    day FROM (
      DATE '2025-11-01'
      + (v.month_index || ' months')::interval
      + interval '1 month'
      - interval '1 day'
    )
  )::integer,
  v.weight,
  sum(v.weight) OVER (ORDER BY v.month_index),
  sum(v.weight) OVER ()
FROM (
  VALUES
    (0, 9), (1, 8), (2, 10), (3, 11), (4, 9), (5, 8),
    (6, 9), (7, 10), (8, 8), (9, 9), (10, 10), (11, 9)
) AS v(month_index, weight);

CREATE TEMP TABLE gen_hour (
  hour integer PRIMARY KEY,
  weight integer NOT NULL,
  cum integer NOT NULL,
  total integer NOT NULL
);

INSERT INTO gen_hour (hour, weight, cum, total)
SELECT
  v.hour,
  v.weight,
  sum(v.weight) OVER (ORDER BY v.hour),
  sum(v.weight) OVER ()
FROM (
  VALUES
    (0, 1), (1, 1), (2, 1), (3, 1), (4, 1), (5, 2),
    (6, 4), (7, 8), (8, 10), (9, 9), (10, 8), (11, 7),
    (12, 6), (13, 7), (14, 8), (15, 9), (16, 8), (17, 6),
    (18, 4), (19, 3), (20, 2), (21, 2), (22, 1), (23, 1)
) AS v(hour, weight);

CREATE TEMP TABLE gen_test AS
SELECT
  t.test_id,
  t.test_code,
  t.department_id,
  t.required_specimen_type::text AS required_specimen_type,
  t.routine_turnaround_minutes,
  t.urgent_turnaround_minutes,
  t.stat_turnaround_minutes,
  p.pace,
  w.weight,
  sum(w.weight) OVER (ORDER BY t.test_code) AS cum,
  sum(w.weight) OVER () AS total
FROM clinical_lab.test_catalog AS t
JOIN clinical_lab.departments AS d
  ON d.department_id = t.department_id
JOIN (
  VALUES
    ('CHEM', 1.00),
    ('HEM', 0.90),
    ('MICRO', 1.15),
    ('BBANK', 0.80),
    ('UA', 0.95),
    ('IMM', 1.25)
) AS p(department_code, pace)
  ON p.department_code = d.department_code
JOIN (
  VALUES
    ('BMP', 14), ('CMP', 12), ('GLU', 10), ('HBA1C', 6), ('LIPID', 5),
    ('TSH', 4), ('TROP', 3), ('CBC', 16), ('DIFF', 6), ('RETIC', 2),
    ('ESR', 2), ('BCULT', 3), ('UCULT', 4), ('COVID', 5), ('STREP', 3),
    ('ABORH', 4), ('ABID', 2), ('XM', 3), ('DAT', 1), ('UACOMP', 8),
    ('UMICRO', 3), ('UHCG', 4), ('ANA', 2), ('CRP', 5), ('RF', 2)
) AS w(test_code, weight)
  ON w.test_code = t.test_code;

DO $weights$
BEGIN
  IF (SELECT count(*) FROM gen_month) <> 12
     OR (SELECT count(*) FROM gen_hour) <> 24
     OR (SELECT count(*) FROM gen_test) <> 25 THEN
    RAISE EXCEPTION 'month, hour, or test weight tables are incomplete';
  END IF;
END
$weights$;

CREATE TEMP TABLE gen_draw (
  n integer PRIMARY KEY,
  u_month double precision NOT NULL,
  u_day double precision NOT NULL,
  u_hour double precision NOT NULL,
  u_minute double precision NOT NULL,
  u_priority double precision NOT NULL,
  u_status double precision NOT NULL,
  u_test double precision NOT NULL,
  u_patient double precision NOT NULL,
  u_tat double precision NOT NULL,
  u_collect double precision NOT NULL,
  u_issue double precision NOT NULL,
  u_disc double precision NOT NULL,
  u_label double precision NOT NULL,
  u_wrong_type double precision NOT NULL,
  u_missing double precision NOT NULL,
  u_recollect double precision NOT NULL,
  u_resolve double precision NOT NULL
);

INSERT INTO gen_draw (
  n, u_month, u_day, u_hour, u_minute, u_priority, u_status, u_test, u_patient,
  u_tat, u_collect, u_issue, u_disc, u_label, u_wrong_type, u_missing, u_recollect, u_resolve
)
SELECT
  n,
  random(), random(), random(), random(), random(), random(), random(), random(),
  random(), random(), random(), random(), random(), random(), random(), random(), random()
FROM generate_series(1, 50000) AS g(n)
ORDER BY n;

CREATE TEMP TABLE gen_staff AS
SELECT
  staff_id,
  employee_number,
  job_role,
  shift_code::text AS shift_code,
  department_id,
  row_number() OVER (PARTITION BY job_role, shift_code ORDER BY employee_number) AS rn,
  count(*) OVER (PARTITION BY job_role, shift_code)::integer AS cnt
FROM clinical_lab.lab_staff;

DO $staff_cover$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM (
      VALUES
        ('accessioner', 'day'),
        ('accessioner', 'evening'),
        ('accessioner', 'night'),
        ('phlebotomist', 'day'),
        ('phlebotomist', 'evening'),
        ('phlebotomist', 'night'),
        ('technologist', 'day'),
        ('technologist', 'evening'),
        ('technologist', 'night'),
        ('supervisor', 'day')
    ) AS need(job_role, shift_code)
    WHERE NOT EXISTS (
      SELECT 1
      FROM gen_staff AS s
      WHERE s.job_role = need.job_role
        AND s.shift_code = need.shift_code
        AND s.cnt > 0
    )
  ) THEN
    RAISE EXCEPTION 'a required role and shift has no employee';
  END IF;
END
$staff_cover$;

CREATE TEMP TABLE gen_built (
  n integer PRIMARY KEY,
  u_day double precision NOT NULL,
  u_collect double precision NOT NULL,
  u_tat double precision NOT NULL,
  u_issue double precision NOT NULL,
  u_disc double precision NOT NULL,
  u_label double precision NOT NULL,
  u_wrong_type double precision NOT NULL,
  u_missing double precision NOT NULL,
  u_recollect double precision NOT NULL,
  u_resolve double precision NOT NULL,
  test_id bigint,
  department_id bigint,
  required_specimen_type text,
  routine_minutes integer,
  urgent_minutes integer,
  stat_minutes integer,
  pace numeric,
  test_code text,
  patient_id bigint,
  patient_name text,
  patient_dob date,
  priority text NOT NULL,
  order_status text NOT NULL,
  ordered_at timestamptz,
  received_at timestamptz,
  testing_started_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  rejected_at timestamptz,
  tat_minutes integer,
  accession_number text,
  received_shift text,
  corrected_test_id bigint,
  order_is_incorrect boolean NOT NULL DEFAULT false,
  incorrect_order_reason text,
  missing_information boolean NOT NULL DEFAULT false,
  missing_information_detail text,
  requisition_patient_name text,
  requisition_date_of_birth date,
  cancellation_reason text,
  rejection_reason text
);

INSERT INTO gen_built (
  n, u_day, u_collect, u_tat, u_issue, u_disc, u_label, u_wrong_type, u_missing,
  u_recollect, u_resolve, test_id, department_id, required_specimen_type,
  routine_minutes, urgent_minutes, stat_minutes, pace, test_code,
  patient_id, patient_name, patient_dob, priority, order_status
)
SELECT
  d.n,
  d.u_day,
  d.u_collect,
  d.u_tat,
  d.u_issue,
  d.u_disc,
  d.u_label,
  d.u_wrong_type,
  d.u_missing,
  d.u_recollect,
  d.u_resolve,
  CASE
    WHEN picked.order_status = 'incomplete'
     AND d.u_patient >= 0.25
     AND d.u_patient < 0.45 THEN NULL
    ELSE t.test_id
  END,
  CASE
    WHEN picked.order_status = 'incomplete'
     AND d.u_patient >= 0.25
     AND d.u_patient < 0.45 THEN NULL
    ELSE t.department_id
  END,
  CASE
    WHEN picked.order_status = 'incomplete'
     AND d.u_patient >= 0.25
     AND d.u_patient < 0.45 THEN NULL
    ELSE t.required_specimen_type
  END,
  t.routine_turnaround_minutes,
  t.urgent_turnaround_minutes,
  t.stat_turnaround_minutes,
  t.pace,
  CASE
    WHEN picked.order_status = 'incomplete'
     AND d.u_patient >= 0.25
     AND d.u_patient < 0.45 THEN NULL
    ELSE t.test_code
  END,
  CASE
    WHEN picked.order_status = 'incomplete' AND d.u_patient < 0.25 THEN NULL
    WHEN picked.order_status = 'rejected' AND d.u_patient < 0.10 THEN NULL
    ELSE p.patient_id
  END,
  CASE
    WHEN picked.order_status = 'incomplete' AND d.u_patient < 0.25 THEN NULL
    WHEN picked.order_status = 'rejected' AND d.u_patient < 0.10 THEN NULL
    ELSE p.first_name || ' ' || p.last_name
  END,
  CASE
    WHEN picked.order_status = 'incomplete' AND d.u_patient < 0.25 THEN NULL
    WHEN picked.order_status = 'rejected' AND d.u_patient < 0.10 THEN NULL
    ELSE p.date_of_birth
  END,
  picked.priority,
  picked.order_status
FROM gen_draw AS d
JOIN LATERAL (
  SELECT m.month_start, m.days_in_month
  FROM gen_month AS m
  WHERE m.cum > d.u_month * m.total
  ORDER BY m.cum
  LIMIT 1
) AS m ON true
JOIN LATERAL (
  SELECT h.hour
  FROM gen_hour AS h
  WHERE h.cum > d.u_hour * h.total
  ORDER BY h.cum
  LIMIT 1
) AS h ON true
JOIN LATERAL (
  SELECT gt.*
  FROM gen_test AS gt
  WHERE gt.cum > d.u_test * gt.total
  ORDER BY gt.cum
  LIMIT 1
) AS t ON true
JOIN LATERAL (
  SELECT
    CASE
      WHEN d.u_status < 0.78 THEN 'completed'
      WHEN d.u_status < 0.82 THEN 'in_progress'
      WHEN d.u_status < 0.86 THEN 'received'
      WHEN d.u_status < 0.90 THEN 'incomplete'
      WHEN d.u_status < 0.95 THEN 'cancelled'
      ELSE 'rejected'
    END AS order_status,
    CASE
      WHEN t.test_code IN ('TROP', 'ABORH', 'XM', 'GLU') AND d.u_priority < 0.22 THEN 'stat'
      WHEN t.test_code IN ('TROP', 'ABORH', 'XM', 'CBC', 'GLU') AND d.u_priority < 0.45 THEN 'urgent'
      WHEN d.u_priority < 0.74 THEN 'routine'
      WHEN d.u_priority < 0.92 THEN 'urgent'
      ELSE 'stat'
    END AS priority
) AS picked ON true
LEFT JOIN clinical_lab.patients AS p
  ON p.mrn = 'MRN' || lpad((1 + floor(d.u_patient * 10000)::integer)::text, 8, '0');

UPDATE gen_built AS b
SET
  ordered_at = calc.ordered_at,
  received_at = calc.received_at,
  testing_started_at = calc.testing_started_at,
  completed_at = calc.completed_at,
  cancelled_at = calc.cancelled_at,
  rejected_at = calc.rejected_at,
  tat_minutes = calc.tat_minutes,
  received_shift = calc.received_shift
FROM (
  SELECT
    timed.n,
    timed.ordered_at,
    timed.received_at,
    CASE
      WHEN timed.order_status = 'completed' THEN timed.received_at + interval '4 minutes'
      WHEN timed.order_status = 'in_progress' THEN timed.received_at + interval '4 minutes'
      WHEN timed.order_status = 'rejected' AND timed.n % 2 = 0 THEN timed.received_at + interval '5 minutes'
      ELSE NULL
    END AS testing_started_at,
    CASE
      WHEN timed.order_status = 'completed' THEN timed.received_at + (timed.tat_minutes * interval '1 minute')
      ELSE NULL
    END AS completed_at,
    CASE
      WHEN timed.order_status = 'cancelled' AND timed.received_at IS NULL THEN timed.ordered_at + interval '30 minutes'
      WHEN timed.order_status = 'cancelled' THEN timed.received_at + interval '45 minutes'
      ELSE NULL
    END AS cancelled_at,
    CASE
      WHEN timed.order_status = 'rejected' THEN timed.received_at + ((20 + (timed.n % 90)) * interval '1 minute')
      ELSE NULL
    END AS rejected_at,
    timed.tat_minutes,
    CASE
      WHEN timed.received_at IS NULL THEN NULL
      WHEN extract(hour FROM timed.received_at AT TIME ZONE 'America/New_York') BETWEEN 7 AND 14 THEN 'day'
      WHEN extract(hour FROM timed.received_at AT TIME ZONE 'America/New_York') BETWEEN 15 AND 22 THEN 'evening'
      ELSE 'night'
    END AS received_shift
  FROM (
    SELECT
      base.n,
      base.order_status,
      base.ordered_at,
      CASE
        WHEN base.include_receipt THEN base.ordered_at + (base.receipt_minutes * interval '1 minute')
        ELSE NULL
      END AS received_at,
      CASE
        WHEN base.order_status <> 'completed' THEN NULL
        ELSE greatest(
          5,
          least(
            base.raw_tat,
            floor(extract(epoch FROM (
              TIMESTAMPTZ '2026-11-11 12:00:00-05'
              - (base.ordered_at + (base.receipt_minutes * interval '1 minute'))
            )) / 60.0)::integer
          )
        )
      END AS tat_minutes
    FROM (
      SELECT
        g.n,
        g.order_status,
        (
          g.month_anchor
          + (floor(g.u_day * g.days_in_month)::integer * interval '1 day')
          + (g.hour * interval '1 hour')
          + (floor(g.u_minute * 60)::integer * interval '1 minute')
          + (g.n * interval '1 microsecond')
        ) AT TIME ZONE 'America/New_York' AS ordered_at,
        g.order_status NOT IN ('incomplete')
          AND NOT (g.order_status = 'cancelled' AND g.n % 2 = 0) AS include_receipt,
        CASE g.priority
          WHEN 'stat' THEN 6 + (g.n % 8)
          WHEN 'urgent' THEN 10 + (g.n % 20)
          ELSE 15 + (g.n % 40)
        END AS receipt_minutes,
        round((
          g.target_minutes::numeric
          * g.pace
          * CASE
              WHEN g.hour >= 7 AND g.hour < 15 THEN 1.00
              WHEN g.hour >= 15 AND g.hour < 23 THEN 1.06
              ELSE 1.18
            END
          * (0.55 + g.u_tat::numeric)
        ))::integer AS raw_tat
      FROM (
        SELECT
          b.n,
          b.u_day,
          b.u_tat,
          d.u_minute,
          b.order_status,
          b.priority,
          b.pace,
          m.month_start::timestamp AS month_anchor,
          m.days_in_month,
          h.hour,
          CASE b.priority
            WHEN 'stat' THEN b.stat_minutes
            WHEN 'urgent' THEN b.urgent_minutes
            ELSE b.routine_minutes
          END AS target_minutes
        FROM gen_built AS b
        JOIN gen_draw AS d ON d.n = b.n
        JOIN LATERAL (
          SELECT gm.month_start, gm.days_in_month
          FROM gen_month AS gm
          WHERE gm.cum > d.u_month * gm.total
          ORDER BY gm.cum
          LIMIT 1
        ) AS m ON true
        JOIN LATERAL (
          SELECT gh.hour
          FROM gen_hour AS gh
          WHERE gh.cum > d.u_hour * gh.total
          ORDER BY gh.cum
          LIMIT 1
        ) AS h ON true
      ) AS g
    ) AS base
  ) AS timed
) AS calc
WHERE calc.n = b.n;

UPDATE gen_built AS b
SET
  order_is_incorrect = flags.incorrect,
  corrected_test_id = CASE
    WHEN flags.incorrect THEN (
      SELECT t2.test_id
      FROM clinical_lab.test_catalog AS t2
      WHERE t2.test_id <> b.test_id
      ORDER BY t2.test_code
      OFFSET (b.n % 24)
      LIMIT 1
    )
    ELSE NULL
  END,
  incorrect_order_reason = CASE
    WHEN flags.incorrect THEN 'The ordered test did not match the test the provider requested.'
    ELSE NULL
  END,
  missing_information = flags.missing,
  missing_information_detail = CASE
    WHEN flags.missing THEN 'Ordering provider was not identified on the requisition.'
    ELSE NULL
  END,
  requisition_patient_name = CASE
    WHEN b.patient_id IS NOT NULL AND b.department_id IS NOT NULL AND b.u_disc < 0.009
      THEN b.patient_name || ' Lee'
    WHEN b.patient_id IS NOT NULL THEN b.patient_name
    ELSE NULL
  END,
  requisition_date_of_birth = CASE
    WHEN b.patient_id IS NOT NULL
     AND b.department_id IS NOT NULL
     AND b.u_disc >= 0.009
     AND b.u_disc < 0.018 THEN b.patient_dob - 1
    WHEN b.patient_id IS NOT NULL THEN b.patient_dob
    ELSE NULL
  END,
  cancellation_reason = CASE
    WHEN b.order_status = 'cancelled' AND b.received_at IS NULL THEN 'Provider cancelled the order before receipt.'
    WHEN b.order_status = 'cancelled' THEN 'Provider cancelled the order after receipt.'
    ELSE NULL
  END,
  rejection_reason = CASE
    WHEN b.order_status = 'rejected' THEN 'The laboratory could not complete testing for this order.'
    ELSE NULL
  END,
  accession_number = CASE
    WHEN b.order_status = 'incomplete' THEN NULL
    WHEN b.order_status = 'cancelled' AND b.received_at IS NULL THEN NULL
    ELSE 'A' || lpad(b.n::text, 8, '0')
  END
FROM (
  SELECT
    n,
    (test_id IS NOT NULL AND order_status <> 'incomplete' AND u_issue < 0.022) AS incorrect,
    (department_id IS NOT NULL AND order_status <> 'completed' AND u_missing < 0.04) AS missing
  FROM gen_built
) AS flags
WHERE flags.n = b.n;

DO $before_orders$
BEGIN
  IF (SELECT count(*) FROM gen_built) <> 50000 THEN
    RAISE EXCEPTION 'order plan did not contain 50000 rows';
  END IF;
  IF EXISTS (
    SELECT 1 FROM gen_built
    WHERE patient_id IS NULL
      AND order_status NOT IN ('incomplete', 'rejected')
  ) THEN
    RAISE EXCEPTION 'an order that requires a patient has none';
  END IF;
  IF EXISTS (
    SELECT 1 FROM gen_built
    WHERE test_id IS NULL
      AND order_status <> 'incomplete'
  ) THEN
    RAISE EXCEPTION 'an order that requires a test has none';
  END IF;
  IF EXISTS (
    SELECT 1 FROM gen_built
    WHERE (test_id IS NULL) <> (department_id IS NULL)
  ) THEN
    RAISE EXCEPTION 'test and performing department were not kept together';
  END IF;
  IF EXISTS (
    SELECT 1 FROM gen_built
    WHERE order_is_incorrect
      AND (corrected_test_id IS NULL OR corrected_test_id = test_id OR incorrect_order_reason IS NULL)
  ) THEN
    RAISE EXCEPTION 'an incorrect order is missing its corrected test';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM gen_built
    GROUP BY ordered_at
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'ordered_at values are not unique';
  END IF;
  IF EXISTS (
    SELECT 1 FROM gen_built
    WHERE order_status = 'completed'
      AND (received_at IS NULL OR testing_started_at IS NULL OR completed_at IS NULL OR tat_minutes < 5)
  ) THEN
    RAISE EXCEPTION 'a completed order is missing a usable timeline';
  END IF;
END
$before_orders$;

CREATE TEMP TABLE gen_order_id (
  n integer PRIMARY KEY,
  lab_order_id bigint NOT NULL UNIQUE
);

WITH inserted AS (
  INSERT INTO clinical_lab.lab_orders (
    accession_number,
    patient_id,
    test_id,
    corrected_test_id,
    performing_department_id,
    received_by_staff_id,
    received_during_shift,
    priority,
    order_status,
    order_is_incorrect,
    incorrect_order_reason,
    missing_information,
    missing_information_detail,
    requisition_patient_name,
    requisition_date_of_birth,
    ordered_at,
    received_at,
    testing_started_at,
    completed_at,
    cancelled_at,
    rejected_at,
    cancellation_reason,
    rejection_reason
  )
  SELECT
    b.accession_number,
    b.patient_id,
    b.test_id,
    b.corrected_test_id,
    b.department_id,
    CASE
      WHEN b.received_at IS NULL THEN NULL
      ELSE COALESCE(matched.staff_id, fallback.staff_id)
    END,
    b.received_shift::clinical_lab.shift_code,
    b.priority,
    b.order_status,
    b.order_is_incorrect,
    b.incorrect_order_reason,
    b.missing_information,
    b.missing_information_detail,
    b.requisition_patient_name,
    b.requisition_date_of_birth,
    b.ordered_at,
    b.received_at,
    b.testing_started_at,
    b.completed_at,
    b.cancelled_at,
    b.rejected_at,
    b.cancellation_reason,
    b.rejection_reason
  FROM gen_built AS b
  LEFT JOIN LATERAL (
    SELECT s.staff_id
    FROM gen_staff AS s
    WHERE b.received_at IS NOT NULL
      AND s.job_role = 'accessioner'
      AND s.shift_code = b.received_shift
      AND s.rn = 1 + (b.n % s.cnt)
    LIMIT 1
  ) AS matched ON true
  LEFT JOIN LATERAL (
    SELECT s.staff_id
    FROM gen_staff AS s
    WHERE s.job_role = 'accessioner'
    ORDER BY s.employee_number
    LIMIT 1
  ) AS fallback ON true
  RETURNING lab_order_id, ordered_at
)
INSERT INTO gen_order_id (n, lab_order_id)
SELECT b.n, i.lab_order_id
FROM inserted AS i
JOIN gen_built AS b
  ON b.ordered_at = i.ordered_at;

DO $mapped$
BEGIN
  IF (SELECT count(*) FROM gen_order_id) <> 50000 THEN
    RAISE EXCEPTION 'order id map has % rows', (SELECT count(*) FROM gen_order_id);
  END IF;
END
$mapped$;

CREATE TEMP TABLE gen_specimen (
  n integer NOT NULL,
  seq integer NOT NULL,
  specimen_type text NOT NULL,
  specimen_status text NOT NULL,
  labeling_error boolean NOT NULL,
  labeling_error_detail text,
  missing_information boolean NOT NULL,
  missing_information_detail text,
  rejection_reason text,
  collected_at timestamptz,
  labeled_at timestamptz,
  received_at timestamptz,
  accepted_at timestamptz,
  rejected_at timestamptz,
  cancelled_at timestamptz,
  PRIMARY KEY (n, seq)
);

INSERT INTO gen_specimen (
  n, seq, specimen_type, specimen_status, labeling_error, labeling_error_detail,
  missing_information, missing_information_detail, rejection_reason,
  collected_at, labeled_at, received_at, accepted_at, rejected_at, cancelled_at
)
SELECT
  core.n,
  1,
  core.specimen_type,
  core.specimen_status,
  core.collected_at IS NOT NULL AND core.u_label < 0.015,
  CASE
    WHEN core.collected_at IS NOT NULL AND core.u_label < 0.015
      THEN 'The specimen label did not match the requisition name.'
    ELSE NULL
  END,
  core.collected_at IS NOT NULL AND core.u_missing > 0.975,
  CASE
    WHEN core.collected_at IS NOT NULL AND core.u_missing > 0.975
      THEN 'Collection time was not recorded on the specimen.'
    ELSE NULL
  END,
  CASE
    WHEN core.specimen_status <> 'rejected' THEN NULL
    WHEN core.required_specimen_type IS NOT NULL
     AND core.specimen_type <> core.required_specimen_type
      THEN 'Specimen type does not match the ordered test.'
    ELSE 'Quantity not sufficient for the ordered test.'
  END,
  core.collected_at,
  CASE
    WHEN core.collected_at IS NULL THEN NULL
    ELSE core.collected_at + interval '1 minute'
  END,
  core.spec_received_at,
  core.accepted_at,
  core.rejected_at,
  core.cancelled_at
FROM (
  SELECT
    b.n,
    b.u_label,
    b.u_missing,
    b.required_specimen_type,
    CASE b.order_status
      WHEN 'completed' THEN 'accepted'
      WHEN 'in_progress' THEN CASE WHEN b.u_recollect < 0.50 THEN 'accepted' ELSE 'received' END
      WHEN 'received' THEN 'received'
      WHEN 'rejected' THEN 'rejected'
      WHEN 'cancelled' THEN 'cancelled'
      ELSE CASE WHEN b.n % 5 = 0 THEN 'cancelled' ELSE 'pending_collection' END
    END AS specimen_status,
    CASE
      WHEN b.order_status = 'rejected'
       AND b.u_wrong_type < 0.40
       AND b.required_specimen_type IS NOT NULL THEN
        CASE b.required_specimen_type
          WHEN 'serum' THEN 'plasma'
          WHEN 'plasma' THEN 'serum'
          WHEN 'whole_blood' THEN 'serum'
          WHEN 'urine' THEN 'whole_blood'
          WHEN 'swab' THEN 'serum'
          ELSE 'other'
        END
      ELSE COALESCE(b.required_specimen_type, 'other')
    END AS specimen_type,
    CASE
      WHEN (
        CASE b.order_status
          WHEN 'completed' THEN 'accepted'
          WHEN 'in_progress' THEN 'received'
          WHEN 'received' THEN 'received'
          WHEN 'rejected' THEN 'rejected'
          WHEN 'cancelled' THEN 'cancelled'
          ELSE CASE WHEN b.n % 5 = 0 THEN 'cancelled' ELSE 'pending_collection' END
        END
      ) = 'pending_collection' THEN NULL
      WHEN (
        CASE b.order_status
          WHEN 'cancelled' THEN 'cancelled'
          ELSE CASE WHEN b.order_status = 'incomplete' AND b.n % 5 = 0 THEN 'cancelled' ELSE '' END
        END
      ) = 'cancelled'
       AND b.received_at IS NULL THEN NULL
      WHEN b.u_collect < 0.04 THEN b.ordered_at - ((2 + (b.n % 8)) * interval '1 day')
      ELSE b.ordered_at - ((15 + (b.n % 40)) * interval '1 minute')
    END AS collected_at,
    CASE
      WHEN (
        CASE b.order_status
          WHEN 'completed' THEN 'accepted'
          WHEN 'in_progress' THEN 'received'
          WHEN 'received' THEN 'received'
          WHEN 'rejected' THEN 'rejected'
          WHEN 'cancelled' THEN 'cancelled'
          ELSE 'pending_collection'
        END
      ) IN ('pending_collection') THEN NULL
      WHEN b.order_status = 'cancelled' AND b.received_at IS NULL THEN NULL
      WHEN b.order_status = 'incomplete' THEN NULL
      WHEN b.order_status = 'completed' THEN b.received_at - interval '2 minutes'
      ELSE b.received_at
    END AS spec_received_at,
    CASE
      WHEN b.order_status = 'completed' THEN b.received_at
      WHEN b.order_status = 'in_progress' AND b.u_recollect < 0.50 THEN b.received_at + interval '2 minutes'
      ELSE NULL
    END AS accepted_at,
    CASE
      WHEN b.order_status = 'rejected' THEN b.rejected_at
      ELSE NULL
    END AS rejected_at,
    CASE
      WHEN b.order_status = 'incomplete' AND b.n % 5 = 0 THEN b.ordered_at + interval '1 hour'
      WHEN b.order_status = 'cancelled' THEN b.cancelled_at
      ELSE NULL
    END AS cancelled_at
  FROM gen_built AS b
) AS core;

INSERT INTO gen_specimen (
  n, seq, specimen_type, specimen_status, labeling_error, labeling_error_detail,
  missing_information, missing_information_detail, rejection_reason,
  collected_at, labeled_at, received_at, accepted_at, rejected_at, cancelled_at
)
SELECT
  b.n,
  2,
  CASE
    WHEN b.u_wrong_type < 0.015 THEN
      CASE b.required_specimen_type
        WHEN 'serum' THEN 'plasma'
        WHEN 'plasma' THEN 'serum'
        WHEN 'whole_blood' THEN 'serum'
        WHEN 'urine' THEN 'whole_blood'
        WHEN 'swab' THEN 'serum'
        ELSE 'other'
      END
    ELSE b.required_specimen_type
  END,
  'rejected',
  false,
  NULL,
  false,
  NULL,
  CASE
    WHEN b.u_wrong_type < 0.015 THEN 'Specimen type does not match the ordered test.'
    ELSE 'Quantity not sufficient for the ordered test.'
  END,
  drawn.collected_at,
  drawn.collected_at + interval '1 minute',
  drawn.collected_at + interval '20 minutes',
  NULL,
  drawn.collected_at + interval '35 minutes',
  NULL
FROM gen_built AS b
JOIN LATERAL (
  SELECT b.ordered_at - ((15 + (b.n % 40)) * interval '1 minute') - interval '3 hours' AS collected_at
) AS drawn ON true
WHERE b.order_status = 'completed'
  AND (b.u_recollect < 0.07 OR b.u_wrong_type < 0.015);

INSERT INTO clinical_lab.specimens (
  lab_order_id,
  collected_by_staff_id,
  collected_during_shift,
  specimen_barcode,
  specimen_type,
  specimen_status,
  labeling_error,
  labeling_error_detail,
  missing_information,
  missing_information_detail,
  rejection_reason,
  collected_at,
  labeled_at,
  received_at,
  accepted_at,
  rejected_at,
  cancelled_at
)
SELECT
  m.lab_order_id,
  CASE
    WHEN s.collected_at IS NULL THEN NULL
    ELSE COALESCE(collector.staff_id, any_phleb.staff_id)
  END,
  CASE
    WHEN s.collected_at IS NULL THEN NULL
    WHEN extract(hour FROM s.collected_at AT TIME ZONE 'America/New_York') BETWEEN 7 AND 14 THEN 'day'
    WHEN extract(hour FROM s.collected_at AT TIME ZONE 'America/New_York') BETWEEN 15 AND 22 THEN 'evening'
    ELSE 'night'
  END::clinical_lab.shift_code,
  CASE WHEN s.seq = 1 THEN 'S' ELSE 'R' END || lpad(s.n::text, 8, '0'),
  s.specimen_type::clinical_lab.specimen_type,
  s.specimen_status,
  s.labeling_error,
  s.labeling_error_detail,
  s.missing_information,
  s.missing_information_detail,
  s.rejection_reason,
  s.collected_at,
  s.labeled_at,
  s.received_at,
  s.accepted_at,
  s.rejected_at,
  s.cancelled_at
FROM gen_specimen AS s
JOIN gen_order_id AS m ON m.n = s.n
LEFT JOIN LATERAL (
  SELECT st.staff_id
  FROM gen_staff AS st
  WHERE s.collected_at IS NOT NULL
    AND st.job_role = 'phlebotomist'
    AND st.shift_code = CASE
      WHEN extract(hour FROM s.collected_at AT TIME ZONE 'America/New_York') BETWEEN 7 AND 14 THEN 'day'
      WHEN extract(hour FROM s.collected_at AT TIME ZONE 'America/New_York') BETWEEN 15 AND 22 THEN 'evening'
      ELSE 'night'
    END
    AND st.rn = 1 + (s.n % st.cnt)
  LIMIT 1
) AS collector ON true
LEFT JOIN LATERAL (
  SELECT st.staff_id
  FROM gen_staff AS st
  WHERE st.job_role = 'phlebotomist'
  ORDER BY st.employee_number
  LIMIT 1
) AS any_phleb ON true;

INSERT INTO clinical_lab.lab_exceptions (
  lab_order_id,
  specimen_id,
  department_id,
  opened_by_staff_id,
  resolved_by_staff_id,
  exception_type,
  severity,
  resolution_status,
  opened_during_shift,
  description,
  resolution_note,
  opened_at,
  resolved_at
)
SELECT
  ready.lab_order_id,
  ready.specimen_id,
  ready.department_id,
  COALESCE(tech.staff_id, any_tech.staff_id),
  CASE
    WHEN ready.resolution_status = 'resolved' THEN supervisor.staff_id
    ELSE NULL
  END,
  ready.exception_type,
  ready.severity,
  ready.resolution_status,
  CASE
    WHEN extract(hour FROM ready.opened_at AT TIME ZONE 'America/New_York') BETWEEN 7 AND 14 THEN 'day'
    WHEN extract(hour FROM ready.opened_at AT TIME ZONE 'America/New_York') BETWEEN 15 AND 22 THEN 'evening'
    ELSE 'night'
  END::clinical_lab.shift_code,
  ready.description,
  CASE
    WHEN ready.resolution_status = 'resolved' THEN 'Corrective action completed and documented.'
    WHEN ready.resolution_status = 'cancelled' THEN 'Event recorded in error and withdrawn.'
    ELSE NULL
  END,
  ready.opened_at,
  CASE
    WHEN ready.resolution_status = 'resolved' THEN ready.resolved_deadline
    ELSE NULL
  END
FROM (
  SELECT
    staged.*,
    CASE
      WHEN staged.u_resolve < 0.62
       AND staged.opened_at + ((30 + floor(staged.u_resolve * 1800)::integer) * interval '1 minute')
           <= TIMESTAMPTZ '2026-11-10 18:00:00-05'
        THEN 'resolved'
      WHEN staged.u_resolve < 0.78 THEN 'in_progress'
      WHEN staged.u_resolve < 0.86 THEN 'cancelled'
      ELSE 'open'
    END AS resolution_status,
    staged.opened_at + ((30 + floor(staged.u_resolve * 1800)::integer) * interval '1 minute') AS resolved_deadline
  FROM (
    SELECT
      ev.lab_order_id,
      ev.specimen_id,
      ev.department_id,
      ev.exception_type,
      ev.severity,
      ev.description,
      ev.n,
      ev.u_resolve,
      greatest(ev.event_time, ev.ordered_at - interval '12 hours') AS opened_at
    FROM (
      SELECT
        o.lab_order_id,
        NULL::bigint AS specimen_id,
        o.performing_department_id AS department_id,
        'incorrect_test_order'::text AS exception_type,
        CASE
          WHEN b.test_code IN ('XM', 'ABORH') THEN 'critical'
          ELSE 'moderate'
        END AS severity,
        'The ordered test did not match the test the provider requested.' AS description,
        b.n,
        b.u_resolve,
        o.ordered_at,
        COALESCE(o.received_at, o.ordered_at) AS event_time
      FROM clinical_lab.lab_orders AS o
      JOIN gen_order_id AS m ON m.lab_order_id = o.lab_order_id
      JOIN gen_built AS b ON b.n = m.n
      WHERE o.order_is_incorrect
        AND o.performing_department_id IS NOT NULL

      UNION ALL

      SELECT
        o.lab_order_id,
        NULL::bigint,
        o.performing_department_id,
        'patient_record_discrepancy',
        'moderate',
        'Requisition demographics do not match the patient record.',
        b.n,
        b.u_resolve,
        o.ordered_at,
        COALESCE(o.received_at, o.ordered_at)
      FROM clinical_lab.lab_orders AS o
      JOIN clinical_lab.patients AS p ON p.patient_id = o.patient_id
      JOIN gen_order_id AS m ON m.lab_order_id = o.lab_order_id
      JOIN gen_built AS b ON b.n = m.n
      WHERE o.performing_department_id IS NOT NULL
        AND (
          o.requisition_patient_name IS DISTINCT FROM (p.first_name || ' ' || p.last_name)
          OR o.requisition_date_of_birth IS DISTINCT FROM p.date_of_birth
        )

      UNION ALL

      SELECT
        o.lab_order_id,
        NULL::bigint,
        o.performing_department_id,
        'missing_information',
        'low',
        'Required order information was not on the requisition.',
        b.n,
        b.u_resolve,
        o.ordered_at,
        COALESCE(o.received_at, o.ordered_at)
      FROM clinical_lab.lab_orders AS o
      JOIN gen_order_id AS m ON m.lab_order_id = o.lab_order_id
      JOIN gen_built AS b ON b.n = m.n
      WHERE o.missing_information
        AND o.performing_department_id IS NOT NULL

      UNION ALL

      SELECT
        s.lab_order_id,
        s.specimen_id,
        o.performing_department_id,
        'labeling_error',
        'low',
        'The specimen label did not match the requisition.',
        b.n,
        b.u_resolve,
        o.ordered_at,
        COALESCE(s.labeled_at, s.collected_at, o.ordered_at)
      FROM clinical_lab.specimens AS s
      JOIN clinical_lab.lab_orders AS o ON o.lab_order_id = s.lab_order_id
      JOIN gen_order_id AS m ON m.lab_order_id = o.lab_order_id
      JOIN gen_built AS b ON b.n = m.n
      WHERE s.labeling_error
        AND o.performing_department_id IS NOT NULL

      UNION ALL

      SELECT
        s.lab_order_id,
        s.specimen_id,
        o.performing_department_id,
        'missing_information',
        'low',
        'Required specimen information was not recorded.',
        b.n,
        b.u_resolve,
        o.ordered_at,
        COALESCE(s.received_at, s.collected_at, o.ordered_at)
      FROM clinical_lab.specimens AS s
      JOIN clinical_lab.lab_orders AS o ON o.lab_order_id = s.lab_order_id
      JOIN gen_order_id AS m ON m.lab_order_id = o.lab_order_id
      JOIN gen_built AS b ON b.n = m.n
      WHERE s.missing_information
        AND o.performing_department_id IS NOT NULL

      UNION ALL

      SELECT
        s.lab_order_id,
        s.specimen_id,
        o.performing_department_id,
        'incorrect_specimen_type',
        CASE
          WHEN b.test_code IN ('XM', 'ABORH') THEN 'critical'
          ELSE 'high'
        END,
        'The collected specimen type does not match the ordered test.',
        b.n,
        b.u_resolve,
        o.ordered_at,
        COALESCE(s.rejected_at, s.received_at, s.collected_at, o.ordered_at)
      FROM clinical_lab.specimens AS s
      JOIN clinical_lab.lab_orders AS o ON o.lab_order_id = s.lab_order_id
      JOIN clinical_lab.test_catalog AS t ON t.test_id = o.test_id
      JOIN gen_order_id AS m ON m.lab_order_id = o.lab_order_id
      JOIN gen_built AS b ON b.n = m.n
      WHERE s.specimen_type <> t.required_specimen_type
        AND o.performing_department_id IS NOT NULL

      UNION ALL

      SELECT
        s.lab_order_id,
        s.specimen_id,
        o.performing_department_id,
        'specimen_rejection',
        'moderate',
        'The specimen was rejected and could not be tested as received.',
        b.n,
        b.u_resolve,
        o.ordered_at,
        COALESCE(s.rejected_at, o.ordered_at)
      FROM clinical_lab.specimens AS s
      JOIN clinical_lab.lab_orders AS o ON o.lab_order_id = s.lab_order_id
      JOIN gen_order_id AS m ON m.lab_order_id = o.lab_order_id
      JOIN gen_built AS b ON b.n = m.n
      WHERE s.specimen_status = 'rejected'
        AND o.performing_department_id IS NOT NULL
    ) AS ev
  ) AS staged
) AS ready
LEFT JOIN LATERAL (
  SELECT s.staff_id
  FROM gen_staff AS s
  WHERE s.job_role = 'technologist'
    AND s.shift_code = CASE
      WHEN extract(hour FROM ready.opened_at AT TIME ZONE 'America/New_York') BETWEEN 7 AND 14 THEN 'day'
      WHEN extract(hour FROM ready.opened_at AT TIME ZONE 'America/New_York') BETWEEN 15 AND 22 THEN 'evening'
      ELSE 'night'
    END
    AND s.rn = 1 + (ready.n % s.cnt)
  LIMIT 1
) AS tech ON true
LEFT JOIN LATERAL (
  SELECT s.staff_id
  FROM gen_staff AS s
  WHERE s.job_role = 'technologist'
  ORDER BY s.employee_number
  LIMIT 1
) AS any_tech ON true
LEFT JOIN LATERAL (
  SELECT s.staff_id
  FROM gen_staff AS s
  WHERE s.job_role = 'supervisor'
  ORDER BY s.employee_number
  OFFSET (ready.n % 4)
  LIMIT 1
) AS supervisor ON true;

DO $check$
DECLARE
  problems text := '';
  n_orders integer;
  n_specimens integer;
  n_mismatch integer;
BEGIN
  SELECT count(*) INTO n_orders FROM clinical_lab.lab_orders;
  SELECT count(*) INTO n_specimens FROM clinical_lab.specimens;
  IF (SELECT count(*) FROM clinical_lab.departments) <> 6 THEN
    problems := problems || 'departments; ';
  END IF;
  IF (SELECT count(*) FROM clinical_lab.patients) <> 10000 THEN
    problems := problems || 'patients; ';
  END IF;
  IF (SELECT count(*) FROM clinical_lab.test_catalog) <> 25 THEN
    problems := problems || 'tests; ';
  END IF;
  IF (SELECT count(*) FROM clinical_lab.lab_staff) <> 40 THEN
    problems := problems || 'staff; ';
  END IF;
  IF n_orders <> 50000 THEN
    problems := problems || format('orders %s; ', n_orders);
  END IF;
  IF n_specimens < 50000 THEN
    problems := problems || format('specimens %s; ', n_specimens);
  END IF;
  IF (SELECT count(DISTINCT order_status) FROM clinical_lab.lab_orders) <> 6 THEN
    problems := problems || 'order status coverage; ';
  END IF;
  IF (SELECT count(DISTINCT priority) FROM clinical_lab.lab_orders) <> 3 THEN
    problems := problems || 'priority coverage; ';
  END IF;
  IF (SELECT count(DISTINCT record_status) FROM clinical_lab.patients) <> 5 THEN
    problems := problems || 'patient status coverage; ';
  END IF;
  IF (
    SELECT count(DISTINCT exception_type)
    FROM clinical_lab.lab_exceptions
    WHERE exception_type IN (
      'incorrect_test_order',
      'patient_record_discrepancy',
      'incorrect_specimen_type',
      'specimen_rejection',
      'labeling_error',
      'missing_information'
    )
  ) <> 6 THEN
    problems := problems || 'exception type coverage; ';
  END IF;
  IF (SELECT count(DISTINCT severity) FROM clinical_lab.lab_exceptions) <> 4 THEN
    problems := problems || 'severity coverage; ';
  END IF;
  IF (SELECT count(DISTINCT resolution_status) FROM clinical_lab.lab_exceptions) <> 4 THEN
    problems := problems || 'resolution coverage; ';
  END IF;
  IF (
    SELECT count(DISTINCT date_trunc('month', ordered_at AT TIME ZONE 'America/New_York'))
    FROM clinical_lab.lab_orders
  ) <> 12 THEN
    problems := problems || 'month coverage; ';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM clinical_lab.lab_orders
    WHERE ordered_at IS NULL
      OR (ordered_at AT TIME ZONE 'America/New_York') < TIMESTAMP '2025-11-01 00:00:00'
      OR (ordered_at AT TIME ZONE 'America/New_York') >= TIMESTAMP '2026-11-01 00:00:00'
  ) THEN
    problems := problems || 'order window; ';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM clinical_lab.lab_orders AS o
    WHERE NOT EXISTS (
      SELECT 1 FROM clinical_lab.specimens AS s WHERE s.lab_order_id = o.lab_order_id
    )
  ) THEN
    problems := problems || 'order without specimen; ';
  END IF;

  SELECT count(*)
    INTO n_mismatch
  FROM clinical_lab.lab_orders AS o
  JOIN gen_order_id AS m ON m.lab_order_id = o.lab_order_id
  JOIN gen_built AS b ON b.n = m.n
  WHERE o.order_status = 'completed'
    AND o.turnaround_minutes IS DISTINCT FROM b.tat_minutes;
  IF n_mismatch <> 0 THEN
    problems := problems || format('turnaround mismatch %s; ', n_mismatch);
  END IF;

  IF EXISTS (
    SELECT 1
    FROM clinical_lab.lab_orders AS o
    WHERE o.order_status = 'completed'
      AND NOT EXISTS (
        SELECT 1
        FROM clinical_lab.specimens AS s
        WHERE s.lab_order_id = o.lab_order_id
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

  IF EXISTS (
    SELECT 1
    FROM clinical_lab.lab_orders AS o
    WHERE o.order_is_incorrect
      AND NOT EXISTS (
        SELECT 1
        FROM clinical_lab.lab_exceptions AS e
        WHERE e.lab_order_id = o.lab_order_id
          AND e.exception_type = 'incorrect_test_order'
      )
  ) OR EXISTS (
    SELECT 1
    FROM clinical_lab.lab_exceptions AS e
    JOIN clinical_lab.lab_orders AS o ON o.lab_order_id = e.lab_order_id
    WHERE e.exception_type = 'incorrect_test_order'
      AND NOT o.order_is_incorrect
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
    JOIN clinical_lab.specimens AS s ON s.specimen_id = e.specimen_id
    WHERE e.exception_type = 'labeling_error'
      AND NOT s.labeling_error
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
    JOIN clinical_lab.specimens AS s ON s.specimen_id = e.specimen_id
    WHERE e.exception_type = 'specimen_rejection'
      AND s.specimen_status <> 'rejected'
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
    JOIN clinical_lab.test_catalog AS t ON t.test_id = o.test_id
    WHERE e.exception_type = 'incorrect_specimen_type'
      AND s.specimen_type = t.required_specimen_type
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
    JOIN clinical_lab.specimens AS s ON s.specimen_id = e.specimen_id
    WHERE e.exception_type = 'missing_information'
      AND NOT s.missing_information
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
    RAISE EXCEPTION 'synthetic load failed: %', problems;
  END IF;
END
$check$;

COMMIT;

SELECT 'departments' AS table_name, count(*) AS row_count FROM clinical_lab.departments
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
ORDER BY table_name;

SELECT 'random_seed' AS parameter, '0.20241124' AS value
UNION ALL
SELECT 'window_start', '2025-11-01'
UNION ALL
SELECT 'window_end', '2026-10-31';
