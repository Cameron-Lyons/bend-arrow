import Base
import ./sql_lexer.bend as L
import ./table.bend as T
import ./sql_real.bend as Real

type Split is Data:
  BeforeAfter{before: L.Tokens, found: Bool, after: L.Tokens}

def delimiter(token: L.Token, key: L.Token) -> Bool:
  match token key:
    case L.Keyword{x} L.Keyword{y}: String.eq(x, y)
    case L.Symbol{x} L.Symbol{y}: U32.is_eq(x, y)
    case _ _: False{}

def split_step(found: Bool, acc: L.Tokens, tail: L.Tokens, more: L.Tokens -> Split) -> Split:
  match found:
    case True{}: BeforeAfter{List.reverse(&2, L.Token, acc), True{}, tail}
    case False{}: more(acc)

def split_go(tokens: L.Tokens, +key: L.Token, acc: L.Tokens) -> Split:
  match tokens:
    case Nil{}: BeforeAfter{List.reverse(&2, L.Token, acc), False{}, Nil{}}
    case +h <> +t:
      # Choose before recurring so a found separator skips the rest.
      split_step(delimiter(h, key), acc, t, go => split_go(t, key, h <> go))

def split(tokens: L.Tokens, key: L.Token) -> Split:
  split_go(tokens, key, Nil{})

def expect(-A: Type, ok: Bool, value: A, error: String) -> L.Checked(A):
  match ok:
    case True{}: Done{value}
    case False{}: L.error(A, error)

# A typed SQL literal, including its display name when projected without an AS.
type Literal is Data:
  Lit{cell: T.Cell, kind: String, label: String}

def integer_type(+hi: U32, +lo: U32) -> String:
  fits = (U32.is_zero(hi) && U32.is_lt(lo, 2147483648)) || (U32.is_eq(hi, 4294967295) && U32.is_ge(lo, 2147483648))
  Bool.pick(String, fits, "INTEGER", "BIGINT")

type Words is Data:
  Words{hi: U32, lo: U32}

def decimal(digits: String, +hi: U32, +lo: U32) -> L.Checked(Words):
  match digits:
    case SNil{}: Done{Words{hi, lo}}
    case SCon{Chr{+d}, rest}:
      # Split the low word so multiplying it by ten retains the carry.
      +low = U32.add(U32.mul(U32.and(lo, 65535), 10), U32.sub(d, 48))
      +mid = U32.add(U32.mul(U32.shrn(lo, 16n), 10), U32.shrn(low, 16n))
      +carry = U32.shrn(mid, 16n)
      valid = Char.is_digit(Chr{d}) && U32.is_le(hi, U32.div(U32.sub(4294967295, carry), 10))
      do L.Checked<Words>:
        _ : Unit <- expect(Unit, valid, Unit{}, "invalid or overflowing integer literal")
        decimal(rest, U32.add(U32.mul(hi, 10), carry), U32.or(U32.shln(mid, 16n), U32.and(low, 65535)))

def signed_words(negative: Bool, +hi: U32, +lo: U32, label: String) -> L.Checked(Literal):
  match negative:
    case False{}:
      expect(Literal, U32.is_lt(hi, 2147483648), Lit{T.Signed{hi, lo}, integer_type(hi, lo), label}, "integer exceeds BIGINT")
    case True{}:
      +upper = U32.sub(U32.sub(0, hi), Bool.to_u32(U32.is_ne(lo, 0)))
      +lower = U32.sub(0, lo)
      in_range = U32.is_lt(hi, 2147483648) || (U32.is_eq(hi, 2147483648) && U32.is_zero(lo))
      expect(Literal, in_range, Lit{T.Signed{upper, lower}, integer_type(upper, lower), "-" ++ label}, "integer exceeds BIGINT")

def signed_result(w: Words, negative: Bool, label: String) -> L.Checked(Literal):
  Words{hi, lo} = w
  signed_words(negative, hi, lo, label)

def integer(+text: String, negative: Bool) -> L.Checked(Literal):
  do L.Checked<Literal>:
    words : Words <- decimal(text, 0, 0)
    signed_result(words, negative, text)

def unsigned_limit(kind: String) -> U32:
  match kind:
    case "UTINYINT": 255
    case "USMALLINT": 65535
    case _: 4294967295

def unsigned_kind(+kind: String) -> Bool:
  String.eq(kind, "UTINYINT") || String.eq(kind, "USMALLINT") || String.eq(kind, "UINTEGER") || String.eq(kind, "UBIGINT")

def unsigned_value(words: Words, +kind: String, label: String) -> L.Checked(Literal):
  Words{+hi, +lo} = words
  fits = String.eq(kind, "UBIGINT") || (U32.is_zero(hi) && U32.is_le(lo, unsigned_limit(kind)))
  expect(Literal, fits, Lit{T.Unsigned{hi, lo}, kind, label}, "unsigned literal exceeds its target type")

def real_literal(+whole: String, +fraction: String, +negative: Bool, +kind: String) -> L.Checked(Literal):
  do L.Checked<Literal>:
    c : T.Cell <- Real.parse(whole, fraction, negative, kind)
    return Lit{c, kind, Bool.pick(String, negative, "-", "") ++ whole ++ "." ++ fraction}

def literal(tokens: L.Tokens) -> L.Checked(Literal):
  match tokens:
    case L.Number{w} <> L.Symbol{46} <> L.Number{f} <> Nil{}: real_literal(w, f, False{}, "DOUBLE")
    case L.Symbol{45} <> L.Number{w} <> L.Symbol{46} <> L.Number{f} <> Nil{}: real_literal(w, f, True{}, "DOUBLE")
    case L.Number{x} <> Nil{}: integer(x, False{})
    case L.Symbol{45} <> L.Number{x} <> Nil{}: integer(x, True{})
    case L.StringLiteral{+s} <> Nil{}: Done{Lit{T.Utf8{s}, "VARCHAR", s}}
    case L.Keyword{"TRUE"} <> Nil{}: Done{Lit{T.Boolean{True{}}, "BOOLEAN", "true"}}
    case L.Keyword{"FALSE"} <> Nil{}: Done{Lit{T.Boolean{False{}}, "BOOLEAN", "false"}}
    case L.Keyword{"NULL"} <> Nil{}: Done{Lit{T.Null{}, "NULL", "NULL"}}
    case _: L.error(Literal, "expected an integer, string, boolean, or NULL literal")

type Expr is Data:
  Field{name: String}
  Constant{literal: Literal}
  RowCount{}
  ColumnSum{name: String}

type Item is Data:
  Item{expression: Expr, alias: Maybe<&2, String>, cast: Maybe<&2, String>}

def scalar_fn(+func: String, name: String) -> L.Checked(Expr):
  expect(Expr, String.eq(String.to_upper(func), "SUM"), ColumnSum{name}, "expected SUM(column)")

def expression(tokens: L.Tokens) -> L.Checked(Expr):
  match tokens:
    case L.Name{f} <> L.Symbol{40} <> L.Symbol{42} <> L.Symbol{41} <> Nil{}:
      expect(Expr, String.eq(String.to_upper(f), "COUNT"), RowCount{}, "expected COUNT(*)")
    case L.Name{f} <> L.Symbol{40} <> L.Name{name} <> L.Symbol{41} <> Nil{}: scalar_fn(f, name)
    case L.Name{name} <> Nil{}: Done{Field{name}}
    case _:
      do L.Checked<Expr>:
        lit : Literal <- literal(tokens)
        return Constant{lit}

def alias(found: Bool, rest: L.Tokens) -> L.Checked(Maybe<&2, String>):
  match found rest:
    case False{} Nil{}: Done{None{}}
    case True{} Con{L.Name{name}, Nil{}}: Done{Some{name}}
    case _ _: L.error(Maybe<&2, String>, "expected an identifier after AS")

def cast(found: Bool, rest: L.Tokens) -> L.Checked(Maybe<&2, String>):
  match found rest:
    case False{} Nil{}: Done{None{}}
    case True{} Con{L.Symbol{58}, Con{L.Name{name}, Nil{}}}: Done{Some{String.to_upper(name)}}
    case _ _: L.error(Maybe<&2, String>, "expected ::TYPE")

def numeric_expr(+kind: String, +whole: String, +negative: Bool, unsigned: Bool) -> L.Checked(Expr):
  match unsigned:
    case True{}:
      do L.Checked<Expr>:
        _ : Unit <- expect(Unit, Bool.not(negative), Unit{}, "unsigned integer cannot be negative")
        w : Words <- decimal(whole, 0, 0)
        value : Literal <- unsigned_value(w, kind, whole)
        return Constant{value}
    case False{}:
      do L.Checked<Expr>:
        value : Literal <- real_literal(whole, "0", negative, kind)
        return Constant{value}

def cast_expr(tokens: L.Tokens, +kind: String) -> L.Checked(Expr):
  match tokens:
    case L.Number{w} <> L.Symbol{46} <> L.Number{f} <> Nil{}:
      do L.Checked<Expr>:
        v : Literal <- real_literal(w, f, False{}, kind)
        return Constant{v}
    case L.Symbol{45} <> L.Number{w} <> L.Symbol{46} <> L.Number{f} <> Nil{}:
      do L.Checked<Expr>:
        v : Literal <- real_literal(w, f, True{}, kind)
        return Constant{v}
    case L.Number{w} <> Nil{}: numeric_expr(kind, w, False{}, unsigned_kind(kind))
    case L.Symbol{45} <> L.Number{w} <> Nil{}: numeric_expr(kind, w, True{}, unsigned_kind(kind))
    case ts: expression(ts)

def typed_choice(special: Bool, converted: Unit -> L.Checked(Expr), normal: Unit -> L.Checked(Expr)) -> L.Checked(Expr):
  match special:
    case True{}: converted(Unit{})
    case False{}: normal(Unit{})

def typed_expr(cast: Maybe<&2, String>, +tokens: L.Tokens) -> L.Checked(Expr):
  match cast:
    case None{}: expression(tokens)
    case Some{+kind}:
      numeric = unsigned_kind(kind) || String.eq(kind, "FLOAT") || String.eq(kind, "DOUBLE")
      # Delay the branches so a failed or expensive conversion is only run once.
      typed_choice(numeric, _ => cast_expr(tokens, kind), _ => expression(tokens))

def item_cast(s: Split, has_alias: Bool, alias_tokens: L.Tokens) -> L.Checked(Item):
  BeforeAfter{expr, has_cast, cast_tokens} = s
  do L.Checked<Item>:
    +c : Maybe<&2, String> <- cast(has_cast, cast_tokens)
    e : Expr <- typed_expr(c, expr)
    a : Maybe<&2, String> <- alias(has_alias, alias_tokens)
    return Item{e, a, c}

def item_alias(s: Split) -> L.Checked(Item):
  BeforeAfter{body, has_alias, alias_tokens} = s
  item_cast(split(body, L.Symbol{58}), has_alias, alias_tokens)

def item(tokens: L.Tokens) -> L.Checked(Item):
  item_alias(split(tokens, L.Keyword{"AS"}))

# Split comma-separated items. Empty segments are preserved for syntax errors.
def segments(tokens: L.Tokens, current: L.Tokens, acc: List<&2, L.Tokens>) -> List<&2, L.Tokens>:
  match tokens:
    case Nil{}: List.reverse(&2, L.Tokens, List.reverse(&2, L.Token, current) <> acc)
    case L.Symbol{44} <> tail: segments(tail, Nil{}, List.reverse(&2, L.Token, current) <> acc)
    case t <> tail: segments(tail, t <> current, acc)

def items(parts: List<&2, L.Tokens>) -> L.Checked(List<&2, Item>):
  match parts:
    case Nil{}: Done{Nil{}}
    case h <> t:
      do L.Checked<List<&2, Item>>:
        first : Item <- item(h)
        rest : List<&2, Item> <- items(t)
        return first <> rest
