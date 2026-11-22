import Base
import ./duckdb.bend as DB

# Affine, process-local ownership of an ArrowArrayStream. Move the stream
# into another effect, import it as a table, or close it explicitly.
type Stream is Type:
  StreamId{id: U32}

def query_id(db: U32, sql: String) -> IO(Result<&1, &1, (U32 & String), U32>):
  import "./arrow_effects.c"
  import "./arrow_effects.js"

def wrap(result: Result<&1, &1, (U32 & String), U32>) -> Result<&1, &1, (U32 & String), Stream>:
  match result:
    case Done{id}:
      Done{StreamId{id}}
    case Fail{error}:
      Fail{error}

def query(db: DB.Connection, sql: String) -> IO(Result<&1, &1, (U32 & String), Stream>):
  DB.ConnectionId{id} = db
  do IO<Result<&1, &1, (U32 & String), Stream>>:
    result : Result<&1, &1, (U32 & String), U32> <- query_id(id, sql)
    return wrap(result)

def import_id(db: U32, name: String, stream: U32) -> IO(Result<&1, &1, (U32 & String), Unit>):
  import "./arrow_effects.c"
  import "./arrow_effects.js"

# Consume the stream, including on error. Create a connection-local temp table.
def into_table(db: DB.Connection, name: String, stream: Stream) -> IO(Result<&1, &1, (U32 & String), Unit>):
  DB.ConnectionId{db_id} = db
  StreamId{stream_id} = stream
  import_id(db_id, name, stream_id)

def close_id(id: U32) -> IO(Result<&1, &1, (U32 & String), Unit>):
  import "./arrow_effects.c"
  import "./arrow_effects.js"

def close(stream: Stream) -> IO(Result<&1, &1, (U32 & String), Unit>):
  StreamId{id} = stream
  close_id(id)
