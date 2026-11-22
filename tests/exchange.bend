import Base
import ../src/arrow.bend as Arrow
import ../src/duckdb.bend as DB
import ../src/table.bend as T
import ../src/parquet.bend as Parquet

def existing(r: Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  match r:
    case Fail{_}: IO.pure(Unit, Unit{})
    case Done{_}: IO.die(Unit, 1, "existing Parquet output was overwritten")

def total(t: T.Table) -> IO(Unit):
  match t:
    case T.Table{_, (T.Signed{0, 2098176} <> Nil{}) <> Nil{}}: IO.pure(Unit, Unit{})
    case _: IO.die(Unit, 1, "wrong total")

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> +base <> Nil{}:
      +ipc = base ++ ".arrows"
      +pq = base ++ ".parquet"
      do IO<Unit>:
        +db : DB.Connection <- IO.try(DB.Connection, DB.memory())
        s : Arrow.Stream <- IO.try(Arrow.Stream, Arrow.query(db, "SELECT i FROM range(2049) t(i)"))
        IO.try(Unit, Arrow.write(s, ipc))
        read : Arrow.Stream <- IO.try(Arrow.Stream, Arrow.read(ipc))
        IO.try(Unit, Arrow.into_table(db, "numbers", read))
        IO.try(Unit, Parquet.write(db, "select * from numbers", pq))
        collision : Result<&1, &1, U32 & String, Unit> <- Parquet.write(db, "select 0 as i", pq)
        existing(collision)
        IO.try(Unit, DB.exec(db, "create table scanned as select sum(i) as total from " ++ Parquet.scan(pq)))
        IO.try(Unit, DB.exec(db, "create temp table imported(n bigint); insert into imported select i from " ++ Parquet.scan(pq)))
        result : T.Table <- IO.try(T.Table, DB.query(db, "select sum(n) from imported"))
        original : T.Table <- IO.try(T.Table, DB.query(db, "select total from scanned"))
        IO.try(Unit, DB.close(db))
        total(original)
        total(result)
        IO.print("Arrow file exchange and Parquet table creation passed")
    case _: IO.die(Unit, 2, "provide a fresh path prefix")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
