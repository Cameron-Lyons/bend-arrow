import Base
import ./sql_lexer.bend as L
import ./sql_parse.bend as P
import ./sql_eval.bend as E
import ./sql_order.bend as O
import ./table.bend as T

def Row() -> Data:
  List<&2, T.Cell>

def Rows() -> Data:
  List<&2, Row>

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

type GroupState is Data:
  GroupState{key: O.Values, first: Row, current: Rows, complete: Rows}

def add(equal: Bool, key: O.Values, +row: Row, first: Row, current: Rows, complete: Rows, outputs: List<&2, E.Output>) -> L.Checked(GroupState):
  match equal:
    case True{}: Done{GroupState{key, first, row <> current, complete}}
    case False{}:
      do L.Checked<GroupState>:
        result : Row <- values(outputs, first, current)
        return GroupState{key, row, [row], result <> complete}

# Emit a group as soon as the next distinct key is encountered.
def summarize(sorted: List<&2, O.SortRow>, +outputs: List<&2, E.Output>, state: GroupState) -> L.Checked(Rows):
  match sorted state:
    case Nil{} GroupState{_, first, current, acc}:
      do L.Checked<Rows>:
        row : Row <- values(outputs, first, current)
        return List.reverse(&2, Row, row <> acc)
    case O.SortRow{+next, row} <> rest GroupState{key, first, current, acc}:
      do L.Checked<Rows>:
        step : GroupState <- add(Cmp.is_eq(O.key_order(key, next, EQ{})), next, row, first, current, acc, outputs)
        summarize(rest, outputs, step)

def grouped(sorted: List<&2, O.SortRow>, outputs: List<&2, E.Output>) -> L.Checked(Rows):
  match sorted:
    case Nil{}: Done{Nil{}}
    case O.SortRow{key, +row} <> rest: summarize(rest, outputs, GroupState{key, row, [row], Nil{}})

def includes(keys: List<&2, O.SortKey>, +index: Nat) -> Bool:
  match keys:
    case Nil{}: False{}
    case O.SortKey{i, _} <> rest: Nat.is_eq(i, index) || includes(rest, index)

def valid(outputs: List<&2, E.Output>, +keys: List<&2, O.SortKey>) -> Bool:
  match outputs:
    case Nil{}: True{}
    case E.Out{E.At{i}, _} <> rest: includes(keys, i) && valid(rest, keys)
    case _ <> rest: valid(rest, keys)

def project(found: Bool, group_tokens: L.Tokens, items: L.Tokens, table: T.Table) -> L.Checked(T.Table):
  match found table:
    case False{} t: E.select(items, t)
    case True{} T.Table{+cols, rows}:
      do L.Checked<T.Table>:
        +keys : List<&2, O.SortKey> <- O.keys(group_tokens, cols, True{})
        +outputs : List<&2, E.Output> <- E.bind_select(items, cols)
        _ : Unit <- P.expect(Unit, valid(outputs, keys), Unit{}, "projected column is missing from GROUP BY")
        sorted : List<&2, O.SortRow> <- O.sorted(rows, keys)
        result : Rows <- grouped(sorted, outputs)
        return T.Table{E.output_columns(outputs), result}
