import Base
import ../src/table.bend as T
import ../src/file_bytes.bend as FileBytes
import ../src/ipc_flatbuffer.bend as F
import ../src/ipc_read.bend as Reader
import ../src/ipc_write.bend as Writer
import ../src/parquet_write.bend as ParquetWriter
import ../src/parquet_read.bend as ParquetReader

# The fixture was made by PyArrow 26.0.1 using ipc.new_stream and write_batch.
# The source batch contains lower bounds, upper bounds and nulls. PyArrow
# wrote that batch, a zero-row slice, and a slice containing the last two rows.
def expected() -> T.Table:
  names : List<&2, T.Column> = [T.Column{"bool", "BOOLEAN"}, T.Column{"int8", "TINYINT"}, T.Column{"int16", "SMALLINT"},
           T.Column{"int32", "INTEGER"}, T.Column{"int64", "BIGINT"}, T.Column{"uint8", "UTINYINT"},
           T.Column{"uint16", "USMALLINT"}, T.Column{"uint32", "UINTEGER"}, T.Column{"uint64", "UBIGINT"},
           T.Column{"float", "FLOAT"}, T.Column{"double", "DOUBLE"}, T.Column{"string", "VARCHAR"}, T.Column{"binary", "BLOB"}]
  lower : List<&2, T.Cell> = [T.Boolean{True{}}, T.Signed{4294967295, 4294967168}, T.Signed{4294967295, 4294934528},
           T.Signed{4294967295, 2147483648}, T.Signed{2147483648, 0}, T.Unsigned{0, 0}, T.Unsigned{0, 0},
           T.Unsigned{0, 0}, T.Unsigned{0, 0}, T.Float{1.25}, T.Double{1072955392, 0}, T.Utf8{"☃🙃"}, T.Bytes{[0,255]}]
  +upper : List<&2, T.Cell> = [T.Boolean{False{}}, T.Signed{0, 127}, T.Signed{0, 32767}, T.Signed{0, 2147483647},
            T.Signed{2147483647, 4294967295}, T.Unsigned{0, 255}, T.Unsigned{0, 65535},
            T.Unsigned{0, 4294967295}, T.Unsigned{4294967295, 4294967295}, T.Float{(0.0 - 0.375 : F32)},
            T.Double{3218604032, 0}, T.Utf8{""}, T.Bytes{Nil{}}]
  +nulls = List.replicate(T.Cell, 13n, T.Null{})
  T.Table{names, [lower, upper, nulls, upper, nulls]}

def equal_bytes(a: F.Bytes, b: F.Bytes) -> Bool:
  match a b:
    case Nil{} Nil{}: True{}
    case h <> t x <> u: U32.is_eq(h, x) && equal_bytes(t, u)
    case _ _: False{}

def rejected(r: F.R(T.Table)) -> F.R(Unit):
  match r:
    case Fail{_}: Done{Unit{}}
    case Done{_}: Fail{(1, "expected malformed Arrow IPC input to fail")}

def check_normalized(encoded: F.Bytes, expected: F.Bytes) -> F.R(Unit):
  do F.R<Unit>:
    reread : T.Table <- Reader.decode(encoded)
    again : F.Bytes <- Writer.encode(reread)
    F.check(equal_bytes(expected, again), "Bend IPC stream failed to round-trip")

def check_parquet(table: T.Table, expected: F.Bytes) -> F.R(Unit):
  do F.R<Unit>:
    parquet : F.Bytes <- ParquetWriter.encode(table)
    restored : T.Table <- ParquetReader.decode(parquet)
    normalized : F.Bytes <- Writer.encode(restored)
    F.check(equal_bytes(expected, normalized), "Parquet changed the scalar schema or values")

def check_stream(external: F.Bytes) -> F.R(Unit):
  do F.R<Unit>:
    +table : T.Table <- Reader.decode(external)
    +wanted : F.Bytes <- Writer.encode(expected())
    +actual : F.Bytes <- Writer.encode(table)
    F.check(equal_bytes(wanted, actual), "PyArrow fixture differs from expected schema or values")
    check_normalized(actual, wanted)
    check_parquet(table, wanted)

def empty_rows(t: T.Table) -> Bool:
  match t:
    case T.Table{Nil{}, Nil{} <> Nil{} <> Nil{}}: True{}
    case _: False{}

def check_zero_columns() -> F.R(Unit):
  do F.R<Unit>:
    bytes : F.Bytes <- Writer.encode(T.Table{Nil{}, [Nil{}, Nil{}]})
    result : T.Table <- Reader.decode(bytes)
    F.check(empty_rows(result), "zero-column record batch lost rows")

def check_corrupt(+external: F.Bytes) -> F.R(Unit):
  do F.R<Unit>:
    rejected(Reader.decode([255, 255, 255, 255, 8, 0, 0, 0, 254, 255, 255, 255, 0, 0, 0, 0]))
    rejected(Reader.decode(List.append(&2, U32, external, [0])))
    remaining : F.Bytes <- F.drop(List.reverse(&2, U32, external), 17)
    rejected(Reader.decode(List.reverse(&2, U32, remaining)))

def main() -> IO(Unit):
  do IO<Unit>:
    +bytes : F.Bytes <- IO.try(F.Bytes, FileBytes.read("tests/fixtures/pyarrow-v5.arrows"))
    IO.try(Unit, IO.pure(F.R(Unit), check_stream(bytes)))
    IO.try(Unit, IO.pure(F.R(Unit), check_corrupt(bytes)))
    IO.try(Unit, IO.pure(F.R(Unit), check_zero_columns()))
    IO.print("Arrow IPC interoperability passed")
