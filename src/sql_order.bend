import Base
import ./sql_lexer.bend as L
import ./sql_parse.bend as P
import ./arrow_layout.bend as A
import ./sql_eval.bend as E
import ./sql_where.bend as W
import ./table.bend as T

type SortKey is Data:
  SortKey{index: Nat, descending: Bool}

type Values is Data:
  EndKeys{}
  KeyValue{cell: T.Cell, descending: Bool, tail: Values}

type SortRow is Data:
  SortRow{keys: Values, row: List<&2, T.Cell>}

def then_order(order: Cmp, next: Unit -> Cmp) -> Cmp:
  match order:
    case EQ{}: next(Unit{})
    case unequal: unequal

def byte_order(xs: List<&2, U32>, ys: List<&2, U32>) -> Cmp:
  match xs ys:
    case Nil{} Nil{}: EQ{}
    case Nil{} _: LT{}
    case _ Nil{}: GT{}
    case x <> xt y <> yt:
      then_order(U32.cmp(x, y), _ => byte_order(xt, yt))

def wide_order(a: U32, b: U32, c: U32, d: U32, w: U32, x: U32, y: U32, z: U32) -> Cmp:
  then_order(W.unsigned_cmp(a, b, w, x), _ => W.unsigned_cmp(c, d, y, z))

def scalar_order(x: T.Cell, y: T.Cell) -> Cmp:
  match x y:
    case T.Signed{ah, al} T.Signed{bh, bl}: W.cmp_int(ah, al, bh, bl)
    case T.Unsigned{ah, al} T.Unsigned{bh, bl}: W.unsigned_cmp(ah, al, bh, bl)
    case T.WideSigned{a, b, c, d} T.WideSigned{w, x, y, z}:
      wide_order(U32.xor(a, 2147483648), b, c, d, U32.xor(w, 2147483648), x, y, z)
    case T.WideUnsigned{a, b, c, d} T.WideUnsigned{w, x, y, z}: wide_order(a, b, c, d, w, x, y, z)
    case T.Float{a} T.Float{b}: W.float_order(a, b)
    case T.Double{ah, al} T.Double{bh, bl}: W.real_order(ah, al, bh, bl)
    case T.Boolean{a} T.Boolean{b}: Bool.cmp(a, b)
    case T.Utf8{a} T.Utf8{b}: String.order(a, b)
    case T.Bytes{a} T.Bytes{b}: byte_order(a, b)
    case _ _: EQ{}

def directed(order: Cmp, descending: Bool) -> Cmp:
  match order descending:
    case LT{} True{}: GT{}
    case GT{} True{}: LT{}
    case same _: same

# Bound keys in a column share a physical type. NULL sorts last in either direction.
def cell_order(x: T.Cell, y: T.Cell, descending: Bool) -> Cmp:
  match x y:
    case T.Null{} T.Null{}: EQ{}
    case T.Null{} _: GT{}
    case _ T.Null{}: LT{}
    case a b: directed(scalar_order(a, b), descending)

def key_order(xs: Values, ys: Values, prior: Cmp) -> Cmp:
  match xs ys prior:
    case _ _ LT{}: LT{}
    case _ _ GT{}: GT{}
    case EndKeys{} EndKeys{} _: EQ{}
    case EndKeys{} _ _: LT{}
    case _ EndKeys{} _: GT{}
    case KeyValue{x, desc, xt} KeyValue{y, _, yt} _: key_order(xt, yt, cell_order(x, y, desc))

def before(x: SortRow, y: SortRow) -> Bool:
  SortRow{a, _} = x
  SortRow{b, _} = y
  Cmp.is_le(key_order(a, b, EQ{}))

def row_keys(keys: List<&2, SortKey>, +row: List<&2, T.Cell>) -> L.Checked(Values):
  match keys:
    case Nil{}: Done{EndKeys{}}
    case SortKey{index, desc} <> rest:
      do L.Checked<Values>:
        cell : T.Cell <- E.at(row, index)
        tail : Values <- row_keys(rest, row)
        return KeyValue{cell, desc, tail}

# Already ordered rows need no merge sort. A strictly reversed run can be
# returned directly from the accumulator because it contains no ties.
type InputOrder is Data:
  FirstKey{}
  Forward{}
  Backward{}
  Unsorted{}

def direction(previous: InputOrder, step: Cmp) -> InputOrder:
  match previous step:
    case FirstKey{} GT{}: Backward{}
    case FirstKey{} _: Forward{}
    case Forward{} GT{}: Unsorted{}
    case Forward{} _: Forward{}
    case Backward{} GT{}: Backward{}
    case _ _: Unsorted{}

def input_order(previous: InputOrder, acc: List<&2, SortRow>, next: Values) -> InputOrder:
  match previous acc:
    case Unsorted{} _: Unsorted{}
    case state Nil{}: state
    case state SortRow{last, _} <> _: direction(state, key_order(last, next, EQ{}))

def finish_sort(order: InputOrder, reversed: List<&2, SortRow>) -> List<&2, SortRow>:
  match order:
    case Backward{}: reversed
    case Unsorted{}: List.sort(~SortRow, ~before, List.reverse(&2, SortRow, reversed))
    case _: List.reverse(&2, SortRow, reversed)

def sorted_rows(rows: T.Rows, +keys: List<&2, SortKey>, order: InputOrder, +acc: List<&2, SortRow>) -> L.Checked(List<&2, SortRow>):
  match rows:
    case Nil{}: Done{finish_sort(order, acc)}
    case +row <> rest:
      do L.Checked<List<&2, SortRow>>:
        +values : Values <- row_keys(keys, row)
        sorted_rows(rest, keys, input_order(order, acc, values), SortRow{values, row} <> acc)

def sorted(rows: T.Rows, keys: List<&2, SortKey>) -> L.Checked(List<&2, SortRow>):
  sorted_rows(rows, keys, FirstKey{}, Nil{})

def unkey(rows: List<&2, SortRow>) -> T.Rows:
  match rows:
    case Nil{}: Nil{}
    case SortRow{_, row} <> rest: row <> unkey(rest)

def sortable(+kind: String) -> Bool:
  Maybe.is_some(&2, A.Physical, A.kind(kind)) || String.eq(kind, "HUGEINT") || String.eq(kind, "UHUGEINT") || String.eq(kind, "NULL")

def bind_ref(ref: E.ColumnRef, desc: Bool) -> L.Checked(SortKey):
  E.Ref{index, _, kind} = ref
  P.expect(SortKey, sortable(kind), SortKey{index, desc}, "unsupported sort key type")

def bind(cols: List<&2, T.Column>, name: String, desc: Bool) -> L.Checked(SortKey):
  do L.Checked<SortKey>:
    ref : E.ColumnRef <- E.find(cols, name, 0n)
    bind_ref(ref, desc)

def key(part: L.Tokens, cols: List<&2, T.Column>, grouping: Bool) -> L.Checked(SortKey):
  match part grouping:
    case L.Name{name} <> Nil{} _: bind(cols, name, False{})
    case L.Name{name} <> L.Keyword{"ASC"} <> Nil{} False{}: bind(cols, name, False{})
    case L.Name{name} <> L.Keyword{"DESC"} <> Nil{} False{}: bind(cols, name, True{})
    case _ True{}: L.error(SortKey, "expected GROUP BY column")
    case _ False{}: L.error(SortKey, "expected ORDER BY output_column [ASC|DESC]")

def bind_keys(parts: List<&2, L.Tokens>, +cols: List<&2, T.Column>, +grouping: Bool) -> L.Checked(List<&2, SortKey>):
  match parts:
    case Nil{}: Done{Nil{}}
    case part <> rest:
      do L.Checked<List<&2, SortKey>>:
        head : SortKey <- key(part, cols, grouping)
        tail : List<&2, SortKey> <- bind_keys(rest, cols, grouping)
        return head <> tail

def keys(tokens: L.Tokens, cols: List<&2, T.Column>, grouping: Bool) -> L.Checked(List<&2, SortKey>):
  match tokens:
    case L.Keyword{"BY"} <> rest: bind_keys(P.segments(rest, Nil{}, Nil{}), cols, grouping)
    case _: L.error(List<&2, SortKey>, "expected BY and column names")

def apply(tokens: L.Tokens, table: T.Table) -> L.Checked(T.Table):
  T.Table{+cols, rows} = table
  do L.Checked<T.Table>:
    ks : List<&2, SortKey> <- keys(tokens, cols, False{})
    ordered : List<&2, SortRow> <- sorted(rows, ks)
    return T.Table{cols, unkey(ordered)}
