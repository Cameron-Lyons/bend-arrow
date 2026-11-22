import Base
import ./sql_lexer.bend as L
import ./sql_parse.bend as P
import ./table.bend as T

def Literals() -> Data:
  List<&2, P.Literal>

def Rows() -> Data:
  List<&2, Literals>

def literals(parts: List<&2, L.Tokens>) -> L.Checked(Literals):
  match parts:
    case Nil{}: Done{Nil{}}
    case h <> t:
      do L.Checked<Literals>:
        v : P.Literal <- P.literal(h)
        vs : Literals <- literals(t)
        return v <> vs

def row_end(found: Bool, rest: L.Tokens, row: Literals, more: L.Tokens -> L.Checked(Rows)) -> L.Checked(Rows):
  match found rest:
    case True{} Nil{}: Done{row <> Nil{}}
    case True{} Con{L.Symbol{44}, tail}:
      do L.Checked<Rows>:
        rows : Rows <- more(tail)
        return row <> rows
    case _ _: L.error(Rows, "expected comma or end after VALUES row")

def row_body(s: P.Split, more: L.Tokens -> L.Checked(Rows)) -> L.Checked(Rows):
  P.BeforeAfter{fields, found, rest} = s
  do L.Checked<Rows>:
    cells : Literals <- literals(P.segments(fields, Nil{}, Nil{}))
    row_end(found, rest, cells, more)

def parse_rows(fuel: Nat, tokens: L.Tokens) -> L.Checked(Rows):
  match fuel tokens:
    case 1n+n Con{L.Symbol{40}, t}: row_body(P.split(t, L.Symbol{41}), rest => parse_rows(n, rest))
    case _ _: L.error(Rows, "expected parenthesized VALUES row")

def drop_close(reversed: L.Tokens) -> L.Checked(L.Tokens):
  match reversed:
    case L.Symbol{41} <> t: Done{List.reverse(&2, L.Token, t)}
    case _: L.error(L.Tokens, "expected ')' in VALUES source")

def names(tokens: L.Tokens) -> L.Checked(List<&2, T.Column>):
  match tokens:
    case L.Name{name} <> Nil{}: Done{T.Column{name, "NULL"} <> Nil{}}
    case L.Name{name} <> L.Symbol{44} <> t:
      do L.Checked<List<&2, T.Column>>:
        other : List<&2, T.Column> <- names(t)
        return T.Column{name, "NULL"} <> other
    case _: L.error(List<&2, T.Column>, "expected a VALUES column name")

def columns(tokens: L.Tokens) -> L.Checked(List<&2, T.Column>):
  match tokens:
    case L.Name{_} <> L.Symbol{40} <> t:
      do L.Checked<List<&2, T.Column>>:
        ns : L.Tokens <- drop_close(List.reverse(&2, L.Token, t))
        names(ns)
    case _: L.error(List<&2, T.Column>, "VALUES source requires AS name(column, ...)")

def integer_kind(+kind: String) -> Bool:
  String.eq(kind, "TINYINT") || String.eq(kind, "SMALLINT") || String.eq(kind, "INTEGER") || String.eq(kind, "INT") || String.eq(kind, "BIGINT")

def merge(+prior: String, +kind: String) -> L.Checked(String):
  +same = String.eq(prior, kind) || String.eq(prior, "NULL")
  ok = same || String.eq(kind, "NULL") || (integer_kind(prior) && integer_kind(kind))
  result = Bool.pick(String, same, kind, Bool.pick(String, String.eq(kind, "NULL"), prior, "BIGINT"))
  P.expect(String, ok, result, "incompatible types in VALUES column")

def merge_row(schema: List<&2, T.Column>, row: Literals) -> L.Checked(List<&2, T.Column>):
  match schema row:
    case Nil{} Nil{}: Done{Nil{}}
    case Con{T.Column{name, prior}, tail} Con{P.Lit{_, kind, _}, t}:
      do L.Checked<List<&2, T.Column>>:
        common : String <- merge(prior, kind)
        cs : List<&2, T.Column> <- merge_row(tail, t)
        return T.Column{name, common} <> cs
    case _ _: L.error(List<&2, T.Column>, "VALUES row width differs from its column list")

def finish(schema: List<&2, T.Column>) -> List<&2, T.Column>:
  match schema:
    case Nil{}: Nil{}
    case T.Column{name, "NULL"} <> rest: T.Column{name, "INTEGER"} <> finish(rest)
    case c <> rest: c <> finish(rest)

def infer(rows: Rows, schema: List<&2, T.Column>) -> L.Checked(List<&2, T.Column>):
  match rows:
    case Nil{}: Done{schema}
    case h <> t:
      do L.Checked<List<&2, T.Column>>:
        new_schema : List<&2, T.Column> <- merge_row(schema, h)
        infer(t, new_schema)

def cells(row: Literals) -> List<&2, T.Cell>:
  match row:
    case Nil{}: Nil{}
    case P.Lit{cell, _, _} <> t: cell <> cells(t)

def table_rows(rows: Rows) -> List<&2, List<&2, T.Cell>>:
  match rows:
    case Nil{}: Nil{}
    case h <> t: cells(h) <> table_rows(t)

def from_split(s: P.Split) -> L.Checked(T.Table):
  P.BeforeAfter{body, _, suffix} = s
  do L.Checked<T.Table>:
    cols : List<&2, T.Column> <- columns(suffix)
    +toks : L.Tokens <- drop_close(List.reverse(&2, L.Token, body))
    +rows : Rows <- parse_rows(List.length(&2, L.Token, toks), toks)
    schema : List<&2, T.Column> <- infer(rows, cols)
    return T.Table{schema, table_rows(rows)}

def source(tokens: L.Tokens) -> L.Checked(T.Table):
  from_split(P.split(tokens, L.Keyword{"AS"}))
