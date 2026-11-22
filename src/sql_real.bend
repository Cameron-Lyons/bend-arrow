import Base
import ./sql_lexer.bend as L
import ./table.bend as T

def Digits() -> Data:
  List<&2, U32>

def digits_step(ok: Bool, next: Unit -> L.Checked(Digits)) -> L.Checked(Digits):
  match ok:
    case True{}: next(Unit{})
    case False{}: L.error(Digits, "invalid decimal digits")

def digits(s: String, acc: Digits) -> L.Checked(Digits):
  match s:
    case SNil{}: Done{List.reverse(&2, U32, acc)}
    case SCon{Chr{+code}, tail}:
      digits_step(Char.is_digit(Chr{code}), _ => digits(tail, U32.sub(code, 48) <> acc))

def trim(xs: Digits) -> Digits:
  match xs:
    case 0 <> t: trim(t)
    case other: other

type Division is Data:
  Division{digits: Digits, bit: U32}

# Long division by two on the whole-number digits, most significant first.
def half(xs: Digits, carry: U32, acc: Digits) -> Division:
  match xs:
    case Nil{}: Division{trim(List.reverse(&2, U32, acc)), carry}
    case d <> rest:
      +value = U32.add(U32.mul(carry, 10), d)
      half(rest, U32.and(value, 1), U32.shr(value) <> acc)

def more_integer(part: Division, acc: Digits, next: Digits -> Digits -> L.Checked(Digits)) -> L.Checked(Digits):
  Division{rest, bit} = part
  next(rest, bit <> acc)

def integer_bits(fuel: Nat, xs: Digits, acc: Digits) -> L.Checked(Digits):
  match fuel xs:
    case _ Nil{}: Done{acc}
    case 0n _: L.error(Digits, "DOUBLE literal is out of range")
    case 1n+k ds: more_integer(half(ds, 0, Nil{}), acc, (rest => (out => integer_bits(k, rest, out))))

# Double fractional decimal digits, least significant first. The carry is
# the next binary digit. Keeping the remainder lets us round ties to even.
def twice(xs: Digits, carry: U32, acc: Digits) -> Division:
  match xs:
    case Nil{}: Division{trim(List.reverse(&2, U32, acc)), carry}
    case d <> rest:
      +value = U32.add(U32.mul(d, 2), carry)
      twice(rest, U32.div(value, 10), U32.mod(value, 10) <> acc)

type BitSource is Data:
  Source{whole: Digits, fraction: Digits}

type NextBit is Data:
  NextBit{bit: U32, source: BitSource}

def fraction_bit(part: Division) -> NextBit:
  Division{digits, bit} = part
  NextBit{bit, Source{Nil{}, digits}}

def next_bit(source: BitSource) -> NextBit:
  match source:
    case Source{h <> t, f}: NextBit{h, Source{t, f}}
    case Source{Nil{}, f}: fraction_bit(twice(f, 0, Nil{}))

def sticky(source: BitSource) -> Bool:
  Source{whole, fraction} = source
  Bool.not(List.is_empty(&2, U32, trim(whole)) && List.is_empty(&2, U32, fraction))

def finite_double(finite: Bool, hi: U32, lo: U32) -> L.Checked(T.Cell):
  match finite:
    case True{}: Done{T.Double{hi, lo}}
    case False{}: L.error(T.Cell, "DOUBLE literal is out of range")

def pack(+hi: U32, +lo: U32, sign: U32, guard: NextBit) -> L.Checked(T.Cell):
  NextBit{bit, rest} = guard
  up = U32.is_ne(bit, 0) && (U32.is_ne(U32.and(lo, 1), 0) || sticky(rest))
  +low = U32.add(lo, Bool.to_u32(up))
  +high = U32.add(hi, Bool.to_u32(U32.is_lt(low, lo)))
  finite = U32.is_lt(high, 2146435072)
  finite_double(finite, U32.or(high, sign), low)

def advance(step: NextBit, hi: U32, lo: U32, next: BitSource -> U32 -> U32 -> L.Checked(T.Cell)) -> L.Checked(T.Cell):
  NextBit{bit, source} = step
  next(source, hi, U32.or(lo, bit))

def mantissa(n: Nat, source: BitSource, hi: U32, +lo: U32, exp: U32, sign: U32) -> L.Checked(T.Cell):
  match n:
    case 0n: pack(U32.or(hi, U32.shln(exp, 20n)), lo, sign, next_bit(source))
    case 1n+k:
      advance(next_bit(source), U32.or(U32.shl(hi), U32.shrn(lo, 31n)), U32.shl(lo), (s => h => l => mantissa(k, s, h, l, exp, sign)))

def normalized(step: NextBit, exp: U32, sign: U32, more: BitSource -> L.Checked(T.Cell)) -> L.Checked(T.Cell):
  match step:
    case NextBit{0, source}: more(source)
    case NextBit{_, source}: mantissa(52n, source, 0, 0, exp, sign)

def leading(fuel: Nat, source: BitSource, +exp: U32, +sign: U32) -> L.Checked(T.Cell):
  match fuel:
    case 0n: mantissa(52n, source, 0, 0, 0, sign)
    case 1n+k: normalized(next_bit(source), exp, sign, s => leading(k, s, U32.sub(exp, 1), sign))

def start(whole: Digits, fraction: Digits, sign: U32) -> L.Checked(T.Cell):
  match whole fraction:
    case Nil{} Nil{}: Done{T.Double{sign, 0}}
    case Nil{} f: leading(1022n, Source{Nil{}, f}, 1022, sign)
    case Con{_, +t} f:
      exp = U32.add(1023, U32.from_nat(List.length(&2, U32, t)))
      mantissa(52n, Source{t, f}, 0, 0, exp, sign)

def double(whole: String, fraction: String, negative: Bool) -> L.Checked(T.Cell):
  do L.Checked<T.Cell>:
    w : Digits <- digits(whole, Nil{})
    f : Digits <- digits(fraction, Nil{})
    bits : Digits <- integer_bits(1024n, trim(w), Nil{})
    start(bits, trim(List.reverse(&2, U32, f)), Bool.pick(U32, negative, 2147483648, 0))

def finite_float(finite: Bool, f: F32) -> L.Checked(T.Cell):
  match finite:
    case True{}: Done{T.Float{f}}
    case False{}: L.error(T.Cell, "FLOAT literal is out of range")

def float_value(value: Maybe<&2, F32>) -> L.Checked(T.Cell):
  match value:
    case None{}: L.error(T.Cell, "invalid FLOAT literal")
    case Some{+f}: finite_float(U32.is_ne(U32.and(F32.bits(f), 2139095040), 2139095040), f)

def parse(whole: String, fraction: String, +negative: Bool, kind: String) -> L.Checked(T.Cell):
  match kind:
    case "DOUBLE": double(whole, fraction, negative)
    case "FLOAT":
      float_value(F32.read(Bool.pick(String, negative, "-", "") ++ whole ++ "." ++ fraction))
    case _: L.error(T.Cell, "decimal literal requires FLOAT or DOUBLE")
