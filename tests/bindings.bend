import Base
import ../src/duckdb.bend as DB
import ../src/table.bend as T
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

def scalar(table: T.Table, expected: U32) -> Bool:
  match table:
    case T.Table{_, (T.Signed{0, x} <> Nil{}) <> Nil{}}:
      U32.is_eq(x, expected)
    case _: False{}

def empty(table: T.Table) -> Bool:
  match table:
    case T.Table{T.Column{name, sql_type} <> Nil{}, Nil{}}:
      String.eq(name, "amount") && String.eq(sql_type, "BIGINT")
    case _: False{}

def batch_size(table: T.Table, n: U32) -> Bool:
  T.Table{_, rows} = table
  U32.is_eq(n, U32.from_nat(List.length(&2, List<&2, T.Cell>, rows)))

def at_end(step: Arrow.Step) -> IO(Unit):
  match step:
    case Arrow.End{}: IO.pure(Unit, Unit{})
    case _: IO.die(Unit, 1, "stream yielded an extra batch")

def after_first(step: Arrow.Step) -> IO(Unit):
  match step:
    case Arrow.End{}: IO.die(Unit, 1, "expected a second Arrow batch")
    case Arrow.Next{batch, rest}:
      do IO<Unit>:
        expect(batch_size(batch, 1), "wrong final batch size")
        at_end(Arrow.next(rest))

def check_batches(step: Arrow.Step) -> IO(Unit):
  match step:
    case Arrow.End{}: IO.die(Unit, 1, "missing first Arrow batch")
    case Arrow.Next{batch, rest}:
      do IO<Unit>:
        expect(batch_size(batch, 2048), "wrong first batch size")
        after_first(Arrow.next(rest))

def rejects(db: DB.Connection, table: T.Table) -> IO(Unit):
  do IO<Unit>:
    r : Result<&1, &1, U32 & String, Unit> <- DB.register(db, "checked", table)
    expect(failed(Unit, r), "registered a table that disagrees with its schema")

def one_cell(kind: String, value: T.Cell) -> T.Table:
  T.Table{[T.Column{"v", kind}], [[value]]}

def registration(+db: DB.Connection) -> IO(Unit):
  do IO<Unit>:
    rejects(db, T.Table{[T.Column{"n", "INTEGER"}], [Nil{}]})
    rejects(db, T.Table{Nil{}, [[T.Null{}]]})
    rejects(db, one_cell("BIGINT", T.Boolean{True{}}))
    rejects(db, one_cell("TINYINT", T.Signed{0, 128}))
    rejects(db, one_cell("SMALLINT", T.Signed{4294967295, 4294934527}))
    rejects(db, one_cell("UINTEGER", T.Unsigned{1, 0}))
    rejects(db, one_cell("BLOB", T.Bytes{[0, 256]}))
    rejects(db, one_cell("VARCHAR", T.Utf8{SCon{Chr{55296}, ""}}))
    rejects(db, T.Table{[T.Column{"x", "unknown"}], Nil{}})
    rejects(db, one_cell("HUGEINT", T.WideUnsigned{0, 0, 0, 1}))
    IO.try(Unit, DB.register(db, "checked", T.Table{
      [T.Column{"wide", "HUGEINT"}, T.Column{"wide", "UHUGEINT"}, T.Column{"", "NULL"}, T.Column{"v", "TINYINT"}],
      [[T.WideSigned{4294967295, 4294967295, 4294967295, 4294967295}, T.WideUnsigned{1, 2, 3, 4}, T.Null{}, T.Signed{4294967295, 4294967168}]]}))
    t : T.Table <- IO.try(T.Table, DB.query(db, "SELECT count(*) FROM checked"))
    expect(scalar(t, 1), "valid registration after a rejected table lost rows")

def main() -> IO(Unit):
  do IO<Unit>:
    +src : DB.Connection <- IO.try(DB.Connection, DB.memory())
    +dst : DB.Connection <- IO.try(DB.Connection, DB.memory())
    registration(src)
    expect(String.eq(Parquet.path_literal("'a''β'"), "'''a''''β'''"), "incorrect SQL path quoting")
    empty_table : T.Table <- IO.try(T.Table, DB.query(src, "SELECT 0::BIGINT AS amount WHERE false"))
    expect(empty(empty_table), "empty result lost its schema")
    invalid : Result<&1, &1, (U32 & String), T.Table> <- DB.query(src, "SELECT missing_column")
    expect(failed(T.Table, invalid), "expected a SQL error")
    missing : Result<&1, &1, (U32 & String), T.Table> <- Parquet.read(src, "missing/unknown.parquet")
    expect(failed(T.Table, missing), "expected a missing file error")
    bad : Result<&1, &1, (U32 & String), Unit> <- DB.exec(src, "SELECT 1" ++ SCon{Chr{0}, ";"})
    expect(failed(Unit, bad), "embedded NUL in SQL was ignored")
    s : Arrow.Stream <- IO.try(Arrow.Stream, Arrow.query(src, "SELECT i FROM range(11000) t(i)"))
    batches : Arrow.Stream <- IO.try(Arrow.Stream, Arrow.query(src, "SELECT * FROM range(2049)"))
    check_batches(Arrow.next(batches))
    discard : Arrow.Stream <- IO.try(Arrow.Stream, Arrow.query(src, "SELECT 1"))
    IO.try(Unit, Arrow.close(discard))
    IO.try(Unit, DB.close(src))
    stale : Result<&1, &1, (U32 & String), Unit> <- DB.exec(src, "SELECT 1")
    expect(failed(Unit, stale), "closed token still accepted")
    IO.try(Unit, Arrow.into_table(dst, "d\"ata", s))
    count : T.Table <- IO.try(T.Table, DB.query(dst, "SELECT count(*) FROM \"d\"\"ata\""))
    expect(scalar(count, 11000), "multi-batch transfer after connection close lost rows")
    replacement : Arrow.Stream <- IO.try(Arrow.Stream, Arrow.query(dst, "SELECT 1 AS i"))
    collision : Result<&1, &1, (U32 & String), Unit> <- Arrow.into_table(dst, "d\"ata", replacement)
    expect(failed(Unit, collision), "import replaced an existing table")
    sum : T.Table <- IO.try(T.Table, DB.query(dst, "SELECT sum(i)::BIGINT FROM \"d\"\"ata\""))
    expect(scalar(sum, 60494500), "import changed existing rows")
    IO.try(Unit, DB.close(dst))
    IO.print("Bend bindings passed")
