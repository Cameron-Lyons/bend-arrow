import Base
import ./parquet_wire.bend as W
import ./random_access_list.bend as Index

# Keep the reversed output and a pointer into it at each 64-byte boundary.
# A copy can then find its source with one lookup and at most 63 list steps.
type Output is Data:
  Out{size: U32, checkpoints: Index.Index(W.Bytes), reversed: W.Bytes}

def remember(n: U32, checkpoints: Index.Index(W.Bytes), +rev: W.Bytes, boundary: Bool) -> Output:
  match boundary:
    case True{}: Out{n, Index.push(W.Bytes, rev, checkpoints), rev}
    case False{}: Out{n, checkpoints, rev}

def emit(b: U32, out: Output) -> Output:
  Out{n, checkpoints, rev} = out
  +size = (n + 1 : U32)
  remember(size, checkpoints, b <> rev, U32.is_zero((size .&. 63 : U32)))

def literals(bs: W.Bytes, out: Output) -> Output:
  match bs:
    case Nil{}: out
    case h <> t: literals(t, emit(h, out))

def from_checkpoint(found: Maybe<&2, W.Bytes>, skip: U32) -> W.R(W.Bytes):
  match found:
    case None{}: W.fail(W.Bytes, "Snappy copy outside decoded prefix")
    case Some{rev}: W.skip(skip, rev)

def history(out: Output, +end: U32, recent: Bool) -> W.R(W.Bytes):
  Out{size, checkpoints, rev} = out
  match recent:
    case True{}: W.skip((size - end : U32), rev)
    case False{}:
      +skip = ((0 - end) .&. 63 : U32)
      index = ((size >> 6n) - ((end + skip) >> 6n) : U32)
      from_checkpoint(Index.seek(W.Bytes, checkpoints, index), skip)

def window(bs: W.Bytes, n: U32, acc: W.Bytes) -> W.R(W.Bytes):
  match bs n:
    case _ 0: Done{acc}
    case h <> t k: window(t, (k - 1 : U32), h <> acc)
    case Nil{} _: W.fail(W.Bytes, "truncated Snappy copy source")

# An overlapping copy repeats the original source bytes. A Snappy command
# emits at most 64 bytes, so its forward-ordered window is small.
def replay(n: Nat, bytes: W.Bytes, +cycle: W.Bytes, out: Output) -> W.R(Output):
  match n bytes:
    case 0n _: Done{out}
    case 1n+p h <> t: replay(p, t, cycle, emit(h, out))
    case 1n+p Nil{}:
      match cycle:
        case +h <> +t: replay(p, t, h <> t, emit(h, out))
        case Nil{}: W.fail(Output, "empty Snappy copy source")

def copy(+n: U32, +offset: U32, +out: Output) -> W.R(Output):
  Out{+size, _, _} = out
  +span = U32.min(n, offset)
  +end = (size - offset + span : U32)
  do W.R<Output>:
    source : W.Bytes <- history(out, end, U32.is_lt((size - end : U32), 64))
    +bytes : W.Bytes <- window(source, span, Nil{})
    replay(U32.to_nat(n), bytes, bytes, out)

def length(tag: U32, extended: Bool) -> W.P(U32):
  match extended:
    case False{}: W.P.pure(U32, (tag + 1 : U32))
    case True{}:
      do W.P<U32>:
        bs : W.Bytes <- W.take((tag - 59 : U32))
        +n : U32 = W.little(bs)
        W.lift(Unit, W.check(U32.is_ne(n, 4294967295), "Snappy literal length overflow"))
        return (n + 1 : U32)

def copy_offset(tag: U32, kind: U32) -> W.P(U32):
  match kind:
    case 1:
      do W.P<U32>:
        b : U32 <- W.byte
        return (b + ((tag .&. 224) << 3n) : U32)
    case 2:
      do W.P<U32>:
        bs : W.Bytes <- W.take(2)
        return W.little(bs)
    case _: W.le32

def command(+tag: U32, kind: U32, +left: U32, +out: Output) -> W.P(Output):
  match kind:
    case 0:
      +short = (tag >> 2n : U32)
      do W.P<Output>:
        +n : U32 <- length(short, U32.is_ge(short, 60))
        W.lift(Unit, W.check(U32.is_le(n, left), "Snappy literal exceeds declared output"))
        bs : W.Bytes <- W.take(n)
        return literals(bs, out)
    case +k:
      Out{written, _, _} = out
      +n = Bool.pick(U32, U32.is_eq(k, 1), (((tag >> 2n) .&. 7) + 4 : U32), ((tag >> 2n) + 1 : U32))
      do W.P<Output>:
        +offset : U32 <- copy_offset(tag, k)
        W.lift(Unit, W.check(U32.is_ne(offset, 0) && U32.is_le(offset, written) && U32.is_le(n, left), "invalid Snappy copy"))
        W.lift(Output, copy(n, offset, out))

@unsafe def commands(bs: W.Bytes, +size: U32, +out: Output) -> W.R(W.Bytes):
  match bs:
    case Nil{}:
      Out{n, _, rev} = out
      do W.R<W.Bytes>:
        W.check(U32.is_eq(n, size), "truncated Snappy block")
        return List.reverse(&2, U32, rev)
    case +tag <> tail:
      Out{n, _, _} = out
      do W.R<W.Bytes>:
        +step : W.Step<Output> <- W.step(Output, command(tag, (tag .&. 3 : U32), (size - n : U32), out, tail))
        commands(W.rest(Output, step), size, W.parsed(Output, step))

def decode(+expected: U32, bytes: W.Bytes) -> W.R(W.Bytes):
  do W.R<W.Bytes>:
    +step : W.Step<U32> <- W.step(U32, W.uint(bytes))
    W.check(U32.is_eq(expected, W.parsed(U32, step)), "Snappy length differs from page size")
    commands(W.rest(U32, step), expected, Out{0, Nil{}, Nil{}})
