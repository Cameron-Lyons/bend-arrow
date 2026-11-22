# bend-arrow

Use embedded DuckDB from a native Bend program to query Parquet, work with typed rows, and exchange record batches with other Arrow libraries in the same process.

## Run the example

Requires Bend 2.0.40, Clang, Make, Bash, curl, and unzip. From this directory, run

```sh
make
./build/roundtrip /tmp/scores.parquet
make test
```

The example writes four rows (including a null score), filters the Parquet file, transfers the result through an Arrow stream into a temporary table, and prints `Score total: 19`. Supply a fresh output path to keep existing files.

The first build downloads the official DuckDB 1.5.6 C library and checks its SHA-256. The fetch script has pins for Linux x86-64 and ARM64 and for macOS. To use a local copy of this version, set `DUCKDB_DIR` to the directory containing `duckdb.h` and the shared library. The binding uses Bend's native effects. JavaScript execution, including the default interpreter lane, returns an error directing the caller to the native build.

Compile another Bend entry point with the same runtime and link settings using

```sh
./scripts/build path/to/program.bend ./my-program
./my-program
```

The executable records the local paths to the bridge and DuckDB shared libraries. Rebuild it if you move the project.

## Bend API

Import the modules relative to your program. The complete [round-trip example](examples/roundtrip.bend) includes imports, error handling, and a pattern match on a query result. Each database or stream operation returns an `IO(Result<…>)`. Use `IO.try` to exit on failure or match on `Fail{(code, message)}` to recover.

| Operation | Result |
| --- | --- |
| `DB.memory()`, `DB.open(path)` | Open an in-memory or file-backed connection. |
| `DB.exec(db, sql)` | Execute SQL on that connection. |
| `DB.query(db, sql)` | Return a `DB.Table` with ordered columns, SQL type names, and rows of typed cells. |
| `DB.close(db)` | Close the connection. Further calls with that token fail. |
| `Parquet.scan(path)` | Build a quoted `read_parquet(…)` expression for use after `FROM` in SQL. DuckDB supports glob patterns here. |
| `Parquet.read(db, path)` / `Parquet.read_arrow(db, path)` | Read a Parquet file into a Bend table or an Arrow stream. |
| `Parquet.write(db, query, path)` | Write the result of a trusted query to Parquet. Omit the trailing SQL semicolon. |
| `Arrow.query(db, sql)` | Materialize the SQL result and expose it as an affine `Arrow.Stream`. Record batches are converted as the consumer requests them. |
| `Arrow.into_table(db, name, stream)` | Consume the remaining stream into a new temporary table on the destination connection. The stream is released on success and failure. |
| `Arrow.close(stream)` | Release a stream you do not consume. |

For example, inside a Bend `do IO<Unit>` block

```python
+db : DB.Connection <- IO.try(DB.Connection, DB.memory())
sql : String = "SELECT region, sum(amount) AS total FROM " ++ Parquet.scan("sales.parquet") ++ " GROUP BY region"
totals : Arrow.Stream <- IO.try(Arrow.Stream, Arrow.query(db, sql))
IO.try(Unit, Arrow.into_table(db, "totals", totals))
IO.try(Unit, Parquet.write(db, "SELECT * FROM totals ORDER BY region", "totals.parquet"))
IO.try(Unit, DB.close(db))
```

`DB.query` supports nulls, booleans, signed and unsigned integers through 128 bits, floats, doubles, UTF-8 strings, and blobs. Bend stores 64-bit integers and doubles as two exact 32-bit words and 128-bit integers as four, most significant word first. Signed integers use two's complement. For decimals, dates, timestamps, and nested columns, use `Arrow.query` or `Parquet.read_arrow` to preserve DuckDB's Arrow representation. Requesting these types as Bend cells returns an error. The database calls run synchronously on Bend's native IO loop.

## Exchange streams with native code

The shared library built by `make native` exposes the standard Arrow C Data and C Stream structures. Both sides use the same process and library instance. A stream yields a struct `ArrowSchema` and independently owned `ArrowArray` batches. A successful `get_next` with a null release callback marks the end, including for an empty result. Release each live schema, batch, and stream once via its own callback.

A custom Bend effect can bridge to another Arrow library using [streams.h](native/streams.h).

- To export a Bend stream, destructure `Arrow.StreamId{id}` in Bend and pass the ID to the effect. Call `bd_stream_take(id, &stream)` in C to take ownership. Give the stream to the native consumer or release it. Other attempts to take the ID fail.
- To import a foreign stream, call `bd_stream_put(&stream, &id)` in a native effect. On success the producer's stream has moved and its release pointer is null. Return the ID to Bend, wrap it in `Arrow.StreamId{id}`, and pass it to `Arrow.into_table` or `Arrow.close`.

A Bend-created stream retains its source connection through release. It can be imported into another connection after the original Bend handle closes. For direct C use with a caller-owned `duckdb_connection`, see `bd_arrow_query` and `bd_arrow_import` in [arrow.h](native/arrow.h). Keep that source connection live through release of its exported stream. The direct import function borrows the input stream for the call. Both APIs preserve supported column values and types through DuckDB's SQL representation. DuckDB may normalize field names, nullability, extension types, or Arrow-specific metadata when creating the table.

See the [Arrow C Data specification](https://arrow.apache.org/docs/format/CDataInterface.html) and the [Arrow C Stream specification](https://arrow.apache.org/docs/format/CStreamInterface.html).

DuckDB 1.5.6 can read nulls from the wrong positions in lists of dictionary-encoded elements. Decode the element dictionaries before importing sliced or deeply nested lists with nullable indices. For top-level `LIST` and `LARGE_LIST` columns, the bridge returns `EINVAL` when it detects a mismatched window.

## Verification

`make test` checks Arrow imports and exports, concurrent stream transfers and database opens, the Bend bindings, and the Parquet example. To exercise the C ABI against an independent Arrow implementation, run the optional test in a Python environment with PyArrow installed.

```sh
make test-pyarrow PYTHON=/path/to/venv/bin/python
```

The PyArrow test supplies sliced record batches larger than DuckDB's vector size, including a zero-row batch, nullable UTF-8, and nested lists. It checks the values after releasing the result stream and database.

## License

bend-arrow is distributed under the [MIT License](LICENSE). Third-party attributions for Arrow and DuckDB are listed in [licenses/NOTICE](licenses/NOTICE).
