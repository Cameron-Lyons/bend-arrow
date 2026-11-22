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

def int32(+kind: String) -> Bool:
  String.eq(kind, "INT") || String.eq(kind, "INTEGER")

def check_value(+target: String, +source: String) -> Bool:
  String.eq(source, "NULL") || String.eq(target, source) || (int32(source) && (int32(target) || String.eq(target, "BIGINT")))

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

# A SELECT supplies one schema for every row, including an empty result.
def compatible_columns(target: List<&2, T.Column>, source: List<&2, T.Column>) -> Bool:
  match target source:
    case Nil{} Nil{}: True{}
    case T.Column{_, t} <> ts T.Column{_, s} <> ss: check_value(t, s) && compatible_columns(ts, ss)
    case _ _: False{}

type Change is Data:
  AddValues{values: V.Rows}
  AddSelection{source: T.Table}
  Drop{}

def changes_table(change: Change) -> Bool:
  match change:
    case AddSelection{T.Table{_, Nil{}}}: False{}
    case _: True{}

def append_rows(added: T.Rows, rows: T.Rows) -> T.Rows:
  match added:
    case Nil{}: rows
    case extra: List.append(&2, List<&2, T.Cell>, rows, extra)

def change_table(change: Change, key: String, table: T.Table, tail: Entries) -> L.Checked(Entries):
  match change:
    case Drop{}: Done{tail}
    case AddValues{values}:
      do L.Checked<Entries>:
        updated : T.Table <- insert_rows(table, values)
        return SQL.Entry{key, updated} <> tail
    case AddSelection{T.Table{source, extra}}:
      T.Table{+cols, rows} = table
      do L.Checked<Entries>:
        _ : Unit <- P.expect(Unit, compatible_columns(cols, source), Unit{}, "SELECT columns disagree with target schema")
        return SQL.Entry{key, T.Table{cols, append_rows(extra, rows)}} <> tail

# None denotes a missing table. Some{Nil{}} is a successful drop of the last table.
def Changed() -> Data:
  Maybe<&2, Entries>

def prepend(entry: SQL.Entry, change: Changed) -> Changed:
  match change:
    case None{}: None{}
    case Some{entries}: Some{entry <> entries}

def change_entry(found: Bool, +key: String, +table: T.Table, +tail: Entries, change: Change, more: Change -> L.Checked(Changed)) -> L.Checked(Changed):
  match found:
    case True{}:
      do L.Checked<Changed>:
        next : Entries <- change_table(change, key, table, tail)
        return Some{next}
    case False{}:
      do L.Checked<Changed>:
        result : Changed <- more(change)
        return prepend(SQL.Entry{key, table}, result)

def change_entries(xs: Entries, +name: String, change: Change) -> L.Checked(Changed):
  match xs:
    case Nil{}: Done{None{}}
    case SQL.Entry{+key, table} <> +tail:
      change_entry(same(key, name), key, table, tail, change, op => change_entries(tail, name, op))

# Track persistent changes separately from connection-local changes.
type Edit is Data:
  Edit{catalog: Catalog, dirty: Bool}

def modified(value: L.Checked(Catalog), dirty: Bool) -> L.Checked(Edit):
  do L.Checked<Edit>:
    c : Catalog <- value
    return Edit{c, dirty}

def stored_change(result: Changed, original: Catalog, local: Entries, dirty: Bool, optional: Bool) -> L.Checked(Edit):
  match result optional:
    case Some{entries} _: Done{Edit{Catalog{entries, local}, dirty}}
    case None{} True{}: Done{Edit{original, False{}}}
    case None{} False{}: L.error(Edit, "unknown table")

def local_change(result: Changed, c: Catalog, name: String, +change: Change, optional: Bool) -> L.Checked(Edit):
  match result c:
    case Some{entries} Catalog{stored, _}: Done{Edit{Catalog{stored, entries}, False{}}}
    case None{} Catalog{+stored, +local}:
      do L.Checked<Edit>:
        result : Changed <- change_entries(stored, name, change)
        stored_change(result, Catalog{stored, local}, local, changes_table(change), optional)

def alter(c: Catalog, +name: String, +change: Change, optional: Bool) -> L.Checked(Edit):
  Catalog{stored, +local} = c
  do L.Checked<Edit>:
    result : Changed <- change_entries(local, name, change)
    local_change(result, Catalog{stored, local}, name, change, optional)

def insert(c: Catalog, name: String, +tokens: L.Tokens) -> L.Checked(Edit):
  do L.Checked<Edit>:
    rows : V.Rows <- V.parse_rows(List.length(&2, L.Token, tokens), tokens)
    alter(c, name, AddValues{rows}, False{})

def drop_table(tokens: L.Tokens, c: Catalog) -> L.Checked(Edit):
  match tokens:
    case L.Name{name} <> Nil{}: alter(c, name, Drop{}, False{})
    case L.Keyword{"IF"} <> Nil{}: alter(c, "IF", Drop{}, False{})
    case L.Keyword{"IF"} <> L.Keyword{"EXISTS"} <> L.Name{name} <> Nil{}: alter(c, name, Drop{}, True{})
    case _: L.error(Edit, "expected DROP TABLE [IF EXISTS] name")

def execute(tokens: L.Tokens, +c: Catalog, external: Entries) -> L.Checked(Edit):
  match tokens:
    case L.Keyword{"CREATE"} <> L.Keyword{"TABLE"} <> t: modified(create(t, c, False{}, external), True{})
    case L.Keyword{"CREATE"} <> L.Keyword{"TEMP"} <> L.Keyword{"TABLE"} <> t: modified(create(t, c, True{}, external), False{})
    case L.Keyword{"CREATE"} <> L.Keyword{"TEMPORARY"} <> L.Keyword{"TABLE"} <> t: modified(create(t, c, True{}, external), False{})
    case L.Keyword{"INSERT"} <> L.Keyword{"INTO"} <> L.Name{n} <> L.Keyword{"VALUES"} <> t: insert(c, n, t)
    case L.Keyword{"INSERT"} <> L.Keyword{"INTO"} <> L.Name{n} <> L.Keyword{"SELECT"} <> t:
      do L.Checked<Edit>:
        source : T.Table <- SQL.raw_query_tokens(L.Keyword{"SELECT"} <> t, List.append(&2, SQL.Entry, external, visible(c)))
        alter(c, n, AddSelection{source}, False{})
    case L.Keyword{"DROP"} <> L.Keyword{"TABLE"} <> t: drop_table(t, c)
    case L.Keyword{"SELECT"} <> t:
      do L.Checked<Edit>:
        _ : T.Table <- SQL.query_tokens(L.Keyword{"SELECT"} <> t, List.append(&2, SQL.Entry, external, visible(c)))
        return Edit{c, False{}}
    case _: L.error(Edit, "unsupported SQL statement")
