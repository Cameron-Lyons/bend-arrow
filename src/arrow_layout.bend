import Base
import ./table.bend as T

def Bytes() -> Data:
  List<&2, U32>

def Outcome(-A: Type) -> Type:
  Result<&1, &1, (U32 & String), A>

# Flat Arrow types supported by the IPC reader and writer.
type Physical is Data:
  Integer{width: U32, signed: Bool}
  Real{width: U32}
  Utf8Type{}
  Binary{}
  Bit{}

def kind(name: String) -> Maybe<&2, Physical>:
  match name:
    case "TINYINT": Some{Integer{8, True{}}}
    case "UTINYINT": Some{Integer{8, False{}}}
    case "SMALLINT": Some{Integer{16, True{}}}
    case "USMALLINT": Some{Integer{16, False{}}}
    case "INTEGER": Some{Integer{32, True{}}}
    case "INT": Some{Integer{32, True{}}}
    case "UINTEGER": Some{Integer{32, False{}}}
    case "BIGINT": Some{Integer{64, True{}}}
    case "UBIGINT": Some{Integer{64, False{}}}
    case "FLOAT": Some{Real{32}}
    case "DOUBLE": Some{Real{64}}
    case "VARCHAR": Some{Utf8Type{}}
    case "BLOB": Some{Binary{}}
    case "BOOLEAN": Some{Bit{}}
    case _: None{}

def integer_name(width: U32, signed: Bool) -> String:
  match width signed:
    case 8 True{}: "TINYINT"
    case 8 False{}: "UTINYINT"
    case 16 True{}: "SMALLINT"
    case 16 False{}: "USMALLINT"
    case 32 True{}: "INTEGER"
    case 32 False{}: "UINTEGER"
    case 64 True{}: "BIGINT"
    case _ _: "UBIGINT"

def sql_type(kind: Physical) -> String:
  match kind:
    case Integer{w, s}: integer_name(w, s)
    case Real{32}: "FLOAT"
    case Real{_}: "DOUBLE"
    case Utf8Type{}: "VARCHAR"
    case Binary{}: "BLOB"
    case Bit{}: "BOOLEAN"

def length(-A: Data, xs: List<&2, A>) -> U32:
  match xs:
    case Nil{}: 0
    case _ <> tail: (1 + length(A, tail) : U32)

def join(xs: Bytes, ys: Bytes) -> Bytes:
  List.append(&2, U32, xs, ys)

def zeros(n: U32) -> Bytes:
  List.replicate(U32, U32.to_nat(n), 0)

def pad_size(+n: U32, +alignment: U32) -> U32:
  ((alignment - (n % alignment : U32) : U32) % alignment : U32)

def padded(+xs: Bytes, alignment: U32) -> Bytes:
  join(xs, zeros(pad_size(length(U32, xs), alignment)))

def u16(+n: U32) -> Bytes:
  [(n .&. 255 : U32), ((n >> 8n : U32) .&. 255 : U32)]

def u32(+n: U32) -> Bytes:
  join(u16(n), u16((n >> 16n : U32)))

def u64(n: U32) -> Bytes:
  join(u32(n), [0, 0, 0, 0])

def flag(b: Bool) -> U32:
  match b:
    case True{}: 1
    case False{}: 0

def bits(xs: List<&2, Bool>, +shift: U32, acc: U32) -> Bytes:
  match xs:
    case Nil{}:
      Bool.pick(Bytes, U32.is_zero(shift), Nil{}, [acc])
    case h <> t:
      +word = (acc .|. (flag(h) << U32.to_nat(shift) : U32) : U32)
      +next = ((shift + 1 : U32) % 8 : U32)
      +more = bits(t, next, Bool.pick(U32, U32.is_zero(next), 0, word))
      Bool.pick(Bytes, U32.is_zero(next), word <> more, more)

type Split is Data:
  Parts{cells: List<&2, T.Cell>, rest: List<&2, List<&2, T.Cell>>}

def prepend(h: T.Cell, tail: List<&2, T.Cell>, split: Split) -> Split:
  Parts{cells, rest} = split
  Parts{h <> cells, tail <> rest}

def first_column(rows: List<&2, List<&2, T.Cell>>) -> Outcome(Split):
  match rows:
    case Nil{}: Done{Parts{Nil{}, Nil{}}}
    case Nil{} <> _: Fail{(22, "row has fewer cells than fields")}
    case (h <> t) <> next:
      do Result<&1, &1, (U32 & String), Split>:
        split : Split <- first_column(next)
        return prepend(h, t, split)

def integer_fits(width: U32, +signed: Bool, +high: U32, +low: U32) -> Bool:
  match width:
    case 64: True{}
    case w:
      +bits = U32.to_nat(w)
      +mask = ((1 << bits : U32) - 1 : U32)
      neg = signed && U32.is_ne((low .&. ((mask >> 1n : U32) + 1 : U32) : U32), 0)
      +extension = Bool.pick(U32, neg, 4294967295, 0)
      U32.is_eq(high, extension) && U32.is_eq(U32.and(low, U32.not(mask)), U32.and(extension, U32.not(mask)))
