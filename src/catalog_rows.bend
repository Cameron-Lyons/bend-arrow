import Base
import ./sql_lexer.bend as L
import ./sql_parse.bend as P
import ./sql_eval.bend as E
import ./sql_where.bend as W
import ./table.bend as T

def int32(+kind: String) -> Bool:
  String.eq(kind, "INT") || String.eq(kind, "INTEGER")

def compatible_type(+target: String, +source: String) -> Bool:
  String.eq(source, "NULL") || String.eq(target, source) || (int32(source) && (int32(target) || String.eq(target, "BIGINT")))

type Operation is Data:
  Delete{}
  Update{assignments: List<&2, L.Tokens>}

# A SET list is bound once. Gaps keep the original cell, and the list ends at
# the last assignment so wide rows can share the rest of their original tail.
def Assignments() -> Data:
  List<&2, Maybe<&2, E.Bound>>

def assign(index: Nat, value: E.Bound, plan: Assignments) -> L.Checked(Assignments):
  match index plan:
    case 0n Some{_} <> _: L.error(Assignments, "duplicate column in SET")
    case 0n None{} <> rest: Done{Some{value} <> rest}
    case 0n Nil{}: Done{[Some{value}]}
    case 1n+n Nil{}:
      do L.Checked<Assignments>:
        tail : Assignments <- assign(n, value, Nil{})
        return None{} <> tail
    case 1n+n head <> rest:
      do L.Checked<Assignments>:
        tail : Assignments <- assign(n, value, rest)
        return head <> tail

def scalar(src: E.Bound) -> L.Checked(E.Bound):
  match src:
    case E.Fixed{x}: Done{E.Fixed{x}}
    case E.At{i}: Done{E.At{i}}
    case _: L.error(E.Bound, "SET requires a scalar value")

def bind_value(item: P.Item, cols: List<&2, T.Column>) -> L.Checked(E.Output):
  match item:
    case P.Item{e, None{}, cast}: E.bind_item(P.Item{e, None{}, cast}, cols)
    case _: L.error(E.Output, "unexpected alias in SET")

def add_assignment(ref: E.ColumnRef, output: E.Output, plan: Assignments) -> L.Checked(Assignments):
  E.Ref{i, _, target} = ref
  E.Out{bound, T.Column{_, source}} = output
  do L.Checked<Assignments>:
    value : E.Bound <- scalar(bound)
    _ : Unit <- P.expect(Unit, compatible_type(target, source), Unit{}, "SET value disagrees with column type")
    assign(i, value, plan)

def assignment(tokens: L.Tokens, +cols: List<&2, T.Column>, plan: Assignments) -> L.Checked(Assignments):
  match tokens:
    case L.Name{name} <> L.Symbol{61} <> expr:
      do L.Checked<Assignments>:
        ref : E.ColumnRef <- E.find(cols, name, 0n)
        item : P.Item <- P.item(expr)
        output : E.Output <- bind_value(item, cols)
        add_assignment(ref, output, plan)
    case _: L.error(Assignments, "expected column = value in SET")

def bind_all(parts: List<&2, L.Tokens>, +cols: List<&2, T.Column>, plan: Assignments) -> L.Checked(Assignments):
  match parts:
    case Nil{}: Done{plan}
    case h <> t:
      do L.Checked<Assignments>:
        next : Assignments <- assignment(h, cols, plan)
        bind_all(t, cols, next)

def replacements(op: Operation, cols: List<&2, T.Column>) -> L.Checked(Maybe<&2, Assignments>):
  match op:
    case Delete{}: Done{None{}}
    case Update{parts}:
      do L.Checked<Maybe<&2, Assignments>>:
        plan : Assignments <- bind_all(parts, cols, Nil{})
        return Some{plan}

def predicate(condition: Maybe<&2, L.Tokens>, cols: List<&2, T.Column>) -> L.Checked(W.Predicate):
  match condition:
    case None{}: Done{W.Always{True{}}}
    case Some{ts}: W.parse(ts, cols, W.Terms{None{}, None{}}, Nil{}, W.Tokens{Nil{}})

def Row() -> Data:
  List<&2, T.Cell>

# All right-hand sides read from the row as it was before the update.
def replace(plan: Assignments, row: Row, +original: Row) -> L.Checked(Row):
  match plan row:
    case Nil{} remaining: Done{remaining}
    case None{} <> tail x <> xs:
      do L.Checked<Row>:
        rest : Row <- replace(tail, xs, original)
        return x <> rest
    case Some{bound} <> tail _ <> xs:
      do L.Checked<Row>:
        x : T.Cell <- E.cell(bound, original)
        rest : Row <- replace(tail, xs, original)
        return x <> rest
    case _ Nil{}: L.error(Row, "row is shorter than its schema")

type ResultRows is Data:
  ResultRows{rows: T.Rows, changed: Bool}

def select_row(hit: Bool, plan: Maybe<&2, Assignments>, +row: Row, acc: T.Rows) -> L.Checked(T.Rows):
  match hit plan:
    case False{} _: Done{row <> acc}
    case True{} None{}: Done{acc}
    case True{} Some{values}:
      do L.Checked<T.Rows>:
        updated : Row <- replace(values, row, row)
        return updated <> acc

def edit(rows: T.Rows, +pred: W.Predicate, +plan: Maybe<&2, Assignments>, acc: T.Rows, dirty: Bool) -> L.Checked(ResultRows):
  match rows:
    case Nil{}: Done{ResultRows{List.reverse(&2, Row, acc), dirty}}
    case +row <> tail:
      do L.Checked<ResultRows>:
        +hit : Bool <- W.test(pred, row)
        next : T.Rows <- select_row(hit, plan, row, acc)
        edit(tail, pred, plan, next, dirty || hit)

def edit_matching(pred: W.Predicate, plan: Maybe<&2, Assignments>, rows: T.Rows) -> L.Checked(ResultRows):
  match pred plan:
    case W.Always{False{}} _: Done{ResultRows{rows, False{}}}
    case W.Always{True{}} None{}: Done{ResultRows{Nil{}, Bool.not(List.is_empty(&2, Row, rows))}}
    case p values: edit(rows, p, values, Nil{}, False{})

def apply(op: Operation, condition: Maybe<&2, L.Tokens>, +cols: List<&2, T.Column>, rows: T.Rows) -> L.Checked(ResultRows):
  do L.Checked<ResultRows>:
    plan : Maybe<&2, Assignments> <- replacements(op, cols)
    pred : W.Predicate <- predicate(condition, cols)
    edit_matching(pred, plan, rows)
