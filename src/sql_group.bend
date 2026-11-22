import Base
import ./sql_lexer.bend as L
import ./sql_parse.bend as P
import ./sql_values.bend as V
import ./sql_eval.bend as E
import ./sql_where.bend as W
import ./sql_order.bend as O
import ./table.bend as T

def Row() -> Data:
  List<&2, T.Cell>

def Rows() -> Data:
  List<&2, Row>

# Sorting by the group key keeps equal values (including NULL) adjacent.
def same(a: T.Cell, b: T.Cell) -> Bool:
  match a b:
    case T.Null{} T.Null{}: True{}
    case T.Null{} _: False{}
    case _ T.Null{}: False{}
    case x y: O.before(x, y, W.Equal{})

type BucketState is Data:
  BucketState{key: T.Cell, current: Rows, complete: List<&2, Rows>}

def put(continues: Bool, next: T.Cell, row: Row, current: Rows, acc: List<&2, Rows>) -> BucketState:
  match continues:
    case True{}: BucketState{next, row <> current, acc}
    case False{}: BucketState{next, row <> Nil{}, List.reverse(&2, Row, current) <> acc}

def buckets(sorted: List<&2, O.SortRow>, state: BucketState) -> List<&2, Rows>:
  match sorted state:
    case Nil{} BucketState{_, current, acc}: List.reverse(&2, Rows, List.reverse(&2, Row, current) <> acc)
    case Con{O.SortRow{+next, row}, tail} BucketState{key, current, acc}:
      buckets(tail, put(same(key, next), next, row, current, acc))

def groups(sorted: List<&2, O.SortRow>) -> List<&2, Rows>:
  match sorted:
    case Nil{}: Nil{}
    case O.SortRow{key, row} <> rest: buckets(rest, BucketState{key, row <> Nil{}, Nil{}})

def values(outputs: List<&2, E.Output>, +first: Row, +rows: Rows) -> L.Checked(Row):
  match outputs:
    case Nil{}: Done{Nil{}}
    case E.Out{E.At{index}, _} <> rest:
      do L.Checked<Row>:
        c : T.Cell <- E.at(first, index)
        cells : Row <- values(rest, first, rows)
        return c <> cells
    case E.Out{E.Fixed{c}, _} <> rest:
      do L.Checked<Row>:
        cells : Row <- values(rest, first, rows)
        return c <> cells
    case E.Out{agg, _} <> rest:
      do L.Checked<Row>:
        c : T.Cell <- E.aggregate(agg, rows)
        cells : Row <- values(rest, first, rows)
        return c <> cells

def summarize(groups: List<&2, Rows>, +outputs: List<&2, E.Output>, acc: Rows) -> L.Checked(Rows):
  match groups:
    case Nil{}: Done{List.reverse(&2, Row, acc)}
    case (+row <> t) <> rest:
      do L.Checked<Rows>:
        result : Row <- values(outputs, row, row <> t)
        summarize(rest, outputs, result <> acc)
    case Nil{} <> rest: summarize(rest, outputs, acc)

def valid(outputs: List<&2, E.Output>, +key: Nat) -> Bool:
  match outputs:
    case Nil{}: True{}
    case E.Out{E.At{i}, _} <> rest: Nat.is_eq(i, key) && valid(rest, key)
    case _ <> rest: valid(rest, key)

def collect(ref: E.ColumnRef, rows: Rows, +outputs: List<&2, E.Output>) -> L.Checked(T.Table):
  E.Ref{+index, _, +kind} = ref
  allowed = O.sortable(kind)
  do L.Checked<T.Table>:
    _ : Unit <- P.expect(Unit, allowed, Unit{}, "unsupported GROUP BY column type")
    _ : Unit <- P.expect(Unit, valid(outputs, index), Unit{}, "projected column is missing from GROUP BY")
    keys : List<&2, O.SortRow> <- O.keyed(rows, index, Nil{})
    result : Rows <- summarize(groups(List.sort(~O.SortRow, ~O.ascending, keys)), outputs, Nil{})
    return T.Table{E.output_columns(outputs), result}

def grouping_name(tokens: L.Tokens) -> L.Checked(String):
  match tokens:
    case L.Keyword{"BY"} <> L.Name{name} <> Nil{}: Done{name}
    case _: L.error(String, "expected GROUP BY column")

def project(found: Bool, group_tokens: L.Tokens, items: L.Tokens, table: T.Table) -> L.Checked(T.Table):
  match found table:
    case False{} t: E.select(items, t)
    case True{} T.Table{+cols, rows}:
      do L.Checked<T.Table>:
        name : String <- grouping_name(group_tokens)
        ref : E.ColumnRef <- E.find(cols, name, 0n)
        parsed : List<&2, P.Item> <- P.items(P.segments(items, Nil{}, Nil{}))
        outputs : List<&2, E.Output> <- E.bind(parsed, cols)
        collect(ref, rows, outputs)
