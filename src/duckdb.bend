import Base
import ./table.bend as T
import ./sql.bend as SQL
import ./sql_lexer.bend as Lexer
import ./catalog.bend as C
import ./store.bend as Store
import ./file_bytes.bend as F
import ./parquet_read.bend as Parquet

# This module keeps the original connection API. Each connection owns one
# channel slot holding its current catalog and optional transaction snapshot.
def Table() -> Data:
  T.Table

type Transaction is Data:
  Transaction{before: C.Catalog, dirty: Bool}
  AwaitingCommit{before: C.Catalog, nonce: Store.Id, explicit: Bool}

type Session is Data:
  Session{path: Maybe<&2, String>, revision: U32, current: C.Catalog, tx: Maybe<&2, Transaction>}

type Connection is Data:
  Connection{slot: Chan(Session)}

type Step is Type:
  Step{session: Session, outcome: F.Outcome(Unit)}

def error(-A: Type, text: String) -> F.Outcome(A):
  Fail{(22, text)}

def closed(-A: Type) -> F.Outcome(A):
  Fail{(9, "database connection is closed")}

def start(session: Session) -> IO(F.Outcome(Connection)):
  do IO<F.Outcome(Connection)>:
    +slot : Chan(Session) <- Chan.new(Session, 1)
    _ : Result<&1, &1, Session, Unit> <- Chan.send(Session, slot, session)
    return Done{Connection{slot}}

def memory() -> IO(F.Outcome(Connection)):
  start(Session{None{}, 0, C.Catalog{Nil{}, Nil{}}, None{}})

def open_snapshot(path: String, r: F.Outcome(Store.Snapshot)) -> IO(F.Outcome(Connection)):
  match r:
    case Fail{err}: IO.pure(F.Outcome(Connection), Fail{err})
    case Done{Store.Snapshot{rev, entries}}:
      start(Session{Some{path}, rev, C.Catalog{entries, Nil{}}, None{}})

def open_path(+path: String, opened: F.Outcome(File)) -> IO(F.Outcome(Connection)):
  match opened:
    case Fail{err}: IO.pure(F.Outcome(Connection), Fail{err})
    case Done{f}:
      do IO<F.Outcome(Connection)>:
        File.close(f)
        r : F.Outcome(Store.Snapshot) <- Store.load(path)
        open_snapshot(path, r)

def open(path: String) -> IO(F.Outcome(Connection)):
  match path:
    case ":memory:": memory()
    case +p:
      do IO<F.Outcome(Connection)>:
        f : F.Outcome(File) <- File.open(p, "a")
        open_path(p, f)

def apply_snapshot(path: String, local: C.Entries, r: F.Outcome(Store.Snapshot)) -> F.Outcome(Session):
  match r:
    case Fail{err}: Fail{err}
    case Done{Store.Snapshot{rev, entries}}: Done{Session{Some{path}, rev, C.Catalog{entries, local}, None{}}}

def refresh(s: Session) -> IO(F.Outcome(Session)):
  match s:
    case Session{Some{+path}, _, C.Catalog{_, local}, None{}}:
      do IO<F.Outcome(Session)>:
        snap : F.Outcome(Store.Snapshot) <- Store.load(path)
        return apply_snapshot(path, local, snap)
    case state: IO.pure(F.Outcome(Session), Done{state})

def file_table(bytes: F.Outcome(F.Bytes)) -> F.Outcome(T.Table):
  Result.bind(&1, &1, U32 & String, F.Bytes, T.Table, bytes, x => Parquet.decode(x))

def query_file(+path: String, tokens: Lexer.Tokens, tables: C.Entries) -> IO(F.Outcome(T.Table)):
  do IO<F.Outcome(T.Table)>:
    r : F.Outcome(F.Bytes) <- F.read(path)
    return Result.bind(&1, &1, U32 & String, T.Table, T.Table, file_table(r), t => SQL.query_tokens(tokens, SQL.Entry{path, t} <> tables))

def from_source(source: Maybe<&2, String>, tokens: Lexer.Tokens, tables: C.Entries) -> IO(F.Outcome(T.Table)):
  match source:
    case None{}: IO.pure(F.Outcome(T.Table), SQL.query_tokens(tokens, tables))
    case Some{path}: query_file(path, tokens, tables)

def awaiting(-A: Type) -> F.Outcome(A):
  Fail{(115, "commit outcome is unknown; retry COMMIT on this connection")}

def query_ready(tokens: F.Outcome(Lexer.Tokens), r: F.Outcome(Session)) -> IO(F.Outcome(T.Table)):
  match tokens r:
    case Fail{err} _: IO.pure(F.Outcome(T.Table), Fail{err})
    case _ Fail{err}: IO.pure(F.Outcome(T.Table), Fail{err})
    case _ Done{Session{_, _, _, Some{AwaitingCommit{_, _, _}}}}: IO.pure(F.Outcome(T.Table), awaiting(T.Table))
    case Done{+ts} Done{Session{_, _, catalog, _}}:
      from_source(SQL.file_path(ts), ts, C.visible(catalog))

def query_slot(slot: Chan(Session), sql: String, received: Maybe<&1, Session>) -> IO(F.Outcome(T.Table)):
  match received:
    case None{}: IO.pure(F.Outcome(T.Table), closed(T.Table))
    case Some{+s}:
      do IO<F.Outcome(T.Table)>:
        result : F.Outcome(Session) <- refresh(s)
        _ : Result<&1, &1, Session, Unit> <- Chan.send(Session, slot, s)
        query_ready(Lexer.tokenize(sql), result)

def query(db: Connection, sql: String) -> IO(F.Outcome(T.Table)):
  Connection{+slot} = db
  do IO<F.Outcome(T.Table)>:
    value : Maybe<&1, Session> <- Chan.recv(Session, slot)
    query_slot(slot, sql, value)

def success(s: Session) -> Step:
  Step{s, Done{Unit{}}}

def done(s: Session) -> IO(Step):
  IO.pure(Step, success(s))

def failed(s: Session, msg: String) -> IO(Step):
  IO.pure(Step, Step{s, error(Unit, msg)})

def stored(c: C.Catalog) -> C.Entries:
  C.Catalog{entries, _} = c
  entries

def committed(status: Store.Commit, +path: String, +rev: U32, +next: C.Catalog, +before: C.Catalog, +explicit: Bool) -> Step:
  match status:
    case Store.Saved{}: success(Session{Some{path}, U32.inc(rev), next, None{}})
    case Store.Conflict{}: Step{Session{Some{path}, rev, before, None{}}, Fail{(11, "transaction conflict: the database changed")}}
    case Store.Unwritten{err}:
      original = Bool.pick(Session, explicit, Session{Some{path}, rev, next, Some{Transaction{before, True{}}}}, Session{Some{path}, rev, before, None{}})
      Step{original, Fail{err}}
    case Store.Uncertain{id, why}:
      state : Session = Session{Some{path}, rev, next, Some{AwaitingCommit{before, id, explicit}}}
      Step{state, Fail{(115, "commit outcome is unknown; retry COMMIT on this connection: " ++ why)}}

def persist(path: Maybe<&2, String>, +rev: U32, +next: C.Catalog, before: C.Catalog, explicit: Bool, dirty: Bool) -> IO(Step):
  match path dirty:
    case Some{+p} True{}:
      do IO<Step>:
        r : Store.Commit <- Store.commit(p, rev, stored(next))
        return committed(r, p, rev, next, before, explicit)
    case p _: done(Session{p, rev, next, None{}})

def begin(+s: Session) -> IO(Step):
  match s:
    case Session{p, r, +c, None{}}: done(Session{p, r, c, Some{Transaction{c, False{}}}})
    case state: failed(state, "transaction already active")

def finish(s: Session, save: Bool) -> IO(Step):
  match s save:
    case Session{p, rev, _, Some{Transaction{before, _}}} False{}:
      done(Session{p, rev, before, None{}})
    case Session{p, rev, current, Some{Transaction{before, dirty}}} True{}:
      persist(p, rev, current, before, True{}, dirty)
    case Session{Some{+p}, +rev, +current, Some{AwaitingCommit{before, id, explicit}}} True{}:
      do IO<Step>:
        r : Store.Commit <- Store.resume(id, p, rev, stored(current))
        return committed(r, p, rev, current, before, explicit)
    case Session{_, _, _, Some{AwaitingCommit{_, _, _}}} _: IO.pure(Step, Step{s, awaiting(Unit)})
    case state _: failed(state, "no active transaction")

def edited_result(e: F.Outcome(C.Edit), +s: Session) -> IO(Step):
  match e:
    case Fail{err}: IO.pure(Step, Step{s, Fail{err}})
    case Done{C.Edit{next, dirty}}:
      match s:
        case Session{p, r, _, Some{Transaction{before, prior}}}:
          done(Session{p, r, next, Some{Transaction{before, prior || dirty}}})
        case Session{p, r, c, None{}}: persist(p, r, next, c, False{}, dirty)
        case state: IO.pure(Step, Step{state, awaiting(Unit)})

def edited(s: Session, e: F.Outcome(C.Edit)) -> IO(Step):
  edited_result(e, s)

def catalog(s: Session) -> C.Catalog:
  Session{_, _, c, _} = s
  c

def file_command(r: F.Outcome(T.Table), tokens: Lexer.Tokens, +s: Session, path: String) -> IO(Step):
  match r:
    case Fail{err}: IO.pure(Step, Step{s, Fail{err}})
    case Done{t}: edited(s, C.execute(tokens, catalog(s), [SQL.Entry{path, t}]))

def execute_source(src: Maybe<&2, String>, tokens: Lexer.Tokens, +s: Session) -> IO(Step):
  match src:
    case None{}: edited(s, C.execute(tokens, catalog(s), Nil{}))
    case Some{+path}:
      do IO<Step>:
        bytes : F.Outcome(F.Bytes) <- F.read(path)
        file_command(file_table(bytes), tokens, s, path)

def run_command(ts: Lexer.Tokens, +s: Session) -> IO(Step):
  match ts:
    case Lexer.Keyword{"BEGIN"} <> Nil{}: begin(s)
    case Lexer.Keyword{"ROLLBACK"} <> Nil{}: finish(s, False{})
    case +tokens: execute_source(SQL.file_path(tokens), tokens, s)

def command(ts: Lexer.Tokens, +s: Session) -> IO(Step):
  match ts s:
    case Lexer.Keyword{"COMMIT"} <> Nil{} _: finish(s, True{})
    case _ Session{_, _, _, Some{AwaitingCommit{_, _, _}}}: IO.pure(Step, Step{s, awaiting(Unit)})
    case tokens _: run_command(tokens, s)

def statements(tokens: Lexer.Tokens, acc: Lexer.Tokens) -> List<&2, Lexer.Tokens>:
  match tokens:
    case Nil{}: [List.reverse(&2, Lexer.Token, acc)]
    case Lexer.Symbol{59} <> t: List.reverse(&2, Lexer.Token, acc) <> statements(t, Nil{})
    case h <> t: statements(t, h <> acc)

def commands(ts: List<&2, Lexer.Tokens>, state: Step) -> IO(Step):
  match ts state:
    case _ Step{s, Fail{err}}: IO.pure(Step, Step{s, Fail{err}})
    case Nil{} Step{s, Done{_}}: done(s)
    case Con{Nil{}, tail} Step{s, Done{_}}: commands(tail, success(s))
    case Con{head, tail} Step{s, Done{_}}:
      do IO<Step>:
        result : Step <- command(head, s)
        commands(tail, result)

def execute_parsed(r: F.Outcome(Lexer.Tokens), s: Session) -> IO(Step):
  match r:
    case Fail{err}: IO.pure(Step, Step{s, Fail{err}})
    case Done{ts}: commands(statements(ts, Nil{}), success(s))

def execute(sql: String, +s: Session) -> IO(Step):
  execute_parsed(Lexer.tokenize(sql), s)

def imported(name: String, table: T.Table, +s: Session) -> IO(Step):
  edited(s, C.modified(C.add(catalog(s), name, table, True{}), False{}))

def on_refresh(r: F.Outcome(Session), original: Session, action: Session -> IO(Step)) -> IO(Step):
  match r:
    case Fail{err}: IO.pure(Step, Step{original, Fail{err}})
    case Done{s}: action(s)

def put_back(slot: Chan(Session), step: Step) -> IO(F.Outcome(Unit)):
  Step{s, r} = step
  do IO<F.Outcome(Unit)>:
    _ : Result<&1, &1, Session, Unit> <- Chan.send(Session, slot, s)
    return r

def mutate_slot(slot: Chan(Session), action: Session -> IO(Step), value: Maybe<&1, Session>) -> IO(F.Outcome(Unit)):
  match value:
    case None{}: IO.pure(F.Outcome(Unit), closed(Unit))
    case Some{+s}:
      do IO<F.Outcome(Unit)>:
        r : F.Outcome(Session) <- refresh(s)
        step : Step <- on_refresh(r, s, action)
        put_back(slot, step)

def mutate(db: Connection, action: Session -> IO(Step)) -> IO(F.Outcome(Unit)):
  Connection{+slot} = db
  do IO<F.Outcome(Unit)>:
    v : Maybe<&1, Session> <- Chan.recv(Session, slot)
    mutate_slot(slot, action, v)

def exec(db: Connection, sql: String) -> IO(F.Outcome(Unit)):
  mutate(db, s => execute(sql, s))

def register(db: Connection, name: String, t: T.Table) -> IO(F.Outcome(Unit)):
  mutate(db, s => imported(name, t, s))

def close_slot(slot: Chan(Session), value: Maybe<&1, Session>) -> IO(F.Outcome(Unit)):
  match value:
    case None{}: IO.pure(F.Outcome(Unit), closed(Unit))
    case Some{_}:
      do IO<F.Outcome(Unit)>:
        Chan.close(Session, slot)
        return Done{Unit{}}

def close(db: Connection) -> IO(F.Outcome(Unit)):
  Connection{+slot} = db
  do IO<F.Outcome(Unit)>:
    v : Maybe<&1, Session> <- Chan.recv(Session, slot)
    close_slot(slot, v)
