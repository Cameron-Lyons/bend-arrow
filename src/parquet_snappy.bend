import Base
import ./parquet_wire.bend as W
import ./parquet_index.bend as Index

type Output is Data:
  Out{size: U32, index: Index.Index(U32), reversed: W.Bytes}

def emit(+b: U32, out: Output) -> Output:
  Out{n, history, rev} = out
  Out{(n + 1 : U32), Index.push(U32, b, history), b <> rev}

def literals(bs: W.Bytes, out: Output) -> Output:
  match bs:
    case Nil{}: out
    case h <> t: literals(t, emit(h, out))

def from_history(found: Maybe<&2, U32>) -> W.R(U32):
  match found:
    case None{}: W.fail(U32, "Snappy copy outside decoded prefix")
    case Some{v}: Done{v}

@unsafe def copy(n: U32, +offset: U32, +out: Output) -> W.R(Output):
  match n:
    case 0: Done{out}
    case k:
      Out{_, history, _} = out
      do W.R<Output>:
        b : U32 <- from_history(Index.seek(U32, history, (offset - 1 : U32)))
        copy((k - 1 : U32), offset, emit(b, out))

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
