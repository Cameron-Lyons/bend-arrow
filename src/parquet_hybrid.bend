import Base
import ./parquet_wire.bend as W

# RLE / bit-packed hybrid decoder shared by definition levels and dictionary IDs.
# A packed run occupies complete groups of eight values. DuckDB can pad the
# final run to a larger block, so its physical size and logical count differ.
type Bits is Data:
  Bits{bytes: W.Bytes, current: U32, available: U32}

def mask(n: U32) -> U32:
  ((1 << U32.to_nat(n)) - 1 : U32)

@unsafe def bits(+need: U32, cursor: Bits, acc: U32, shift: U32) -> W.R(Bits & U32):
  bits.ready(U32.is_zero(need), need, cursor, acc, shift)

@unsafe def bits.ready(done: Bool, need: U32, cursor: Bits, acc: U32, shift: U32) -> W.R(Bits & U32):
  match done:
    case True{}: Done{(cursor, acc)}
    case False{}:
      Bits{bs, word, +available} = cursor
      bits.consume(need, bs, word, available, acc, shift, U32.is_zero(available))

@unsafe def bits.consume(+need: U32, bs: W.Bytes, +word: U32, +available: U32, acc: U32, +shift: U32, fetch: Bool) -> W.R(Bits & U32):
  match fetch:
    case True{}: bits.fetch(need, bs, acc, shift)
    case False{}:
      +used = U32.min(need, available)
      next : Bits = Bits{bs, (word >> U32.to_nat(used) : U32), (available - used : U32)}
      value = (acc .|. ((word .&. mask(used)) << U32.to_nat(shift)) : U32)
      bits((need - used : U32), next, value, (shift + used : U32))

@unsafe def bits.fetch(need: U32, bs: W.Bytes, acc: U32, shift: U32) -> W.R(Bits & U32):
  match bs:
    case h <> rest: bits(need, Bits{rest, h, 8}, acc, shift)
    case Nil{}: W.fail(Bits & U32, "truncated packed values")

@unsafe def unpack(n: U32, +width: U32, cursor: Bits, acc: W.Bytes) -> W.R(W.Bytes):
  match n:
    case 0: Done{acc}
    case k:
      W.R.bind(Bits & U32, W.Bytes, bits(width, cursor, 0, 0), unpack.next((k - 1 : U32), width, acc))

@unsafe def unpack.next(n: U32, width: U32, acc: W.Bytes, pair: Bits & U32) -> W.R(W.Bytes):
  (cursor, v) = pair
  unpack(n, width, cursor, v <> acc)

@unsafe def repeat(n: U32, +v: U32, acc: W.Bytes) -> W.Bytes:
  match n:
    case 0: acc
    case k: repeat((k - 1 : U32), v, v <> acc)

@unsafe def runs(n: U32, +width: U32, bs: W.Bytes, acc: W.Bytes) -> W.R(W.Bytes):
  match n:
    case 0:
      do W.R<W.Bytes>:
        W.check(W.empty(U32, bs), "extra bytes after hybrid runs")
        return List.reverse(&2, U32, acc)
    case left:
      do W.R<W.Bytes>:
        +step : W.Step<U32> <- W.step(U32, W.uint(bs))
        +header : U32 = W.parsed(U32, step)
        +count : U32 = (header >> 1n : U32)
        W.check(U32.is_ne(count, 0), "zero-length hybrid run")
        run(left, width, W.rest(U32, step), acc, count, U32.is_even(header))

@unsafe def run(+left: U32, +width: U32, bs: W.Bytes, acc: W.Bytes, +count: U32, rle: Bool) -> W.R(W.Bytes):
  match rle:
    case True{}:
      do W.R<W.Bytes>:
        W.check(U32.is_le(count, left), "RLE run exceeds value count")
        +step : W.Step<W.Bytes> <- W.step(W.Bytes, W.take(((width + 7) >> 3n : U32), bs))
        +v : U32 = W.little(W.parsed(W.Bytes, step))
        W.check(U32.is_eq(width, 32) || U32.is_le(v, mask(width)), "RLE value exceeds bit width")
        runs((left - count : U32), width, W.rest(W.Bytes, step), repeat(count, v, acc))
    case False{}:
      do W.R<W.Bytes>:
        W.check(U32.is_le(count, 268435455), "packed run exceeds the Parquet length limit")
        W.check(U32.is_le(width, (4294967295 / count : U32)), "packed run byte length overflow")
        +n : U32 = U32.min(left, (count * 8 : U32))
        +step : W.Step<W.Bytes> <- W.step(W.Bytes, W.take((count * width : U32), bs))
        out : W.Bytes <- unpack(n, width, Bits{W.parsed(W.Bytes, step), 0, 0}, acc)
        runs((left - n : U32), width, W.rest(W.Bytes, step), out)

def decode(n: U32, +width: U32, bs: W.Bytes) -> W.R(W.Bytes):
  do W.R<W.Bytes>:
    W.check(U32.is_le(width, 32), "hybrid bit width exceeds 32")
    runs(n, width, bs, Nil{})
