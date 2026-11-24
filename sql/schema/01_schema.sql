-- Clinical lab SQL analytics, phase 1 schema.
--
-- PostgreSQL 14 or newer. Run the whole file once, in one session, against an
-- empty database. The script creates schema clinical_lab and does not drop,
-- truncate, or update existing tables. If any statement fails, the transaction
-- rolls back.
--
-- Grain
--   patients       one fictional person
--   departments    one laboratory section
--   test_catalog   one orderable test
--   lab_staff      one employee and that employee's current shift
--   lab_orders     one ordered test (50,000-row target)
--   specimens      one physical sample belonging to one order
--   lab_exceptions one quality event opened against an order, and optionally
--                  against one of that order's specimens
--
-- Relationships
--   departments 1---* test_catalog, lab_staff, lab_orders, lab_exceptions
--   patients 1---* lab_orders
--   patients 1---* patients            merged_into_patient_id (surviving row)
--   test_catalog 1---* lab_orders      ordered test and, separately, corrected test
--   lab_orders (test_id, performing_department_id) -> test_catalog (test_id, department_id)
--   lab_staff 1---* lab_orders, specimens, lab_exceptions
--   lab_orders 1---* specimens, lab_exceptions
--   specimens (specimen_id, lab_order_id) -> referenced by lab_exceptions so a
--     specimen-level exception cannot point at a different order
--
-- Assumptions
--   * Every person, accession, and result in this design is fictional.
--   * One laboratory site. Event timestamps are timestamptz. Shift clocks are
--     local wall times with no time zone, interpreted as America/New_York.
--   * A laboratory order is one ordered test, not a multi-test panel. A
--     specimen belongs to exactly one order. Two tests do not share a tube row.
--   * Planned volume is 10,000 patients and 50,000 orders across 12 months.
--     Keys are bigint. Tables are not partitioned.
--   * Accession numbers are assigned when the order leaves the incomplete state,
--     except a cancellation that happens before receipt, which may have none.
--   * The performing department is the test catalog's department at load time.
--     The composite foreign key rejects a department that does not match the
--     catalog, so a test cannot be moved to another department while orders
--     point at it.
--   * Quality flags on orders and specimens are independently stored from
--     lab_exceptions. Nothing in this script keeps the two in sync. Rates can
--     be counted from the flags. Resolution time comes from lab_exceptions.
--   * Incorrect specimen type is not a stored boolean. Compare
--     specimens.specimen_type with test_catalog.required_specimen_type through
--     the order. Confirmed problems are lab_exceptions rows.
--   * CHECK constraints fail only on FALSE, not on NULL. Comparisons below are
--     written so an invalid row is FALSE rather than an unknown result.
--   * Surrogate keys are GENERATED ALWAYS AS IDENTITY. Inserts omit them.
--   * All foreign keys are ON DELETE RESTRICT. Deleting a parent with children
--     is an error.
--   * Collection may occur up to 30 days before the order (stored-sample add-on
--     testing) and up to 30 days after the order. An exception may be opened up
--     to 1 day before ordered_at. Event timestamps may not be more than five
--     minutes in the future. Those rules are triggers because CHECK cannot see
--     the clock or another table.

BEGIN;

CREATE SCHEMA IF NOT EXISTS clinical_lab;

COMMENT ON SCHEMA clinical_lab IS
  'Synthetic clinical laboratory operations. No protected health information.';

-- Shared value sets ----------------------------------------------------------

CREATE DOMAIN clinical_lab.specimen_type AS text
  CONSTRAINT specimen_type_check CHECK (
    VALUE IN (
      'whole_blood',
      'serum',
      'plasma',
      'urine',
      'cerebrospinal_fluid',
      'swab',
      'tissue',
      'stool',
      'sputum',
      'other'
    )
  );

COMMENT ON DOMAIN clinical_lab.specimen_type IS
  'Specimen material collected or required by a test. The same list is used on the catalog and on specimens so the two can be compared.';

CREATE DOMAIN clinical_lab.shift_code AS text
  CONSTRAINT shift_code_check CHECK (
    VALUE IN ('day', 'evening', 'night', 'rotating')
  );

COMMENT ON DOMAIN clinical_lab.shift_code IS
  'Laboratory shift. rotating is an assignment that is not fixed to one clock shift. Event rows store the shift that was on duty, not only the employee default.';

-- Reference tables -----------------------------------------------------------

CREATE TABLE clinical_lab.departments (
  department_id bigint GENERATED ALWAYS AS IDENTITY,
  department_code text NOT NULL,
  department_name text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT departments_pkey PRIMARY KEY (department_id),
  CONSTRAINT departments_department_code_key UNIQUE (department_code),
  CONSTRAINT departments_department_name_key UNIQUE (department_name),
  CONSTRAINT departments_department_code_ck CHECK (
    department_code ~ '^[A-Z][A-Z0-9]{1,9}$'
  ),
  CONSTRAINT departments_department_name_ck CHECK (
    department_name = btrim(department_name)
    AND char_length(department_name) BETWEEN 2 AND 80
  )
);

CREATE TABLE clinical_lab.patients (
  patient_id bigint GENERATED ALWAYS AS IDENTITY,
  mrn text NOT NULL,
  first_name text NOT NULL,
  last_name text NOT NULL,
  date_of_birth date NOT NULL,
  sex text NOT NULL,
  phone_number text,
  email text,
  address_line text,
  city text,
  state_code text,
  postal_code text,
  record_status text NOT NULL DEFAULT 'active',
  identity_verified boolean NOT NULL DEFAULT false,
  merged_into_patient_id bigint,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT patients_pkey PRIMARY KEY (patient_id),
  CONSTRAINT patients_mrn_key UNIQUE (mrn),
  CONSTRAINT patients_merged_into_fk
    FOREIGN KEY (merged_into_patient_id)
    REFERENCES clinical_lab.patients (patient_id)
    ON DELETE RESTRICT,
  CONSTRAINT patients_mrn_ck CHECK (
    char_length(mrn) BETWEEN 4 AND 32
    AND mrn ~ '^[A-Za-z0-9-]+$'
  ),
  CONSTRAINT patients_first_name_ck CHECK (
    first_name = btrim(first_name)
    AND char_length(first_name) BETWEEN 1 AND 80
  ),
  CONSTRAINT patients_last_name_ck CHECK (
    last_name = btrim(last_name)
    AND char_length(last_name) BETWEEN 1 AND 80
  ),
  CONSTRAINT patients_date_of_birth_ck CHECK (
    date_of_birth >= DATE '1900-01-01'
    AND date_of_birth <= DATE '2100-01-01'
  ),
  CONSTRAINT patients_sex_ck CHECK (
    sex IN ('female', 'male', 'intersex', 'unknown')
  ),
  CONSTRAINT patients_phone_number_ck CHECK (
    phone_number IS NULL
    OR phone_number ~ '^[0-9+(). -]{7,20}$'
  ),
  CONSTRAINT patients_email_ck CHECK (
    email IS NULL
    OR (
      email = btrim(email)
      AND char_length(email) <= 254
      AND email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
    )
  ),
  CONSTRAINT patients_address_line_ck CHECK (
    address_line IS NULL
    OR (
      address_line = btrim(address_line)
      AND char_length(address_line) BETWEEN 1 AND 120
    )
  ),
  CONSTRAINT patients_city_ck CHECK (
    city IS NULL
    OR (
      city = btrim(city)
      AND char_length(city) BETWEEN 1 AND 80
    )
  ),
  CONSTRAINT patients_state_code_ck CHECK (
    state_code IS NULL OR state_code ~ '^[A-Z]{2}$'
  ),
  CONSTRAINT patients_postal_code_ck CHECK (
    postal_code IS NULL OR postal_code ~ '^[0-9]{5}(-[0-9]{4})?$'
  ),
  CONSTRAINT patients_record_status_ck CHECK (
    record_status IN (
      'active',
      'inactive',
      'incomplete',
      'merged',
      'duplicate_suspected'
    )
  ),
  CONSTRAINT patients_merge_ck CHECK (
    (
      record_status = 'merged'
      AND merged_into_patient_id IS NOT NULL
      AND merged_into_patient_id <> patient_id
    )
    OR (
      record_status <> 'merged'
      AND merged_into_patient_id IS NULL
    )
  ),
  CONSTRAINT patients_identity_status_ck CHECK (
    (
      record_status IN ('merged', 'duplicate_suspected', 'incomplete')
      AND identity_verified = false
    )
    OR record_status IN ('active', 'inactive')
  )
);

CREATE TABLE clinical_lab.test_catalog (
  test_id bigint GENERATED ALWAYS AS IDENTITY,
  test_code text NOT NULL,
  test_name text NOT NULL,
  department_id bigint NOT NULL,
  required_specimen_type clinical_lab.specimen_type NOT NULL,
  routine_turnaround_minutes integer NOT NULL,
  urgent_turnaround_minutes integer NOT NULL,
  stat_turnaround_minutes integer NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT test_catalog_pkey PRIMARY KEY (test_id),
  CONSTRAINT test_catalog_test_code_key UNIQUE (test_code),
  CONSTRAINT test_catalog_test_department_key UNIQUE (test_id, department_id),
  CONSTRAINT test_catalog_department_fk
    FOREIGN KEY (department_id)
    REFERENCES clinical_lab.departments (department_id)
    ON DELETE RESTRICT,
  CONSTRAINT test_catalog_test_code_ck CHECK (
    test_code ~ '^[A-Z0-9][A-Z0-9.-]{1,31}$'
  ),
  CONSTRAINT test_catalog_test_name_ck CHECK (
    test_name = btrim(test_name)
    AND char_length(test_name) BETWEEN 2 AND 120
  ),
  CONSTRAINT test_catalog_turnaround_ck CHECK (
    stat_turnaround_minutes >= 1
    AND stat_turnaround_minutes <= urgent_turnaround_minutes
    AND urgent_turnaround_minutes <= routine_turnaround_minutes
    AND routine_turnaround_minutes <= 20160
  )
);

CREATE TABLE clinical_lab.lab_staff (
  staff_id bigint GENERATED ALWAYS AS IDENTITY,
  employee_number text NOT NULL,
  first_name text NOT NULL,
  last_name text NOT NULL,
  job_role text NOT NULL,
  department_id bigint NOT NULL,
  shift_code clinical_lab.shift_code NOT NULL,
  shift_start_time time NOT NULL,
  shift_end_time time NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  hired_on date NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT lab_staff_pkey PRIMARY KEY (staff_id),
  CONSTRAINT lab_staff_employee_number_key UNIQUE (employee_number),
  CONSTRAINT lab_staff_department_fk
    FOREIGN KEY (department_id)
    REFERENCES clinical_lab.departments (department_id)
    ON DELETE RESTRICT,
  CONSTRAINT lab_staff_employee_number_ck CHECK (
    employee_number ~ '^[A-Z0-9]{4,16}$'
  ),
  CONSTRAINT lab_staff_first_name_ck CHECK (
    first_name = btrim(first_name)
    AND char_length(first_name) BETWEEN 1 AND 80
  ),
  CONSTRAINT lab_staff_last_name_ck CHECK (
    last_name = btrim(last_name)
    AND char_length(last_name) BETWEEN 1 AND 80
  ),
  CONSTRAINT lab_staff_job_role_ck CHECK (
    job_role IN (
      'phlebotomist',
      'accessioner',
      'technologist',
      'supervisor',
      'pathologist'
    )
  ),
  CONSTRAINT lab_staff_shift_times_ck CHECK (
    shift_start_time <> shift_end_time
  ),
  CONSTRAINT lab_staff_hired_on_ck CHECK (
    hired_on >= DATE '1970-01-01'
    AND hired_on <= DATE '2100-01-01'
  )
);

-- Operational tables ---------------------------------------------------------

CREATE TABLE clinical_lab.lab_orders (
  lab_order_id bigint GENERATED ALWAYS AS IDENTITY,
  accession_number text,
  patient_id bigint,
  test_id bigint,
  corrected_test_id bigint,
  performing_department_id bigint,
  received_by_staff_id bigint,
  received_during_shift clinical_lab.shift_code,
  priority text NOT NULL DEFAULT 'routine',
  order_status text NOT NULL,
  order_is_incorrect boolean NOT NULL DEFAULT false,
  incorrect_order_reason text,
  missing_information boolean NOT NULL DEFAULT false,
  missing_information_detail text,
  requisition_patient_name text,
  requisition_date_of_birth date,
  ordered_at timestamptz,
  received_at timestamptz,
  testing_started_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  rejected_at timestamptz,
  cancellation_reason text,
  rejection_reason text,
  turnaround_minutes integer GENERATED ALWAYS AS (
    CASE
      WHEN completed_at IS NOT NULL AND received_at IS NOT NULL
        THEN (round(extract(epoch FROM (completed_at - received_at)) / 60.0))::integer
      ELSE NULL::integer
    END
  ) STORED,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT lab_orders_pkey PRIMARY KEY (lab_order_id),
  CONSTRAINT lab_orders_accession_number_key UNIQUE (accession_number),
  CONSTRAINT lab_orders_patient_fk
    FOREIGN KEY (patient_id)
    REFERENCES clinical_lab.patients (patient_id)
    ON DELETE RESTRICT,
  CONSTRAINT lab_orders_test_fk
    FOREIGN KEY (test_id)
    REFERENCES clinical_lab.test_catalog (test_id)
    ON DELETE RESTRICT,
  CONSTRAINT lab_orders_corrected_test_fk
    FOREIGN KEY (corrected_test_id)
    REFERENCES clinical_lab.test_catalog (test_id)
    ON DELETE RESTRICT,
  CONSTRAINT lab_orders_department_fk
    FOREIGN KEY (performing_department_id)
    REFERENCES clinical_lab.departments (department_id)
    ON DELETE RESTRICT,
  CONSTRAINT lab_orders_test_department_fk
    FOREIGN KEY (test_id, performing_department_id)
    REFERENCES clinical_lab.test_catalog (test_id, department_id)
    ON DELETE RESTRICT,
  CONSTRAINT lab_orders_received_by_fk
    FOREIGN KEY (received_by_staff_id)
    REFERENCES clinical_lab.lab_staff (staff_id)
    ON DELETE RESTRICT,
  CONSTRAINT lab_orders_priority_ck CHECK (
    priority IN ('routine', 'urgent', 'stat')
  ),
  CONSTRAINT lab_orders_order_status_ck CHECK (
    order_status IN (
      'incomplete',
      'received',
      'in_progress',
      'completed',
      'cancelled',
      'rejected'
    )
  ),
  CONSTRAINT lab_orders_patient_required_ck CHECK (
    patient_id IS NOT NULL
    OR order_status IN ('incomplete', 'rejected')
  ),
  CONSTRAINT lab_orders_test_required_ck CHECK (
    test_id IS NOT NULL
    OR order_status = 'incomplete'
  ),
  CONSTRAINT lab_orders_department_required_ck CHECK (
    test_id IS NULL
    OR performing_department_id IS NOT NULL
  ),
  CONSTRAINT lab_orders_accession_ck CHECK (
    (
      order_status = 'incomplete'
      AND accession_number IS NULL
    )
    OR (
      order_status = 'cancelled'
      AND received_at IS NULL
      AND (
        accession_number IS NULL
        OR (
          char_length(accession_number) BETWEEN 6 AND 32
          AND accession_number = btrim(accession_number)
          AND accession_number ~ '^[A-Z0-9-]+$'
        )
      )
    )
    OR (
      order_status IN ('received', 'in_progress', 'completed', 'rejected')
      AND accession_number IS NOT NULL
      AND char_length(accession_number) BETWEEN 6 AND 32
      AND accession_number = btrim(accession_number)
      AND accession_number ~ '^[A-Z0-9-]+$'
    )
    OR (
      order_status = 'cancelled'
      AND received_at IS NOT NULL
      AND accession_number IS NOT NULL
      AND char_length(accession_number) BETWEEN 6 AND 32
      AND accession_number = btrim(accession_number)
      AND accession_number ~ '^[A-Z0-9-]+$'
    )
  ),
  CONSTRAINT lab_orders_incorrect_test_ck CHECK (
    (
      order_is_incorrect = false
      AND corrected_test_id IS NULL
      AND incorrect_order_reason IS NULL
    )
    OR (
      order_is_incorrect = true
      AND test_id IS NOT NULL
      AND corrected_test_id IS NOT NULL
      AND corrected_test_id <> test_id
      AND incorrect_order_reason IS NOT NULL
      AND incorrect_order_reason = btrim(incorrect_order_reason)
      AND char_length(incorrect_order_reason) BETWEEN 1 AND 500
    )
  ),
  CONSTRAINT lab_orders_missing_information_ck CHECK (
    (
      missing_information = false
      AND missing_information_detail IS NULL
    )
    OR (
      missing_information = true
      AND missing_information_detail IS NOT NULL
      AND missing_information_detail = btrim(missing_information_detail)
      AND char_length(missing_information_detail) BETWEEN 1 AND 500
    )
  ),
  CONSTRAINT lab_orders_completed_info_ck CHECK (
    order_status <> 'completed'
    OR missing_information = false
  ),
  CONSTRAINT lab_orders_receipt_staff_ck CHECK (
    (
      received_at IS NULL
      AND received_by_staff_id IS NULL
      AND received_during_shift IS NULL
    )
    OR (
      received_at IS NOT NULL
      AND received_during_shift IS NOT NULL
    )
  ),
  CONSTRAINT lab_orders_cancellation_reason_ck CHECK (
    (
      order_status = 'cancelled'
      AND cancellation_reason IS NOT NULL
      AND cancellation_reason = btrim(cancellation_reason)
      AND char_length(cancellation_reason) BETWEEN 1 AND 500
    )
    OR (
      order_status <> 'cancelled'
      AND cancellation_reason IS NULL
    )
  ),
  CONSTRAINT lab_orders_rejection_reason_ck CHECK (
    (
      order_status = 'rejected'
      AND rejection_reason IS NOT NULL
      AND rejection_reason = btrim(rejection_reason)
      AND char_length(rejection_reason) BETWEEN 1 AND 500
    )
    OR (
      order_status <> 'rejected'
      AND rejection_reason IS NULL
    )
  ),
  CONSTRAINT lab_orders_requisition_name_ck CHECK (
    requisition_patient_name IS NULL
    OR (
      requisition_patient_name = btrim(requisition_patient_name)
      AND char_length(requisition_patient_name) BETWEEN 1 AND 160
    )
  ),
  CONSTRAINT lab_orders_requisition_dob_ck CHECK (
    requisition_date_of_birth IS NULL
    OR (
      requisition_date_of_birth >= DATE '1900-01-01'
      AND requisition_date_of_birth <= DATE '2100-01-01'
    )
  ),
  CONSTRAINT lab_orders_timestamp_bounds_ck CHECK (
    (ordered_at IS NULL OR (
      ordered_at >= TIMESTAMPTZ '2000-01-01 00:00:00+00'
      AND ordered_at < TIMESTAMPTZ '2100-01-01 00:00:00+00'
    ))
    AND (received_at IS NULL OR (
      received_at >= TIMESTAMPTZ '2000-01-01 00:00:00+00'
      AND received_at < TIMESTAMPTZ '2100-01-01 00:00:00+00'
    ))
    AND (testing_started_at IS NULL OR (
      testing_started_at >= TIMESTAMPTZ '2000-01-01 00:00:00+00'
      AND testing_started_at < TIMESTAMPTZ '2100-01-01 00:00:00+00'
    ))
    AND (completed_at IS NULL OR (
      completed_at >= TIMESTAMPTZ '2000-01-01 00:00:00+00'
      AND completed_at < TIMESTAMPTZ '2100-01-01 00:00:00+00'
    ))
    AND (cancelled_at IS NULL OR (
      cancelled_at >= TIMESTAMPTZ '2000-01-01 00:00:00+00'
      AND cancelled_at < TIMESTAMPTZ '2100-01-01 00:00:00+00'
    ))
    AND (rejected_at IS NULL OR (
      rejected_at >= TIMESTAMPTZ '2000-01-01 00:00:00+00'
      AND rejected_at < TIMESTAMPTZ '2100-01-01 00:00:00+00'
    ))
  ),
  CONSTRAINT lab_orders_status_timestamps_ck CHECK (
    CASE order_status
      WHEN 'incomplete' THEN
        received_at IS NULL
        AND testing_started_at IS NULL
        AND completed_at IS NULL
        AND cancelled_at IS NULL
        AND rejected_at IS NULL
      WHEN 'received' THEN
        ordered_at IS NOT NULL
        AND received_at IS NOT NULL
        AND testing_started_at IS NULL
        AND completed_at IS NULL
        AND cancelled_at IS NULL
        AND rejected_at IS NULL
        AND received_at >= ordered_at
      WHEN 'in_progress' THEN
        ordered_at IS NOT NULL
        AND received_at IS NOT NULL
        AND testing_started_at IS NOT NULL
        AND completed_at IS NULL
        AND cancelled_at IS NULL
        AND rejected_at IS NULL
        AND received_at >= ordered_at
        AND testing_started_at >= received_at
      WHEN 'completed' THEN
        ordered_at IS NOT NULL
        AND received_at IS NOT NULL
        AND testing_started_at IS NOT NULL
        AND completed_at IS NOT NULL
        AND cancelled_at IS NULL
        AND rejected_at IS NULL
        AND received_at >= ordered_at
        AND testing_started_at >= received_at
        AND completed_at >= testing_started_at
      WHEN 'cancelled' THEN
        ordered_at IS NOT NULL
        AND cancelled_at IS NOT NULL
        AND cancelled_at >= ordered_at
        AND completed_at IS NULL
        AND rejected_at IS NULL
        AND (
          received_at IS NULL
          OR (
            received_at >= ordered_at
            AND cancelled_at >= received_at
          )
        )
        AND (
          received_at IS NOT NULL
          OR testing_started_at IS NULL
        )
        AND (
          testing_started_at IS NULL
          OR (
            received_at IS NOT NULL
            AND testing_started_at >= received_at
            AND cancelled_at >= testing_started_at
          )
        )
      WHEN 'rejected' THEN
        ordered_at IS NOT NULL
        AND received_at IS NOT NULL
        AND rejected_at IS NOT NULL
        AND completed_at IS NULL
        AND cancelled_at IS NULL
        AND received_at >= ordered_at
        AND rejected_at >= received_at
        AND (
          testing_started_at IS NULL
          OR (
            testing_started_at >= received_at
            AND rejected_at >= testing_started_at
          )
        )
      ELSE false
    END
  ),
  CONSTRAINT lab_orders_turnaround_nonnegative_ck CHECK (
    turnaround_minutes IS NULL
    OR turnaround_minutes >= 0
  )
);

CREATE TABLE clinical_lab.specimens (
  specimen_id bigint GENERATED ALWAYS AS IDENTITY,
  lab_order_id bigint NOT NULL,
  collected_by_staff_id bigint,
  collected_during_shift clinical_lab.shift_code,
  specimen_barcode text NOT NULL,
  specimen_type clinical_lab.specimen_type NOT NULL,
  specimen_status text NOT NULL,
  labeling_error boolean NOT NULL DEFAULT false,
  labeling_error_detail text,
  missing_information boolean NOT NULL DEFAULT false,
  missing_information_detail text,
  rejection_reason text,
  collected_at timestamptz,
  labeled_at timestamptz,
  received_at timestamptz,
  accepted_at timestamptz,
  rejected_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT specimens_pkey PRIMARY KEY (specimen_id),
  CONSTRAINT specimens_barcode_key UNIQUE (specimen_barcode),
  CONSTRAINT specimens_order_ref_key UNIQUE (specimen_id, lab_order_id),
  CONSTRAINT specimens_order_fk
    FOREIGN KEY (lab_order_id)
    REFERENCES clinical_lab.lab_orders (lab_order_id)
    ON DELETE RESTRICT,
  CONSTRAINT specimens_collected_by_fk
    FOREIGN KEY (collected_by_staff_id)
    REFERENCES clinical_lab.lab_staff (staff_id)
    ON DELETE RESTRICT,
  CONSTRAINT specimens_barcode_ck CHECK (
    char_length(specimen_barcode) BETWEEN 6 AND 40
    AND specimen_barcode = btrim(specimen_barcode)
    AND specimen_barcode ~ '^[A-Z0-9-]+$'
  ),
  CONSTRAINT specimens_status_ck CHECK (
    specimen_status IN (
      'pending_collection',
      'collected',
      'received',
      'accepted',
      'rejected',
      'cancelled'
    )
  ),
  CONSTRAINT specimens_labeling_error_ck CHECK (
    (
      labeling_error = false
      AND labeling_error_detail IS NULL
    )
    OR (
      labeling_error = true
      AND labeling_error_detail IS NOT NULL
      AND labeling_error_detail = btrim(labeling_error_detail)
      AND char_length(labeling_error_detail) BETWEEN 1 AND 500
    )
  ),
  CONSTRAINT specimens_missing_information_ck CHECK (
    (
      missing_information = false
      AND missing_information_detail IS NULL
    )
    OR (
      missing_information = true
      AND missing_information_detail IS NOT NULL
      AND missing_information_detail = btrim(missing_information_detail)
      AND char_length(missing_information_detail) BETWEEN 1 AND 500
    )
  ),
  CONSTRAINT specimens_collection_staff_ck CHECK (
    (
      collected_at IS NULL
      AND collected_by_staff_id IS NULL
      AND collected_during_shift IS NULL
    )
    OR (
      collected_at IS NOT NULL
      AND (
        collected_by_staff_id IS NULL
        OR collected_during_shift IS NOT NULL
      )
    )
  ),
  CONSTRAINT specimens_rejection_reason_ck CHECK (
    (
      specimen_status = 'rejected'
      AND rejection_reason IS NOT NULL
      AND rejection_reason = btrim(rejection_reason)
      AND char_length(rejection_reason) BETWEEN 1 AND 500
    )
    OR (
      specimen_status <> 'rejected'
      AND rejection_reason IS NULL
    )
  ),
  CONSTRAINT specimens_labeled_at_ck CHECK (
    labeled_at IS NULL
    OR (
      labeled_at >= TIMESTAMPTZ '2000-01-01 00:00:00+00'
      AND labeled_at < TIMESTAMPTZ '2100-01-01 00:00:00+00'
      AND (
        collected_at IS NULL
        OR (
          labeled_at >= collected_at - INTERVAL '24 hours'
          AND labeled_at <= collected_at + INTERVAL '2 hours'
        )
      )
      AND (
        received_at IS NULL
        OR labeled_at <= received_at + INTERVAL '2 hours'
      )
    )
  ),
  CONSTRAINT specimens_timestamp_bounds_ck CHECK (
    (collected_at IS NULL OR (
      collected_at >= TIMESTAMPTZ '2000-01-01 00:00:00+00'
      AND collected_at < TIMESTAMPTZ '2100-01-01 00:00:00+00'
    ))
    AND (received_at IS NULL OR (
      received_at >= TIMESTAMPTZ '2000-01-01 00:00:00+00'
      AND received_at < TIMESTAMPTZ '2100-01-01 00:00:00+00'
    ))
    AND (accepted_at IS NULL OR (
      accepted_at >= TIMESTAMPTZ '2000-01-01 00:00:00+00'
      AND accepted_at < TIMESTAMPTZ '2100-01-01 00:00:00+00'
    ))
    AND (rejected_at IS NULL OR (
      rejected_at >= TIMESTAMPTZ '2000-01-01 00:00:00+00'
      AND rejected_at < TIMESTAMPTZ '2100-01-01 00:00:00+00'
    ))
    AND (cancelled_at IS NULL OR (
      cancelled_at >= TIMESTAMPTZ '2000-01-01 00:00:00+00'
      AND cancelled_at < TIMESTAMPTZ '2100-01-01 00:00:00+00'
    ))
  ),
  CONSTRAINT specimens_status_timestamps_ck CHECK (
    CASE specimen_status
      WHEN 'pending_collection' THEN
        collected_at IS NULL
        AND received_at IS NULL
        AND accepted_at IS NULL
        AND rejected_at IS NULL
        AND cancelled_at IS NULL
      WHEN 'collected' THEN
        collected_at IS NOT NULL
        AND received_at IS NULL
        AND accepted_at IS NULL
        AND rejected_at IS NULL
        AND cancelled_at IS NULL
      WHEN 'received' THEN
        collected_at IS NOT NULL
        AND received_at IS NOT NULL
        AND accepted_at IS NULL
        AND rejected_at IS NULL
        AND cancelled_at IS NULL
        AND received_at >= collected_at
      WHEN 'accepted' THEN
        collected_at IS NOT NULL
        AND received_at IS NOT NULL
        AND accepted_at IS NOT NULL
        AND rejected_at IS NULL
        AND cancelled_at IS NULL
        AND received_at >= collected_at
        AND accepted_at >= received_at
      WHEN 'rejected' THEN
        received_at IS NOT NULL
        AND rejected_at IS NOT NULL
        AND accepted_at IS NULL
        AND cancelled_at IS NULL
        AND rejected_at >= received_at
        AND (
          collected_at IS NULL
          OR received_at >= collected_at
        )
      WHEN 'cancelled' THEN
        cancelled_at IS NOT NULL
        AND rejected_at IS NULL
        AND accepted_at IS NULL
        AND (
          collected_at IS NULL
          OR cancelled_at >= collected_at
        )
        AND (
          received_at IS NULL
          OR (
            collected_at IS NOT NULL
            AND received_at >= collected_at
            AND cancelled_at >= received_at
          )
        )
      ELSE false
    END
  )
);

CREATE TABLE clinical_lab.lab_exceptions (
  exception_id bigint GENERATED ALWAYS AS IDENTITY,
  lab_order_id bigint NOT NULL,
  specimen_id bigint,
  department_id bigint NOT NULL,
  opened_by_staff_id bigint NOT NULL,
  resolved_by_staff_id bigint,
  exception_type text NOT NULL,
  severity text NOT NULL,
  resolution_status text NOT NULL DEFAULT 'open',
  opened_during_shift clinical_lab.shift_code NOT NULL,
  description text NOT NULL,
  resolution_note text,
  opened_at timestamptz NOT NULL,
  resolved_at timestamptz,
  resolution_minutes integer GENERATED ALWAYS AS (
    CASE
      WHEN resolved_at IS NOT NULL
        THEN (round(extract(epoch FROM (resolved_at - opened_at)) / 60.0))::integer
      ELSE NULL::integer
    END
  ) STORED,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT lab_exceptions_pkey PRIMARY KEY (exception_id),
  CONSTRAINT lab_exceptions_order_fk
    FOREIGN KEY (lab_order_id)
    REFERENCES clinical_lab.lab_orders (lab_order_id)
    ON DELETE RESTRICT,
  CONSTRAINT lab_exceptions_specimen_fk
    FOREIGN KEY (specimen_id)
    REFERENCES clinical_lab.specimens (specimen_id)
    ON DELETE RESTRICT,
  CONSTRAINT lab_exceptions_specimen_order_fk
    FOREIGN KEY (specimen_id, lab_order_id)
    REFERENCES clinical_lab.specimens (specimen_id, lab_order_id)
    ON DELETE RESTRICT,
  CONSTRAINT lab_exceptions_department_fk
    FOREIGN KEY (department_id)
    REFERENCES clinical_lab.departments (department_id)
    ON DELETE RESTRICT,
  CONSTRAINT lab_exceptions_opened_by_fk
    FOREIGN KEY (opened_by_staff_id)
    REFERENCES clinical_lab.lab_staff (staff_id)
    ON DELETE RESTRICT,
  CONSTRAINT lab_exceptions_resolved_by_fk
    FOREIGN KEY (resolved_by_staff_id)
    REFERENCES clinical_lab.lab_staff (staff_id)
    ON DELETE RESTRICT,
  CONSTRAINT lab_exceptions_type_ck CHECK (
    exception_type IN (
      'incorrect_test_order',
      'patient_record_discrepancy',
      'incorrect_specimen_type',
      'specimen_rejection',
      'labeling_error',
      'missing_information',
      'other'
    )
  ),
  CONSTRAINT lab_exceptions_severity_ck CHECK (
    severity IN ('low', 'moderate', 'high', 'critical')
  ),
  CONSTRAINT lab_exceptions_resolution_status_ck CHECK (
    resolution_status IN ('open', 'in_progress', 'resolved', 'cancelled')
  ),
  CONSTRAINT lab_exceptions_specimen_required_ck CHECK (
    (
      exception_type IN (
        'incorrect_specimen_type',
        'specimen_rejection',
        'labeling_error'
      )
      AND specimen_id IS NOT NULL
    )
    OR exception_type IN (
      'incorrect_test_order',
      'patient_record_discrepancy',
      'missing_information',
      'other'
    )
  ),
  CONSTRAINT lab_exceptions_description_ck CHECK (
    description = btrim(description)
    AND char_length(description) BETWEEN 1 AND 4000
  ),
  CONSTRAINT lab_exceptions_resolution_ck CHECK (
    CASE resolution_status
      WHEN 'open' THEN
        resolved_at IS NULL
        AND resolved_by_staff_id IS NULL
        AND resolution_note IS NULL
      WHEN 'in_progress' THEN
        resolved_at IS NULL
        AND resolved_by_staff_id IS NULL
        AND resolution_note IS NULL
      WHEN 'resolved' THEN
        resolved_at IS NOT NULL
        AND resolved_by_staff_id IS NOT NULL
        AND resolution_note IS NOT NULL
        AND resolved_at >= opened_at
        AND resolution_note = btrim(resolution_note)
        AND char_length(resolution_note) BETWEEN 1 AND 4000
      WHEN 'cancelled' THEN
        resolved_at IS NULL
        AND resolved_by_staff_id IS NULL
        AND resolution_note IS NOT NULL
        AND resolution_note = btrim(resolution_note)
        AND char_length(resolution_note) BETWEEN 1 AND 4000
      ELSE false
    END
  ),
  CONSTRAINT lab_exceptions_timestamp_bounds_ck CHECK (
    opened_at >= TIMESTAMPTZ '2000-01-01 00:00:00+00'
    AND opened_at < TIMESTAMPTZ '2100-01-01 00:00:00+00'
    AND (
      resolved_at IS NULL
      OR (
        resolved_at >= TIMESTAMPTZ '2000-01-01 00:00:00+00'
        AND resolved_at < TIMESTAMPTZ '2100-01-01 00:00:00+00'
      )
    )
  ),
  CONSTRAINT lab_exceptions_resolution_nonnegative_ck CHECK (
    resolution_minutes IS NULL
    OR resolution_minutes >= 0
  )
);

-- Indexes for the planned 50,000 orders --------------------------------------
-- Foreign-key columns are indexed so parent deletes and joins are not
-- sequential scans. Partial indexes cover the rarer quality flags.

CREATE INDEX patients_name_dob_idx
  ON clinical_lab.patients (last_name, first_name, date_of_birth);

CREATE INDEX patients_record_status_idx
  ON clinical_lab.patients (record_status);

CREATE INDEX patients_duplicate_idx
  ON clinical_lab.patients (date_of_birth, last_name)
  WHERE record_status = 'duplicate_suspected';

CREATE INDEX patients_merged_into_idx
  ON clinical_lab.patients (merged_into_patient_id)
  WHERE merged_into_patient_id IS NOT NULL;

CREATE INDEX test_catalog_department_idx
  ON clinical_lab.test_catalog (department_id);

CREATE INDEX test_catalog_specimen_type_idx
  ON clinical_lab.test_catalog (required_specimen_type);

CREATE INDEX lab_staff_department_idx
  ON clinical_lab.lab_staff (department_id);

CREATE INDEX lab_staff_shift_department_idx
  ON clinical_lab.lab_staff (shift_code, department_id);

CREATE INDEX lab_orders_patient_idx
  ON clinical_lab.lab_orders (patient_id);

CREATE INDEX lab_orders_test_idx
  ON clinical_lab.lab_orders (test_id);

CREATE INDEX lab_orders_corrected_test_idx
  ON clinical_lab.lab_orders (corrected_test_id)
  WHERE corrected_test_id IS NOT NULL;

CREATE INDEX lab_orders_department_priority_idx
  ON clinical_lab.lab_orders (performing_department_id, priority, ordered_at);

CREATE INDEX lab_orders_received_by_idx
  ON clinical_lab.lab_orders (received_by_staff_id);

CREATE INDEX lab_orders_status_ordered_idx
  ON clinical_lab.lab_orders (order_status, ordered_at);

CREATE INDEX lab_orders_shift_idx
  ON clinical_lab.lab_orders (received_during_shift, ordered_at);

CREATE INDEX lab_orders_completed_tat_idx
  ON clinical_lab.lab_orders (performing_department_id, completed_at)
  WHERE order_status = 'completed';

CREATE INDEX lab_orders_incorrect_idx
  ON clinical_lab.lab_orders (performing_department_id, ordered_at)
  WHERE order_is_incorrect;

CREATE INDEX lab_orders_missing_idx
  ON clinical_lab.lab_orders (performing_department_id, ordered_at)
  WHERE missing_information;

CREATE INDEX lab_orders_requisition_dob_idx
  ON clinical_lab.lab_orders (patient_id, requisition_date_of_birth)
  WHERE requisition_date_of_birth IS NOT NULL;

CREATE INDEX specimens_order_idx
  ON clinical_lab.specimens (lab_order_id);

CREATE INDEX specimens_collector_idx
  ON clinical_lab.specimens (collected_by_staff_id);

CREATE INDEX specimens_status_type_idx
  ON clinical_lab.specimens (specimen_status, specimen_type);

CREATE INDEX specimens_rejected_idx
  ON clinical_lab.specimens (received_at)
  WHERE specimen_status = 'rejected';

CREATE INDEX specimens_label_error_idx
  ON clinical_lab.specimens (lab_order_id)
  WHERE labeling_error;

CREATE INDEX specimens_missing_idx
  ON clinical_lab.specimens (lab_order_id)
  WHERE missing_information;

CREATE INDEX specimens_shift_idx
  ON clinical_lab.specimens (collected_during_shift, collected_at);

CREATE INDEX lab_exceptions_order_idx
  ON clinical_lab.lab_exceptions (lab_order_id);

CREATE INDEX lab_exceptions_specimen_idx
  ON clinical_lab.lab_exceptions (specimen_id)
  WHERE specimen_id IS NOT NULL;

CREATE INDEX lab_exceptions_type_status_opened_idx
  ON clinical_lab.lab_exceptions (exception_type, resolution_status, opened_at);

CREATE INDEX lab_exceptions_department_idx
  ON clinical_lab.lab_exceptions (department_id, opened_at);

CREATE INDEX lab_exceptions_opened_by_idx
  ON clinical_lab.lab_exceptions (opened_by_staff_id);

CREATE INDEX lab_exceptions_resolved_by_idx
  ON clinical_lab.lab_exceptions (resolved_by_staff_id)
  WHERE resolved_by_staff_id IS NOT NULL;

CREATE INDEX lab_exceptions_shift_idx
  ON clinical_lab.lab_exceptions (opened_during_shift, opened_at);

CREATE INDEX lab_exceptions_open_idx
  ON clinical_lab.lab_exceptions (opened_at)
  WHERE resolution_status IN ('open', 'in_progress');

-- Cross-row workflow rules ---------------------------------------------------

CREATE FUNCTION clinical_lab.assert_not_future(label text, instant timestamptz)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $func$
BEGIN
  IF instant IS NOT NULL
     AND instant > pg_catalog.clock_timestamp() + interval '5 minutes' THEN
    RAISE EXCEPTION '% % is more than 5 minutes in the future', label, instant;
  END IF;
END;
$func$;

CREATE FUNCTION clinical_lab.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $func$
BEGIN
  NEW.updated_at = pg_catalog.now();
  RETURN NEW;
END;
$func$;

CREATE FUNCTION clinical_lab.reject_future_calendar_dates()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $func$
BEGIN
  IF TG_TABLE_NAME = 'patients' AND NEW.date_of_birth > CURRENT_DATE THEN
    RAISE EXCEPTION 'patients.date_of_birth % is in the future', NEW.date_of_birth;
  ELSIF TG_TABLE_NAME = 'lab_staff' AND NEW.hired_on > CURRENT_DATE THEN
    RAISE EXCEPTION 'lab_staff.hired_on % is in the future', NEW.hired_on;
  ELSIF TG_TABLE_NAME = 'lab_orders'
        AND NEW.requisition_date_of_birth IS NOT NULL
        AND NEW.requisition_date_of_birth > CURRENT_DATE THEN
    RAISE EXCEPTION
      'lab_orders.requisition_date_of_birth % is in the future',
      NEW.requisition_date_of_birth;
  END IF;
  RETURN NEW;
END;
$func$;

CREATE FUNCTION clinical_lab.enforce_lab_order_times()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $func$
BEGIN
  PERFORM clinical_lab.assert_not_future('lab_orders.ordered_at', NEW.ordered_at);
  PERFORM clinical_lab.assert_not_future('lab_orders.received_at', NEW.received_at);
  PERFORM clinical_lab.assert_not_future(
    'lab_orders.testing_started_at',
    NEW.testing_started_at
  );
  PERFORM clinical_lab.assert_not_future('lab_orders.completed_at', NEW.completed_at);
  PERFORM clinical_lab.assert_not_future('lab_orders.cancelled_at', NEW.cancelled_at);
  PERFORM clinical_lab.assert_not_future('lab_orders.rejected_at', NEW.rejected_at);
  RETURN NEW;
END;
$func$;

CREATE FUNCTION clinical_lab.enforce_specimen_workflow()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $func$
DECLARE
  order_ordered_at timestamptz;
  order_completed_at timestamptz;
  order_cancelled_at timestamptz;
  order_rejected_at timestamptz;
BEGIN
  PERFORM clinical_lab.assert_not_future('specimens.collected_at', NEW.collected_at);
  PERFORM clinical_lab.assert_not_future('specimens.labeled_at', NEW.labeled_at);
  PERFORM clinical_lab.assert_not_future('specimens.received_at', NEW.received_at);
  PERFORM clinical_lab.assert_not_future('specimens.accepted_at', NEW.accepted_at);
  PERFORM clinical_lab.assert_not_future('specimens.rejected_at', NEW.rejected_at);
  PERFORM clinical_lab.assert_not_future('specimens.cancelled_at', NEW.cancelled_at);

  SELECT o.ordered_at, o.completed_at, o.cancelled_at, o.rejected_at
    INTO order_ordered_at, order_completed_at, order_cancelled_at, order_rejected_at
  FROM clinical_lab.lab_orders AS o
  WHERE o.lab_order_id = NEW.lab_order_id
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'specimen references missing lab order %',
      NEW.lab_order_id;
  END IF;

  IF NEW.collected_at IS NOT NULL AND order_ordered_at IS NOT NULL THEN
    IF NEW.collected_at < order_ordered_at - interval '30 days' THEN
      RAISE EXCEPTION
        'collected_at is more than 30 days before ordered_at for order %',
        NEW.lab_order_id;
    END IF;
    IF NEW.collected_at > order_ordered_at + interval '30 days' THEN
      RAISE EXCEPTION
        'collected_at is more than 30 days after ordered_at for order %',
        NEW.lab_order_id;
    END IF;
  END IF;

  IF NEW.collected_at IS NOT NULL
     AND order_completed_at IS NOT NULL
     AND NEW.collected_at > order_completed_at THEN
    RAISE EXCEPTION
      'collected_at is after the order was completed for order %',
      NEW.lab_order_id;
  END IF;

  IF NEW.received_at IS NOT NULL
     AND order_completed_at IS NOT NULL
     AND NEW.received_at > order_completed_at THEN
    RAISE EXCEPTION
      'specimen received_at is after the order was completed for order %',
      NEW.lab_order_id;
  END IF;

  IF NEW.collected_at IS NOT NULL
     AND order_cancelled_at IS NOT NULL
     AND NEW.collected_at > order_cancelled_at THEN
    RAISE EXCEPTION
      'collected_at is after the order was cancelled for order %',
      NEW.lab_order_id;
  END IF;

  IF NEW.collected_at IS NOT NULL
     AND order_rejected_at IS NOT NULL
     AND NEW.collected_at > order_rejected_at THEN
    RAISE EXCEPTION
      'collected_at is after the order was rejected for order %',
      NEW.lab_order_id;
  END IF;

  RETURN NEW;
END;
$func$;

CREATE FUNCTION clinical_lab.enforce_exception_times()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $func$
DECLARE
  order_ordered_at timestamptz;
BEGIN
  PERFORM clinical_lab.assert_not_future('lab_exceptions.opened_at', NEW.opened_at);
  PERFORM clinical_lab.assert_not_future('lab_exceptions.resolved_at', NEW.resolved_at);

  SELECT o.ordered_at
    INTO order_ordered_at
  FROM clinical_lab.lab_orders AS o
  WHERE o.lab_order_id = NEW.lab_order_id
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'exception references missing lab order %',
      NEW.lab_order_id;
  END IF;

  IF order_ordered_at IS NOT NULL
     AND NEW.opened_at < order_ordered_at - interval '1 day' THEN
    RAISE EXCEPTION
      'opened_at is more than 1 day before ordered_at for order %',
      NEW.lab_order_id;
  END IF;

  RETURN NEW;
END;
$func$;

CREATE FUNCTION clinical_lab.assert_order_specimens(target_order_id bigint)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $func$
DECLARE
  current_status text;
  matching_count bigint;
BEGIN
  SELECT o.order_status
    INTO current_status
  FROM clinical_lab.lab_orders AS o
  WHERE o.lab_order_id = target_order_id;

  IF current_status IS NULL THEN
    RETURN;
  END IF;

  IF current_status = 'incomplete' THEN
    SELECT count(*)
      INTO matching_count
    FROM clinical_lab.specimens AS s
    WHERE s.lab_order_id = target_order_id
      AND s.specimen_status NOT IN ('pending_collection', 'cancelled');

    IF matching_count > 0 THEN
      RAISE EXCEPTION
        'incomplete order % has a specimen past pending collection',
        target_order_id;
    END IF;
  ELSIF current_status = 'in_progress' THEN
    SELECT count(*)
      INTO matching_count
    FROM clinical_lab.specimens AS s
    WHERE s.lab_order_id = target_order_id
      AND s.specimen_status IN ('received', 'accepted');

    IF matching_count < 1 THEN
      RAISE EXCEPTION
        'in-progress order % requires a received or accepted specimen',
        target_order_id;
    END IF;
  ELSIF current_status = 'completed' THEN
    SELECT count(*)
      INTO matching_count
    FROM clinical_lab.specimens AS s
    WHERE s.lab_order_id = target_order_id
      AND s.specimen_status = 'accepted';

    IF matching_count < 1 THEN
      RAISE EXCEPTION
        'completed order % requires at least one accepted specimen',
        target_order_id;
    END IF;
  ELSIF current_status = 'rejected' THEN
    SELECT count(*)
      INTO matching_count
    FROM clinical_lab.specimens AS s
    WHERE s.lab_order_id = target_order_id
      AND s.specimen_status = 'accepted';

    IF matching_count > 0 THEN
      RAISE EXCEPTION
        'rejected order % cannot have an accepted specimen',
        target_order_id;
    END IF;
  END IF;
END;
$func$;

CREATE FUNCTION clinical_lab.enforce_order_specimen_consistency()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $func$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM clinical_lab.assert_order_specimens(OLD.lab_order_id);
    RETURN NULL;
  END IF;

  PERFORM clinical_lab.assert_order_specimens(NEW.lab_order_id);

  IF TG_OP = 'UPDATE'
     AND TG_TABLE_NAME = 'specimens'
     AND OLD.lab_order_id IS DISTINCT FROM NEW.lab_order_id THEN
    PERFORM clinical_lab.assert_order_specimens(OLD.lab_order_id);
  END IF;

  RETURN NULL;
END;
$func$;

CREATE TRIGGER patients_reject_future_dates
  BEFORE INSERT OR UPDATE ON clinical_lab.patients
  FOR EACH ROW
  EXECUTE FUNCTION clinical_lab.reject_future_calendar_dates();

CREATE TRIGGER patients_set_updated_at
  BEFORE UPDATE ON clinical_lab.patients
  FOR EACH ROW
  EXECUTE FUNCTION clinical_lab.set_updated_at();

CREATE TRIGGER lab_staff_reject_future_dates
  BEFORE INSERT OR UPDATE ON clinical_lab.lab_staff
  FOR EACH ROW
  EXECUTE FUNCTION clinical_lab.reject_future_calendar_dates();

CREATE TRIGGER lab_orders_reject_future_dates
  BEFORE INSERT OR UPDATE ON clinical_lab.lab_orders
  FOR EACH ROW
  EXECUTE FUNCTION clinical_lab.reject_future_calendar_dates();

CREATE TRIGGER lab_orders_enforce_times
  BEFORE INSERT OR UPDATE ON clinical_lab.lab_orders
  FOR EACH ROW
  EXECUTE FUNCTION clinical_lab.enforce_lab_order_times();

CREATE TRIGGER lab_orders_set_updated_at
  BEFORE UPDATE ON clinical_lab.lab_orders
  FOR EACH ROW
  EXECUTE FUNCTION clinical_lab.set_updated_at();

CREATE TRIGGER specimens_enforce_workflow
  BEFORE INSERT OR UPDATE ON clinical_lab.specimens
  FOR EACH ROW
  EXECUTE FUNCTION clinical_lab.enforce_specimen_workflow();

CREATE TRIGGER specimens_set_updated_at
  BEFORE UPDATE ON clinical_lab.specimens
  FOR EACH ROW
  EXECUTE FUNCTION clinical_lab.set_updated_at();

CREATE TRIGGER lab_exceptions_enforce_times
  BEFORE INSERT OR UPDATE ON clinical_lab.lab_exceptions
  FOR EACH ROW
  EXECUTE FUNCTION clinical_lab.enforce_exception_times();

CREATE TRIGGER lab_exceptions_set_updated_at
  BEFORE UPDATE ON clinical_lab.lab_exceptions
  FOR EACH ROW
  EXECUTE FUNCTION clinical_lab.set_updated_at();

CREATE CONSTRAINT TRIGGER lab_orders_specimen_consistency
  AFTER INSERT OR UPDATE OF order_status ON clinical_lab.lab_orders
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  EXECUTE FUNCTION clinical_lab.enforce_order_specimen_consistency();

CREATE CONSTRAINT TRIGGER specimens_order_consistency
  AFTER INSERT OR UPDATE OR DELETE ON clinical_lab.specimens
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  EXECUTE FUNCTION clinical_lab.enforce_order_specimen_consistency();

-- Catalog comments ------------------------------------------------------------

COMMENT ON TABLE clinical_lab.departments IS
  'Laboratory sections that perform tests and employ staff. Department performance is measured from orders and exceptions that point here.';

COMMENT ON COLUMN clinical_lab.departments.department_id IS
  'Surrogate key generated by the identity column.';
COMMENT ON COLUMN clinical_lab.departments.department_code IS
  'Short stable code such as CHEM or HEM. Uppercase letters and digits.';
COMMENT ON COLUMN clinical_lab.departments.department_name IS
  'Unique display name of the section.';
COMMENT ON COLUMN clinical_lab.departments.is_active IS
  'False when the section no longer accepts work. Historical rows may still reference it.';
COMMENT ON COLUMN clinical_lab.departments.created_at IS
  'When this row was inserted.';

COMMENT ON TABLE clinical_lab.patients IS
  'Fictional patient master. Discrepancies are recorded with record_status, identity_verified, merged_into_patient_id, and by comparing requisition fields on lab_orders. Sex value unknown means the sex was not recorded.';

COMMENT ON COLUMN clinical_lab.patients.patient_id IS
  'Surrogate key generated by the identity column.';
COMMENT ON COLUMN clinical_lab.patients.mrn IS
  'Medical record number. Unique. Not a clinical identifier from a real source.';
COMMENT ON COLUMN clinical_lab.patients.first_name IS
  'Given name on the master record.';
COMMENT ON COLUMN clinical_lab.patients.last_name IS
  'Family name on the master record.';
COMMENT ON COLUMN clinical_lab.patients.date_of_birth IS
  'Date of birth. A trigger rejects dates after the current date. The check constraint only bounds the year.';
COMMENT ON COLUMN clinical_lab.patients.sex IS
  'female, male, intersex, or unknown. unknown is an explicit missing value.';
COMMENT ON COLUMN clinical_lab.patients.phone_number IS
  'Optional contact number. Null means it was not recorded.';
COMMENT ON COLUMN clinical_lab.patients.email IS
  'Optional email. Null means it was not recorded.';
COMMENT ON COLUMN clinical_lab.patients.address_line IS
  'Optional street address. Address parts may be only partly filled.';
COMMENT ON COLUMN clinical_lab.patients.city IS
  'Optional city.';
COMMENT ON COLUMN clinical_lab.patients.state_code IS
  'Optional two-letter US state code.';
COMMENT ON COLUMN clinical_lab.patients.postal_code IS
  'Optional US ZIP or ZIP+4.';
COMMENT ON COLUMN clinical_lab.patients.record_status IS
  'active, inactive, incomplete, merged, or duplicate_suspected.';
COMMENT ON COLUMN clinical_lab.patients.identity_verified IS
  'True only after the master identity was checked. Forced false for incomplete, merged, and duplicate_suspected rows.';
COMMENT ON COLUMN clinical_lab.patients.merged_into_patient_id IS
  'Surviving patient when record_status is merged. Null otherwise. Cannot reference its own row. Cycles are not rejected.';
COMMENT ON COLUMN clinical_lab.patients.created_at IS
  'When this row was inserted.';
COMMENT ON COLUMN clinical_lab.patients.updated_at IS
  'Set to the transaction time on every update.';

COMMENT ON TABLE clinical_lab.test_catalog IS
  'Orderable tests. required_specimen_type is the correct material. Turnaround targets differ by priority. performing department on an order must match department_id.';

COMMENT ON COLUMN clinical_lab.test_catalog.test_id IS
  'Surrogate key generated by the identity column.';
COMMENT ON COLUMN clinical_lab.test_catalog.test_code IS
  'Unique orderable code. Not required to be a real LOINC code.';
COMMENT ON COLUMN clinical_lab.test_catalog.test_name IS
  'Display name of the test.';
COMMENT ON COLUMN clinical_lab.test_catalog.department_id IS
  'Section that performs this test.';
COMMENT ON COLUMN clinical_lab.test_catalog.required_specimen_type IS
  'Specimen material this test requires. Compare with specimens.specimen_type.';
COMMENT ON COLUMN clinical_lab.test_catalog.routine_turnaround_minutes IS
  'Target receipt-to-completion minutes for a routine order. Longest of the three targets.';
COMMENT ON COLUMN clinical_lab.test_catalog.urgent_turnaround_minutes IS
  'Target minutes for an urgent order. Between the stat and routine targets.';
COMMENT ON COLUMN clinical_lab.test_catalog.stat_turnaround_minutes IS
  'Target minutes for a stat order. Shortest of the three targets.';
COMMENT ON COLUMN clinical_lab.test_catalog.is_active IS
  'False when the test is no longer orderable. Existing orders may still reference it.';
COMMENT ON COLUMN clinical_lab.test_catalog.created_at IS
  'When this row was inserted.';

COMMENT ON TABLE clinical_lab.lab_staff IS
  'Employees. shift_code and the clock times are the current assignment. Orders and exceptions copy the shift that was actually on duty so a later assignment change does not rewrite history.';

COMMENT ON COLUMN clinical_lab.lab_staff.staff_id IS
  'Surrogate key generated by the identity column.';
COMMENT ON COLUMN clinical_lab.lab_staff.employee_number IS
  'Unique employee number.';
COMMENT ON COLUMN clinical_lab.lab_staff.first_name IS
  'Employee given name.';
COMMENT ON COLUMN clinical_lab.lab_staff.last_name IS
  'Employee family name.';
COMMENT ON COLUMN clinical_lab.lab_staff.job_role IS
  'phlebotomist, accessioner, technologist, supervisor, or pathologist.';
COMMENT ON COLUMN clinical_lab.lab_staff.department_id IS
  'Home section. Not necessarily the section on every order the employee touches.';
COMMENT ON COLUMN clinical_lab.lab_staff.shift_code IS
  'Current shift assignment.';
COMMENT ON COLUMN clinical_lab.lab_staff.shift_start_time IS
  'Local start of the current shift. A night shift may start after it ends.';
COMMENT ON COLUMN clinical_lab.lab_staff.shift_end_time IS
  'Local end of the current shift. Must differ from the start. Earlier than the start means the shift crosses midnight.';
COMMENT ON COLUMN clinical_lab.lab_staff.is_active IS
  'False when the employee is not currently working. Historical orders may still reference them.';
COMMENT ON COLUMN clinical_lab.lab_staff.hired_on IS
  'Hire date. A trigger rejects a date after today.';
COMMENT ON COLUMN clinical_lab.lab_staff.created_at IS
  'When this row was inserted.';

COMMENT ON TABLE clinical_lab.lab_orders IS
  'One ordered test. Status incomplete, cancelled, and rejected are first-class. turnaround_minutes is receipt to completion. An order may have many specimens and many exceptions.';

COMMENT ON COLUMN clinical_lab.lab_orders.lab_order_id IS
  'Surrogate key generated by the identity column.';
COMMENT ON COLUMN clinical_lab.lab_orders.accession_number IS
  'Unique laboratory accession. Null only while incomplete, or when cancelled before receipt. Multiple nulls are allowed.';
COMMENT ON COLUMN clinical_lab.lab_orders.patient_id IS
  'Master patient. Required except for incomplete orders and rejected orders whose identity could not be matched.';
COMMENT ON COLUMN clinical_lab.lab_orders.test_id IS
  'Test that was ordered, including a wrong test. Required except while incomplete.';
COMMENT ON COLUMN clinical_lab.lab_orders.corrected_test_id IS
  'Test that should have been ordered when order_is_incorrect is true. Must differ from test_id.';
COMMENT ON COLUMN clinical_lab.lab_orders.performing_department_id IS
  'Section responsible for the ordered test. Required when test_id is set, and must match that test''s catalog department.';
COMMENT ON COLUMN clinical_lab.lab_orders.received_by_staff_id IS
  'Employee who accessioned the order. Null when the receiver was not recorded. Cannot be set before receipt.';
COMMENT ON COLUMN clinical_lab.lab_orders.received_during_shift IS
  'Shift on duty at receipt. Required once received_at is set. This is the historical shift, not lab_staff.shift_code.';
COMMENT ON COLUMN clinical_lab.lab_orders.priority IS
  'routine, urgent, or stat. Selects which catalog turnaround target applies.';
COMMENT ON COLUMN clinical_lab.lab_orders.order_status IS
  'incomplete, received, in_progress, completed, cancelled, or rejected.';
COMMENT ON COLUMN clinical_lab.lab_orders.order_is_incorrect IS
  'True when the ordered test was the wrong test. Does not by itself create a lab_exceptions row.';
COMMENT ON COLUMN clinical_lab.lab_orders.incorrect_order_reason IS
  'Why the ordered test was wrong. Required exactly when order_is_incorrect is true.';
COMMENT ON COLUMN clinical_lab.lab_orders.missing_information IS
  'True when required order information is missing. A completed order cannot still be missing information.';
COMMENT ON COLUMN clinical_lab.lab_orders.missing_information_detail IS
  'What is missing. Required exactly when missing_information is true.';
COMMENT ON COLUMN clinical_lab.lab_orders.requisition_patient_name IS
  'Name written on the requisition. Compare with the master patient. A mismatch is a record discrepancy and is allowed.';
COMMENT ON COLUMN clinical_lab.lab_orders.requisition_date_of_birth IS
  'Date of birth written on the requisition. A mismatch with patients.date_of_birth is allowed and is the discrepancy signal.';
COMMENT ON COLUMN clinical_lab.lab_orders.ordered_at IS
  'When the order was placed. Null only while incomplete.';
COMMENT ON COLUMN clinical_lab.lab_orders.received_at IS
  'When the laboratory received the order. Start of turnaround_minutes.';
COMMENT ON COLUMN clinical_lab.lab_orders.testing_started_at IS
  'When testing started. Separates received from in_progress.';
COMMENT ON COLUMN clinical_lab.lab_orders.completed_at IS
  'When the result was completed. End of turnaround_minutes.';
COMMENT ON COLUMN clinical_lab.lab_orders.cancelled_at IS
  'When the order was cancelled. Must be null unless status is cancelled.';
COMMENT ON COLUMN clinical_lab.lab_orders.rejected_at IS
  'When the order was rejected. Must be null unless status is rejected.';
COMMENT ON COLUMN clinical_lab.lab_orders.cancellation_reason IS
  'Why the order was cancelled. Required exactly when status is cancelled.';
COMMENT ON COLUMN clinical_lab.lab_orders.rejection_reason IS
  'Why the order was rejected. Required exactly when status is rejected.';
COMMENT ON COLUMN clinical_lab.lab_orders.turnaround_minutes IS
  'Generated whole minutes from received_at to completed_at, rounded half away from zero. Null until both timestamps exist.';
COMMENT ON COLUMN clinical_lab.lab_orders.created_at IS
  'When this row was inserted.';
COMMENT ON COLUMN clinical_lab.lab_orders.updated_at IS
  'Set to the transaction time on every update.';

COMMENT ON TABLE clinical_lab.specimens IS
  'Physical samples for one order. Many rows per order are allowed. Rejection rate uses specimen_status = rejected. Barcodes are unique, so a duplicate label is recorded in labeling_error_detail instead of a second row with the same barcode.';

COMMENT ON COLUMN clinical_lab.specimens.specimen_id IS
  'Surrogate key generated by the identity column.';
COMMENT ON COLUMN clinical_lab.specimens.lab_order_id IS
  'Order this sample belongs to. Combined with specimen_id as the target of specimen-level exceptions.';
COMMENT ON COLUMN clinical_lab.specimens.collected_by_staff_id IS
  'Employee who collected the sample. Null when the collector was not recorded.';
COMMENT ON COLUMN clinical_lab.specimens.collected_during_shift IS
  'Shift on duty at collection. Required when a collector is named. Null when collection has not happened.';
COMMENT ON COLUMN clinical_lab.specimens.specimen_barcode IS
  'Unique label identifier. Two specimens cannot store the same barcode.';
COMMENT ON COLUMN clinical_lab.specimens.specimen_type IS
  'Material that was actually collected. Compare with the ordered test''s required_specimen_type.';
COMMENT ON COLUMN clinical_lab.specimens.specimen_status IS
  'pending_collection, collected, received, accepted, rejected, or cancelled.';
COMMENT ON COLUMN clinical_lab.specimens.labeling_error IS
  'True when the label was wrong, unreadable, or mismatched. Independent of lab_exceptions.';
COMMENT ON COLUMN clinical_lab.specimens.labeling_error_detail IS
  'What was wrong with the label. Required exactly when labeling_error is true.';
COMMENT ON COLUMN clinical_lab.specimens.missing_information IS
  'True when required specimen information is missing.';
COMMENT ON COLUMN clinical_lab.specimens.missing_information_detail IS
  'What is missing on the specimen. Required exactly when missing_information is true.';
COMMENT ON COLUMN clinical_lab.specimens.rejection_reason IS
  'Why the specimen was rejected. Required exactly when status is rejected.';
COMMENT ON COLUMN clinical_lab.specimens.collected_at IS
  'When the sample was drawn or gathered. A trigger keeps it within 30 days of ordered_at.';
COMMENT ON COLUMN clinical_lab.specimens.labeled_at IS
  'When the label was applied. May be up to 24 hours before collection and up to 2 hours after collection or receipt.';
COMMENT ON COLUMN clinical_lab.specimens.received_at IS
  'When this specimen arrived in the laboratory. Not the same column as the order receipt time.';
COMMENT ON COLUMN clinical_lab.specimens.accepted_at IS
  'When the specimen was accepted for testing.';
COMMENT ON COLUMN clinical_lab.specimens.rejected_at IS
  'When the specimen was rejected.';
COMMENT ON COLUMN clinical_lab.specimens.cancelled_at IS
  'When the specimen was cancelled.';
COMMENT ON COLUMN clinical_lab.specimens.created_at IS
  'When this row was inserted.';
COMMENT ON COLUMN clinical_lab.specimens.updated_at IS
  'Set to the transaction time on every update.';

COMMENT ON TABLE clinical_lab.lab_exceptions IS
  'Quality events. Many rows per order. Specimen-specific types must name a specimen on that same order. resolution_minutes is the resolution time for status resolved. Cancelled exceptions have a note and no resolution time.';

COMMENT ON COLUMN clinical_lab.lab_exceptions.exception_id IS
  'Surrogate key generated by the identity column.';
COMMENT ON COLUMN clinical_lab.lab_exceptions.lab_order_id IS
  'Order the event belongs to.';
COMMENT ON COLUMN clinical_lab.lab_exceptions.specimen_id IS
  'Specimen involved, when the event is about a sample. The composite foreign key requires that specimen to be on lab_order_id. Null skips that check.';
COMMENT ON COLUMN clinical_lab.lab_exceptions.department_id IS
  'Section that owns the event. Used for department performance, and it may differ from the order''s performing department.';
COMMENT ON COLUMN clinical_lab.lab_exceptions.opened_by_staff_id IS
  'Employee who opened the event.';
COMMENT ON COLUMN clinical_lab.lab_exceptions.resolved_by_staff_id IS
  'Employee who resolved the event. Required exactly when resolution_status is resolved.';
COMMENT ON COLUMN clinical_lab.lab_exceptions.exception_type IS
  'incorrect_test_order, patient_record_discrepancy, incorrect_specimen_type, specimen_rejection, labeling_error, missing_information, or other.';
COMMENT ON COLUMN clinical_lab.lab_exceptions.severity IS
  'low, moderate, high, or critical.';
COMMENT ON COLUMN clinical_lab.lab_exceptions.resolution_status IS
  'open, in_progress, resolved, or cancelled.';
COMMENT ON COLUMN clinical_lab.lab_exceptions.opened_during_shift IS
  'Shift on duty when the event was opened.';
COMMENT ON COLUMN clinical_lab.lab_exceptions.description IS
  'What happened.';
COMMENT ON COLUMN clinical_lab.lab_exceptions.resolution_note IS
  'How it was closed. Required for resolved and cancelled. Forbidden while open or in progress.';
COMMENT ON COLUMN clinical_lab.lab_exceptions.opened_at IS
  'When the event was opened. A trigger rejects a time more than one day before the order was placed.';
COMMENT ON COLUMN clinical_lab.lab_exceptions.resolved_at IS
  'When the event was resolved. Null unless resolution_status is resolved.';
COMMENT ON COLUMN clinical_lab.lab_exceptions.resolution_minutes IS
  'Generated whole minutes from opened_at to resolved_at, rounded half away from zero. Null when the event is not resolved.';
COMMENT ON COLUMN clinical_lab.lab_exceptions.created_at IS
  'When this row was inserted.';
COMMENT ON COLUMN clinical_lab.lab_exceptions.updated_at IS
  'Set to the transaction time on every update.';

COMMIT;
