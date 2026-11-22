import Base
import ../src/table.bend as T
import ../src/file_bytes.bend as FileBytes
import ../src/utf8.bend as UTF8
import ../src/arrow_layout.bend as Layout
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

# PyArrow wrote two dictionaries, appended "green" with a delta, then
# replaced both dictionaries. The score dictionary itself contains a null.
def check_dictionaries(external: F.Bytes) -> F.R(Unit):
  cols : List<&2, T.Column> = [T.Column{"label", "VARCHAR"}, T.Column{"score", "INTEGER"}]
  rows : T.Rows = [[T.Utf8{"blue"}, T.Null{}], [T.Null{}, T.Signed{0, 40}], [T.Utf8{"red"}, T.Signed{0, 40}],
    [T.Utf8{"green"}, T.Signed{0, 40}], [T.Utf8{"blue"}, T.Null{}], [T.Utf8{"new"}, T.Signed{0, 7}]]
  do F.R<Unit>:
    t : T.Table <- Reader.decode(external)
    actual : F.Bytes <- Writer.encode(t)
    expected : F.Bytes <- Writer.encode(T.Table{cols, rows})
    F.check(equal_bytes(actual, expected), "PyArrow dictionary values differ")

def index_record(row: List<&2, T.Cell>) -> F.R(F.Bytes):
  cols : List<&2, T.Column> = [T.Column{"label", "TINYINT"}, T.Column{"score", "USMALLINT"}]
  do F.R<F.Bytes>:
    batch : Writer.Batch <- Writer.columns(cols, [row])
    return Writer.record(batch, 1)

def null_dictionary_row(table: T.Table) -> Bool:
  match table:
    case T.Table{_, (T.Null{} <> T.Null{} <> Nil{}) <> Nil{}}: True{}
    case _: False{}

def check_keys(+external: F.Bytes) -> F.R(Unit):
  do F.R<Unit>:
    # A stream may carry an entirely null record before the dictionaries.
    header : F.Bytes <- F.drop(external, 4)
    size : U32 <- F.u32(header)
    schema : F.Span <- F.split(external, (8 + size : U32))
    +initial : F.Bytes = F.head(schema)
    nulls : F.Bytes <- index_record([T.Null{}, T.Null{}])
    t : T.Table <- Reader.decode(List.append(&2, U32, initial, nulls))
    F.check(null_dictionary_row(t), "lost null indices preceding their dictionaries")
    used : F.Bytes <- index_record([T.Signed{0, 0}, T.Null{}])
    rejected(Reader.decode(List.append(&2, U32, initial, used)))
    # Add a batch after the fixture's replacements, before its EOS marker.
    backwards : F.Bytes <- F.drop(List.reverse(&2, U32, external), 8)
    +prior : F.Bytes = List.reverse(&2, U32, backwards)
    negative : F.Bytes <- index_record([T.Signed{4294967295, 4294967295}, T.Null{}])
    rejected(Reader.decode(List.append(&2, U32, prior, negative)))
    past_end : F.Bytes <- index_record([T.Null{}, T.Unsigned{0, 1}])
    rejected(Reader.decode(List.append(&2, U32, prior, past_end)))

def empty_rows(t: T.Table) -> Bool:
  match t:
    case T.Table{Nil{}, Nil{} <> Nil{} <> Nil{}}: True{}
    case _: False{}

def check_zero_columns() -> F.R(Unit):
  do F.R<Unit>:
    bytes : F.Bytes <- Writer.encode(T.Table{Nil{}, [Nil{}, Nil{}]})
    result : T.Table <- Reader.decode(bytes)
    F.check(empty_rows(result), "zero-column record batch lost rows")

# PyArrow 26.0.1 wrote the same 14 rows using legacy V4 and modern V5 framing.
# Both schemas have binary-valued field metadata and a pandas metadata key.
# The V5 record batch carries its own application metadata.
def metadata_rows(n: Nat, +i: U32) -> T.Rows:
  match n:
    case 0n: Nil{}
    case 1n+k:
      id = Bool.pick(T.Cell, U32.is_eq((i % 4 : U32), 2), T.Null{}, T.Signed{0, i})
      ok = Bool.pick(T.Cell, U32.is_eq((i % 5 : U32), 3), T.Null{}, T.Boolean{U32.is_even(i)})
      [id, ok] <> metadata_rows(k, U32.inc(i))

def check_metadata(stream: F.Bytes) -> F.R(Unit):
  expected : T.Table = T.Table{[T.Column{"id", "INTEGER"}, T.Column{"ok", "BOOLEAN"}], metadata_rows(14n, 0)}
  do F.R<Unit>:
    table : T.Table <- Reader.decode(stream)
    actual : F.Bytes <- Writer.encode(table)
    wanted : F.Bytes <- Writer.encode(expected)
    F.check(equal_bytes(actual, wanted), "application metadata changed table values")

def overwrite(bs: F.Bytes, position: U32, +replacement: F.Bytes) -> F.R(F.Bytes):
  do F.R<F.Bytes>:
    +parts : F.Span <- F.split(bs, position)
    rest : F.Bytes <- F.drop(F.tail(parts), Layout.length(U32, replacement))
    return Writer.chunks([F.head(parts), replacement, rest])

def rejected_with(result: F.R(T.Table), message: String) -> F.R(Unit):
  match result:
    case Fail{(22, +why)}: F.check(String.eq(why, "Arrow IPC: " ++ message), why)
    case _: F.fail(Unit, "invalid IPC metadata was accepted")

def check_metadata_errors(+stream: F.Bytes) -> F.R(Unit):
  do F.R<Unit>:
    # Replace the fixture's 20-byte field key with an extension declaration.
    name : F.Bytes <- UTF8.encode("ARROW:extension:name")
    extension : F.Bytes <- overwrite(stream, 264, name)
    rejected_with(Reader.decode(extension), "unsupported metadata key ARROW:extension:name")
    # Change the batch metadata version to V4 and turn its application key
    # into the old experimental body-compression marker.
    v4 : F.Bytes <- overwrite(stream, 350, [3])
    marker : F.Bytes <- UTF8.encode("ARROW")
    compressed : F.Bytes <- overwrite(v4, 408, marker)
    rejected_with(Reader.decode(compressed), "unsupported metadata key ARROW:experimental_compression")
    # Shorten the declared 80-byte body while leaving the physical bytes and
    # next frame intact. A buffer may never consume either as part of its data.
    short : F.Bytes <- overwrite(stream, 360, [72])
    rejected_with(Reader.decode(short), "buffer extends past message body")
    unterminated : F.Bytes <- overwrite(stream, 98, [1])
    rejected_with(Reader.decode(unterminated), "unterminated string")

# Shorten descriptors while leaving their bytes in the stream. Array decoders
# must honor each declared length even when enough padding or data follows.
def check_buffer_bounds(+metadata: F.Bytes, +scalars: F.Bytes) -> F.R(Unit):
  do F.R<Unit>:
    bitmap : F.Bytes <- overwrite(metadata, 536, [1])
    rejected_with(Reader.decode(bitmap), "truncated bitmap")
    fixed : F.Bytes <- overwrite(metadata, 504, [55])
    rejected_with(Reader.decode(fixed), "truncated primitive array")
    offsets : F.Bytes <- overwrite(scalars, 1184, [12])
    rejected_with(Reader.decode(offsets), "truncated variable-width offsets")
    text : F.Bytes <- overwrite(scalars, 1200, [6])
    rejected_with(Reader.decode(text), "invalid variable-width offset")

def check_corrupt(+external: F.Bytes) -> F.R(Unit):
  do F.R<Unit>:
    rejected(Reader.decode([255, 255, 255, 255, 8, 0, 0, 0, 254, 255, 255, 255, 0, 0, 0, 0]))
    rejected(Reader.decode(List.append(&2, U32, external, [0])))
    remaining : F.Bytes <- F.drop(List.reverse(&2, U32, external), 17)
    rejected(Reader.decode(List.reverse(&2, U32, remaining)))

def main() -> IO(Unit):
  do IO<Unit>:
    +bytes : F.Bytes <- IO.try(F.Bytes, FileBytes.read("tests/fixtures/pyarrow-v5.arrows"))
    +dictionaries : F.Bytes <- IO.try(F.Bytes, FileBytes.read("tests/fixtures/pyarrow-dictionaries.arrows"))
    +metadata : F.Bytes <- IO.try(F.Bytes, FileBytes.read("tests/fixtures/pyarrow-metadata.arrows"))
    legacy : F.Bytes <- IO.try(F.Bytes, FileBytes.read("tests/fixtures/pyarrow-legacy-v4.arrows"))
    IO.try(Unit, IO.pure(F.R(Unit), check_stream(bytes)))
    IO.try(Unit, IO.pure(F.R(Unit), check_dictionaries(dictionaries)))
    IO.try(Unit, IO.pure(F.R(Unit), check_keys(dictionaries)))
    IO.try(Unit, IO.pure(F.R(Unit), check_corrupt(bytes)))
    IO.try(Unit, IO.pure(F.R(Unit), check_zero_columns()))
    IO.try(Unit, IO.pure(F.R(Unit), check_metadata(metadata)))
    IO.try(Unit, IO.pure(F.R(Unit), check_metadata(legacy)))
    IO.try(Unit, IO.pure(F.R(Unit), check_metadata_errors(metadata)))
    IO.try(Unit, IO.pure(F.R(Unit), check_buffer_bounds(metadata, bytes)))
    IO.print("Arrow IPC interoperability passed")
