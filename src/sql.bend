import Base
import ./sql_lexer.bend as L
import ./sql_parse.bend as P
import ./sql_values.bend as V
import ./sql_eval.bend as E
import ./sql_where.bend as W
import ./table.bend as T
import ./sql_order.bend as O
import ./sql_group.bend as G

type Entry is Data:
  Entry{name: String, table: T.Table}

def hit(ok: Bool, table: T.Table, more: Unit -> L.Checked(T.Table)) -> L.Checked(T.Table):
  match ok:
    case True{}: Done{table}
    case False{}: more(Unit{})

def lookup(tables: List<&2, Entry>, +name: String, +exact: Bool) -> L.Checked(T.Table):
  match tables:
    case Nil{}: L.error(T.Table, "unknown table or file " ++ name)
    case Entry{+key, table} <> rest:
      equal = Bool.pick(Bool, exact, String.eq(key, name), String.eq(String.to_upper(key), String.to_upper(name)))
      hit(equal, table, _ => lookup(rest, name, exact))

def range_name(tokens: L.Tokens) -> L.Checked(String):
  match tokens:
    case Nil{}: Done{"range"}
    case L.Name{_} <> L.Symbol{40} <> L.Name{name} <> L.Symbol{41} <> Nil{}: Done{name}
    case L.Keyword{"AS"} <> L.Name{_} <> L.Symbol{40} <> L.Name{name} <> L.Symbol{41} <> Nil{}: Done{name}
    case _: L.error(String, "expected range(n) or range(n) AS t(column)")

def range_rows(n: Nat, +value: U32, acc: List<&2, List<&2, T.Cell>>) -> List<&2, List<&2, T.Cell>>:
  match n:
    case 0n: List.reverse(&2, List<&2, T.Cell>, acc)
    case 1n+k: range_rows(k, U32.inc(value), (T.Signed{0, value} <> Nil{}) <> acc)

def range_table(n: P.Literal, name: String) -> L.Checked(T.Table):
  match n:
    case P.Lit{T.Signed{0, count}, _, _}:
      Done{T.Table{T.Column{name, "BIGINT"} <> Nil{}, range_rows(U32.to_nat(count), 0, Nil{})}}
    case _: L.error(T.Table, "range expects a nonnegative 32-bit bound")

def file_table(func: String, +path: String, tables: List<&2, Entry>) -> L.Checked(T.Table):
  do L.Checked<T.Table>:
    _ : Unit <- P.expect(Unit, String.eq(String.to_upper(func), "READ_PARQUET"), Unit{}, "unknown table function")
    lookup(tables, path, True{})

def source(tokens: L.Tokens, tables: List<&2, Entry>) -> L.Checked(T.Table):
  match tokens:
    case L.Name{name} <> Nil{}: lookup(tables, name, False{})
    case L.Name{f} <> L.Symbol{40} <> L.StringLiteral{path} <> L.Symbol{41} <> Nil{}: file_table(f, path, tables)
    case L.Name{f} <> L.Symbol{40} <> L.Number{n} <> L.Symbol{41} <> rest:
      do L.Checked<T.Table>:
        _ : Unit <- P.expect(Unit, String.eq(String.to_upper(f), "RANGE"), Unit{}, "unknown table function")
        count : P.Literal <- P.integer(n, False{})
        name : String <- range_name(rest)
        range_table(count, name)
    case L.Symbol{40} <> L.Keyword{"VALUES"} <> rest: V.source(rest)
    case _: L.error(T.Table, "expected a table, range, read_parquet or VALUES source")

def source_or_scalar(found: Bool, tokens: L.Tokens, tables: List<&2, Entry>) -> L.Checked(T.Table):
  match found:
    case True{}: source(tokens, tables)
    case False{}: Done{T.Table{Nil{}, Nil{} <> Nil{}}}

def filtered(found: Bool, tokens: L.Tokens, table: T.Table) -> L.Checked(T.Table):
  match found:
    case True{}: W.apply(table, tokens)
    case False{}: Done{table}

def select_table(s: P.Split, where_found: Bool, where_tokens: L.Tokens, grouped: Bool, group_tokens: L.Tokens, tables: List<&2, Entry>) -> L.Checked(T.Table):
  P.BeforeAfter{items, has_from, table_tokens} = s
  do L.Checked<T.Table>:
    table : T.Table <- source_or_scalar(has_from, table_tokens, tables)
    rows : T.Table <- filtered(where_found, where_tokens, table)
    G.project(grouped, group_tokens, items, rows)

def select_where(s: P.Split, grouped: Bool, group_tokens: L.Tokens, tables: List<&2, Entry>) -> L.Checked(T.Table):
  P.BeforeAfter{body, found, tokens} = s
  select_table(P.split(body, L.Keyword{"FROM"}), found, tokens, grouped, group_tokens, tables)

def select_group(s: P.Split, tables: List<&2, Entry>) -> L.Checked(T.Table):
  P.BeforeAfter{body, found, group_tokens} = s
  select_where(P.split(body, L.Keyword{"WHERE"}), found, group_tokens, tables)

def ordered(found: Bool, tokens: L.Tokens, table: T.Table) -> L.Checked(T.Table):
  match found:
    case False{}: Done{table}
    case True{}: O.apply(tokens, table)

def select_order(s: P.Split, tables: List<&2, Entry>) -> L.Checked(T.Table):
  P.BeforeAfter{body, found, order_tokens} = s
  do L.Checked<T.Table>:
    t : T.Table <- select_group(P.split(body, L.Keyword{"GROUP"}), tables)
    ordered(found, order_tokens, t)

def statement(tokens: L.Tokens, tables: List<&2, Entry>) -> L.Checked(T.Table):
  match tokens:
    case L.Keyword{"SELECT"} <> rest: select_order(P.split(rest, L.Keyword{"ORDER"}), tables)
    case _: L.error(T.Table, "expected SELECT")

def trim_end(reversed: L.Tokens) -> L.Tokens:
  match reversed:
    case L.Symbol{59} <> t: List.reverse(&2, L.Token, t)
    case ts: List.reverse(&2, L.Token, ts)

# INSERT SELECT resolves untyped NULL columns against its target schema.
def raw_query_tokens(tokens: L.Tokens, tables: List<&2, Entry>) -> L.Checked(T.Table):
  statement(trim_end(List.reverse(&2, L.Token, tokens)), tables)

def result_types(table: T.Table) -> T.Table:
  T.Table{cols, rows} = table
  T.Table{V.finish(cols), rows}

def query_tokens(tokens: L.Tokens, tables: List<&2, Entry>) -> L.Checked(T.Table):
  do L.Checked<T.Table>:
    table : T.Table <- raw_query_tokens(tokens, tables)
    return result_types(table)

def query(sql: String, tables: List<&2, Entry>) -> L.Checked(T.Table):
  do L.Checked<T.Table>:
    ts : L.Tokens <- L.tokenize(sql)
    query_tokens(ts, tables)

# File paths are case-sensitive and use ordinary SQL single-quote escaping.
def from_path(tokens: L.Tokens) -> Maybe<&2, String>:
  match tokens:
    case L.Keyword{"FROM"} <> L.Name{func} <> L.Symbol{40} <> L.StringLiteral{path} <> L.Symbol{41} <> _:
      Bool.pick(Maybe<&2, String>, String.eq(String.to_upper(func), "READ_PARQUET"), Some{path}, None{})
    case L.Keyword{"FROM"} <> _: None{}
    case L.Keyword{"WHERE"} <> _: None{}
    case L.Keyword{"GROUP"} <> _: None{}
    case L.Keyword{"ORDER"} <> _: None{}
    case L.Symbol{59} <> _: None{}
    case _ <> rest: from_path(rest)
    case Nil{}: None{}

def select_path(tokens: L.Tokens) -> Maybe<&2, String>:
  match tokens:
    case L.Keyword{"SELECT"} <> tail: from_path(tail)
    case _: None{}

def create_path(tokens: L.Tokens) -> Maybe<&2, String>:
  match tokens:
    case L.Keyword{"TABLE"} <> L.Name{_} <> L.Keyword{"AS"} <> tail: select_path(tail)
    case _: None{}

# Only statements with a SELECT source can request external input.
def file_path(tokens: L.Tokens) -> Maybe<&2, String>:
  match tokens:
    case L.Keyword{"CREATE"} <> L.Keyword{"TEMP"} <> tail: create_path(tail)
    case L.Keyword{"CREATE"} <> L.Keyword{"TEMPORARY"} <> tail: create_path(tail)
    case L.Keyword{"CREATE"} <> tail: create_path(tail)
    case L.Keyword{"INSERT"} <> L.Keyword{"INTO"} <> L.Name{_} <> tail: select_path(tail)
    case ts: select_path(ts)

def file_tokens(result: L.Checked(L.Tokens)) -> Maybe<&2, String>:
  match result:
    case Done{ts}: file_path(ts)
    case Fail{_}: None{}

def source_path(sql: String) -> Maybe<&2, String>:
  file_tokens(L.tokenize(sql))
