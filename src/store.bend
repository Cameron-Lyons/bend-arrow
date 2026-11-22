import Base
import ./file_bytes.bend as F
import ./arrow_layout.bend as L
import ./ipc_write.bend as Writer
import ./ipc_read.bend as Reader
import ./table.bend as T
import ./sql.bend as SQL

def Entries() -> Data:
  List<&2, SQL.Entry>

type Snapshot is Data:
  Snapshot{revision: U32, entries: Entries}

def pack(entries: Entries) -> F.Outcome(List<&2, List<&2, T.Cell>>):
  match entries:
    case Nil{}: Done{Nil{}}
    case SQL.Entry{name, t} <> tail:
      do Result<&1, &1, U32 & String, List<&2, List<&2, T.Cell>>>:
        blob : F.Bytes <- Writer.encode(t)
        rest : List<&2, List<&2, T.Cell>> <- pack(tail)
        return [T.Utf8{name}, T.Bytes{blob}] <> rest

def serialize(entries: Entries) -> F.Outcome(F.Bytes):
  do Result<&1, &1, U32 & String, F.Bytes>:
    rows : List<&2, List<&2, T.Cell>> <- pack(entries)
    Writer.encode(T.Table{[T.Column{"name", "VARCHAR"}, T.Column{"stream", "BLOB"}], rows})

def unpack(rows: List<&2, List<&2, T.Cell>>) -> F.Outcome(Entries):
  match rows:
    case Nil{}: Done{Nil{}}
    case (T.Utf8{name} <> T.Bytes{blob} <> Nil{}) <> tail:
      do Result<&1, &1, U32 & String, Entries>:
        table : T.Table <- Reader.decode(blob)
        rest : Entries <- unpack(tail)
        return SQL.Entry{name, table} <> rest
    case _: Fail{(22, "invalid Bend database catalog")}

# Each commit names the revision it was based on. Within an append-only file
# the first complete record for that revision wins, even across connections.
type Id is Data:
  Id{high: U32, low: U32}

type Scan is Data:
  Scan{revision: U32, payload: F.Bytes, accepted: Bool, recognized: Bool}

def word(a: U32, b: U32, c: U32, d: U32) -> U32:
  (a + b * 256 + c * 65536 + d * 16777216 : U32)

# Length and FNV-1a cover the base revision, nonce and payload together. A
# mixed or truncated frame is discarded before it can change the snapshot.
type Digest is Data:
  Digest{length: U32, hash: U32}

def digest(bytes: F.Bytes, length: U32, hash: U32) -> Digest:
  match bytes:
    case Nil{}: Digest{length, hash}
    case h <> t: digest(t, U32.inc(length), (U32.xor(hash, h) * 16777619 : U32))

def matches(d: Digest, size: U32, checksum: U32) -> Bool:
  Digest{n, h} = d
  U32.is_eq(n, size) && U32.is_eq(h, checksum)

def apply_record(body: F.Bytes, old: Scan, wanted: Id) -> Scan:
  match body:
    case a <> b <> c <> d <> e <> f <> g <> h <> i <> j <> k <> l <> payload:
      Scan{+rev, prior, +seen, _} = old
      Id{high, low} = wanted
      mine = U32.is_eq(word(e,f,g,h), high) && U32.is_eq(word(i,j,k,l), low)
      fresh = U32.is_eq(rev, word(a,b,c,d))
      Bool.pick(Scan, fresh, Scan{U32.inc(rev), payload, seen || mine, True{}}, Scan{rev, prior, seen, True{}})
    case _: old

def identified(s: Scan) -> Scan:
  Scan{rev, payload, mine, _} = s
  Scan{rev, payload, mine, True{}}

def accept(bytes: F.Bytes, +old: Scan, wanted: Id) -> Scan:
  match bytes:
    case 66 <> 68 <> 66 <> 50 <> a <> b <> c <> d <> e <> f <> g <> h <> +body:
      ok = matches(digest(body, 0, 2166136261), word(a,b,c,d), word(e,f,g,h))
      Bool.pick(Scan, ok, apply_record(body, old, wanted), identified(old))
    # Read complete records from the original framing.
    case 66 <> 68 <> 66 <> 49 <> body: apply_record(body, identified(old), wanted)
    case 66 <> 68 <> 66 <> 50 <> _: identified(old)
    case _: old

type Frame is Data:
  Start{}
  Between{}
  InFrame{reversed: F.Bytes}
  Escaped{reversed: F.Bytes}

# A start marker abandons the previous partial record. Between frames any
# remaining suffix of an interrupted append is discarded.
type Cursor is Data:
  Cursor{frame: Frame, snapshot: Scan}

def in_frame(byte: U32, acc: F.Bytes, prior: Scan, wanted: Id) -> F.Outcome(Cursor):
  match byte:
    case 253: Done{Cursor{Escaped{acc}, prior}}
    case 254: Done{Cursor{Between{}, accept(List.reverse(&2, U32, acc), prior, wanted)}}
    case x: Done{Cursor{InFrame{x <> acc}, prior}}

def advance(+byte: U32, frame: Frame, prior: Scan, wanted: Id) -> F.Outcome(Cursor):
  match frame:
    case Start{}: Fail{(22, "unrecognized database file")}
    case Between{}: Done{Cursor{Between{}, prior}}
    case Escaped{acc}:
      next = Bool.pick(Frame, U32.is_le(byte, 2), InFrame{(253 + byte : U32) <> acc}, Between{})
      Done{Cursor{next, prior}}
    case InFrame{acc}: in_frame(byte, acc, prior, wanted)

def has_magic(bytes: F.Bytes) -> Bool:
  match bytes:
    case 66 <> 68 <> 66 <> 49 <> _: True{}
    case 66 <> 68 <> 66 <> 50 <> _: True{}
    case _: False{}

# Remember the file signature even when no complete commit has survived yet.
def abandoned(frame: Frame, +prior: Scan) -> Scan:
  match frame prior:
    case _ Scan{_, _, _, True{}}: prior
    case InFrame{acc} _: Bool.pick(Scan, has_magic(List.reverse(&2, U32, acc)), identified(prior), prior)
    case Escaped{acc} _: Bool.pick(Scan, has_magic(List.reverse(&2, U32, acc)), identified(prior), prior)
    case _ _: prior

def on_byte(byte: U32, frame: Frame, prior: Scan, wanted: Id) -> F.Outcome(Cursor):
  match byte:
    case 255: Done{Cursor{InFrame{Nil{}}, abandoned(frame, prior)}}
    case x: advance(x, frame, prior, wanted)

def consume(byte: U32, cursor: Cursor, wanted: Id) -> F.Outcome(Cursor):
  match cursor:
    case Cursor{frame, prior}:
      on_byte(byte, frame, prior, wanted)

def scan(bytes: F.Bytes, cursor: Cursor, +wanted: Id) -> F.Outcome(Cursor):
  match bytes:
    case Nil{}: Done{cursor}
    case h <> t:
      do Result<&1, &1, U32 & String, Cursor>:
        next : Cursor <- consume(h, cursor, wanted)
        scan(t, next, wanted)

def escape(bytes: F.Bytes) -> F.Bytes:
  match bytes:
    case Nil{}: [254]
    case 253 <> tail: 253 <> 0 <> escape(tail)
    case 254 <> tail: 253 <> 1 <> escape(tail)
    case 255 <> tail: 253 <> 2 <> escape(tail)
    case byte <> tail: byte <> escape(tail)

def frame(body: F.Bytes, d: Digest) -> F.Bytes:
  Digest{n, h} = d
  255 <> escape(List.concat(&2, U32, [[66,68,66,50], L.u32(n), L.u32(h), body]))

def record(base: U32, nonce: Id, payload: F.Bytes) -> F.Bytes:
  Id{hi, lo} = nonce
  +body = List.concat(&2, U32, [L.u32(base), L.u32(hi), L.u32(lo), payload])
  frame(body, digest(body, 0, 2166136261))

def partial_header(prefix: F.Bytes) -> Bool:
  match prefix:
    case Nil{}: True{}
    case 66 <> Nil{}: True{}
    case 66 <> 68 <> Nil{}: True{}
    case 66 <> 68 <> 66 <> Nil{}: True{}
    case 66 <> 68 <> 66 <> 49 <> _: True{}
    case 66 <> 68 <> 66 <> 50 <> _: True{}
    case _: False{}

def recognizable(f: Frame) -> Bool:
  match f:
    case Start{}: True{}
    case InFrame{acc}: partial_header(List.reverse(&2, U32, acc))
    case Escaped{acc}: partial_header(List.reverse(&2, U32, acc))
    case Between{}: False{}

def latest(cursor: Cursor) -> F.Outcome(Scan):
  match cursor:
    case Cursor{f, Scan{0, p, seen, False{}}}:
      Bool.pick(F.Outcome(Scan), recognizable(f), Done{Scan{0, p, seen, False{}}}, Fail{(22, "unrecognized or damaged database")})
    case Cursor{_, result}: Done{result}

# Scan incrementally. Only the current record and the latest accepted snapshot
# need to be kept, regardless of the total length of the append log.
@unsafe def read_next(file: File, cursor: Cursor, wanted: Id) -> IO(F.Outcome(Scan)):
  do IO<F.Outcome(Scan)>:
    part : File & F.Outcome(F.Bytes) <- File.read_bytes(file, 32768)
    read_part(part, cursor, wanted)

@unsafe def read_part(part: File & F.Outcome(F.Bytes), cursor: Cursor, wanted: Id) -> IO(F.Outcome(Scan)):
  (file, bytes) = part
  read_chunk(bytes, file, cursor, wanted)

@unsafe def read_chunk(bytes: F.Outcome(F.Bytes), file: File, cursor: Cursor, +wanted: Id) -> IO(F.Outcome(Scan)):
  match bytes:
    case Fail{err}: F.closed(Scan, (file, Fail{err}))
    case Done{Nil{}}: F.closed(Scan, (file, latest(cursor)))
    case Done{xs}: after_chunk(scan(xs, cursor, wanted), file, wanted)

@unsafe def after_chunk(r: F.Outcome(Cursor), file: File, wanted: Id) -> IO(F.Outcome(Scan)):
  match r:
    case Fail{err}: F.closed(Scan, (file, Fail{err}))
    case Done{cursor}: read_next(file, cursor, wanted)

def scan_opened(opened: F.Outcome(File), wanted: Id) -> IO(F.Outcome(Scan)):
  match opened:
    case Fail{err}: IO.pure(F.Outcome(Scan), Fail{err})
    case Done{file}: read_next(file, Cursor{Start{}, Scan{0, Nil{}, False{}, False{}}}, wanted)

def scan_file(path: String, id: Id) -> IO(F.Outcome(Scan)):
  do IO<F.Outcome(Scan)>:
    opened : F.Outcome(File) <- File.open(path, "r")
    scan_opened(opened, id)

def unpack_catalog(t: T.Table) -> F.Outcome(Entries):
  match t:
    case T.Table{T.Column{"name", "VARCHAR"} <> T.Column{"stream", "BLOB"} <> Nil{}, rows}: unpack(rows)
    case _: Fail{(22, "unexpected Bend database schema")}

def snapshot(s: Scan) -> F.Outcome(Snapshot):
  match s:
    case Scan{0, _, _, _}: Done{Snapshot{0, Nil{}}}
    case Scan{rev, bytes, _, _}:
      do Result<&1, &1, U32 & String, Snapshot>:
        t : T.Table <- Reader.decode(bytes)
        entries : Entries <- unpack_catalog(t)
        return Snapshot{rev, entries}

def loaded(r: F.Outcome(Scan)) -> F.Outcome(Snapshot):
  Result.bind(&1, &1, U32 & String, Scan, Snapshot, r, snapshot)

def load(path: String) -> IO(F.Outcome(Snapshot)):
  do IO<F.Outcome(Snapshot)>:
    r : F.Outcome(Scan) <- scan_file(path, Id{0, 0})
    return loaded(r)

type Commit is Type:
  Saved{}
  Conflict{}
  Unwritten{error: U32 & String}
  Uncertain{nonce: Id, reason: String}

def absent(written: F.Outcome(Unit)) -> Commit:
  match written:
    case Fail{err}: Unwritten{err}
    case Done{_}: Unwritten{(5, "database append was interrupted")}

def verified(r: F.Outcome(Scan), written: F.Outcome(Unit), base: U32, id: Id) -> Commit:
  match r:
    case Fail{(_, message)}: Uncertain{id, message}
    case Done{Scan{_, _, True{}, _}}: Saved{}
    case Done{Scan{rev, _, False{}, _}}: Bool.pick(Commit, U32.is_eq(rev, base), absent(written), Conflict{})

def verify_again(r: F.Outcome(Scan), written: F.Outcome(Unit), path: String, base: U32, +id: Id) -> IO(Commit):
  match r:
    case Fail{_}:
      do IO<Commit>:
        retry : F.Outcome(Scan) <- scan_file(path, id)
        return verified(retry, written, base, id)
    case ok: IO.pure(Commit, verified(ok, written, base, id))

def verify_path(written: F.Outcome(Unit), +path: String, +base: U32, +id: Id) -> IO(Commit):
  do IO<Commit>:
    r : F.Outcome(Scan) <- scan_file(path, id)
    verify_again(r, written, path, base, id)

def append_opened(opened: F.Outcome(File), bytes: F.Bytes, path: String, +base: U32, +id: Id) -> IO(Commit):
  match opened:
    case Fail{err}: IO.pure(Commit, Unwritten{err})
    case Done{f}:
      do IO<Commit>:
        written : F.Outcome(Unit) <- F.write_opened(Done{f}, record(base, id, bytes))
        verify_path(written, path, base, id)

def append_prepared(encoded: F.Outcome(F.Bytes), nonce: F.Outcome(Id), +path: String, base: U32) -> IO(Commit):
  match encoded nonce:
    case Fail{err} _: IO.pure(Commit, Unwritten{err})
    case _ Fail{err}: IO.pure(Commit, Unwritten{err})
    case Done{bytes} Done{id}:
      do IO<Commit>:
        opened : F.Outcome(File) <- File.open(path, "a")
        append_opened(opened, bytes, path, base, id)

def random_id(a: F.Outcome(U32), b: F.Outcome(U32)) -> F.Outcome(Id):
  do Result<&1, &1, U32 & String, Id>:
    x : U32 <- a
    y : U32 <- b
    return Id{x, y}

def commit(path: String, base: U32, entries: Entries) -> IO(Commit):
  do IO<Commit>:
    a : F.Outcome(U32) <- IO.random_u32()
    b : F.Outcome(U32) <- IO.random_u32()
    append_prepared(serialize(entries), random_id(a, b), path, base)

def resume_after(r: F.Outcome(Scan), id: Id, path: String, +base: U32, entries: Entries) -> IO(Commit):
  match r:
    case Fail{(_, message)}: IO.pure(Commit, Uncertain{id, message})
    case Done{Scan{_, _, True{}, _}}: IO.pure(Commit, Saved{})
    case Done{Scan{rev, _, False{}, _}}:
      retry = U32.is_eq(rev, base)
      Bool.pick(IO(Commit), retry, append_prepared(serialize(entries), Done{id}, path, base), IO.pure(Commit, Conflict{}))

def resume(+id: Id, +path: String, +base: U32, entries: Entries) -> IO(Commit):
  do IO<Commit>:
    r : F.Outcome(Scan) <- scan_file(path, id)
    resume_after(r, id, path, base, entries)
