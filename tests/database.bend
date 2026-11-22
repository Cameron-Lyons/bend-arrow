import Base
import ../src/duckdb.bend as DB
import ../src/table.bend as T

def expect_equal(ok: Bool) -> IO(Unit):
  match ok:
    case True{}: IO.pure(Unit, Unit{})
    case False{}: IO.die(Unit, 1, "unexpected database row count")

def check_count(table: T.Table, expected: U32) -> IO(Unit):
  match table:
    case T.Table{_, (T.Signed{0, n} <> Nil{}) <> Nil{}}:
      expect_equal(U32.is_eq(n, expected))
    case _: IO.die(Unit, 1, "expected a BIGINT count")

def expect_failure(r: Result<&1, &1, (U32 & String), T.Table>, message: String) -> IO(Unit):
  match r:
    case Fail{_}: IO.pure(Unit, Unit{})
    case Done{_}: IO.die(Unit, 1, message)

def count(db: DB.Connection, expected: U32) -> IO(Unit):
  do IO<Unit>:
    t : T.Table <- IO.try(T.Table, DB.query(db, "SELECT count(*) FROM items"))
    check_count(t, expected)

def expect_conflict(r: Result<&1, &1, (U32 & String), Unit>) -> IO(Unit):
  match r:
    case Fail{(11, _)}: IO.pure(Unit, Unit{})
    case _: IO.die(Unit, 1, "expected conflicting commit")

def transactions(+a: DB.Connection, +b: DB.Connection) -> IO(Unit):
  do IO<Unit>:
    IO.try(Unit, DB.exec(a, "BEGIN; INSERT INTO items VALUES (100)"))
    count(a, 2)
    count(b, 1)
    IO.try(Unit, DB.exec(a, "ROLLBACK"))
    count(a, 1)
    IO.try(Unit, DB.exec(a, "BEGIN; INSERT INTO items VALUES (101)"))
    IO.try(Unit, DB.exec(b, "INSERT INTO items VALUES (102)"))
    count(a, 2)
    conflict : Result<&1, &1, (U32 & String), Unit> <- DB.exec(a, "COMMIT")
    expect_conflict(conflict)
    count(a, 2)

def expect_command_error(r: Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  match r:
    case Fail{(22, _)}: IO.pure(Unit, Unit{})
    case _: IO.die(Unit, 1, "expected invalid table operation")

def invalid_command(db: DB.Connection, sql: String) -> IO(Unit):
  do IO<Unit>:
    result : Result<&1, &1, U32 & String, Unit> <- DB.exec(db, sql)
    expect_command_error(result)

def counted(db: DB.Connection, sql: String, expected: U32) -> IO(Unit):
  do IO<Unit>:
    result : T.Table <- IO.try(T.Table, DB.query(db, sql))
    check_count(result, expected)

def row_edits(+a: DB.Connection, +b: DB.Connection) -> IO(Unit):
  do IO<Unit>:
    IO.try(Unit, DB.exec(a, "CREATE TABLE edits(a INT, b BIGINT, v VARCHAR); INSERT INTO edits VALUES (1,10,'x'), (2,20,NULL), (3,30,'y')"))
    IO.try(Unit, DB.exec(a, "UPDATE edits SET b = a, a = 9, v = 'new' WHERE a = 1 OR (a = 2 AND v IS NULL)"))
    counted(b, "SELECT sum(b) FROM edits WHERE a = 9 AND v = 'new'", 3)
    IO.try(Unit, DB.exec(a, "BEGIN; DELETE FROM edits WHERE a = 9; UPDATE edits SET v = NULL"))
    counted(a, "SELECT count(*) FROM edits WHERE v IS NULL", 1)
    counted(b, "SELECT count(*) FROM edits", 3)
    IO.try(Unit, DB.exec(a, "ROLLBACK"))
    invalid_command(a, "UPDATE edits SET v = 'lost', missing = 3")
    invalid_command(a, "UPDATE edits SET a = 3, A = 4 WHERE false")
    invalid_command(a, "UPDATE edits SET v = 1 WHERE false")
    invalid_command(a, "UPDATE edits SET b = count(*)")
    invalid_command(a, "DELETE FROM edits WHERE missing IS NULL")
    invalid_command(a, "DELETE FROM read_parquet('missing/inexistent.parquet')")
    IO.try(Unit, DB.exec(a, "UPDATE edits SET a = 1::INT WHERE false"))
    counted(a, "SELECT count(*) FROM edits WHERE v = 'new'", 2)
    IO.try(Unit, DB.exec(a, "BEGIN; DELETE FROM edits WHERE false; UPDATE edits SET a = 1 WHERE a = 0"))
    IO.try(Unit, DB.exec(b, "INSERT INTO edits VALUES (4,40,'other')"))
    IO.try(Unit, DB.exec(a, "COMMIT; BEGIN; CREATE TEMP TABLE copied AS SELECT * FROM edits"))
    counted(a, "SELECT count(*) FROM copied", 4)
    IO.try(Unit, DB.exec(b, "DELETE FROM edits WHERE v = 'other'"))
    IO.try(Unit, DB.exec(a, "ROLLBACK; BEGIN; UPDATE edits SET v = 'keep' WHERE a = 3; COMMIT"))
    counted(b, "SELECT count(*) FROM edits WHERE v = 'keep'", 1)
    IO.try(Unit, DB.exec(a, "DELETE FROM edits"))
    counted(b, "SELECT count(*) FROM edits", 0)
    invalid_command(a, "UPDATE edits SET a = missing")
    invalid_command(a, "DELETE FROM edits WHERE")
    IO.try(Unit, DB.exec(a, "CREATE TEMP TABLE update(set INT, delete INT); INSERT INTO update VALUES (1, 2); UPDATE update SET set = delete, delete = set"))
    counted(a, "SELECT count(*) FROM update WHERE set = 2 AND delete = 1", 1)
    IO.try(Unit, DB.exec(a, "DELETE FROM update WHERE set = 2; DROP TABLE edits"))

def check_catalog(+a: DB.Connection, +b: DB.Connection) -> IO(Unit):
  do IO<Unit>:
    IO.try(Unit, DB.exec(a, "CREATE TEMP TABLE staging AS SELECT i FROM range(2) t(i); CREATE TABLE totals(n BIGINT)"))
    IO.try(Unit, DB.exec(a, "INSERT INTO totals SELECT * FROM staging; INSERT INTO totals SELECT n FROM totals; INSERT INTO totals SELECT 7"))
    total : T.Table <- IO.try(T.Table, DB.query(b, "SELECT sum(n) FROM totals"))
    check_count(total, 9)
    invalid : Result<&1, &1, U32 & String, Unit> <- DB.exec(a, "INSERT INTO totals SELECT 'wrong' WHERE false")
    expect_command_error(invalid)
    invalid : Result<&1, &1, U32 & String, Unit> <- DB.exec(a, "INSERT INTO totals SELECT 1, 2")
    expect_command_error(invalid)
    IO.try(Unit, DB.exec(a, "BEGIN; DROP TABLE totals; DROP TABLE staging; ROLLBACK"))
    total : T.Table <- IO.try(T.Table, DB.query(a, "SELECT count(*) FROM totals"))
    check_count(total, 5)
    IO.try(Unit, DB.exec(a, "BEGIN; DROP TABLE staging; DROP TABLE IF EXISTS absent; INSERT INTO totals SELECT 1 WHERE false"))
    IO.try(Unit, DB.exec(b, "INSERT INTO totals VALUES (8)"))
    IO.try(Unit, DB.exec(a, "COMMIT"))
    missing : Result<&1, &1, U32 & String, T.Table> <- DB.query(a, "SELECT * FROM staging")
    expect_failure(missing, "temporary table survived DROP")
    invalid : Result<&1, &1, U32 & String, Unit> <- DB.exec(a, "DROP TABLE staging")
    expect_command_error(invalid)
    invalid : Result<&1, &1, U32 & String, Unit> <- DB.exec(a, "\"drop\" TABLE totals")
    expect_command_error(invalid)
    IO.try(Unit, DB.exec(a, "DROP TABLE IF EXISTS totals; DROP TABLE IF EXISTS totals"))
    missing : Result<&1, &1, U32 & String, T.Table> <- DB.query(b, "SELECT * FROM totals")
    expect_failure(missing, "another connection still sees a dropped table")
    IO.try(Unit, DB.exec(a, "CREATE TEMP TABLE txt(v VARCHAR); INSERT INTO txt SELECT NULL; INSERT INTO txt SELECT v FROM (VALUES (NULL)) AS t(v)"))
    nullable : T.Table <- IO.try(T.Table, DB.query(a, "SELECT count(*) FROM txt WHERE v IS NULL"))
    check_count(nullable, 2)
    IO.try(Unit, DB.exec(a, "CREATE TEMP TABLE if(drop INT); INSERT INTO if SELECT 1; DROP TABLE if"))

def check_file(+path: String) -> IO(Unit):
  do IO<Unit>:
    +a : DB.Connection <- IO.try(DB.Connection, DB.open(path))
    +b : DB.Connection <- IO.try(DB.Connection, DB.open(path))
    IO.try(Unit, DB.exec(a, "CREATE TABLE items(i INT); CREATE TEMP TABLE scoped AS SELECT 1"))
    IO.try(Unit, DB.exec(a, "BEGIN; INSERT INTO items VALUES (42)"))
    count(b, 0)
    IO.try(Unit, DB.exec(a, "COMMIT"))
    count(b, 1)
    hidden : Result<&1, &1, (U32 & String), T.Table> <- DB.query(b, "SELECT * FROM scoped")
    expect_failure(hidden, "temporary table visible in another session")
    transactions(a, b)
    check_catalog(a, b)
    row_edits(a, b)
    IO.try(Unit, DB.close(a))
    IO.try(Unit, DB.exec(b, "INSERT INTO items VALUES (43)"))
    IO.try(Unit, DB.exec(b, "BEGIN; INSERT INTO items VALUES (44)"))
    count(b, 4)
    IO.try(Unit, DB.close(b))
    +reopened : DB.Connection <- IO.try(DB.Connection, DB.open(path))
    stale : Result<&1, &1, (U32 & String), T.Table> <- DB.query(a, "SELECT count(*) FROM items")
    expect_failure(stale, "closed token selected a reopened database")
    count(reopened, 3)
    IO.try(Unit, DB.close(reopened))

def check_memory() -> IO(Unit):
  do IO<Unit>:
    +a : DB.Connection <- IO.try(DB.Connection, DB.memory())
    +b : DB.Connection <- IO.try(DB.Connection, DB.memory())
    IO.try(Unit, DB.exec(a, "CREATE TABLE private_table(i INT)"))
    hidden : Result<&1, &1, (U32 & String), T.Table> <- DB.query(b, "SELECT * FROM private_table")
    expect_failure(hidden, "in-memory table visible in another database")
    IO.try(Unit, DB.close(a))
    IO.try(Unit, DB.close(b))

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> path <> Nil{}:
      do IO<Unit>:
        check_file(path)
        check_memory()
        IO.print("Database sessions and persistence passed")
    case _: IO.die(Unit, 2, "Usage: database NEW_DATABASE_PATH")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
