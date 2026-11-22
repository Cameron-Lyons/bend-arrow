import Base
import ../src/duckdb.bend as DB

def expect_equal(ok: Bool) -> IO(Unit):
  match ok:
    case True{}: IO.pure(Unit, Unit{})
    case False{}: IO.die(Unit, 1, "unexpected database row count")

def check_count(table: DB.Table, expected: U32) -> IO(Unit):
  match table:
    case DB.Table{_, (DB.Signed{0, n} <> Nil{}) <> Nil{}}:
      expect_equal(U32.is_eq(n, expected))
    case _: IO.die(Unit, 1, "expected a BIGINT count")

def missing(r: Result<&1, &1, (U32 & String), DB.Table>) -> IO(Unit):
  match r:
    case Fail{_}: IO.pure(Unit, Unit{})
    case Done{_}: IO.die(Unit, 1, "unexpected visibility across connections")

def count(db: DB.Connection, expected: U32) -> IO(Unit):
  do IO<Unit>:
    t : DB.Table <- IO.try(DB.Table, DB.query(db, "SELECT count(*) FROM items"))
    check_count(t, expected)

def check_file(+path: String) -> IO(Unit):
  do IO<Unit>:
    +a : DB.Connection <- IO.try(DB.Connection, DB.open(path))
    +b : DB.Connection <- IO.try(DB.Connection, DB.open(path))
    IO.try(Unit, DB.exec(a, "CREATE TABLE items(i INT); CREATE TEMP TABLE scoped AS SELECT 1"))
    IO.try(Unit, DB.exec(a, "BEGIN; INSERT INTO items VALUES (42)"))
    count(b, 0)
    IO.try(Unit, DB.exec(a, "COMMIT"))
    count(b, 1)
    hidden : Result<&1, &1, (U32 & String), DB.Table> <- DB.query(b, "SELECT * FROM scoped")
    missing(hidden)
    IO.try(Unit, DB.close(a))
    IO.try(Unit, DB.exec(b, "INSERT INTO items VALUES (43)"))
    IO.try(Unit, DB.close(b))
    +reopened : DB.Connection <- IO.try(DB.Connection, DB.open(path))
    count(reopened, 2)
    IO.try(Unit, DB.close(reopened))

def check_memory() -> IO(Unit):
  do IO<Unit>:
    +a : DB.Connection <- IO.try(DB.Connection, DB.memory())
    +b : DB.Connection <- IO.try(DB.Connection, DB.memory())
    IO.try(Unit, DB.exec(a, "CREATE TABLE private_table(i INT)"))
    hidden : Result<&1, &1, (U32 & String), DB.Table> <- DB.query(b, "SELECT * FROM private_table")
    missing(hidden)
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
