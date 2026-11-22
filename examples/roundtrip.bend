import Base
import ../src/duckdb.bend as DB
import ../src/parquet.bend as Parquet
import ../src/arrow.bend as Arrow

def show_total(table: DB.Table) -> IO(Unit):
  match table:
    case DB.Table{_, (DB.Signed{0, total} <> Nil{}) <> Nil{}}:
      IO.print("Score total: " ++ U32.show(total))
    case _:
      IO.die(Unit, 1, "Expected one BIGINT total")

def roundtrip(+path: String) -> IO(Unit):
  do IO<Unit>:
    +db : DB.Connection <- IO.try(DB.Connection, DB.memory())
    source : String = "SELECT * FROM (VALUES ('Ada', 12), ('Lin', 7), ('Ada', NULL), ('Eli', 3)) AS t(name, score)"
    IO.try(Unit, Parquet.write(db, source, path))
    sql : String = "SELECT name, score FROM " ++ Parquet.scan(path) ++ " WHERE score >= 7 OR score IS NULL"
    stream : Arrow.Stream <- IO.try(Arrow.Stream, Arrow.query(db, sql))
    IO.try(Unit, Arrow.into_table(db, "scores", stream))
    total : DB.Table <- IO.try(DB.Table, DB.query(db, "SELECT sum(score)::BIGINT FROM scores"))
    IO.try(Unit, DB.close(db))
    show_total(total)

def run(args: List<String>) -> IO(Unit):
  match args:
    case _ <> path <> Nil{}:
      roundtrip(path)
    case _:
      IO.die(Unit, 2, "Usage: roundtrip OUTPUT.parquet")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
