import Base

# Connections are explicit resources. Copies of a closed connection fail with EBADF.
type Connection is Data:
  ConnectionId{id: U32}

# The high and low words preserve every bit of 64-bit numbers, including signed
# two's-complement integers and IEEE 754 binary64 values.
type Cell is Data:
  Null{}
  Boolean{value: Bool}
  Signed{upper: U32, lower: U32}
  Unsigned{upper: U32, lower: U32}
  WideSigned{a: U32, b: U32, c: U32, d: U32}
  WideUnsigned{a: U32, b: U32, c: U32, d: U32}
  Float{value: F32}
  Double{upper: U32, lower: U32}
  Utf8{value: String}
  Bytes{value: List<&2, U32>}

type Column is Data:
  Column{name: String, sql_type: String}

type Table is Data:
  Table{columns: List<&2, Column>, rows: List<&2, List<&2, Cell>>}

def open_id(path: String) -> IO(Result<&1, &1, (U32 & String), U32>):
  import "./engine_effects.c"
  import "./engine_effects.js"

def opened(r: Result<&1, &1, (U32 & String), U32>) -> Result<&1, &1, (U32 & String), Connection>:
  match r:
    case Fail{err}:
      Fail{err}
    case Done{id}:
      Done{ConnectionId{id}}

def open(path: String) -> IO(Result<&1, &1, (U32 & String), Connection>):
  do IO<Result<&1, &1, (U32 & String), Connection>>:
    r : Result<&1, &1, (U32 & String), U32> <- open_id(path)
    return opened(r)

def memory() -> IO(Result<&1, &1, (U32 & String), Connection>):
  open(":memory:")

def exec_id(id: U32, sql: String) -> IO(Result<&1, &1, (U32 & String), Unit>):
  import "./engine_effects.c"
  import "./engine_effects.js"

def exec(db: Connection, sql: String) -> IO(Result<&1, &1, (U32 & String), Unit>):
  ConnectionId{id} = db
  exec_id(id, sql)

def query_id(id: U32, sql: String) -> IO(Result<&1, &1, (U32 & String), Table>):
  import "./engine_effects.c"
  import "./engine_effects.js"

def query(db: Connection, sql: String) -> IO(Result<&1, &1, (U32 & String), Table>):
  ConnectionId{id} = db
  query_id(id, sql)

def close_id(id: U32) -> IO(Result<&1, &1, (U32 & String), Unit>):
  import "./engine_effects.c"
  import "./engine_effects.js"

def close(db: Connection) -> IO(Result<&1, &1, (U32 & String), Unit>):
  ConnectionId{id} = db
  close_id(id)
