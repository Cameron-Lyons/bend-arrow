import Base

# Byte cursors and checked results shared by the Parquet metadata and page readers.
def Bytes() -> Data:
  List<&2, U32>

def R(-A: Type) -> Type:
  Result<&1, &1, (U32 & String), A>

def R.pure(-A: Type, x: A) -> R(A):
  Done{x}

def R.bind(-A: Type, -B: Type, v: R(A), f: A -> R(B)) -> R(B):
  match v:
    case Fail{e}: Fail{e}
    case Done{x}: f(x)

def fail(-A: Type, reason: String) -> R(A):
  Fail{(22, "Parquet: " ++ reason)}

def check(ok: Bool, reason: String) -> R(Unit):
  match ok:
    case True{}: Done{Unit{}}
    case False{}: fail(Unit, reason)

def P(-A: Type) -> Type:
  Bytes() -> R(Bytes() & A)

def P.pure(-A: Type, x: A) -> P(A):
  bs => Done{(bs, x)}

def advance(-A: Type, -B: Type, f: A -> P(B), pair: Bytes() & A) -> R(Bytes() & B):
  (rest, x) = pair
  f(x, rest)

def P.bind(-A: Type, -B: Type, v: P(A), f: A -> P(B)) -> P(B):
  bs => R.bind(Bytes() & A, Bytes() & B, v(bs), advance(A, B, f))

def abort(-A: Type, reason: String) -> P(A):
  bs => fail(Bytes() & A, reason)

def lift(-A: Type, r: R(A)) -> P(A):
  match r:
    case Fail{err}: bs => Fail{err}
    case Done{v}: P.pure(A, v)

def empty(-A: Data, xs: List<&2, A>) -> Bool:
  match xs:
    case Nil{}: True{}
    case _: False{}

def count.go(-A: Data, xs: List<&2, A>, n: U32) -> U32:
  match xs:
    case Nil{}: n
    case _ <> tail: count.go(A, tail, (n + 1 : U32))

def count(-A: Data, xs: List<&2, A>) -> U32:
  count.go(A, xs, 0)

def byte(bs: Bytes()) -> R(Bytes() & U32):
  match bs:
    case h <> t: Done{(t, h)}
    case Nil{}: fail(Bytes() & U32, "unexpected end of input")

@unsafe def take.go(n: U32, bs: Bytes(), acc: Bytes()) -> R(Bytes() & Bytes()):
  match n:
    case 0: Done{(bs, List.reverse(&2, U32, acc))}
    case positive:
      match bs:
        case Nil{}: fail(Bytes() & Bytes(), "truncated byte span")
        case h <> t: take.go((positive - 1 : U32), t, h <> acc)

def take(n: U32) -> P(Bytes()):
  bs => take.go(n, bs, Nil{})

@unsafe def skip(n: U32, bs: Bytes()) -> R(Bytes()):
  match n:
    case 0: Done{bs}
    case positive:
      match bs:
        case Nil{}: fail(Bytes(), "offset outside the file")
        case _ <> t: skip((positive - 1 : U32), t)

def little(bs: Bytes) -> U32:
  match bs:
    case Nil{}: 0
    case h <> t: (h + little(t) * 256 : U32)

def le32(bs: Bytes()) -> R(Bytes() & U32):
  match bs:
    case a <> b <> c <> d <> rest:
      Done{(rest, (a + b * 256 + c * 65536 + d * 16777216 : U32))}
    case _: fail(Bytes() & U32, "truncated little-endian word")

# Compact protocol integer values wider than a U32 are valid in unknown metadata
# fields. Keep them distinct so they cannot wrap into a usable length or offset.
type Number is Data:
  Small{value: U32}
  Wide{}

@unsafe def varint.go(+shift: U32, acc: U32, bs: Bytes()) -> R(Bytes() & Number):
  match bs:
    case Nil{}: fail(Bytes() & Number, "truncated varint")
    case +h <> t:
      varint.step(shift, acc, h, t, U32.is_ge(h, 128))

@unsafe def varint.step(+shift: U32, acc: U32, +h: U32, tail: Bytes(), more: Bool) -> R(Bytes() & Number):
  match more:
    case True{}:
      do R<Bytes() & Number>:
        check(U32.is_lt(shift, 63), "overlong varint")
        varint.go((shift + 7 : U32), U32.or(acc, (U32.and(h, 127) << U32.to_nat(shift) : U32)), tail)
    case False{}:
      do R<Bytes() & Number>:
        check(U32.is_lt(shift, 63) || U32.is_le(h, 1), "varint exceeds 64 bits")
        return (tail, varint.finish(U32.or(acc, (h << U32.to_nat(shift) : U32)), U32.is_lt(shift, 28) || (U32.is_eq(shift, 28) && U32.is_le(h, 15))))

def varint.finish(word: U32, small: Bool) -> Number:
  match small:
    case True{}: Small{word}
    case False{}: Wide{}

def small_int(n: Number) -> R(U32):
  match n:
    case Small{v}: Done{v}
    case Wide{}: fail(U32, "integer exceeds the reader's 32-bit range")

def uint() -> P(U32):
  do P<U32>:
    n : Number <- varint.go(0, 0)
    lift(U32, small_int(n))

type Value is Data:
  Int{n: Number}
  Bin{bytes: Bytes()}
  Seq{items: List<&2, Value>}
  Struct{fields: List<&2, Field>}
  Flag{value: Bool}
  Other{}

type Field is Data:
  Field{id: U32, value: Value}

def zig(n: Number) -> Number:
  match n:
    case Wide{}: Wide{}
    case Small{+v}: Small{U32.xor((v >> 1n : U32), (0 - U32.and(v, 1) : U32))}

def size_nibble(n: U32) -> P(U32):
  match n:
    case 15: uint()
    case x: P.pure(U32, x)

def field_id(previous: U32, delta: U32) -> P(U32):
  match delta:
    case 0:
      do P<U32>:
        n : Number <- varint.go(0, 0)
        lift(U32, small_int(zig(n)))
    case k: P.pure(U32, (previous + k : U32))

@unsafe def fields(depth: U32, previous: U32, acc: List<&2, Field>) -> P(Value):
  do P<Value>:
    h : U32 <- byte
    field(depth, previous, acc, h)

@unsafe def field(+depth: U32, previous: U32, acc: List<&2, Field>, header: U32) -> P(Value):
  match header:
    case 0: P.pure(Value, Struct{acc})
    case +h:
      do P<Value>:
        +id : U32 <- field_id(previous, (h >> 4n : U32))
        v : Value <- value(depth, U32.and(h, 15))
        fields(depth, id, Field{id, v} <> acc)

@unsafe def sequence(+depth: U32, +kind: U32, n: U32, acc: List<&2, Value>) -> P(Value):
  match n:
    case 0: P.pure(Value, Seq{List.reverse(&2, Value, acc)})
    case positive:
      do P<Value>:
        v : Value <- item(depth, kind)
        sequence(depth, kind, (positive - 1 : U32), v <> acc)

# Booleans in a struct are encoded in its field header; collections carry a byte.
def flag() -> P(Value):
  do P<Value>:
    +b : U32 <- byte
    lift(Unit, check(U32.is_eq(b, 1) || U32.is_eq(b, 2), "invalid compact boolean"))
    return Flag{U32.is_eq(b, 1)}

@unsafe def item(depth: U32, kind: U32) -> P(Value):
  match kind:
    case 1: flag()
    case 2: flag()
    case t: value(depth, t)

@unsafe def value(+depth: U32, kind: U32) -> P(Value):
  do P<Value>:
    lift(Unit, check(U32.is_ne(depth, 0), "metadata nesting limit exceeded"))
    value_kind((depth - 1 : U32), kind)

@unsafe def value_kind(depth: U32, kind: U32) -> P(Value):
  match kind:
    case 1: P.pure(Value, Flag{True{}})
    case 2: P.pure(Value, Flag{False{}})
    case 3:
      do P<Value>:
        b : U32 <- byte
        return Int{Small{b}}
    case 4: integer()
    case 5: integer()
    case 6: integer()
    case 7:
      do P<Value>:
        ignored : Bytes() <- take(8)
        return Other{}
    case 8:
      do P<Value>:
        n : U32 <- uint()
        b : Bytes() <- take(n)
        return Bin{b}
    case 9: collection(depth)
    case 10: collection(depth)
    case 12: fields(depth, 0, Nil{})
    case _: abort(Value, "unsupported compact metadata type")


@unsafe def collection(depth: U32) -> P(Value):
  do P<Value>:
    +h : U32 <- byte
    n : U32 <- size_nibble((h >> 4n : U32))
    sequence(depth, U32.and(h, 15), n, Nil{})

def integer() -> P(Value):
  do P<Value>:
    n : Number <- varint.go(0, 0)
    return Int{zig(n)}

@unsafe def lookup(fs: List<&2, Field>, +id: U32) -> Maybe<&2, Value>:
  match fs:
    case Nil{}: None{}
    case Field{k, v} <> rest:
      lookup.hit(rest, id, v, U32.is_eq(k, id))

@unsafe def lookup.hit(rest: List<&2, Field>, id: U32, v: Value, hit: Bool) -> Maybe<&2, Value>:
  match hit:
    case True{}: Some{v}
    case False{}: lookup(rest, id)

def as_fields(v: Value) -> R(List<&2, Field>):
  match v:
    case Struct{fs}: Done{fs}
    case _: fail(List<&2, Field>, "expected a metadata struct")

def required(v: Maybe<&2, Value>) -> R(Value):
  match v:
    case Some{x}: Done{x}
    case None{}: fail(Value, "missing required metadata field")

def get(fs: List<&2, Field>, id: U32) -> R(Value):
  required(lookup(fs, id))

def as_int(v: Value) -> R(U32):
  match v:
    case Int{n}: small_int(n)
    case _: fail(U32, "expected an integer metadata field")

def number(fs: List<&2, Field>, id: U32) -> R(U32):
  R.bind(Value, U32, get(fs, id), as_int)

def as_seq(v: Value) -> R(List<&2, Value>):
  match v:
    case Seq{xs}: Done{xs}
    case _: fail(List<&2, Value>, "expected a metadata list")

def list(fs: List<&2, Field>, id: U32) -> R(List<&2, Value>):
  R.bind(Value, List<&2, Value>, get(fs, id), as_seq)

def as_bytes(v: Value) -> R(Bytes()):
  match v:
    case Bin{bs}: Done{bs}
    case _: fail(Bytes(), "expected a binary metadata field")

def optional_int(v: Maybe<&2, Value>, fallback: U32) -> R(U32):
  match v:
    case None{}: Done{fallback}
    case Some{x}: as_int(x)

def opt_num(fs: List<&2, Field>, id: U32, fallback: U32) -> R(U32):
  optional_int(lookup(fs, id), fallback)

def no_field(fs: List<&2, Field>, id: U32) -> Bool:
  Maybe.is_none(&2, Value, lookup(fs, id))

# A copyable cursor result lets metadata decoders use both fields in do blocks.
type Step<-A: Data> is Data:
  Step{rest: Bytes(), value: A}

def box(-A: Data, pair: Bytes() & A) -> R(Step<A>):
  (bs, x) = pair
  Done{Step{bs, x}}

def step(-A: Data, r: R(Bytes() & A)) -> R(Step<A>):
  R.bind(Bytes() & A, Step<A>, r, box(A))

def rest(-A: Data, x: Step<A>) -> Bytes():
  Step{b, _} = x
  b

def parsed(-A: Data, x: Step<A>) -> A:
  Step{_, v} = x
  v
