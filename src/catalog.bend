import Base
import ./sql_lexer.bend as L
import ./sql_parse.bend as P
import ./sql_values.bend as V
import ./sql.bend as SQL
import ./table.bend as T

def Entries() -> Data:
  List<&2, SQL.Entry>

type Catalog is Data:
  Catalog{stored: Entries, temporary: Entries}

def visible(c: Catalog) -> Entries:
  Catalog{stored, temp} = c
  List.append(&2, SQL.Entry, temp, stored)

def same(x: String, y: String) -> Bool:
  String.eq(String.to_upper(x), String.to_upper(y))

def contains(xs: Entries, +name: String) -> Bool:
  match xs:
    case Nil{}: False{}
    case SQL.Entry{key, _} <> t: same(key, name) || contains(t, name)

def add(c: Catalog, +name: String, table: T.Table, temp: Bool) -> L.Checked(Catalog):
  Catalog{+stored, +local} = c
  +entry : SQL.Entry = SQL.Entry{name, table}
  valid = Bool.not(String.is_empty(name) || contains(stored, name) || contains(local, name))
  next = Bool.pick(Catalog, temp, Catalog{stored, entry <> local}, Catalog{entry <> stored, local})
  P.expect(Catalog, valid, next, "table already exists or name is empty")

def sql_type(+upper: String) -> L.Checked(String):
  match upper:
    case "INT": Done{"INTEGER"}
    case "INTEGER": Done{"INTEGER"}
    case "BIGINT": Done{"BIGINT"}
    case "VARCHAR": Done{"VARCHAR"}
    case "BOOLEAN": Done{"BOOLEAN"}
    case _: L.error(String, "unsupported CREATE TABLE column type")

def unique(cols: List<&2, T.Column>, +name: String) -> Bool:
  match cols:
    case Nil{}: True{}
    case T.Column{n, _} <> t: Bool.not(same(name, n)) && unique(t, name)

def definitions(tokens: L.Tokens) -> L.Checked(List<&2, T.Column>):
  match tokens:
    case L.Name{name} <> L.Name{t} <> L.Symbol{41} <> Nil{}:
      do L.Checked<List<&2, T.Column>>:
        kind : String <- sql_type(String.to_upper(t))
        return [T.Column{name, kind}]
    case L.Name{+name} <> L.Name{t} <> L.Symbol{44} <> tail:
      do L.Checked<List<&2, T.Column>>:
        kind : String <- sql_type(String.to_upper(t))
        +rest : List<&2, T.Column> <- definitions(tail)
        P.expect(List<&2, T.Column>, unique(rest, name), T.Column{name, kind} <> rest, "duplicate column")
    case _: L.error(List<&2, T.Column>, "expected column name and type")

def create(tokens: L.Tokens, +catalog: Catalog, temp: Bool, external: Entries) -> L.Checked(Catalog):
  match tokens:
    case L.Name{name} <> L.Symbol{40} <> tail:
      do L.Checked<Catalog>:
        cols : List<&2, T.Column> <- definitions(tail)
        add(catalog, name, T.Table{cols, Nil{}}, temp)
    case L.Name{name} <> L.Keyword{"AS"} <> tail:
      do L.Checked<Catalog>:
        table : T.Table <- SQL.query_tokens(tail, List.append(&2, SQL.Entry, external, visible(catalog)))
        add(catalog, name, table, temp)
    case _: L.error(Catalog, "expected CREATE TABLE name (...) or AS SELECT")

def check_value(+target: String, +source: String) -> Bool:
  String.eq(source, "NULL") || String.eq(target, source) || (String.eq(target, "BIGINT") && String.eq(source, "INTEGER"))

def compatible(cols: List<&2, T.Column>, row: V.Literals) -> Bool:
  match cols row:
    case Nil{} Nil{}: True{}
    case Con{T.Column{_, t}, cs} Con{P.Lit{_, s, _}, vs}: check_value(t, s) && compatible(cs, vs)
    case _ _: False{}

def valid_rows(rows: V.Rows, +cols: List<&2, T.Column>) -> Bool:
  match rows:
    case Nil{}: True{}
    case row <> t: compatible(cols, row) && valid_rows(t, cols)

def insert_rows(table: T.Table, +values: V.Rows) -> L.Checked(T.Table):
  T.Table{+cols, rows} = table
  P.expect(T.Table, valid_rows(values, cols), T.Table{cols, List.append(&2, List<&2, T.Cell>, rows, V.table_rows(values))}, "VALUES row disagrees with table schema")

def update_entry(name: String, +values: V.Rows, key: String, table: T.Table, tail: Entries, found: Bool, more: V.Rows -> L.Checked(Entries)) -> L.Checked(Entries):
  match found:
    case True{}:
      do L.Checked<Entries>:
        result : T.Table <- insert_rows(table, values)
        return SQL.Entry{key, result} <> tail
    case False{}:
      do L.Checked<Entries>:
        rest : Entries <- more(values)
        return SQL.Entry{key, table} <> rest

def update_entries(xs: Entries, +name: String, +values: V.Rows) -> L.Checked(Entries):
  match xs:
    case Nil{}: L.error(Entries, "unknown table")
    case SQL.Entry{+key, +table} <> +tail:
      update_entry(name, values, key, table, tail, same(key, name), rest => update_entries(tail, name, rest))

def insert_into(stored: Entries, local: Entries, name: String, rows: V.Rows, temp: Bool) -> L.Checked(Catalog):
  match temp:
    case True{}:
      do L.Checked<Catalog>:
        next : Entries <- update_entries(local, name, rows)
        return Catalog{stored, next}
    case False{}:
      do L.Checked<Catalog>:
        next : Entries <- update_entries(stored, name, rows)
        return Catalog{next, local}

def insert(c: Catalog, +name: String, +tokens: L.Tokens) -> L.Checked(Catalog):
  Catalog{stored, +local} = c
  do L.Checked<Catalog>:
    rows : V.Rows <- V.parse_rows(List.length(&2, L.Token, tokens), tokens)
    insert_into(stored, local, name, rows, contains(local, name))

# Track persistent changes separately from connection-local changes.
type Edit is Data:
  Edit{catalog: Catalog, dirty: Bool}

def modified(value: L.Checked(Catalog), dirty: Bool) -> L.Checked(Edit):
  do L.Checked<Edit>:
    c : Catalog <- value
    return Edit{c, dirty}

def execute(tokens: L.Tokens, +c: Catalog, external: Entries) -> L.Checked(Edit):
  match tokens:
    case L.Keyword{"CREATE"} <> L.Keyword{"TABLE"} <> t: modified(create(t, c, False{}, external), True{})
    case L.Keyword{"CREATE"} <> L.Keyword{"TEMP"} <> L.Keyword{"TABLE"} <> t: modified(create(t, c, True{}, external), False{})
    case L.Keyword{"CREATE"} <> L.Keyword{"TEMPORARY"} <> L.Keyword{"TABLE"} <> t: modified(create(t, c, True{}, external), False{})
    case L.Keyword{"INSERT"} <> L.Keyword{"INTO"} <> L.Name{+n} <> L.Keyword{"VALUES"} <> t:
      Catalog{_, locals} = c
      modified(insert(c, n, t), Bool.not(contains(locals, n)))
    case L.Keyword{"SELECT"} <> t:
      do L.Checked<Edit>:
        _ : T.Table <- SQL.query_tokens(L.Keyword{"SELECT"} <> t, List.append(&2, SQL.Entry, external, visible(c)))
        return Edit{c, False{}}
    case _: L.error(Edit, "unsupported SQL statement")
