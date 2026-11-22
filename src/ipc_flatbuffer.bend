import Base
import ./arrow_layout.bend as A
import ./byte_index.bend as B

def Bytes() -> Data:
  A.Bytes

def R(-T: Type) -> Type:
  A.Outcome(T)

def R.pure(-T: Type, x: T) -> R(T):
  Done{x}

def R.bind(-T: Type, -U: Type, r: R(T), f: T -> R(U)) -> R(U):
  Result.bind(&1, &1, (U32 & String), T, U, r, f)

def fail(-T: Type, why: String) -> R(T):
  Fail{(22, "Arrow IPC: " ++ why)}

def check(ok: Bool, why: String) -> R(Unit):
  match ok:
    case True{}: Done{Unit{}}
    case False{}: fail(Unit, why)

def drop(bs: Bytes, n: U32) -> R(Bytes):
  match bs n:
    case _ 0: Done{bs}
    case _ <> rest k: drop(rest, (k - 1 : U32))
    case _ _: fail(Bytes, "offset outside buffer")

type Span is Data:
  Split{head: Bytes, tail: Bytes}

def split.go(bs: Bytes, n: U32, rev: Bytes) -> R(Span):
  match bs n:
    case _ 0: Done{Split{List.reverse(&2, U32, rev), bs}}
    case h <> t k: split.go(t, (k - 1 : U32), h <> rev)
    case _ _: fail(Span, "truncated buffer")

def split(bs: Bytes, n: U32) -> R(Span):
  split.go(bs, n, Nil{})

def head(s: Span) -> Bytes:
  Split{bs, _} = s
  bs

def tail(s: Span) -> Bytes:
  Split{_, bs} = s
  bs

def u32(bs: Bytes) -> R(U32):
  match bs:
    case a <> b <> c <> d <> _: Done{(a .|. (b << 8n) .|. (c << 16n) .|. (d << 24n) : U32)}
    case _: fail(U32, "truncated integer")

def word(bs: Bytes, size: U32) -> R(U32):
  match bs size:
    case a <> _ 1: Done{a}
    case a <> b <> _ 2: Done{(a .|. (b << 8n) : U32)}
    case _ 4: u32(bs)
    case a <> b <> c <> d <> 0 <> 0 <> 0 <> 0 <> _ 8: Done{(a .|. (b << 8n) .|. (c << 16n) .|. (d << 24n) : U32)}
    case _ _: fail(U32, "truncated or oversized integer")

# FlatBuffers contain random-access offsets. Index metadata once so looking up
# each field of a wide schema does not rescan all preceding fields.
def Region() -> Data:
  B.Index

def region(bs: Bytes) -> Region:
  B.build(bs)

def size(r: Region) -> U32:
  B.size(r)

def fits(+length: U32, +pos: U32, n: U32) -> Bool:
  U32.is_le(pos, length) && U32.is_le(n, (length - pos : U32))

def suffix_at(found: Maybe<&2, Bytes>) -> R(Bytes):
  match found:
    case Some{bs}: Done{bs}
    case None{}: fail(Bytes, "offset outside metadata")

def suffix(r: Region, pos: U32) -> R(Bytes):
  suffix_at(B.suffix(r, pos))

def span(+r: Region, +pos: U32, +n: U32) -> R(Bytes):
  do R<Bytes>:
    check(fits(size(r), pos, n), "span outside buffer")
    rest : Bytes <- suffix(r, pos)
    part : Span <- split(rest, n)
    return head(part)

def at(+r: Region, +pos: U32, +n: U32) -> R(U32):
  do R<U32>:
    check(fits(size(r), pos, n), "scalar outside metadata")
    rest : Bytes <- suffix(r, pos)
    word(rest, n)

def indirect(+r: Region, +pos: U32) -> R(U32):
  do R<U32>:
    +delta : U32 <- at(r, pos, 4)
    check(U32.is_ge(delta, 4) && fits(size(r), pos, delta), "invalid relative pointer")
    return (pos + delta : U32)

# Vtables can be shared and can precede or follow an object. The signed
# displacement subtracts modulo 2^32; the resulting position is range checked.
type Object is Data:
  Object{region: Region, start: U32, vt: U32, vt_size: U32, obj_size: U32}

def object(+r: Region, +pos: U32) -> R(Object):
  do R<Object>:
    delta : U32 <- at(r, pos, 4)
    +vt : U32 = (pos - delta : U32)
    +vs : U32 <- at(r, vt, 2)
    check(U32.is_ge(vs, 4) && fits(size(r), vt, vs) && U32.is_even(vs), "invalid vtable")
    +os : U32 <- at(r, (vt + 2 : U32), 2)
    check(U32.is_ge(os, 4) && fits(size(r), pos, os), "invalid object length")
    return Object{r, pos, vt, vs, os}

def nullable_slot(pos: U32, os: U32, width: U32, off: U32) -> R(U32):
  match off:
    case 0: Done{0}
    case +n:
      do R<U32>:
        check(U32.is_ge(n, 4) && fits(os, n, width), "field outside its object")
        return (pos + n : U32)

def lookup(r: Region, pos: U32, os: U32, vtpos: U32, width: U32, inside: Bool) -> R(U32):
  match inside:
    case False{}: Done{0}
    case True{}:
      do R<U32>:
        off : U32 <- at(r, vtpos, 2)
        nullable_slot(pos, os, width, off)

def slot(obj: Object, index: U32, width: U32) -> R(U32):
  Object{r, pos, vt, vs, os} = obj
  +field = (4 + 2 * index : U32)
  lookup(r, pos, os, (vt + field : U32), width, U32.is_lt(field, vs))

def data(obj: Object) -> Region:
  Object{r, _, _, _, _} = obj
  r

def value(r: Region, p: U32, width: U32) -> R(U32):
  match p:
    case 0: Done{0}
    case x: at(r, x, width)

def scalar(+obj: Object, idx: U32, +width: U32) -> R(U32):
  do R<U32>:
    pos : U32 <- slot(obj, idx, width)
    value(data(obj), pos, width)

def ref(+obj: Object, idx: U32) -> R(U32):
  do R<U32>:
    +pos : U32 <- slot(obj, idx, 4)
    check(U32.is_ne(pos, 0), "missing required reference")
    indirect(data(obj), pos)

type Vector is Data:
  Vector{start: U32, count: U32}

def vector_at(+r: Region, p: U32, stride: U32) -> R(Vector):
  match p:
    case 0: Done{Vector{0, 0}}
    case pos:
      do R<Vector>:
        +target : U32 <- indirect(r, pos)
        +count : U32 <- at(r, target, 4)
        +start : U32 = (target + 4 : U32)
        check(U32.is_le(count, ((size(r) - start) / stride : U32)), "truncated vector")
        return Vector{start, count}

def vector(+o: Object, idx: U32, stride: U32) -> R(Vector):
  do R<Vector>:
    pos : U32 <- slot(o, idx, 4)
    vector_at(data(o), pos, stride)

def empty(v: Vector, why: String) -> R(Unit):
  Vector{_, count} = v
  check(U32.is_zero(count), why)

def no_vector(o: Object, idx: U32, stride: U32, why: String) -> R(Unit):
  do R<Unit>:
    v : Vector <- vector(o, idx, stride)
    empty(v, why)

def text(+r: Region, +pos: U32) -> R(Bytes):
  do R<Bytes>:
    +n : U32 <- at(r, pos, 4)
    check(U32.is_lt(n, (size(r) - pos - 4 : U32)), "truncated string")
    zero : U32 <- at(r, (pos + 4 + n : U32), 1)
    check(U32.is_zero(zero), "unterminated string")
    span(r, (pos + 4 : U32), n)
