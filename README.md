# Clinical Lab SQL Analytics

SQL workspace for analyzing clinical laboratory operations: specimens, orders, tests, results, and quality-control events. The database and every row loaded into it will be synthetic. This repository does not contain protected health information.

## Status

The schema is installed in the local PostgreSQL database `lab_operations`, in schema `clinical_lab`.

- [sql/schema/01_schema.sql](sql/schema/01_schema.sql) defines the seven tables. A fresh install includes the corrected future-date trigger.
- [sql/schema/02_repair_future_date_trigger.sql](sql/schema/02_repair_future_date_trigger.sql) replaces that function on a database that already ran the original script. It does not drop tables or change rows.
- [sql/verification/verify_constraints.sql](sql/verification/verify_constraints.sql) checks the essential constraints in `lab_operations` and rolls back every temporary test row.
- [docs/data_dictionary.md](docs/data_dictionary.md) describes every column.
- [docs/erd.md](docs/erd.md) is the entity relationship diagram.
- Synthetic data is not generated yet.
- Analytical queries and a dashboard are not written yet.

## Layout

| Path | What it holds |
| --- | --- |
| `sql/schema/` | Table definitions, constraints, and the future-date trigger repair |
| `sql/verification/` | Constraint checks for `lab_operations`. Test rows are rolled back. |
| `sql/queries/` | Analytical queries, not written yet |
| `sql/views/` | Reporting views, not written yet |
| `data/synthetic/` | Generated datasets, not written yet |
| `docs/` | Data dictionary and entity relationship diagram |
| `scripts/` | Scripts that generate or load data, not written yet |

Empty directories are kept with a `.gitkeep` file so the layout is in version control before those files exist.

## Schema

The script creates the schema `clinical_lab` with seven tables: `patients`, `departments`, `test_catalog`, `lab_staff`, `lab_orders`, `specimens`, and `lab_exceptions`. An order is one test. An order can have many specimens and many exceptions. Primary keys are identity columns. The design targets 10,000 fictional patients and 50,000 orders over 12 months.

PostgreSQL 14 or newer is required. The schema scripts do not drop tables and do not insert rows. `sql/verification/verify_constraints.sql` runs against `lab_operations`, inserts temporary rows in one transaction, and rolls them back.

## Create the schema in DBeaver

1. Install PostgreSQL 14 or newer and start the server.
2. Use the existing database `lab_operations`. Connect DBeaver to it. Do not create another database, and do not drop schemas that are already there.
3. Connect as a user who can create a schema in `lab_operations`.
4. If a transaction is already open on that connection, commit or roll it back. Turn off auto-commit for the connection so the script's own transaction is the one that applies.
5. If schema `clinical_lab` is absent, open `sql/schema/01_schema.sql` and select the `lab_operations` connection. If the seven tables are already present from an earlier run, open `sql/schema/02_repair_future_date_trigger.sql` instead.
6. Run **Execute SQL Script** (Alt+X). That runs the whole file. **Execute SQL Statement** (Ctrl+Enter) runs only the statement at the cursor and will split a function body.
7. Each file begins with `BEGIN` and ends with `COMMIT`. A failed statement rolls that file's transaction back. On success, DBeaver's output shows the commit.
8. Refresh the connection in Database Navigator. Open Schemas → `clinical_lab` and confirm the seven tables listed above. Column comments are visible in each table's column properties.
9. Run `01_schema.sql` only once. A second run stops because the tables already exist. The file contains no `DROP TABLE` statement. `02_repair_future_date_trigger.sql` can be run again; it only replaces the future-date function.

## Working agreement

- Write SQL that can be reviewed without a running database dump in the commit.
- Keep generated database files and bulk synthetic extracts out of git. `.gitignore` already excludes them.
- Do not add real patient, clinician, or laboratory records.

## License

Released under the [MIT License](LICENSE).
