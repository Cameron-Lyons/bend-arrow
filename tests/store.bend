import Base
import ../src/store.bend as S
import ../src/file_bytes.bend as F
import ../src/duckdb.bend as DB
import ../src/catalog.bend as C

def initial() -> S.Cursor:
  S.Cursor{S.Start{}, S.Scan{0, Nil{}, False{}, False{}}}

def inspect(bytes: F.Bytes, id: S.Id) -> F.Outcome(S.Scan):
  do Result<&1, &1, (U32 & String), S.Scan>:
    c : S.Cursor <- S.scan(bytes, initial(), id)
    S.latest(c)

def payload(r: F.Outcome(S.Scan), rev: U32, x: U32) -> Bool:
  match r:
    case Done{S.Scan{r, h <> Nil{}, True{}, _}}: U32.is_eq(r, rev) && U32.is_eq(h, x)
    case _: False{}

def failed(r: F.Outcome(S.Scan)) -> Bool:
  match r:
    case Fail{_}: True{}
    case _: False{}

def assert(ok: Bool, message: String) -> IO(Unit):
  match ok:
    case True{}: IO.pure(Unit, Unit{})
    case False{}: IO.die(Unit, 1, message)

def incomplete(bs: F.Bytes) -> F.Bytes:
  List.take(&2, U32, bs, 20n)

def bad_checksum(bs: F.Bytes) -> F.Bytes:
  match bs:
    case prefix <> a <> b <> c <> d <> e <> f <> g <> h <> i <> t:
      prefix <> a <> b <> c <> d <> e <> f <> g <> h <> U32.xor(i, 1) <> t
    case _: Nil{}

def empty_scan(r: F.Outcome(S.Scan)) -> Bool:
  match r:
    case Done{S.Scan{0, Nil{}, False{}, _}}: True{}
    case _: False{}

def check_scan() -> IO(Unit):
  +a : S.Id = S.Id{10, 20}
  +b : S.Id = S.Id{30, 40}
  +first = S.record(0, a, [253])
  +second = S.record(1, b, [255])
  # The competing writer's remaining bytes can follow a completed record.
  # Separately, a mixed frame with a valid-looking header has a bad checksum.
  together = List.concat(&2, U32, [first, incomplete(S.record(1, a, [254])), second, [1, 253, 1, 254]])
  mixed = List.concat(&2, U32, [first, bad_checksum(second), S.record(1, b, [254])])
  do IO<Unit>:
    assert(payload(inspect(together, b), 2, 255), "orphaned suffix hid the second commit")
    assert(payload(inspect(mixed, b), 2, 254), "damaged frame consumed a revision")
    assert(payload(inspect(List.append(&2, U32, first, incomplete(second)), a), 1, 253), "incomplete record replaced committed data")
    assert(payload(inspect(List.append(&2, U32, second, first), a), 1, 253), "stale base changed selected revision")
    assert(empty_scan(inspect(List.concat(&2, U32, [incomplete(first), [255, 2, 254, 3, 254]]), a)), "two interrupted first appends prevented recovery")
    assert(failed(inspect([255, 216, 255, 224, 32], a)), "accepted a foreign binary file")
    assert(failed(inspect([68, 117, 99, 107], a)), "accepted an unrelated file")

def saved(c: S.Commit) -> Bool:
  match c:
    case S.Saved{}: True{}
    case _: False{}

def stayed(r: F.Outcome(S.Snapshot)) -> Bool:
  match r:
    case Done{S.Snapshot{1, Nil{}}}: True{}
    case _: False{}

def kept_transaction(step: DB.Step) -> Bool:
  match step:
    case DB.Step{DB.Session{_, _, _, Some{DB.Transaction{_, True{}}}}, Fail{_}}: True{}
    case _: False{}

def confirmed(step: DB.Step) -> Bool:
  match step:
    case DB.Step{DB.Session{_, 1, _, None{}}, Done{_}}: True{}
    case _: False{}

def blocked_retry(step: DB.Step) -> Bool:
  match step:
    case DB.Step{DB.Session{_, _, _, Some{DB.AwaitingCommit{_, _, _}}}, Fail{(115, _)}}: True{}
    case _: False{}

def check_session(+path: String, nonce: S.Id) -> IO(Unit):
  +empty : C.Catalog = C.Catalog{Nil{}, Nil{}}
  # The database path is a regular file. An append beneath it always fails
  # before writing, leaving an explicit transaction available for retry.
  tx : DB.Session = DB.Session{Some{path ++ "/child"}, 0, empty, Some{DB.Transaction{empty, True{}}}}
  +pending : DB.Session = DB.Session{Some{path}, 0, empty, Some{DB.AwaitingCommit{empty, nonce, False{}}}}
  do IO<Unit>:
    step : DB.Step <- DB.finish(tx, True{})
    assert(kept_transaction(step), "pre-write error discarded explicit transaction")
    step : DB.Step <- DB.execute("INSERT INTO t VALUES (1)", pending)
    assert(blocked_retry(step), "uncertain commit allowed an INSERT retry")
    step : DB.Step <- DB.execute("COMMIT", pending)
    assert(confirmed(step), "session failed to confirm already-written autocommit")

def retry(+path: String) -> IO(Unit):
  +nonce : S.Id = S.Id{42, 2026}
  do IO<Unit>:
    initial : S.Commit <- S.append_prepared(S.serialize(Nil{}), Done{nonce}, path, 0)
    assert(saved(initial), "first commit failed")
    resolved : S.Commit <- S.resume(nonce, path, 0, Nil{})
    assert(saved(resolved), "retry failed to recognize its committed nonce")
    r : F.Outcome(S.Snapshot) <- S.load(path)
    assert(stayed(r), "retry appended a second revision")
    check_session(path, nonce)

def run(xs: List<String>) -> IO(Unit):
  match xs:
    case _ <> path <> Nil{}: retry(path)
    case _ <> Nil{}: IO.pure(Unit, Unit{})
    case _: IO.die(Unit, 1, "expected at most one fresh database path")

def main() -> IO(Unit):
  do IO<Unit>:
    check_scan()
    xs : List<String> <- IO.args()
    run(xs)
    IO.print("Database log recovery passed")
