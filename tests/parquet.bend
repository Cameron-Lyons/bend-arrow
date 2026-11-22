import Base
import ../src/table.bend as T
import ../src/file_bytes.bend as Files
import ../src/parquet_read.bend as Reader
import ../src/parquet_hybrid.bend as Hybrid
import ../src/parquet_snappy.bend as Snappy

def expect(test: Bool, description: String) -> IO(Unit):
  match test:
    case True{}: IO.pure(Unit, Unit{})
    case False{}: IO.die(Unit, 1, description)

def failed(-A: Type, result: Result<&1, &1, (U32 & String), A>) -> Bool:
  match result:
    case Fail{_}: True{}
    case _: False{}

# The fixtures were written by PyArrow with its default Snappy and dictionary
# encodings. The first column is required; all other columns are optional.
def expected(i: U32, row: List<&2, T.Cell>) -> Bool:
  match i row:
    case 0 T.Signed{4294967295, 4294967294} <> T.Null{} <> T.Signed{256, 1} <> T.Bytes{0 <> 255 <> Nil{}} <> Nil{}: True{}
    case 1 T.Signed{0, 1} <> T.Utf8{"xy"} <> T.Signed{4294967295, 4294967294} <> T.Bytes{Nil{}} <> Nil{}: True{}
    case 2 T.Signed{0, 2} <> T.Utf8{"Bénd"} <> T.Signed{0, 3} <> T.Null{} <> Nil{}: True{}
    case 3 T.Signed{0, 3} <> T.Utf8{"𝄞"} <> T.Null{} <> T.Bytes{120 <> Nil{}} <> Nil{}: True{}
    case 4 T.Signed{0, 4} <> T.Utf8{""} <> T.Signed{4026531840, 2} <> T.Bytes{121 <> Nil{}} <> Nil{}: True{}
    case 5 T.Signed{0, 5} <> T.Null{} <> T.Null{} <> T.Bytes{102 <> 111 <> 111 <> Nil{}} <> Nil{}: True{}
    case _ _: False{}

def check_cells(rows: List<&2, List<&2, T.Cell>>, +i: U32) -> Bool:
  match rows:
    case Nil{}: U32.is_eq(i, 6)
    case row <> rest: expected(i, row) && check_cells(rest, (i + 1 : U32))

def check_rows(table: T.Table) -> Bool:
  match table:
    case T.Table{T.Column{"a", "INTEGER"} <> T.Column{"β", "VARCHAR"} <> T.Column{"C", "BIGINT"} <> T.Column{"b", "BLOB"} <> Nil{}, rows}:
      check_cells(rows, 0)
    case _: False{}

def primitives(row: List<&2, T.Cell>, b: Bool) -> Bool:
  match row:
    case T.Signed{4294967295, 4294967168} <> T.Unsigned{0, 255} <> T.Signed{4294967295, 4294934528} <> T.Unsigned{0, 65535} <> T.Unsigned{0, 4294967295} <> T.Unsigned{4294967295, 4294967295} <> T.Float{x} <> T.Double{1086324800, 0} <> T.Boolean{actual} <> Nil{}:
      F32.is_eq(x, (0.0 - 1.25 : F32)) && Bool.not(Bool.xor(actual, b))
    case _: False{}

def primitive_table(table: T.Table) -> Bool:
  match table:
    case T.Table{_, first <> (T.Null{} <> T.Null{} <> T.Null{} <> T.Null{} <> T.Null{} <> T.Null{} <> T.Null{} <> T.Null{} <> T.Null{} <> Nil{}) <> last <> Nil{}}:
      primitives(first, True{}) && primitives(last, False{})
    case _: False{}

def empty_table(table: T.Table) -> Bool:
  match table:
    case T.Table{T.Column{"x", "INTEGER"} <> T.Column{"s", "VARCHAR"} <> Nil{}, Nil{}}: True{}
    case _: False{}

def legacy_rows(rows: List<&2, List<&2, T.Cell>>) -> Bool:
  match rows:
    case (T.Utf8{"Ada"} <> T.Signed{0, 12} <> Nil{}) <> (T.Utf8{"Lin"} <> T.Signed{0, 7} <> Nil{}) <> (T.Utf8{"Ada"} <> T.Null{} <> Nil{}) <> (T.Utf8{"Eli"} <> T.Signed{0, 3} <> Nil{}) <> Nil{}: True{}
    case _: False{}

# Captured from the original DuckDB 1.5.6 round-trip example. Its optional
# score column stores four definition levels in a padded 256-value packed run.
def legacy_scores(table: T.Table) -> Bool:
  match table:
    case T.Table{T.Column{"name", "VARCHAR"} <> T.Column{"score", "INTEGER"} <> Nil{}, rows}:
      legacy_rows(rows)
    case _: False{}

def damaged(bytes: List<&2, U32>) -> List<&2, U32>:
  match bytes:
    case a <> b <> c <> d <> _ <> tail: a <> b <> c <> d <> 255 <> tail
    case _: Nil{}

def main() -> IO(Unit):
  do IO<Unit>:
    +bytes : Files.Bytes <- IO.try(Files.Bytes, Files.read("tests/fixtures/flat-snappy.parquet"))
    table : T.Table <- IO.try(T.Table, IO.pure(Files.Outcome(T.Table), Reader.decode(bytes)))
    expect(check_rows(table), "Snappy dictionary values, validity, or row-group order changed")
    raw : Files.Bytes <- IO.try(Files.Bytes, Files.read("tests/fixtures/primitive-types.parquet"))
    typed : T.Table <- IO.try(T.Table, IO.pure(Files.Outcome(T.Table), Reader.decode(raw)))
    expect(primitive_table(typed), "numeric widths, floating-point words or packed booleans changed")
    empty : Files.Bytes <- IO.try(Files.Bytes, Files.read("tests/fixtures/empty-snappy.parquet"))
    table : T.Table <- IO.try(T.Table, IO.pure(Files.Outcome(T.Table), Reader.decode(empty)))
    expect(empty_table(table), "empty dictionary-only chunks lost their schema")
    legacy : Files.Bytes <- IO.try(Files.Bytes, Files.read("tests/fixtures/duckdb-scores.parquet"))
    scores : T.Table <- IO.try(T.Table, IO.pure(Files.Outcome(T.Table), Reader.decode(legacy)))
    expect(legacy_scores(scores), "DuckDB padded definition levels changed scores or nulls")
    expect(failed(Files.Bytes, Hybrid.decode(1, 1, [5, 1])), "truncated padded run was accepted")
    expect(failed(Files.Bytes, Hybrid.decode(1, 1, [5, 1, 0, 2, 1])), "extra run after padded final run was accepted")
    expect(failed(T.Table, Reader.decode(damaged(bytes))), "invalid dictionary page header was accepted")
    expect(failed(T.Table, Reader.decode([80, 65, 82, 49, 255, 255, 255, 255, 80, 65, 82, 49])), "invalid footer length was accepted")
    expect(failed(Files.Bytes, Hybrid.decode(1, 1, [2, 2])), "out-of-range RLE value was accepted")
    expect(failed(Files.Bytes, Hybrid.decode(2, 7, [3, 1])), "truncated packed values were accepted")
    expect(failed(Files.Bytes, Snappy.decode(4, [4, 1, 0])), "invalid Snappy back-reference was accepted")
    IO.print("Parquet interoperability passed")
