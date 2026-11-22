import Base
import ./sql_lexer.bend as L
import ./sql_parse.bend as P
import ./sql_values.bend as V
import ./sql_eval.bend as E
import ./sql_where.bend as W
import ./table.bend as T

type SortRow is Data:
  SortRow{key: T.Cell, row: List<&2, T.Cell>}

def keyed(rows: List<&2, List<&2, T.Cell>>, +index: Nat, acc: List<&2, SortRow>) -> L.Checked(List<&2, SortRow>):
  match rows:
    case Nil{}: Done{List.reverse(&2, SortRow, acc)}
    case +row <> rest:
      do L.Checked<List<&2, SortRow>>:
        key : T.Cell <- E.at(row, index)
        keyed(rest, index, SortRow{key, row} <> acc)

def unkey(rows: List<&2, SortRow>) -> List<&2, List<&2, T.Cell>>:
  match rows:
    case Nil{}: Nil{}
    case SortRow{_, row} <> rest: row <> unkey(rest)

def before(x: T.Cell, y: T.Cell, op: W.Comparison) -> Bool:
  match x y:
    case T.Null{} T.Null{}: True{}
    case T.Null{} _: False{}
    case _ T.Null{}: True{}
    case T.Signed{ah, al} T.Signed{bh, bl}: W.relation(W.cmp_int(ah, al, bh, bl), op)
    case T.Unsigned{ah, al} T.Unsigned{bh, bl}: W.relation(W.unsigned_cmp(ah, al, bh, bl), op)
    case T.Float{a} T.Float{b}: W.relation(W.float_order(a, b), op)
    case T.Double{ah, al} T.Double{bh, bl}: W.relation(W.real_order(ah, al, bh, bl), op)
    case T.Boolean{a} T.Boolean{b}: W.relation(Bool.cmp(a, b), op)
    case T.Utf8{a} T.Utf8{b}: W.relation(String.order(a, b), op)
    case _ _: False{}

def ascending(x: SortRow, y: SortRow) -> Bool:
  SortRow{a, _} = x
  SortRow{b, _} = y
  before(a, b, W.AtMost{})

def descending(x: SortRow, y: SortRow) -> Bool:
  SortRow{a, _} = x
  SortRow{b, _} = y
  before(a, b, W.AtLeast{})

def sort(rows: List<&2, SortRow>, desc: Bool) -> List<&2, List<&2, T.Cell>>:
  match desc:
    case False{}: unkey(List.sort(~SortRow, ~ascending, rows))
    case True{}: unkey(List.sort(~SortRow, ~descending, rows))

def sortable(+kind: String) -> Bool:
  V.integer_kind(kind) || P.unsigned_kind(kind) || String.eq(kind, "VARCHAR") || String.eq(kind, "BOOLEAN") || String.eq(kind, "FLOAT") || String.eq(kind, "DOUBLE") || String.eq(kind, "NULL")

def order(ref: E.ColumnRef, rows: List<&2, List<&2, T.Cell>>, desc: Bool) -> L.Checked(List<&2, List<&2, T.Cell>>):
  E.Ref{index, _, +kind} = ref
  ok = sortable(kind)
  do L.Checked<List<&2, List<&2, T.Cell>>>:
    _ : Unit <- P.expect(Unit, ok, Unit{}, "unsupported ORDER BY column type")
    rs : List<&2, SortRow> <- keyed(rows, index, Nil{})
    return sort(rs, desc)

def order_table(table: T.Table, name: String, desc: Bool) -> L.Checked(T.Table):
  T.Table{+cols, rows} = table
  do L.Checked<T.Table>:
    ref : E.ColumnRef <- E.find(cols, name, 0n)
    sorted : List<&2, List<&2, T.Cell>> <- order(ref, rows, desc)
    return T.Table{cols, sorted}

def apply(tokens: L.Tokens, table: T.Table) -> L.Checked(T.Table):
  match tokens:
    case L.Keyword{"BY"} <> L.Name{name} <> Nil{}: order_table(table, name, False{})
    case L.Keyword{"BY"} <> L.Name{name} <> L.Keyword{"ASC"} <> Nil{}: order_table(table, name, False{})
    case L.Keyword{"BY"} <> L.Name{name} <> L.Keyword{"DESC"} <> Nil{}: order_table(table, name, True{})
    case _: L.error(T.Table, "expected ORDER BY output_column [ASC|DESC]")
