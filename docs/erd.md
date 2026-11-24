# Entity relationship diagram

The diagram shows the seven tables in the `clinical_lab` schema. A crow's foot is "many." A circle means that side is optional. The data dictionary lists every column and constraint.

```mermaid
erDiagram
  departments ||--o{ test_catalog : performs
  departments ||--o{ lab_staff : employs
  departments |o--o{ lab_orders : "performs order"
  departments ||--o{ lab_exceptions : owns
  patients |o--o{ patients : "is surviving record for"
  patients |o--o{ lab_orders : "is subject of"
  test_catalog |o--o{ lab_orders : "is ordered test"
  test_catalog |o--o{ lab_orders : "is corrected test"
  lab_staff |o--o{ lab_orders : receives
  lab_staff |o--o{ specimens : collects
  lab_staff ||--o{ lab_exceptions : opens
  lab_staff |o--o{ lab_exceptions : resolves
  lab_orders ||--o{ specimens : contains
  lab_orders ||--o{ lab_exceptions : raises
  specimens |o--o{ lab_exceptions : concerns

  departments {
    bigint department_id PK
    text department_code UK
    text department_name UK
  }

  patients {
    bigint patient_id PK
    text mrn UK
    date date_of_birth
    text record_status
    bigint merged_into_patient_id FK
  }

  test_catalog {
    bigint test_id PK
    text test_code UK
    bigint department_id FK
    specimen_type required_specimen_type
  }

  lab_staff {
    bigint staff_id PK
    text employee_number UK
    bigint department_id FK
    shift_code shift_code
    time shift_start_time
    time shift_end_time
  }

  lab_orders {
    bigint lab_order_id PK
    text accession_number UK
    bigint patient_id FK
    bigint test_id FK
    bigint corrected_test_id FK
    bigint performing_department_id FK
    bigint received_by_staff_id FK
    text order_status
    boolean order_is_incorrect
    timestamptz received_at
    timestamptz completed_at
    integer turnaround_minutes
  }

  specimens {
    bigint specimen_id PK
    bigint lab_order_id FK
    bigint collected_by_staff_id FK
    text specimen_barcode UK
    specimen_type specimen_type
    text specimen_status
    boolean labeling_error
  }

  lab_exceptions {
    bigint exception_id PK
    bigint lab_order_id FK
    bigint specimen_id FK
    bigint department_id FK
    bigint opened_by_staff_id FK
    bigint resolved_by_staff_id FK
    text exception_type
    text resolution_status
    timestamptz opened_at
    timestamptz resolved_at
    integer resolution_minutes
  }
```

## How to read the optional links

- An order has one patient, except an incomplete or rejected order may have none.
- An order has one ordered test, except while it is incomplete. The corrected test is set only when that ordered test was wrong.
- The performing department is required once a test is set, and it must be the department stored on that test.
- Receipt staff may be missing. The receipt shift is required once the order has been received.
- A specimen has one collector or none. Naming a collector requires the collection shift.
- An exception always has an order, a department, and the employee who opened it. The resolver is set only when the exception is resolved.
- Specimen type, labeling, and rejection exceptions must name a specimen. The other exception types may name one.

## Relationships the diagram cannot draw

`lab_exceptions (specimen_id, lab_order_id)` references `specimens (specimen_id, lab_order_id)`. A specimen-level exception cannot point at a specimen from a different order. If `specimen_id` is null, PostgreSQL skips that check.

`lab_orders (test_id, performing_department_id)` references `test_catalog (test_id, department_id)`. The department on the order cannot disagree with the catalog.

`patients.merged_into_patient_id` references another patient, never the same row. A merged row points at the surviving record. One surviving patient can absorb many duplicates.

Every foreign key uses `ON DELETE RESTRICT`. A parent row that still has children cannot be deleted.
