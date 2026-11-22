import Base
import ./sql.bend as SQL
import ./bindings.bend as Bindings
import ./database.bend as Database
import ./parquet.bend as Parquet
import ./ipc.bend as IPC
import ./exchange.bend as Exchange
import ./store.bend as Store

def recovery(args: List<String>) -> IO(Unit):
  match args:
    case _ <> path <> Nil{}:
      do IO<Unit>:
        Store.check_scan()
        Store.retry(path ++ ".recovery")
        IO.print("Database log recovery passed")
    case _: IO.die(Unit, 2, "provide a fresh database path")

def main() -> IO(Unit):
  do IO<Unit>:
    SQL.main()
    Bindings.main()
    Database.main()
    Parquet.main()
    IPC.main()
    Exchange.main()
    args : List<String> <- IO.args()
    recovery(args)
