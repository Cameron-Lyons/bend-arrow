# bend-arrow

Query tables, read and write Parquet, and exchange Apache Arrow IPC streams in Bend. The library, example, and tests are written in Bend 2.0.40. They use the standard library for byte I/O and channels. The build requires no database installation, network downloads, or project-specific native effects.

## Run the example

From the repository root, use a fresh output path.

```sh
bend examples/roundtrip.bend "/tmp/scores.parquet"
```

The example writes four rows, reads the file through a SQL filter, transfers the result into a temporary table, and prints `Score total: 19`. The file is ordinary Parquet and can be opened by other Parquet readers. Writers create files exclusively and report an error if the path already exists.

To compile and test with Bend's native backend, use Make and the C toolchain required by Bend itself.

```sh
make
./build/roundtrip /tmp/native-scores.parquet
make test
```

## Querying tables

Import `src/duckdb.bend` as `DB` for the connection API and `src/table.bend` as `T` for the table, column, and cell constructors. The connection module retains its original filename. The query engine and on-disk database format are specific to this library.

| Operation | Behavior |
| --- | --- |
| `DB.memory()` or `DB.open(":memory:")` | Create an isolated in-memory database. |
| `DB.open(path)` | Open or create a Bend database file. |
| `DB.query(db, sql)` | Return a `T.Table` of ordered column definitions and typed rows. |
| `DB.exec(db, sql)` | Execute statements, including `CREATE [TEMP] TABLE`, `INSERT INTO … VALUES`, `BEGIN`, `COMMIT`, and `ROLLBACK`. |
| `DB.register(db, name, table)` | Add a connection-local temporary table. A name collision returns an error. |
| `DB.close(db)` | Close the session and discard any uncommitted transaction. |

The SELECT evaluator supports column names, aliases, literals, `*`, `COUNT(*)`, and integer `SUM(column)` with a checked signed BIGINT result. Sources include named tables, `(VALUES …) AS t(columns)`, `range(n)`, and `read_parquet('path')`. A WHERE clause can compare a column with a literal or check `IS [NOT] NULL`, with `AND` and `OR`. Group on one input column and order on one output column, optionally with `ASC` or `DESC`. Unsupported SQL syntax returns an error. Identifiers can be double-quoted and strings single-quoted. Double the matching quote to embed one. Explicit column declarations accept `INT`/`INTEGER`, `BIGINT`, `VARCHAR`, and `BOOLEAN`. Use `CREATE TABLE … AS SELECT …` to derive a schema from a query.

```sql
SELECT region, sum(amount) AS total
FROM read_parquet('sales.parquet')
GROUP BY region
ORDER BY total DESC
```

File-backed connections refresh committed data between operations. A transaction reads a snapshot. A competing commit against the same revision returns a conflict and ends the losing transaction. If a write succeeds but its confirmation cannot be read, the connection reports error 115. Retry `COMMIT` on that connection to resolve the original write. Temporary tables stay local to their connection. The store appends full catalog snapshots, so file size grows with each persistent commit. Existing DuckDB files require export to a supported interchange format before use.

## Parquet and Arrow

| Operation | Behavior |
| --- | --- |
| `Parquet.read_table(path)` / `Parquet.write_table(table, path)` | Read or write a table directly. |
| `Parquet.scan(path)` | Quote one literal file path for a SQL FROM clause. |
| `Parquet.read(db, path)` / `Parquet.read_arrow(db, path)` | Read through the connection into a table or stream. |
| `Parquet.write(db, query, path)` | Write a SELECT result to Parquet. |
| `Arrow.query(db, sql)` | Return an affine stream owning a materialized query result. It remains usable after the source connection closes. |
| `Arrow.next(stream)` | Return `End{}` or `Next{batch, rest}`, with up to 2,048 rows per batch. |
| `Arrow.into_table(db, name, stream)` / `Arrow.close(stream)` | Consume the remaining rows as a temporary table or release them. |
| `Arrow.write(stream, path)` / `Arrow.read(path)` | Exchange standard Arrow IPC streaming-format files with another implementation. |

Operations that perform I/O return `IO(Result<…>)`. Use `IO.try` to stop on failure or match on `Fail{(code, message)}` to handle one. See the [round-trip example](examples/roundtrip.bend).

Both codecs support flat nullable booleans, signed and unsigned integers of 8, 16, 32, and 64 bits, 32- and 64-bit floating point, UTF-8 strings, and binary data. A 64-bit cell stores its high and low 32-bit words. Table constructors also include 128-bit integer cells, which are outside the supported interchange profile.

The Parquet writer emits an uncompressed file with PLAIN data pages (version 1) and RLE definition levels. The reader handles multiple row groups and pages, required and optional fields, PLAIN or dictionary encoding, and uncompressed or Snappy-compressed data. Nested schemas, other compression codecs, and data page version 2 are outside this profile. The Parquet and IPC file APIs materialize their input and accept files smaller than 2 GiB.

Arrow interchange uses the little-endian, uncompressed V5 IPC **stream** format. PyArrow callers can use `pyarrow.ipc.open_stream` and `pyarrow.ipc.new_stream`. The reader combines incoming record batches, including zero-row batches. Nested types, dictionary arrays, custom metadata, IPC file-format containers, and the former in-process C callback interface are outside this API. See the [Arrow IPC specification](https://arrow.apache.org/docs/format/Columnar.html#serialization-and-interprocess-communication-ipc) and [Parquet format](https://github.com/apache/parquet-format).

## Verification

`make test` runs the Bend SQL, connection, transaction, Parquet, and IPC tests and the round-trip example. Tests read checked-in binary fixtures produced by PyArrow and the earlier DuckDB-backed example, so running them requires only the Bend toolchain and Make.

## License

[MIT](LICENSE). Historical third-party acknowledgements are in [licenses/NOTICE](licenses/NOTICE).
