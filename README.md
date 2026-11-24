# Clinical Lab SQL Analytics

SQL workspace for analyzing clinical laboratory operations: specimens, orders, tests, results, and quality-control events. The database and every row loaded into it will be synthetic. This repository does not contain protected health information.

## Status

Phase 1 is the database design. The script has not been executed from this workspace.

- [sql/schema/01_schema.sql](sql/schema/01_schema.sql) defines the seven tables.
- [docs/data_dictionary.md](docs/data_dictionary.md) describes every column.
- [docs/erd.md](docs/erd.md) is the entity relationship diagram.
- Synthetic data is not generated yet.
- Analytical queries and a dashboard are not written yet.

## Layout

| Path | What it holds |
| --- | --- |
| `sql/schema/` | Table definitions and constraints |
| `sql/queries/` | Analytical queries, not written yet |
| `sql/views/` | Reporting views, not written yet |
| `data/synthetic/` | Generated datasets, not written yet |
| `docs/` | Data dictionary and entity relationship diagram |
| `scripts/` | Scripts that generate or load data, not written yet |

Empty directories are kept with a `.gitkeep` file so the layout is in version control before those files exist.

## Schema

The script creates the schema `clinical_lab` with seven tables: `patients`, `departments`, `test_catalog`, `lab_staff`, `lab_orders`, `specimens`, and `lab_exceptions`. An order is one test. An order can have many specimens and many exceptions. Primary keys are identity columns. The design targets 10,000 fictional patients and 50,000 orders over 12 months.

PostgreSQL 14 or newer is required. The script does not drop tables and does not insert rows.

## Create the schema in DBeaver

1. Install PostgreSQL 14 or newer and start the server.
2. Create an empty database named `clinical_lab_analytics`. Connect DBeaver to the maintenance database `postgres`, right-click Databases, choose Create New Database, and name it `clinical_lab_analytics`. You can instead run `CREATE DATABASE clinical_lab_analytics;` in a SQL editor connected to `postgres`.
3. Create a DBeaver connection to `clinical_lab_analytics` and connect as a user who can create schemas.
4. If a transaction is already open on that connection, commit or roll it back. Turn off auto-commit for the connection so the script's own transaction is the one that applies.
5. Open `sql/schema/01_schema.sql` in a SQL editor and select the `clinical_lab_analytics` connection.
6. Run **Execute SQL Script** (Alt+X). That runs the whole file. **Execute SQL Statement** (Ctrl+Enter) runs only the statement at the cursor and will split a function body.
7. The file begins with `BEGIN` and ends with `COMMIT`. A failed statement rolls the transaction back, so no partial schema remains. On success, DBeaver's output shows the commit.
8. Refresh the connection in Database Navigator. Open Schemas → `clinical_lab` and confirm the seven tables listed above. Column comments are visible in each table's column properties.
9. Run the script only once. A second run stops because the tables already exist. The file contains no `DROP TABLE` statement.

## Working agreement

- Write SQL that can be reviewed without a running database dump in the commit.
- Keep generated database files and bulk synthetic extracts out of git. `.gitignore` already excludes them.
- Do not add real patient, clinician, or laboratory records.

## License

Released under the [MIT License](LICENSE).
