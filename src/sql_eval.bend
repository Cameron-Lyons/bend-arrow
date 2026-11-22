import Base
import ./sql_lexer.bend as L
import ./sql_parse.bend as P
import ./sql_values.bend as V
import ./table.bend as T

type ColumnRef is Data:
  Ref{index: Nat, name: String, kind: String}

def finish_find(found: Maybe<&2, ColumnRef>, name: String) -> L.Checked(ColumnRef):
  match found:
    case None{}: L.error(ColumnRef, "unknown column " ++ name)
    case Some{ref}: Done{ref}

def find_hit(hit: Bool, prior: Maybe<&2, ColumnRef>, ref: ColumnRef, more: Maybe<&2, ColumnRef> -> L.Checked(ColumnRef)) -> L.Checked(ColumnRef):
  match hit prior:
    case True{} Some{_}:
      Ref{_, name, _} = ref
      L.error(ColumnRef, "ambiguous column " ++ name)
    case True{} None{}: more(Some{ref})
    case False{} found: more(found)

def find_column(cols: List<&2, T.Column>, +upper: String, name: String, +index: Nat, found: Maybe<&2, ColumnRef>) -> L.Checked(ColumnRef):
  match cols:
    case Nil{}: finish_find(found, name)
    case T.Column{+label, kind} <> rest:
      equal = String.eq(String.to_upper(label), upper)
      find_hit(equal, found, Ref{index, label, kind}, next => find_column(rest, upper, name, 1n+index, next))

def find(cols: List<&2, T.Column>, +wanted: String, index: Nat) -> L.Checked(ColumnRef):
  find_column(cols, String.to_upper(wanted), wanted, index, None{})

def at(row: List<&2, T.Cell>, index: Nat) -> L.Checked(T.Cell):
  match row index:
    case Con{x, _} 0n: Done{x}
    case Con{_, t} 1n+n: at(t, n)
    case Nil{} _: L.error(T.Cell, "row is shorter than its schema")

type Bound is Data:
  At{index: Nat}
  Fixed{cell: T.Cell}
  CountRows{}
  CountAt{index: Nat}
  SumAt{index: Nat}

type Output is Data:
  Out{source: Bound, column: T.Column}

def from_field(ref: ColumnRef) -> Output:
  Ref{index, name, kind} = ref
  Out{At{index}, T.Column{name, kind}}

def from_count(ref: ColumnRef) -> Output:
  Ref{index, label, _} = ref
  Out{CountAt{index}, T.Column{"count(" ++ label ++ ")", "BIGINT"}}

def from_sum(ref: ColumnRef) -> L.Checked(Output):
  Ref{index, name, +kind} = ref
  P.expect(Output, V.integer_kind(kind) || P.unsigned_kind(kind) || String.eq(kind, "NULL"), Out{SumAt{index}, T.Column{"sum(" ++ name ++ ")", "BIGINT"}}, "SUM expects an integer column")

def bind_expr(e: P.Expr, cols: List<&2, T.Column>) -> L.Checked(Output):
  match e:
    case P.Field{name}:
      do L.Checked<Output>:
        ref : ColumnRef <- find(cols, name, 0n)
        return from_field(ref)
    case P.Constant{P.Lit{cell, kind, label}}: Done{Out{Fixed{cell}, T.Column{label, kind}}}
    case P.RowCount{}: Done{Out{CountRows{}, T.Column{"count(*)", "BIGINT"}}}
    case P.ColumnCount{name}:
      do L.Checked<Output>:
        ref : ColumnRef <- find(cols, name, 0n)
        return from_count(ref)
    case P.ColumnSum{name}:
      do L.Checked<Output>:
        ref : ColumnRef <- find(cols, name, 0n)
        from_sum(ref)

def cast_type(cast: Maybe<&2, String>, src: Bound, label: String, +old: String) -> L.Checked(Output):
  match cast:
    case None{}: Done{Out{src, T.Column{label, old}}}
    case Some{+typ}:
      +source = P.canonical_type(old)
      allowed = String.eq(source, typ) || (String.eq(source, "INTEGER") && String.eq(typ, "BIGINT")) || (String.eq(source, "NULL") && (V.integer_kind(typ) || P.unsigned_kind(typ) || String.eq(typ, "VARCHAR") || String.eq(typ, "BOOLEAN") || String.eq(typ, "FLOAT") || String.eq(typ, "DOUBLE")))
      P.expect(Output, allowed, Out{src, T.Column{label, typ}}, "unsupported SQL cast")

def with_cast(col: Output, name: Maybe<&2, String>, cast: Maybe<&2, String>) -> L.Checked(Output):
  Out{src, T.Column{old_name, old}} = col
  cast_type(cast, src, Maybe.default(&2, String, name, old_name), old)

def bind_item(item: P.Item, cols: List<&2, T.Column>) -> L.Checked(Output):
  P.Item{e, name, cast} = item
  do L.Checked<Output>:
    col : Output <- bind_expr(e, cols)
    with_cast(col, name, cast)

def bind(items: List<&2, P.Item>, +cols: List<&2, T.Column>) -> L.Checked(List<&2, Output>):
  match items:
    case Nil{}: Done{Nil{}}
    case h <> t:
      do L.Checked<List<&2, Output>>:
        out : Output <- bind_item(h, cols)
        rest : List<&2, Output> <- bind(t, cols)
        return out <> rest

def output_columns(outputs: List<&2, Output>) -> List<&2, T.Column>:
  match outputs:
    case Nil{}: Nil{}
    case Out{_, c} <> rest: c <> output_columns(rest)

def cell(src: Bound, row: List<&2, T.Cell>) -> L.Checked(T.Cell):
  match src:
    case Fixed{value}: Done{value}
    case At{i}: at(row, i)
    case _: L.error(T.Cell, "mixing aggregates and other projections requires GROUP BY")

def project(outputs: List<&2, Output>, +row: List<&2, T.Cell>) -> L.Checked(List<&2, T.Cell>):
  match outputs:
    case Nil{}: Done{Nil{}}
    case Out{src, _} <> rest:
      do L.Checked<List<&2, T.Cell>>:
        c : T.Cell <- cell(src, row)
        r : List<&2, T.Cell> <- project(rest, row)
        return c <> r

def project_rows(rows: List<&2, List<&2, T.Cell>>, +outputs: List<&2, Output>, acc: List<&2, List<&2, T.Cell>>) -> L.Checked(List<&2, List<&2, T.Cell>>):
  match rows:
    case Nil{}: Done{List.reverse(&2, List<&2, T.Cell>, acc)}
    case row <> rest:
      do L.Checked<List<&2, List<&2, T.Cell>>>:
        r : List<&2, T.Cell> <- project(outputs, row)
        project_rows(rest, outputs, r <> acc)

# Accumulate into 128 bits so that an intermediate partial sum can exceed
# BIGINT and later cancel. Range-check only the final result.
type SumState is Data:
  EmptySum{}
  Accum{a: U32, b: U32, c: U32, d: U32}

type Carry is Data:
  Carry{word: U32, carry: U32}

def add_word(+left: U32, right: U32, carry: U32) -> Carry:
  +pair = U32.add(left, right)
  +sum = U32.add(pair, carry)
  Carry{sum, Bool.to_u32(U32.is_lt(pair, left) || U32.is_lt(sum, pair))}

def sum_high(upper: Carry, a: U32, +sign: U32, c: U32, d: U32) -> SumState:
  Carry{b, carry} = upper
  Accum{U32.add(U32.add(a, sign), carry), b, c, d}

def sum_middle(middle: Carry, a: U32, b: U32, +sign: U32, d: U32) -> SumState:
  Carry{c, carry} = middle
  sum_high(add_word(b, sign, carry), a, sign, c, d)

def sum_low(low: Carry, a: U32, b: U32, c: U32, hi: U32, sign: U32) -> SumState:
  Carry{d, carry} = low
  sum_middle(add_word(c, hi, carry), a, b, sign, d)

def add(old: SumState, value: T.Cell) -> L.Checked(SumState):
  match old value:
    case acc T.Null{}: Done{acc}
    case EmptySum{} T.Signed{+hi, lo}:
      +sign = U32.sub(0, U32.shrn(hi, 31n))
      Done{Accum{sign, sign, hi, lo}}
    case Accum{a, b, c, d} T.Signed{+hi, lo}:
      Done{sum_low(add_word(d, lo, 0), a, b, c, hi, U32.sub(0, U32.shrn(hi, 31n)))}
    case EmptySum{} T.Unsigned{hi, lo}: Done{Accum{0, 0, hi, lo}}
    case Accum{a, b, c, d} T.Unsigned{hi, lo}: Done{sum_low(add_word(d, lo, 0), a, b, c, hi, 0)}
    case _ _: L.error(SumState, "non-integer value in SUM")

def finish(sum: SumState) -> L.Checked(T.Cell):
  match sum:
    case EmptySum{}: Done{T.Null{}}
    case Accum{a, b, +c, d}:
      +sign = U32.sub(0, U32.shrn(c, 31n))
      P.expect(T.Cell, U32.is_eq(a, sign) && U32.is_eq(b, sign), T.Signed{c, d}, "SUM exceeds BIGINT")

def sum(rows: List<&2, List<&2, T.Cell>>, +index: Nat, acc: SumState) -> L.Checked(T.Cell):
  match rows:
    case Nil{}: finish(acc)
    case row <> rest:
      do L.Checked<T.Cell>:
        value : T.Cell <- at(row, index)
        next : SumState <- add(acc, value)
        sum(rest, index, next)

def present(value: T.Cell) -> U32:
  match value:
    case T.Null{}: 0
    case _: 1

def counted(index: Maybe<&2, Nat>, row: List<&2, T.Cell>) -> L.Checked(U32):
  match index:
    case None{}: Done{1}
    case Some{i}:
      do L.Checked<U32>:
        value : T.Cell <- at(row, i)
        return present(value)

def count(rows: T.Rows, +index: Maybe<&2, Nat>, hi: U32, +lo: U32) -> L.Checked(T.Cell):
  match rows:
    case Nil{}: Done{T.Signed{hi, lo}}
    case row <> rest:
      do L.Checked<T.Cell>:
        n : U32 <- counted(index, row)
        +next : U32 = U32.add(lo, n)
        count(rest, index, U32.add(hi, Bool.to_u32(U32.is_lt(next, lo))), next)

def aggregate(src: Bound, rows: List<&2, List<&2, T.Cell>>) -> L.Checked(T.Cell):
  match src:
    case SumAt{i}: sum(rows, i, EmptySum{})
    case CountRows{}: count(rows, None{}, 0, 0)
    case CountAt{i}: count(rows, Some{i}, 0, 0)
    case Fixed{value}: Done{value}
    case _: L.error(T.Cell, "mixing aggregates and other projections requires GROUP BY")

def aggregates(outputs: List<&2, Output>, +rows: List<&2, List<&2, T.Cell>>) -> L.Checked(List<&2, T.Cell>):
  match outputs:
    case Nil{}: Done{Nil{}}
    case Out{src, _} <> rest:
      do L.Checked<List<&2, T.Cell>>:
        c : T.Cell <- aggregate(src, rows)
        r : List<&2, T.Cell> <- aggregates(rest, rows)
        return c <> r

def has_aggregate(outputs: List<&2, Output>) -> Bool:
  match outputs:
    case Nil{}: False{}
    case Out{CountRows{}, _} <> _: True{}
    case Out{CountAt{_}, _} <> _: True{}
    case Out{SumAt{_}, _} <> _: True{}
    case _ <> rest: has_aggregate(rest)

def select_kind(agg: Bool, +outputs: List<&2, Output>, rows: List<&2, List<&2, T.Cell>>) -> L.Checked(T.Table):
  match agg:
    case True{}:
      do L.Checked<T.Table>:
        row : List<&2, T.Cell> <- aggregates(outputs, rows)
        return T.Table{output_columns(outputs), row <> Nil{}}
    case False{}:
      do L.Checked<T.Table>:
        result : List<&2, List<&2, T.Cell>> <- project_rows(rows, outputs, Nil{})
        return T.Table{output_columns(outputs), result}

def all_fields(cols: List<&2, T.Column>, +index: Nat) -> List<&2, Output>:
  match cols:
    case Nil{}: Nil{}
    case column <> rest: Out{At{index}, column} <> all_fields(rest, 1n+index)

def bind_select(tokens: L.Tokens, cols: List<&2, T.Column>) -> L.Checked(List<&2, Output>):
  match tokens:
    case L.Symbol{42} <> Nil{}: Done{all_fields(cols, 0n)}
    case ts:
      do L.Checked<List<&2, Output>>:
        items : List<&2, P.Item> <- P.items(P.segments(ts, Nil{}, Nil{}))
        bind(items, cols)

def select(tokens: L.Tokens, table: T.Table) -> L.Checked(T.Table):
  match tokens table:
    case Con{L.Symbol{42}, Nil{}} t: Done{t}
    case ts T.Table{cols, rows}:
      do L.Checked<T.Table>:
        +outputs : List<&2, Output> <- bind_select(ts, cols)
        select_kind(has_aggregate(outputs), outputs, rows)
