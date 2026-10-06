### Supported Actions:
- **`health`**: Checks connectivity and reports the backend engine (`turso (libsql)`, `postgres`, or `sqlite`) and status.
- **`schema`**: Discovers table structures, column types, nullable flags, and primary keys.
- **`query`**: Runs read-only `SELECT` queries (formatted as Markdown tables).
- **`exec`**: Runs DDL/DML statements (`INSERT`, `UPDATE`, `CREATE TABLE`) and reports success; remote service responses also include change counts.

### Example User Prompts:
```text
"What tables exist in our sessions database?"
"Show me the last 5 sessions recorded in the database using the database tool."
"Check the health of our active database connection."
```
