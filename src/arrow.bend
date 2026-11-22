import Base
import ./table.bend as T
import ./duckdb.bend as DB
import ./file_bytes.bend as F
import ./ipc_write.bend as Writer
import ./ipc_read.bend as Reader

# The affine value owns its materialized result independently of a connection.
type Stream is Type:
  Stream{table: T.Table}

def wrap(r: F.Outcome(T.Table)) -> F.Outcome(Stream):
  match r:
    case Fail{err}: Fail{err}
    case Done{table}: Done{Stream{table}}

def query(db: DB.Connection, sql: String) -> IO(F.Outcome(Stream)):
  do IO<F.Outcome(Stream)>:
    result : F.Outcome(T.Table) <- DB.query(db, sql)
    return wrap(result)

def into_table(db: DB.Connection, name: String, stream: Stream) -> IO(F.Outcome(Unit)):
  Stream{table} = stream
  DB.register(db, name, table)

type Step is Type:
  End{}
  Next{batch: T.Table, rest: Stream}

def partition(cols: List<&2, T.Column>, part: T.RowBatch) -> Step:
  T.RowBatch{rows, tail} = part
  +schema = cols
  Next{T.Table{schema, rows}, Stream{T.Table{schema, tail}}}

def next(stream: Stream) -> Step:
  match stream:
    case Stream{T.Table{_, Nil{}}}: End{}
    case Stream{T.Table{cols, rows}}: partition(cols, T.take_rows(rows, T.batch_size(), Nil{}))

def close(stream: Stream) -> IO(F.Outcome(Unit)):
  IO.pure(F.Outcome(Unit), Done{Unit{}})

def write(stream: Stream, path: String) -> IO(F.Outcome(Unit)):
  Stream{table} = stream
  F.create(path, Writer.encode(table))

def decoded(r: F.Outcome(F.Bytes)) -> F.Outcome(Stream):
  wrap(Result.bind(&1, &1, U32 & String, F.Bytes, T.Table, r, x => Reader.decode(x)))

def read(path: String) -> IO(F.Outcome(Stream)):
  do IO<F.Outcome(Stream)>:
    bytes : F.Outcome(F.Bytes) <- F.read(path)
    return decoded(bytes)
