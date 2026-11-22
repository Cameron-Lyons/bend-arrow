import Base
import ../src/duckdb.bend as DB
import ../src/arrow.bend as Arrow
import ../src/parquet.bend as Parquet

def expect(ok: Bool, message: String) -> IO(Unit):
  match ok:
    case True{}: IO.pure(Unit, Unit{})
    case False{}: IO.die(Unit, 1, message)

def failed(-A: Type, r: Result<&1, &1, (U32 & String), A>) -> Bool:
  match r:
    case Fail{(_, SCon{_, _})}: True{}
    case _: False{}

def scalar(table: DB.Table, expected: U32) -> Bool:
  match table:
    case DB.Table{_, (DB.Signed{0, x} <> Nil{}) <> Nil{}}:
      U32.is_eq(x, expected)
    case _: False{}

def empty(table: DB.Table) -> Bool:
  match table:
    case DB.Table{DB.Column{name, sql_type} <> Nil{}, Nil{}}:
      String.eq(name, "amount") && String.eq(sql_type, "BIGINT")
    case _: False{}

def json_column(table: DB.Table) -> Bool:
  match table:
    case DB.Table{DB.Column{_, t} <> Nil{}, (DB.Utf8{value} <> Nil{}) <> Nil{}}:
      String.eq(t, "JSON") && String.eq(value, "[42]")
    case _: False{}

def values(table: DB.Table) -> Bool:
  match table:
    case DB.Table{_, (DB.Null{} <> DB.Boolean{True{}} <> DB.Signed{4294967295, 4294967294} <> DB.Unsigned{4294967295, 4294967295} <> DB.Float{f} <> DB.Double{1073217536, 0} <> DB.Utf8{s} <> DB.Bytes{0 <> 255 <> Nil{}} <> Nil{}) <> Nil{}}:
      F32.is_eq(f, 2.5) && String.eq(s, "Bénd" ++ SCon{Chr{0}, "!"})
    case _: False{}

def wide_values(table: DB.Table) -> Bool:
  match table:
    case DB.Table{_, (DB.WideSigned{4294967295, 4294967295, 4294967295, 4294967294} <> DB.WideUnsigned{1, 2, 3, 4} <> Nil{}) <> Nil{}}:
      True{}
    case _: False{}

def valid_marker(marker: DB.Cell, row: U32) -> Bool:
  match marker:
    case DB.Null{}: U32.is_eq((row % 64 : U32), 63)
    case DB.Signed{0, +n}: U32.is_eq(n, row) && U32.is_ne((n % 64 : U32), 63)
    case _: False{}

def in_order(rows: List<&2, List<&2, DB.Cell>>, +expected: U32) -> Bool:
  match rows:
    case Nil{}: U32.is_eq(expected, 5000)
    case (DB.Signed{0, value} <> marker <> Nil{}) <> rest:
      U32.is_eq(value, expected) && valid_marker(marker, expected) && in_order(rest, (expected + 1 : U32))
    case _: False{}

def check_order(table: DB.Table) -> Bool:
  DB.Table{_, rows} = table
  in_order(rows, 0)

def main() -> IO(Unit):
  do IO<Unit>:
    +src : DB.Connection <- IO.try(DB.Connection, DB.memory())
    +dst : DB.Connection <- IO.try(DB.Connection, DB.memory())
    json : DB.Table <- IO.try(DB.Table, DB.query(src, "SELECT '[42]'::JSON"))
    expect(json_column(json), "JSON column lost its SQL type or value")
    expect(String.eq(Parquet.path_literal("'a''β'"), "'''a''''β'''"), "incorrect SQL path quoting")
    table : DB.Table <- IO.try(DB.Table, DB.query(src, "SELECT NULL::INTEGER, true, -2::BIGINT, 18446744073709551615::UBIGINT, 2.5::FLOAT, 1.5::DOUBLE, 'Bénd' || chr(0) || '!', from_hex('00ff')"))
    expect(values(table), "Bend cells lost type, precision or bytes")
    empty_table : DB.Table <- IO.try(DB.Table, DB.query(src, "SELECT 0::BIGINT AS amount WHERE false"))
    expect(empty(empty_table), "empty result lost its schema")
    wide : DB.Table <- IO.try(DB.Table, DB.query(src, "SELECT -2::HUGEINT, (1::UHUGEINT << 96) + (2::UHUGEINT << 64) + (3::UHUGEINT << 32) + 4"))
    expect(wide_values(wide), "128-bit integer words changed")
    unsupported : Result<&1, &1, (U32 & String), DB.Table> <- DB.query(src, "SELECT current_date, 42")
    expect(failed(DB.Table, unsupported), "unsupported scalar type was accepted")
    ordered : DB.Table <- IO.try(DB.Table, DB.query(src, "SELECT i, CASE WHEN i%64<>63 THEN i END FROM range(5000) t(i) ORDER BY i"))
    expect(check_order(ordered), "row order or null validity changed across a chunk")
    invalid : Result<&1, &1, (U32 & String), DB.Table> <- DB.query(src, "SELECT missing_column")
    expect(failed(DB.Table, invalid), "expected a SQL error")
    missing : Result<&1, &1, (U32 & String), DB.Table> <- Parquet.read(src, "missing/unknown.parquet")
    expect(failed(DB.Table, missing), "expected a missing file error")
    bad : Result<&1, &1, (U32 & String), Unit> <- DB.exec(src, "SELECT 1" ++ SCon{Chr{0}, ";"})
    expect(failed(Unit, bad), "embedded NUL in SQL was ignored")
    s : Arrow.Stream <- IO.try(Arrow.Stream, Arrow.query(src, "SELECT i FROM range(11000) t(i)"))
    discard : Arrow.Stream <- IO.try(Arrow.Stream, Arrow.query(src, "SELECT 1"))
    IO.try(Unit, Arrow.close(discard))
    IO.try(Unit, DB.close(src))
    stale : Result<&1, &1, (U32 & String), Unit> <- DB.exec(src, "SELECT 1")
    expect(failed(Unit, stale), "closed token still accepted")
    IO.try(Unit, Arrow.into_table(dst, "d\"ata", s))
    count : DB.Table <- IO.try(DB.Table, DB.query(dst, "SELECT count(*) FROM \"d\"\"ata\""))
    expect(scalar(count, 11000), "multi-batch transfer after connection close lost rows")
    replacement : Arrow.Stream <- IO.try(Arrow.Stream, Arrow.query(dst, "SELECT 1 AS i"))
    collision : Result<&1, &1, (U32 & String), Unit> <- Arrow.into_table(dst, "d\"ata", replacement)
    expect(failed(Unit, collision), "import replaced an existing table")
    sum : DB.Table <- IO.try(DB.Table, DB.query(dst, "SELECT sum(i)::BIGINT FROM \"d\"\"ata\""))
    expect(scalar(sum, 60494500), "import changed existing rows")
    IO.try(Unit, DB.close(dst))
    IO.print("Bend bindings passed")
