import Base
import ./duckdb.bend as DB
import ./arrow.bend as Arrow

# Double single quotes inside a DuckDB string literal. Backslashes and UTF-8
# characters retain their ordinary meaning in a standard SQL string literal.
def path_literal(path: String) -> String:
  "'" ++ String.join(String.split(path, Chr{39}), "''") ++ "'"

# A table expression for use after FROM. DuckDB also accepts glob patterns.
def scan(path: String) -> String:
  "read_parquet(" ++ path_literal(path) ++ ")"

def select_sql(path: String) -> String:
  "SELECT * FROM " ++ scan(path)

# query is a trusted SELECT expression without a trailing semicolon.
def write_sql(query: String, path: String) -> String:
  "COPY (" ++ query ++ "\n) TO " ++ path_literal(path) ++ " (FORMAT PARQUET)"

def read(db: DB.Connection, path: String) -> IO(Result<&1, &1, (U32 & String), DB.Table>):
  DB.query(db, select_sql(path))

def read_arrow(db: DB.Connection, path: String) -> IO(Result<&1, &1, (U32 & String), Arrow.Stream>):
  Arrow.query(db, select_sql(path))

def write(db: DB.Connection, query: String, path: String) -> IO(Result<&1, &1, (U32 & String), Unit>):
  DB.exec(db, write_sql(query, path))
