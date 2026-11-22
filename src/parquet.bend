import Base
import ./duckdb.bend as DB
import ./arrow.bend as Arrow
import ./table.bend as T
import ./file_bytes.bend as F
import ./parquet_write.bend as Writer
import ./parquet_read.bend as Reader

# Double single quotes inside a SQL string literal. Backslashes and UTF-8
# characters retain their ordinary meaning in a standard SQL string literal.
def path_literal.tail(path: String) -> String:
  match path:
    case SNil{}: "'"
    case SCon{Chr{39}, t}: SCon{Chr{39}, SCon{Chr{39}, path_literal.tail(t)}}
    case SCon{c, t}: SCon{c, path_literal.tail(t)}

def path_literal(path: String) -> String:
  SCon{Chr{39}, path_literal.tail(path)}

# A table expression for use after FROM.
def scan(path: String) -> String:
  "read_parquet(" ++ path_literal(path) ++ ")"

def select_sql(path: String) -> String:
  "SELECT * FROM " ++ scan(path)

def read_table(path: String) -> IO(F.Outcome(T.Table)):
  do IO<F.Outcome(T.Table)>:
    bytes : F.Outcome(F.Bytes) <- F.read(path)
    return Result.bind(&1, &1, U32 & String, F.Bytes, T.Table, bytes, x => Reader.decode(x))

def write_table(table: T.Table, path: String) -> IO(F.Outcome(Unit)):
  F.create(path, Writer.encode(table))

def read(db: DB.Connection, path: String) -> IO(F.Outcome(T.Table)):
  DB.query(db, select_sql(path))

def read_arrow(db: DB.Connection, path: String) -> IO(F.Outcome(Arrow.Stream)):
  Arrow.query(db, select_sql(path))

def write_result(result: F.Outcome(T.Table), path: String) -> IO(F.Outcome(Unit)):
  match result:
    case Fail{err}: IO.pure(F.Outcome(Unit), Fail{err})
    case Done{table}: write_table(table, path)

def write(db: DB.Connection, query: String, path: String) -> IO(F.Outcome(Unit)):
  do IO<F.Outcome(Unit)>:
    result : F.Outcome(T.Table) <- DB.query(db, query)
    write_result(result, path)
