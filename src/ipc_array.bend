import Base
import ./table.bend as T
import ./arrow_layout.bend as A
import ./ipc_flatbuffer.bend as F
import ./utf8.bend as UTF8

def Cells() -> Data:
  List<&2, T.Cell>

def Bools() -> Data:
  List<&2, Bool>

# Views share the stream's list tails. Every decoder checks its descriptor's
# length before consuming bytes, independently of any following buffer.
type Buffer is Data:
  Buffer{bytes: F.Bytes, length: U32}

# The row count is bounded by the value buffer before any replicated flags
# are allocated. A zero-length validity buffer represents an all-valid array.
@unsafe def bits(n: U32, bs: F.Bytes, left: U32, +word: U32, acc: Bools) -> F.R(Bools):
  match n bs left:
    case 0 _ _: Done{List.reverse(&2, Bool, acc)}
    case _ Nil{} 0: F.fail(Bools, "truncated bitmap")
    case k h <> t 0: bits(k, t, 8, h, acc)
    case k _ b:
      bits((k - 1 : U32), bs, (b - 1 : U32), (word >> 1n : U32), U32.is_ne((word .&. 1 : U32), 0) <> acc)

def nulls(xs: Bools, acc: U32) -> U32:
  match xs:
    case Nil{}: acc
    case False{} <> t: nulls(t, (acc + 1 : U32))
    case True{} <> t: nulls(t, acc)

def bitmap(+n: U32, buf: Buffer) -> F.R(Bools):
  Buffer{bs, length} = buf
  do F.R<Bools>:
    F.check(U32.is_le(((n + 7 : U32) / 8 : U32), length), "truncated bitmap")
    bits(n, bs, 0, 0, Nil{})

def validity(buf: Buffer, n: U32, expected: U32) -> F.R(Bools):
  match buf:
    case Buffer{_, 0}:
      do F.R<Bools>:
        F.check(U32.is_zero(expected), "missing validity bitmap")
        return List.replicate(Bool, U32.to_nat(n), True{})
    case data:
      do F.R<Bools>:
        +flags : Bools <- bitmap(n, data)
        F.check(U32.is_eq(nulls(flags, 0), expected), "bitmap disagrees with null count")
        return flags

def int_cell(signed: Bool, width: U32, hi: U32, +lo: U32) -> T.Cell:
  match signed width:
    case False{} _: T.Unsigned{hi, lo}
    case True{} 64: T.Signed{hi, lo}
    case True{} +w:
      +sign = (lo >> U32.to_nat((w - 1 : U32)) : U32)
      +upper = (0 - sign : U32)
      mask = Bool.pick(U32, U32.is_eq(w, 32), 0, (upper << U32.to_nat(w) : U32))
      T.Signed{upper, (lo .|. mask : U32)}

def float_bits(x: U32) -> F32:
  U32{w} = x
  F32{w}

def fixed_cell(p: A.Physical, valid: Bool, hi: U32, lo: U32) -> T.Cell:
  match p valid:
    case _ False{}: T.Null{}
    case A.Integer{w, signed} _: int_cell(signed, w, hi, lo)
    case A.Real{32} _: T.Float{float_bits(lo)}
    case _ _: T.Double{hi, lo}

def fixed_size(p: A.Physical) -> U32:
  match p:
    case A.Integer{w, _}: (w / 8 : U32)
    case A.Real{w}: (w / 8 : U32)
    case _: 0

def high_word(bs: F.Bytes, size: U32) -> F.R(U32):
  match size:
    case 8:
      do F.R<U32>:
        tail : F.Bytes <- F.drop(bs, 4)
        F.u32(tail)
    case _: Done{0}

def fixed(flags: Bools, +p: A.Physical, +size: U32, +bs: F.Bytes, acc: Cells) -> F.R(Cells):
  match flags:
    case Nil{}: Done{List.reverse(&2, T.Cell, acc)}
    case h <> t:
      do F.R<Cells>:
        lo : U32 <- F.word(bs, U32.min(4, size))
        hi : U32 <- high_word(bs, size)
        more : F.Bytes <- F.drop(bs, size)
        fixed(t, p, size, more, fixed_cell(p, h, hi, lo) <> acc)

def boolean(flags: Bools, values: Bools) -> Cells:
  match flags values:
    case True{} <> t h <> u: T.Boolean{h} <> boolean(t, u)
    case False{} <> t _ <> u: T.Null{} <> boolean(t, u)
    case _ _: Nil{}

def fixed_values(p: A.Physical, +n: U32, nulls: U32, validity_bytes: Buffer, data: Buffer) -> F.R(Cells):
  match p data:
    case A.Bit{} buf:
      do F.R<Cells>:
        values : Bools <- bitmap(n, buf)
        flags : Bools <- validity(validity_bytes, n, nulls)
        return boolean(flags, values)
    case +kind Buffer{bs, size}:
      +width = fixed_size(kind)
      do F.R<Cells>:
        F.check(U32.is_le(n, (size / width : U32)), "truncated primitive array")
        flags : Bools <- validity(validity_bytes, n, nulls)
        fixed(flags, kind, width, bs, Nil{})

def var_cell(text: Bool, valid: Bool, bs: F.Bytes) -> F.R(T.Cell):
  match text valid:
    case _ False{}: Done{T.Null{}}
    case False{} True{}: Done{T.Bytes{bs}}
    case True{} True{}:
      do F.R<T.Cell>:
        s : String <- UTF8.decode(bs)
        return T.Utf8{s}

# Null slots may span arbitrary bytes. Advance over them without allocating a
# copied value that will immediately be discarded.
def value_span(valid: Bool, bs: F.Bytes, n: U32) -> F.R(F.Span):
  match valid:
    case True{}: F.split(bs, n)
    case False{}:
      do F.R<F.Span>:
        rest : F.Bytes <- F.drop(bs, n)
        return F.Split{Nil{}, rest}

def variable(flags: Bools, +text: Bool, +offsets: F.Bytes, +start: U32, bs: F.Bytes, +data_len: U32, acc: Cells) -> F.R(Cells):
  match flags:
    case Nil{}: Done{List.reverse(&2, T.Cell, acc)}
    case +h <> t:
      do F.R<Cells>:
        +stop : U32 <- F.u32(offsets)
        F.check(U32.is_ge(stop, start) && U32.is_le(stop, data_len), "invalid variable-width offset")
        +s : F.Span <- value_span(h, bs, (stop - start : U32))
        value : T.Cell <- var_cell(text, h, F.head(s))
        more : F.Bytes <- F.drop(offsets, 4)
        variable(t, text, more, stop, F.tail(s), data_len, value <> acc)

def var_values(text: Bool, +n: U32, nulls: U32, validity_bytes: Buffer, offsets: Buffer, data: Buffer) -> F.R(Cells):
  match n offsets:
    case 0 Buffer{_, 0}: Done{Nil{}}
    case _ Buffer{+bs, length}:
      Buffer{payload, +data_len} = data
      do F.R<Cells>:
        F.check(U32.is_lt(n, (length / 4 : U32)), "truncated variable-width offsets")
        +start : U32 <- F.u32(bs)
        F.check(U32.is_le(start, data_len), "invalid variable-width offset")
        values : F.Bytes <- F.drop(payload, start)
        rest : F.Bytes <- F.drop(bs, 4)
        flags : Bools <- validity(validity_bytes, n, nulls)
        variable(flags, text, rest, start, values, data_len, Nil{})
