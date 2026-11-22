import Base
import ./sql_lexer.bend as L
import ./sql_parse.bend as P
import ./sql_eval.bend as E
import ./sql_values.bend as V
import ./table.bend as T

type Comparison is Data:
  Equal{}
  Unequal{}
  Less{}
  Greater{}
  AtMost{}
  AtLeast{}

type Predicate is Data:
  Always{value: Bool}
  TestNull{index: Nat, invert: Bool}
  Compare{index: Nat, op: Comparison, value: T.Cell}
  Both{left: Predicate, right: Predicate}
  EitherTrue{left: Predicate, right: Predicate}

def null_test(ref: E.ColumnRef, invert: Bool) -> Predicate:
  E.Ref{index, _, _} = ref
  TestNull{index, invert}

def comparison(ref: E.ColumnRef, op: Comparison, lit: P.Literal) -> L.Checked(Predicate):
  E.Ref{index, _, +kind} = ref
  P.Lit{value, +other, _} = lit
  integer = (V.integer_kind(kind) || P.unsigned_kind(kind)) && V.integer_kind(other)
  compatible = integer || (P.unsigned_kind(kind) && P.unsigned_kind(other)) || String.eq(kind, other) || String.eq(kind, "NULL") || String.eq(other, "NULL")
  P.expect(Predicate, compatible, Compare{index, op, value}, "comparison type differs from column")

def constant_expr(e: P.Expr) -> L.Checked(P.Literal):
  match e:
    case P.Constant{v}: Done{v}
    case _: L.error(P.Literal, "comparison requires a literal operand")

def typed_operand(+kind: String, +tokens: L.Tokens, convert: Bool) -> L.Checked(P.Literal):
  match convert:
    case False{}: P.literal(tokens)
    case True{}:
      do L.Checked<P.Literal>:
        e : P.Expr <- P.typed_expr(Some{kind}, tokens)
        constant_expr(e)

def positive(tokens: L.Tokens) -> Bool:
  match tokens:
    case L.Number{_} <> Nil{}: True{}
    case _: False{}

def operand(ref: E.ColumnRef, op: Comparison, +tokens: L.Tokens) -> L.Checked(Predicate):
  E.Ref{index, name, +kind} = ref
  +wide = P.unsigned_kind(kind) && positive(tokens)
  convert = String.eq(kind, "FLOAT") || String.eq(kind, "DOUBLE") || wide
  do L.Checked<Predicate>:
    lit : P.Literal <- typed_operand(Bool.pick(String, wide, "UBIGINT", kind), tokens, convert)
    comparison(E.Ref{index, name, kind}, op, lit)

def operator(tokens: L.Tokens, ref: E.ColumnRef) -> L.Checked(Predicate):
  match tokens:
    case L.Keyword{"IS"} <> L.Keyword{"NULL"} <> Nil{}: Done{null_test(ref, False{})}
    case L.Keyword{"IS"} <> L.Keyword{"NOT"} <> L.Keyword{"NULL"} <> Nil{}: Done{null_test(ref, True{})}
    case L.Symbol{62} <> L.Symbol{61} <> t: operand(ref, AtLeast{}, t)
    case L.Symbol{60} <> L.Symbol{61} <> t: operand(ref, AtMost{}, t)
    case L.Symbol{60} <> L.Symbol{62} <> t: operand(ref, Unequal{}, t)
    case L.Symbol{33} <> L.Symbol{61} <> t: operand(ref, Unequal{}, t)
    case L.Symbol{60} <> t: operand(ref, Less{}, t)
    case L.Symbol{62} <> t: operand(ref, Greater{}, t)
    case L.Symbol{61} <> t: operand(ref, Equal{}, t)
    case _: L.error(Predicate, "expected a comparison or IS [NOT] NULL")

def atom(tokens: L.Tokens, cols: List<&2, T.Column>) -> L.Checked(Predicate):
  match tokens:
    case L.Keyword{"TRUE"} <> Nil{}: Done{Always{True{}}}
    case L.Keyword{"FALSE"} <> Nil{}: Done{Always{False{}}}
    case L.Name{name} <> rest:
      do L.Checked<Predicate>:
        ref : E.ColumnRef <- E.find(cols, name, 0n)
        operator(rest, ref)
    case _: L.error(Predicate, "expected a WHERE condition")

# Each nesting level holds the completed OR terms and the current AND term.
# Bind every atom before evaluation, including on empty input.
type Terms is Data:
  Terms{disjunction: Maybe<&2, Predicate>, conjunction: Maybe<&2, Predicate>}

type Operand is Data:
  Tokens{reversed: L.Tokens}
  Group{value: Predicate}

def bind_operand(input: Operand, cols: List<&2, T.Column>) -> L.Checked(Predicate):
  match input:
    case Tokens{ts}: atom(List.reverse(&2, L.Token, ts), cols)
    case Group{pred}: Done{pred}

def add_and(prior: Maybe<&2, Predicate>, value: Predicate) -> Predicate:
  match prior:
    case None{}: value
    case Some{p}: Both{p, value}

def add_or(prior: Maybe<&2, Predicate>, value: Predicate) -> Predicate:
  match prior:
    case None{}: value
    case Some{p}: EitherTrue{p, value}

def finish_terms(terms: Terms, value: Predicate) -> Predicate:
  Terms{ors, ands} = terms
  add_or(ors, add_and(ands, value))

def join_terms(conjunction: Bool, terms: Terms, value: Predicate) -> Terms:
  match conjunction:
    case False{}: Terms{Some{finish_terms(terms, value)}, None{}}
    case True{}:
      Terms{ors, ands} = terms
      Terms{ors, Some{add_and(ands, value)}}

def parse(tokens: L.Tokens, +cols: List<&2, T.Column>, terms: Terms, stack: List<&2, Terms>, input: Operand) -> L.Checked(Predicate):
  match tokens:
    case Nil{}:
      match stack:
        case Nil{}:
          do L.Checked<Predicate>:
            p : Predicate <- bind_operand(input, cols)
            return finish_terms(terms, p)
        case _: L.error(Predicate, "unclosed '(' in WHERE")
    case L.Symbol{40} <> tail:
      match input:
        case Tokens{Nil{}}: parse(tail, cols, Terms{None{}, None{}}, terms <> stack, Tokens{Nil{}})
        case _: L.error(Predicate, "unexpected '(' in WHERE")
    case L.Symbol{41} <> tail:
      match stack:
        case Nil{}: L.error(Predicate, "unexpected ')' in WHERE")
        case outer <> rest:
          do L.Checked<Predicate>:
            p : Predicate <- bind_operand(input, cols)
            parse(tail, cols, outer, rest, Group{finish_terms(terms, p)})
    case L.Keyword{"AND"} <> tail:
      do L.Checked<Predicate>:
        p : Predicate <- bind_operand(input, cols)
        parse(tail, cols, join_terms(True{}, terms, p), stack, Tokens{Nil{}})
    case L.Keyword{"OR"} <> tail:
      do L.Checked<Predicate>:
        p : Predicate <- bind_operand(input, cols)
        parse(tail, cols, join_terms(False{}, terms, p), stack, Tokens{Nil{}})
    case token <> tail:
      match input:
        case Tokens{ts}: parse(tail, cols, terms, stack, Tokens{token <> ts})
        case Group{_}: L.error(Predicate, "expected AND or OR after WHERE group")

def relation(c: Cmp, op: Comparison) -> Bool:
  match c op:
    case LT{} Less{}: True{}
    case LT{} AtMost{}: True{}
    case LT{} Unequal{}: True{}
    case GT{} Greater{}: True{}
    case GT{} AtLeast{}: True{}
    case GT{} Unequal{}: True{}
    case EQ{} Equal{}: True{}
    case EQ{} AtMost{}: True{}
    case EQ{} AtLeast{}: True{}
    case _ _: False{}

def cmp_int(+ah: U32, al: U32, +bh: U32, bl: U32) -> Cmp:
  Bool.pick(Cmp, U32.is_eq(ah, bh), U32.cmp(al, bl), U32.cmp(U32.xor(ah, 2147483648), U32.xor(bh, 2147483648)))

def unsigned_cmp(+ah: U32, al: U32, +bh: U32, bl: U32) -> Cmp:
  Bool.pick(Cmp, U32.is_eq(ah, bh), U32.cmp(al, bl), U32.cmp(ah, bh))

def nan(+hi: U32, lo: U32) -> Bool:
  U32.is_eq(U32.and(hi, 2146435072), 2146435072) && (U32.is_ne(U32.and(hi, 1048575), 0) || U32.is_ne(lo, 0))

def nan_order(a: Bool, b: Bool, normal: Cmp) -> Cmp:
  match a b:
    case True{} True{}: EQ{}
    case True{} False{}: GT{}
    case False{} True{}: LT{}
    case _ _: normal

def real_order(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> Cmp:
  an = nan(ah, al)
  bn = nan(bh, bl)
  zeros = U32.is_zero(U32.or(U32.and(U32.or(ah, bh), 2147483647), U32.or(al, bl)))
  # Flip the sign bit on positives, invert all bits on negatives. Unsigned
  # word comparison then agrees with IEEE numeric order (zero handled above).
  +am = Bool.pick(U32, U32.is_ge(ah, 2147483648), 4294967295, 2147483648)
  +bm = Bool.pick(U32, U32.is_ge(bh, 2147483648), 4294967295, 2147483648)
  ordered = unsigned_cmp(U32.xor(ah, am), U32.xor(al, U32.sub(0, U32.shrn(ah, 31n))), U32.xor(bh, bm), U32.xor(bl, U32.sub(0, U32.shrn(bh, 31n))))
  nan_order(an, bn, Bool.pick(Cmp, zeros, EQ{}, ordered))

def float_order(+a: F32, +b: F32) -> Cmp:
  ordinary = Bool.pick(Cmp, F32.is_eq(a, b), EQ{}, Bool.pick(Cmp, F32.is_lt(a, b), LT{}, GT{}))
  nan_order(F32.is_ne(a, a), F32.is_ne(b, b), ordinary)

def compare(a: T.Cell, b: T.Cell, op: Comparison) -> L.Checked(Bool):
  match a b:
    case T.Null{} _: Done{False{}}
    case _ T.Null{}: Done{False{}}
    case T.Signed{ah, al} T.Signed{bh, bl}: Done{relation(cmp_int(ah, al, bh, bl), op)}
    case T.Unsigned{ah, al} T.Signed{+bh, bl}:
      Done{relation(Bool.pick(Cmp, U32.is_ge(bh, 2147483648), GT{}, unsigned_cmp(ah, al, bh, bl)), op)}
    case T.Unsigned{ah, al} T.Unsigned{bh, bl}: Done{relation(unsigned_cmp(ah, al, bh, bl), op)}
    case T.Float{a} T.Float{b}: Done{relation(float_order(a, b), op)}
    case T.Double{ah, al} T.Double{bh, bl}: Done{relation(real_order(ah, al, bh, bl), op)}
    case T.Utf8{x} T.Utf8{y}: Done{relation(String.order(x, y), op)}
    case T.Boolean{x} T.Boolean{y}: Done{relation(Bool.cmp(x, y), op)}
    case _ _: L.error(Bool, "unsupported value in comparison")

def is_null(cell: T.Cell) -> Bool:
  match cell:
    case T.Null{}: True{}
    case _: False{}

def and_next(first: Bool, next: Unit -> L.Checked(Bool)) -> L.Checked(Bool):
  match first:
    case True{}: next(Unit{})
    case False{}: Done{False{}}

def or_next(first: Bool, next: Unit -> L.Checked(Bool)) -> L.Checked(Bool):
  match first:
    case True{}: Done{True{}}
    case False{}: next(Unit{})

def test(pred: Predicate, +row: List<&2, T.Cell>) -> L.Checked(Bool):
  match pred:
    case Always{b}: Done{b}
    case TestNull{i, invert}:
      do L.Checked<Bool>:
        cell : T.Cell <- E.at(row, i)
        return Bool.xor(is_null(cell), invert)
    case Compare{i, op, other}:
      do L.Checked<Bool>:
        cell : T.Cell <- E.at(row, i)
        compare(cell, other, op)
    case Both{x, y}:
      do L.Checked<Bool>:
        a : Bool <- test(x, row)
        and_next(a, _ => test(y, row))
    case EitherTrue{x, y}:
      do L.Checked<Bool>:
        a : Bool <- test(x, row)
        or_next(a, _ => test(y, row))

def filter(rows: List<&2, List<&2, T.Cell>>, +pred: Predicate, +acc: List<&2, List<&2, T.Cell>>) -> L.Checked(List<&2, List<&2, T.Cell>>):
  match rows:
    case Nil{}: Done{List.reverse(&2, List<&2, T.Cell>, acc)}
    case +row <> rest:
      do L.Checked<List<&2, List<&2, T.Cell>>>:
        keep : Bool <- test(pred, row)
        filter(rest, pred, Bool.pick(List<&2, List<&2, T.Cell>>, keep, row <> acc, acc))

def apply(table: T.Table, tokens: L.Tokens) -> L.Checked(T.Table):
  T.Table{+cols, rows} = table
  do L.Checked<T.Table>:
    p : Predicate <- parse(tokens, cols, Terms{None{}, None{}}, Nil{}, Tokens{Nil{}})
    valid : List<&2, List<&2, T.Cell>> <- filter(rows, p, Nil{})
    return T.Table{cols, valid}
