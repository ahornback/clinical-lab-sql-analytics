# Clinical Lab SQL Analytics

SQL workspace for analyzing clinical laboratory operations: specimens, orders, tests, results, and quality-control events. The database and every row loaded into it will be synthetic. This repository does not contain protected health information.

## Status

This commit is the project scaffold only.

- Layout, README, `.gitignore`, and the MIT license are in place.
- Database tables are not created yet.
- Synthetic data is not generated yet.

## Layout

| Path | What goes here later |
| --- | --- |
| `sql/schema/` | Table definitions and constraints |
| `sql/queries/` | Analytical queries |
| `sql/views/` | Reporting views |
| `data/synthetic/` | Generated datasets used to load the database |
| `docs/` | Data dictionary and design notes |
| `scripts/` | Scripts that generate or load data |

Empty directories are kept with a `.gitkeep` file so the layout is in version control before those files exist.

## Working agreement

- Write SQL that can be reviewed without a running database dump in the commit.
- Keep generated database files and bulk synthetic extracts out of git. `.gitignore` already excludes them.
- Do not add real patient, clinician, or laboratory records.

## License

Released under the [MIT License](LICENSE).
