import Base
import ../src/table.bend as T
import ../src/file_bytes.bend as F
import ../src/ipc_read.bend as IPCReader
import ../src/ipc_write.bend as IPCWriter
import ../src/parquet_read.bend as ParquetReader
import ../src/parquet_write.bend as ParquetWriter

# Optional cross-implementation test driver; not needed by the Bend-only suite.
def decode(format: String, bytes: F.Bytes) -> F.Outcome(T.Table):
  match format:
    case "ipc": IPCReader.decode(bytes)
    case "parquet": ParquetReader.decode(bytes)
    case _: Fail{(22, "expected ipc or parquet")}

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> format <> input <> +output <> Nil{}:
      do IO<Unit>:
        bytes : F.Bytes <- IO.try(F.Bytes, F.read(input))
        +table : T.Table <- IO.try(T.Table, IO.pure(F.Outcome(T.Table), decode(format, bytes)))
        IO.try(Unit, F.create(output ++ ".arrows", IPCWriter.encode(table)))
        IO.try(Unit, F.create(output ++ ".parquet", ParquetWriter.encode(table)))
    case _: IO.die(Unit, 2, "usage: ipc-interop <ipc|parquet> <input> <fresh-output-prefix>")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
