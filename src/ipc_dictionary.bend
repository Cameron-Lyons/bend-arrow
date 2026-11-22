import Base
import ./table.bend as T
import ./arrow_layout.bend as A
import ./ipc_flatbuffer.bend as F
import ./random_access_list.bend as Index

type Encoding is Data:
  Plain{}
  Encoded{id: String, indices: A.Physical}

# Dictionary IDs are opaque 64-bit values, independent of array sizes.
def id_at(+r: F.Region, pos: U32) -> F.R(String):
  match pos:
    case 0: Done{"0:0"}
    case +p:
      do F.R<String>:
        low : U32 <- F.at(r, p, 4)
        high : U32 <- F.at(r, (p + 4 : U32), 4)
        return U32.show(high) ++ ":" ++ U32.show(low)

def id(+obj: F.Object) -> F.R(String):
  do F.R<String>:
    pos : U32 <- F.slot(obj, 0, 8)
    id_at(F.data(obj), pos)

# Push each new value onto the front of a persistent index. The newest value
# has position zero, so deltas require no copying of earlier dictionary values.
type Values is Data:
  Values{count: U32, entries: Index.Index(T.Cell)}

type Dictionary is Data:
  Dictionary{kind: A.Physical, values: Maybe<&2, Values>}

def Registry() -> Data:
  Map<&2, Maybe<&2, Dictionary>>

def result(pair: Registry & Maybe<&2, Dictionary>) -> Maybe<&2, Dictionary>:
  (_, dict) = pair
  dict

def lookup(reg: Registry, id: String) -> Maybe<&2, Dictionary>:
  result(Map.get(Maybe<&2, Dictionary>, None{}, reg, id))

def declare(reg: Registry, id: String, +kind: A.Physical, existing: Maybe<&2, Dictionary>) -> F.R(Registry):
  match existing:
    case None{}: Done{Map.set(&2, Maybe<&2, Dictionary>, reg, id, Some{Dictionary{kind, None{}}})}
    case Some{Dictionary{prior, _}}:
      do F.R<Registry>:
        F.check(String.eq(A.sql_type(prior), A.sql_type(kind)), "incompatible types share a dictionary ID")
        return reg

def require(existing: Maybe<&2, Dictionary>) -> F.R(Dictionary):
  match existing:
    case Some{d}: Done{d}
    case None{}: F.fail(Dictionary, "undeclared dictionary ID")

def kind(d: Dictionary) -> A.Physical:
  Dictionary{k, _} = d
  k

def base(d: Dictionary, delta: Bool) -> F.R(Values):
  match d delta:
    case _ False{}: Done{Values{0, Nil{}}}
    case Dictionary{_, Some{v}} True{}: Done{v}
    case _ _: F.fail(Values, "dictionary delta precedes its base")

def extend(cells: List<&2, T.Cell>, v: Values) -> Values:
  match cells:
    case Nil{}: v
    case h <> t:
      Values{n, entries} = v
      extend(t, Values{(n + 1 : U32), Index.push(T.Cell, h, entries)})

def found(v: Maybe<&2, T.Cell>) -> F.R(T.Cell):
  match v:
    case Some{v}: Done{v}
    case None{}: F.fail(T.Cell, "dictionary index out of bounds")

def index_value(index: U32, n: U32, entries: Index.Index(T.Cell)) -> F.R(T.Cell):
  found(Index.seek(T.Cell, entries, (n - 1 - index : U32)))

def decoded(c: T.Cell, values: Maybe<&2, Values>) -> F.R(T.Cell):
  match c values:
    case T.Null{} _: Done{T.Null{}}
    case T.Signed{0, low} Some{Values{n, es}}: index_value(low, n, es)
    case T.Unsigned{0, low} Some{Values{n, es}}: index_value(low, n, es)
    case _ None{}: F.fail(T.Cell, "dictionary key precedes its dictionary")
    case _ _: F.fail(T.Cell, "dictionary index out of bounds")

def unpack(cells: List<&2, T.Cell>, +values: Maybe<&2, Values>, acc: List<&2, T.Cell>) -> F.R(List<&2, T.Cell>):
  match cells:
    case Nil{}: Done{List.reverse(&2, T.Cell, acc)}
    case h <> t:
      do F.R<List<&2, T.Cell>>:
        value : T.Cell <- decoded(h, values)
        unpack(t, values, value <> acc)

def expand(d: Dictionary, cells: List<&2, T.Cell>) -> F.R(List<&2, T.Cell>):
  Dictionary{_, values} = d
  unpack(cells, values, Nil{})
