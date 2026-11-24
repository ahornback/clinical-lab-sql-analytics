# Data dictionary

Schema: `clinical_lab`. Source: [sql/schema/01_schema.sql](../sql/schema/01_schema.sql). The diagram is in [erd.md](erd.md).

Every person and accession in this design is fictional. The script creates tables only. It does not insert rows.

## Grain and volume

| Table | One row is | Planned scale |
| --- | --- | --- |
| `patients` | One fictional person | 10,000 |
| `departments` | One laboratory section | A small reference list |
| `test_catalog` | One orderable test | A small reference list |
| `lab_staff` | One employee and that employee's current shift | A small reference list |
| `lab_orders` | One ordered test | 50,000 across 12 months |
| `specimens` | One physical sample for one order | More than one per order is allowed |
| `lab_exceptions` | One quality event for one order | More than one per order is allowed |

Keys are `bigint` identity columns. Tables are not partitioned. Foreign-key columns are indexed so joins and parent deletes stay index lookups at this volume.

## Domains

`clinical_lab.specimen_type` is `whole_blood`, `serum`, `plasma`, `urine`, `cerebrospinal_fluid`, `swab`, `tissue`, `stool`, `sputum`, or `other`. The catalog and the specimen use the same domain so the collected material can be compared with the material the test requires.

`clinical_lab.shift_code` is `day`, `evening`, `night`, or `rotating`. `rotating` means the assignment is not a single fixed clock shift.

## Assumptions

- One laboratory site. Event times are `timestamptz`. Shift start and end are local clock times with no time zone, read as America/New_York. A shift that ends earlier than it starts crosses midnight.
- An order is one test, not a panel. A specimen belongs to one order. Two tests do not share one specimen row.
- Accession numbers are unique. They are absent while an order is incomplete, and they may be absent when an order is cancelled before the laboratory receives it. PostgreSQL allows many null accession numbers.
- The performing department is copied from the test catalog and must match it. A test cannot be moved to another department while orders reference the old pair.
- Quality flags on orders and specimens are stored separately from `lab_exceptions`. The database does not keep them in sync. Use the flags for rates. Use exceptions for resolution time.
- An incorrect specimen type is not a stored boolean. Compare `specimens.specimen_type` with `test_catalog.required_specimen_type` through the order. A confirmed problem is also an exception.
- Barcodes are unique. A duplicate label is described in `labeling_error_detail`. It is not a second row with the same barcode.
- Check constraints reject a row only when the expression is false. The script writes each check so an invalid combination is false rather than unknown.
- Inserts omit identity columns. PostgreSQL generates them, and `GENERATED ALWAYS` refuses an explicit value unless the insert uses `OVERRIDING SYSTEM VALUE`.
- Every foreign key is `ON DELETE RESTRICT`.
- Address fields are US-shaped: a two-letter state and a ZIP or ZIP+4. City, street, state, and ZIP may be filled independently.
- `sex = 'unknown'` means sex was not recorded. It is not a null.

## Where each analysis question lives

| Question | Columns |
| --- | --- |
| Turnaround time | `lab_orders.received_at`, `testing_started_at`, `completed_at`, generated `turnaround_minutes`. Compare that with the catalog target for `priority`: `routine_turnaround_minutes`, `urgent_turnaround_minutes`, or `stat_turnaround_minutes`. |
| Incorrect test orders | `order_is_incorrect`, `test_id`, `corrected_test_id`, `incorrect_order_reason`. Resolution time is an exception of type `incorrect_test_order`. |
| Patient record discrepancies | `patients.record_status`, `identity_verified`, `merged_into_patient_id`. On the order, `requisition_patient_name` and `requisition_date_of_birth` may disagree with the master patient. Confirmed events use exception type `patient_record_discrepancy`. |
| Incorrect specimen types | `test_catalog.required_specimen_type` versus `specimens.specimen_type`. Confirmed events use exception type `incorrect_specimen_type` and must name the specimen. |
| Specimen rejection rate | `specimens.specimen_status = 'rejected'`, with `rejection_reason` and `rejected_at`. Order-level rejection is a separate status on `lab_orders`. |
| Labeling errors | `specimens.labeling_error` and `labeling_error_detail`. Exception type `labeling_error` tracks who resolved it. |
| Missing information | `missing_information` and `missing_information_detail` on orders and specimens. Null contact fields and `sex = 'unknown'` on patients. `patient_id` may be null on an incomplete or rejected order. A collector may be unnamed. Exception type `missing_information`. |
| Department performance | `lab_orders.performing_department_id`, `test_catalog.department_id`, `lab_staff.department_id`, and `lab_exceptions.department_id`. |
| Employee shifts | `lab_staff.shift_code` plus `shift_start_time` and `shift_end_time` for the current assignment. `lab_orders.received_during_shift`, `specimens.collected_during_shift`, and `lab_exceptions.opened_during_shift` are the shift on duty at the event. |
| Exception resolution time | `opened_at`, `resolved_at`, and generated `resolution_minutes`. Cancelled exceptions have a note and no resolution time. |

## departments

A laboratory section that performs tests and employs staff.

| Column | Type | Null | Default | Purpose and constraints |
| --- | --- | --- | --- | --- |
| `department_id` | `bigint` | No | Identity | Primary key. |
| `department_code` | `text` | No |  | Unique short code. Must match `^[A-Z][A-Z0-9]{1,9}$`, for example `CHEM`. |
| `department_name` | `text` | No |  | Unique display name, trimmed, 2 to 80 characters. |
| `is_active` | `boolean` | No | `true` | False when the section no longer accepts work. Old orders may still point at it. |
| `created_at` | `timestamptz` | No | `now()` | When the row was inserted. |

## patients

The master record for one fictional person.

| Column | Type | Null | Default | Purpose and constraints |
| --- | --- | --- | --- | --- |
| `patient_id` | `bigint` | No | Identity | Primary key. |
| `mrn` | `text` | No |  | Unique medical record number, 4 to 32 characters, letters, digits, and hyphens. |
| `first_name` | `text` | No |  | Given name, trimmed, 1 to 80 characters. |
| `last_name` | `text` | No |  | Family name, trimmed, 1 to 80 characters. |
| `date_of_birth` | `date` | No |  | From 1900-01-01 through 2100-01-01. A trigger rejects a date after today. |
| `sex` | `text` | No |  | `female`, `male`, `intersex`, or `unknown`. |
| `phone_number` | `text` | Yes |  | Null when not recorded. If present, 7 to 20 characters from digits, spaces, and `+(). -`. |
| `email` | `text` | Yes |  | Null when not recorded. If present, one `@`, a dot in the domain, no spaces, at most 254 characters. |
| `address_line` | `text` | Yes |  | Optional street line, trimmed, 1 to 120 characters. |
| `city` | `text` | Yes |  | Optional city, trimmed, 1 to 80 characters. |
| `state_code` | `text` | Yes |  | Optional two uppercase letters. |
| `postal_code` | `text` | Yes |  | Optional ZIP or ZIP+4. |
| `record_status` | `text` | No | `active` | `active`, `inactive`, `incomplete`, `merged`, or `duplicate_suspected`. |
| `identity_verified` | `boolean` | No | `false` | Must be false when status is `incomplete`, `merged`, or `duplicate_suspected`. |
| `merged_into_patient_id` | `bigint` | Yes |  | Foreign key to `patients.patient_id`. Required when status is `merged`, forbidden otherwise, and cannot equal `patient_id`. |
| `created_at` | `timestamptz` | No | `now()` | When the row was inserted. |
| `updated_at` | `timestamptz` | No | `now()` | Set to the transaction time on every update. |

A merged patient must be loaded after the surviving patient. The foreign key is not deferred. The check does not reject a longer cycle such as A merged into B and B merged into A.

## test_catalog

One orderable test and the specimen and turnaround targets that belong to it.

| Column | Type | Null | Default | Purpose and constraints |
| --- | --- | --- | --- | --- |
| `test_id` | `bigint` | No | Identity | Primary key. |
| `test_code` | `text` | No |  | Unique code, 2 to 32 characters, matching `^[A-Z0-9][A-Z0-9.-]{1,31}$`. It does not have to be a real LOINC code. |
| `test_name` | `text` | No |  | Display name, trimmed, 2 to 120 characters. |
| `department_id` | `bigint` | No |  | Foreign key to `departments`. The section that performs the test. |
| `required_specimen_type` | `specimen_type` | No |  | Material the test requires. |
| `routine_turnaround_minutes` | `integer` | No |  | Target minutes from receipt to completion for a routine order. |
| `urgent_turnaround_minutes` | `integer` | No |  | Target for an urgent order. Must be less than or equal to the routine target. |
| `stat_turnaround_minutes` | `integer` | No |  | Target for a stat order, at least 1, and less than or equal to the urgent target. The routine target is at most 20,160 minutes (14 days). |
| `is_active` | `boolean` | No | `true` | False when the test is no longer orderable. Existing orders may still reference it. |
| `created_at` | `timestamptz` | No | `now()` | When the row was inserted. |

`UNIQUE (test_id, department_id)` exists so an order can foreign-key to the test and its department together.

## lab_staff

One employee. The shift columns are the current assignment, not a history of every shift the person has worked.

| Column | Type | Null | Default | Purpose and constraints |
| --- | --- | --- | --- | --- |
| `staff_id` | `bigint` | No | Identity | Primary key. |
| `employee_number` | `text` | No |  | Unique, 4 to 16 characters, uppercase letters and digits. |
| `first_name` | `text` | No |  | Trimmed, 1 to 80 characters. |
| `last_name` | `text` | No |  | Trimmed, 1 to 80 characters. |
| `job_role` | `text` | No |  | `phlebotomist`, `accessioner`, `technologist`, `supervisor`, or `pathologist`. |
| `department_id` | `bigint` | No |  | Foreign key to the home section. An employee can still receive an order or open an exception for another section. |
| `shift_code` | `shift_code` | No |  | Current shift assignment. |
| `shift_start_time` | `time` | No |  | Local start. Must differ from the end. |
| `shift_end_time` | `time` | No |  | Local end. An earlier end means the shift crosses midnight. |
| `is_active` | `boolean` | No | `true` | False when the employee is not currently working. Historical rows may still name them. |
| `hired_on` | `date` | No |  | From 1970-01-01 through 2100-01-01. A trigger rejects a date after today. |
| `created_at` | `timestamptz` | No | `now()` | When the row was inserted. |

## lab_orders

One ordered test. This is the table behind turnaround, wrong-test, missing-order, and department measures.

| Column | Type | Null | Default | Purpose and constraints |
| --- | --- | --- | --- | --- |
| `lab_order_id` | `bigint` | No | Identity | Primary key. |
| `accession_number` | `text` | Yes |  | Unique when present. Uppercase letters, digits, and hyphens, 6 to 32 characters. Null while `incomplete`. A `cancelled` order may also have a null accession when `received_at` is null. |
| `patient_id` | `bigint` | Yes |  | Foreign key to `patients`. Required except when status is `incomplete` or `rejected`. |
| `test_id` | `bigint` | Yes |  | Foreign key to the test that was ordered, including a wrong test. Required except while `incomplete`. |
| `corrected_test_id` | `bigint` | Yes |  | Foreign key to the test that should have been ordered. Required when `order_is_incorrect` is true, and it must differ from `test_id`. |
| `performing_department_id` | `bigint` | Yes |  | Foreign key to `departments`. Required when `test_id` is set. The pair `(test_id, performing_department_id)` must match the catalog. |
| `received_by_staff_id` | `bigint` | Yes |  | Foreign key to the employee who accessioned the order. Null when that person was not recorded. Cannot be set before receipt. |
| `received_during_shift` | `shift_code` | Yes |  | Shift on duty at receipt. Required when `received_at` is set, and null before that. This snapshot stays put if the employee's current shift later changes. |
| `priority` | `text` | No | `routine` | `routine`, `urgent`, or `stat`. Chooses the catalog turnaround target. |
| `order_status` | `text` | No |  | `incomplete`, `received`, `in_progress`, `completed`, `cancelled`, or `rejected`. |
| `order_is_incorrect` | `boolean` | No | `false` | True when the ordered test was the wrong test. Does not insert an exception by itself. |
| `incorrect_order_reason` | `text` | Yes |  | Required exactly when the order is incorrect. Trimmed, 1 to 500 characters. |
| `missing_information` | `boolean` | No | `false` | True when required order information is missing. Must be false when status is `completed`. |
| `missing_information_detail` | `text` | Yes |  | Required exactly when `missing_information` is true. Trimmed, 1 to 500 characters. |
| `requisition_patient_name` | `text` | Yes |  | Name written on the requisition. A mismatch with the master patient is allowed. Trimmed, 1 to 160 characters when present. |
| `requisition_date_of_birth` | `date` | Yes |  | Date of birth written on the requisition, bounded like a patient birth date. A trigger rejects a future date. A mismatch with `patients.date_of_birth` is allowed. |
| `ordered_at` | `timestamptz` | Yes |  | When the order was placed. Null only while `incomplete`. |
| `received_at` | `timestamptz` | Yes |  | When the laboratory received the order. Start of `turnaround_minutes`. |
| `testing_started_at` | `timestamptz` | Yes |  | When testing started. This is what separates `received` from `in_progress`. |
| `completed_at` | `timestamptz` | Yes |  | When the result was completed. End of `turnaround_minutes`. |
| `cancelled_at` | `timestamptz` | Yes |  | When the order was cancelled. Set exactly when status is `cancelled`. |
| `rejected_at` | `timestamptz` | Yes |  | When the order was rejected. Set exactly when status is `rejected`. |
| `cancellation_reason` | `text` | Yes |  | Required exactly when status is `cancelled`. Trimmed, 1 to 500 characters. |
| `rejection_reason` | `text` | Yes |  | Required exactly when status is `rejected`. Trimmed, 1 to 500 characters. |
| `turnaround_minutes` | `integer` | Yes | Generated | Whole minutes from `received_at` to `completed_at`, rounded half away from zero. Null until both times exist. A check requires zero or positive when present. Not writable. |
| `created_at` | `timestamptz` | No | `now()` | When the row was inserted. |
| `updated_at` | `timestamptz` | No | `now()` | Set to the transaction time on every update. |

Every event timestamp must fall from 2000-01-01 through 2099-12-31 UTC, and a trigger rejects a time more than five minutes in the future.

Status and time rules:

| Status | Required times | Forbidden times | Order of times |
| --- | --- | --- | --- |
| `incomplete` | None | receipt, testing start, completion, cancellation, rejection | `ordered_at` may already be set |
| `received` | `ordered_at`, `received_at` | testing start, completion, cancellation, rejection | receipt is at or after the order |
| `in_progress` | `ordered_at`, `received_at`, `testing_started_at` | completion, cancellation, rejection | testing starts at or after receipt |
| `completed` | `ordered_at`, `received_at`, `testing_started_at`, `completed_at` | cancellation, rejection | completion is at or after testing start |
| `cancelled` | `ordered_at`, `cancelled_at` | completion, rejection | cancellation is at or after the order, and at or after receipt and testing start when those happened |
| `rejected` | `ordered_at`, `received_at`, `rejected_at` | completion, cancellation | rejection is at or after receipt. Testing start, if present, falls between receipt and rejection |

Cancellation before receipt has no receipt time and no testing start. Time from receipt to cancellation is `cancelled_at - received_at` and is not a stored column. The same is true of time to rejection.

## specimens

One physical sample for one order. Many rows per order are allowed.

| Column | Type | Null | Default | Purpose and constraints |
| --- | --- | --- | --- | --- |
| `specimen_id` | `bigint` | No | Identity | Primary key. Also part of `UNIQUE (specimen_id, lab_order_id)`, which exceptions reference. |
| `lab_order_id` | `bigint` | No |  | Foreign key to `lab_orders`. |
| `collected_by_staff_id` | `bigint` | Yes |  | Foreign key to the collector. Null when the collector was not recorded. |
| `collected_during_shift` | `shift_code` | Yes |  | Shift on duty at collection. Required when a collector is named. Both collector and shift are null when `collected_at` is null. |
| `specimen_barcode` | `text` | No |  | Unique label, 6 to 40 characters, uppercase letters, digits, and hyphens. |
| `specimen_type` | `specimen_type` | No |  | Material that was actually collected. |
| `specimen_status` | `text` | No |  | `pending_collection`, `collected`, `received`, `accepted`, `rejected`, or `cancelled`. |
| `labeling_error` | `boolean` | No | `false` | True when the label was wrong, unreadable, or mismatched. |
| `labeling_error_detail` | `text` | Yes |  | Required exactly when `labeling_error` is true. Trimmed, 1 to 500 characters. |
| `missing_information` | `boolean` | No | `false` | True when required specimen information is missing. |
| `missing_information_detail` | `text` | Yes |  | Required exactly when the flag is true. Trimmed, 1 to 500 characters. |
| `rejection_reason` | `text` | Yes |  | Required exactly when status is `rejected`. Trimmed, 1 to 500 characters. |
| `collected_at` | `timestamptz` | Yes |  | When the sample was drawn or gathered. |
| `labeled_at` | `timestamptz` | Yes |  | When the label was applied. If collection is known, the label is from 24 hours before collection through 2 hours after it. If receipt is known, the label is no later than 2 hours after receipt. |
| `received_at` | `timestamptz` | Yes |  | When this specimen arrived in the laboratory. This is not `lab_orders.received_at`. |
| `accepted_at` | `timestamptz` | Yes |  | When the specimen was accepted for testing. |
| `rejected_at` | `timestamptz` | Yes |  | When the specimen was rejected. |
| `cancelled_at` | `timestamptz` | Yes |  | When the specimen was cancelled. |
| `created_at` | `timestamptz` | No | `now()` | When the row was inserted. |
| `updated_at` | `timestamptz` | No | `now()` | Set to the transaction time on every update. |

Specimen event times use the same year bounds and future-time trigger as orders. A trigger also keeps `collected_at` within 30 days before or after `lab_orders.ordered_at` when both are present, and it rejects collection or specimen receipt after the order is completed, cancelled, or rejected.

| Status | Required times | Other rules |
| --- | --- | --- |
| `pending_collection` | None of collection, receipt, acceptance, rejection, or cancellation | The tube may already be labeled |
| `collected` | `collected_at` | Not yet received |
| `received` | `collected_at`, `received_at` | Receipt is at or after collection. Not yet accepted |
| `accepted` | `collected_at`, `received_at`, `accepted_at` | Acceptance is at or after receipt |
| `rejected` | `received_at`, `rejected_at`, `rejection_reason` | Rejection is at or after receipt. Collection is optional. Cannot also be accepted or cancelled |
| `cancelled` | `cancelled_at` | If the sample was collected or received, cancellation is at or after those times. Cannot be accepted or rejected |

## lab_exceptions

One quality event. Many rows per order are allowed. Specimen-specific types must name a specimen on that same order.

| Column | Type | Null | Default | Purpose and constraints |
| --- | --- | --- | --- | --- |
| `exception_id` | `bigint` | No | Identity | Primary key. |
| `lab_order_id` | `bigint` | No |  | Foreign key to `lab_orders`. |
| `specimen_id` | `bigint` | Yes |  | Foreign key to `specimens`. Required for `incorrect_specimen_type`, `specimen_rejection`, and `labeling_error`. Optional for the other types. The pair `(specimen_id, lab_order_id)` must match one specimen. A null `specimen_id` skips that pair check. |
| `department_id` | `bigint` | No |  | Foreign key to the section that owns the event. It may differ from the order's performing department. |
| `opened_by_staff_id` | `bigint` | No |  | Foreign key to the employee who opened the event. |
| `resolved_by_staff_id` | `bigint` | Yes |  | Foreign key to the employee who resolved it. Required exactly when status is `resolved`. |
| `exception_type` | `text` | No |  | `incorrect_test_order`, `patient_record_discrepancy`, `incorrect_specimen_type`, `specimen_rejection`, `labeling_error`, `missing_information`, or `other`. |
| `severity` | `text` | No |  | `low`, `moderate`, `high`, or `critical`. |
| `resolution_status` | `text` | No | `open` | `open`, `in_progress`, `resolved`, or `cancelled`. |
| `opened_during_shift` | `shift_code` | No |  | Shift on duty when the event was opened. |
| `description` | `text` | No |  | What happened. Trimmed, 1 to 4,000 characters. |
| `resolution_note` | `text` | Yes |  | Required for `resolved` and `cancelled`. Forbidden while `open` or `in_progress`. Trimmed, 1 to 4,000 characters. |
| `opened_at` | `timestamptz` | No |  | When the event was opened. A trigger rejects a time more than one day before `ordered_at` when the order has that timestamp. |
| `resolved_at` | `timestamptz` | Yes |  | When the event was resolved. Set exactly when status is `resolved`, and it must be at or after `opened_at`. |
| `resolution_minutes` | `integer` | Yes | Generated | Whole minutes from open to resolve, rounded half away from zero. Null unless `resolved_at` is set, including when the exception is cancelled. A check requires zero or positive when present. Not writable. |
| `created_at` | `timestamptz` | No | `now()` | When the row was inserted. |
| `updated_at` | `timestamptz` | No | `now()` | Set to the transaction time on every update. |

`opened_at` and `resolved_at` use the same year bounds and five-minute future limit as the other event times.

## Relationships

| From | To | Rule |
| --- | --- | --- |
| `patients.merged_into_patient_id` | `patients.patient_id` | Optional. The surviving patient is loaded first. |
| `test_catalog.department_id` | `departments.department_id` | Required. |
| `lab_staff.department_id` | `departments.department_id` | Required. |
| `lab_orders.patient_id` | `patients.patient_id` | Optional only for `incomplete` and `rejected`. |
| `lab_orders.test_id` | `test_catalog.test_id` | Optional only for `incomplete`. |
| `lab_orders.corrected_test_id` | `test_catalog.test_id` | Optional. A different test from `test_id`. |
| `lab_orders.performing_department_id` | `departments.department_id` | Optional only when `test_id` is null. |
| `lab_orders (test_id, performing_department_id)` | `test_catalog (test_id, department_id)` | Enforced when both columns are present. |
| `lab_orders.received_by_staff_id` | `lab_staff.staff_id` | Optional. |
| `specimens.lab_order_id` | `lab_orders.lab_order_id` | Required. |
| `specimens.collected_by_staff_id` | `lab_staff.staff_id` | Optional. |
| `lab_exceptions.lab_order_id` | `lab_orders.lab_order_id` | Required. |
| `lab_exceptions.specimen_id` | `specimens.specimen_id` | Optional. |
| `lab_exceptions (specimen_id, lab_order_id)` | `specimens (specimen_id, lab_order_id)` | Required when `specimen_id` is present. |
| `lab_exceptions.department_id` | `departments.department_id` | Required. |
| `lab_exceptions.opened_by_staff_id` | `lab_staff.staff_id` | Required. |
| `lab_exceptions.resolved_by_staff_id` | `lab_staff.staff_id` | Optional. |

## Cross-row rules

These are triggers because a check constraint cannot read the clock or another table. The specimen-to-order status rules are deferred until commit, so an order and its specimens can be inserted in one transaction.

- Collection, when both times exist, is no earlier than 30 days before `ordered_at` and no later than 30 days after it.
- A specimen cannot be collected or received after the order is completed, and it cannot be collected after the order is cancelled or rejected.
- An exception cannot be opened more than one day before `ordered_at`.
- An `incomplete` order may only have specimens in `pending_collection` or `cancelled`.
- An `in_progress` order needs at least one specimen in `received` or `accepted`.
- A `completed` order needs at least one `accepted` specimen.
- A `rejected` order cannot keep an `accepted` specimen. It does not have to have a specimen. An order can be rejected on the requisition alone.
- `date_of_birth`, `hired_on`, and `requisition_date_of_birth` cannot be after the current date.
- Business event timestamps cannot be more than five minutes in the future.

`received` orders are not required to have a specimen yet. The tube may still be in transit. `cancelled` orders may keep an accepted specimen if the order is cancelled after the draw. Flags such as `order_is_incorrect` are not required to have a matching exception row, and an exception does not flip the flag.

## Indexes

Primary keys, unique keys, and unique pairs are indexed by their constraints. Additional indexes:

| Index | Supports |
| --- | --- |
| `patients (last_name, first_name, date_of_birth)` | Identity lookup and discrepancy comparison |
| `patients (record_status)` | Incomplete and merged records |
| `patients (date_of_birth, last_name)` where `duplicate_suspected` | Possible duplicates |
| `patients (merged_into_patient_id)` where not null | Merge chains and the self foreign key |
| `test_catalog (department_id)` | Tests by section |
| `test_catalog (required_specimen_type)` | Tests that require a given material |
| `lab_staff (department_id)` | Staff by home section |
| `lab_staff (shift_code, department_id)` | Who is assigned to a shift |
| `lab_orders (patient_id)` | Orders for a patient |
| `lab_orders (test_id)` | Orders for a test |
| `lab_orders (corrected_test_id)` where not null | Wrong-test corrections |
| `lab_orders (performing_department_id, priority, ordered_at)` | Department workload by priority |
| `lab_orders (received_by_staff_id)` | Orders accessioned by an employee |
| `lab_orders (order_status, ordered_at)` | Incomplete, cancelled, and rejected orders over time |
| `lab_orders (received_during_shift, ordered_at)` | Receipt volume by shift |
| `lab_orders (performing_department_id, completed_at)` where `completed` | Turnaround by section |
| `lab_orders (performing_department_id, ordered_at)` where `order_is_incorrect` | Wrong tests by section |
| `lab_orders (performing_department_id, ordered_at)` where `missing_information` | Incomplete requisitions by section |
| `lab_orders (patient_id, requisition_date_of_birth)` where the requisition birth date is present | Requisition versus master identity |
| `specimens (lab_order_id)` | Samples on an order |
| `specimens (collected_by_staff_id)` | Draws by employee |
| `specimens (specimen_status, specimen_type)` | Rejection and specimen-type rates |
| `specimens (received_at)` where `rejected` | When rejections arrive |
| `specimens (lab_order_id)` where `labeling_error` | Label problems |
| `specimens (lab_order_id)` where `missing_information` | Specimen records with gaps |
| `specimens (collected_during_shift, collected_at)` | Collection volume by shift |
| `lab_exceptions (lab_order_id)` | Events on an order |
| `lab_exceptions (specimen_id)` where not null | Events on a specimen |
| `lab_exceptions (exception_type, resolution_status, opened_at)` | Open and resolved events by type |
| `lab_exceptions (department_id, opened_at)` | Department event volume |
| `lab_exceptions (opened_by_staff_id)` | Who opened events |
| `lab_exceptions (resolved_by_staff_id)` where not null | Who closed events |
| `lab_exceptions (opened_during_shift, opened_at)` | Events by shift |
| `lab_exceptions (opened_at)` where status is `open` or `in_progress` | The current queue |

## Load order for a later phase

The foreign keys require this order: `departments`, then `patients`, `test_catalog`, and `lab_staff` in any order among those three, then `lab_orders`, then `specimens`, then `lab_exceptions`. Insert a surviving patient before any row merged into that patient. Insert an order and its specimens in one transaction when the order status requires those specimens at commit.

## Limitations

- There is no eighth table, so a panel is several orders and a shared tube is several specimen rows. Nothing ties those rows together as one draw.
- Catalog department and order department must match. The schema does not keep a history of a test moving between sections.
- Employee shift on `lab_staff` is current state. Only the shift columns on orders, specimens, and exceptions are historical.
- Wrong-test flags, labeling flags, and rejection statuses are not forced to have an exception, so a rate and a mean resolution time can disagree until the load step writes both.
- A duplicate barcode cannot be stored. The labeling flag describes it instead.
- Patient merge cycles are not rejected.
- Check constraints bound dates through 2100. Triggers, not checks, reject dates after today and timestamps more than five minutes ahead.
- `created_at` can be supplied by the insert. Event timestamps cannot be placed in the future.
- The script is not idempotent. It does not drop existing objects. Run it once on an empty database.
- PostgreSQL 14 or newer is required.
