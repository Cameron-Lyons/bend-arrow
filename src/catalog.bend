import Base
import ./sql_lexer.bend as L
import ./sql_parse.bend as P
import ./sql_values.bend as V
import ./sql.bend as SQL
import ./catalog_rows.bend as M
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

def compatible(cols: List<&2, T.Column>, row: V.Literals) -> Bool:
  match cols row:
    case Nil{} Nil{}: True{}
    case Con{T.Column{_, t}, cs} Con{P.Lit{_, s, _}, vs}: M.compatible_type(t, s) && compatible(cs, vs)
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
    case T.Column{_, t} <> ts T.Column{_, s} <> ss: M.compatible_type(t, s) && compatible_columns(ts, ss)
    case _ _: False{}

type Change is Data:
  AddValues{values: V.Rows}
  AddSelection{source: T.Table}
  Drop{}
  ModifyRows{operation: M.Operation, condition: Maybe<&2, L.Tokens>}

def append_rows(added: T.Rows, rows: T.Rows) -> T.Rows:
  match added:
    case Nil{}: rows
    case extra: List.append(&2, List<&2, T.Cell>, rows, extra)

type Changed is Data:
  Missing{}
  Changed{entries: Entries, dirty: Bool}

def updated_entry(result: M.ResultRows, cols: List<&2, T.Column>, key: String, tail: Entries) -> Changed:
  M.ResultRows{updated, dirty} = result
  Changed{SQL.Entry{key, T.Table{cols, updated}} <> tail, dirty}

def change_table(change: Change, key: String, table: T.Table, tail: Entries) -> L.Checked(Changed):
  match change:
    case Drop{}: Done{Changed{tail, True{}}}
    case AddValues{values}:
      do L.Checked<Changed>:
        updated : T.Table <- insert_rows(table, values)
        return Changed{SQL.Entry{key, updated} <> tail, True{}}
    case AddSelection{T.Table{source, +extra}}:
      T.Table{+cols, rows} = table
      do L.Checked<Changed>:
        _ : Unit <- P.expect(Unit, compatible_columns(cols, source), Unit{}, "SELECT columns disagree with target schema")
        return Changed{SQL.Entry{key, T.Table{cols, append_rows(extra, rows)}} <> tail, Bool.not(List.is_empty(&2, M.Row, extra))}
    case ModifyRows{op, condition}:
      T.Table{+cols, rows} = table
      do L.Checked<Changed>:
        result : M.ResultRows <- M.apply(op, condition, cols, rows)
        return updated_entry(result, cols, key, tail)

def prepend(entry: SQL.Entry, change: Changed) -> Changed:
  match change:
    case Missing{}: Missing{}
    case Changed{entries, dirty}: Changed{entry <> entries, dirty}

def change_entry(found: Bool, +key: String, +table: T.Table, +tail: Entries, change: Change, more: Change -> L.Checked(Changed)) -> L.Checked(Changed):
  match found:
    case True{}: change_table(change, key, table, tail)
    case False{}:
      do L.Checked<Changed>:
        result : Changed <- more(change)
        return prepend(SQL.Entry{key, table}, result)

def change_entries(xs: Entries, +name: String, change: Change) -> L.Checked(Changed):
  match xs:
    case Nil{}: Done{Missing{}}
    case SQL.Entry{+key, table} <> +tail:
      change_entry(same(key, name), key, table, tail, change, op => change_entries(tail, name, op))

# Track persistent changes separately from connection-local changes.
type Edit is Data:
  Edit{catalog: Catalog, dirty: Bool}

def modified(value: L.Checked(Catalog), dirty: Bool) -> L.Checked(Edit):
  do L.Checked<Edit>:
    c : Catalog <- value
    return Edit{c, dirty}

def stored_change(result: Changed, original: Catalog, local: Entries, optional: Bool) -> L.Checked(Edit):
  match result optional:
    case Changed{entries, dirty} _: Done{Edit{Catalog{entries, local}, dirty}}
    case Missing{} True{}: Done{Edit{original, False{}}}
    case Missing{} False{}: L.error(Edit, "unknown table")

def local_change(result: Changed, c: Catalog, name: String, change: Change, optional: Bool) -> L.Checked(Edit):
  match result c:
    case Changed{entries, _} Catalog{stored, _}: Done{Edit{Catalog{stored, entries}, False{}}}
    case Missing{} Catalog{+stored, +local}:
      do L.Checked<Edit>:
        result : Changed <- change_entries(stored, name, change)
        stored_change(result, Catalog{stored, local}, local, optional)

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

def delete_rows(tokens: L.Tokens, c: Catalog) -> L.Checked(Edit):
  match tokens:
    case L.Name{name} <> Nil{}: alter(c, name, ModifyRows{M.Delete{}, None{}}, False{})
    case L.Name{name} <> L.Keyword{"WHERE"} <> ts: alter(c, name, ModifyRows{M.Delete{}, Some{ts}}, False{})
    case _: L.error(Edit, "expected DELETE FROM name [WHERE condition]")

def update_rows(body: P.Split, name: String, c: Catalog) -> L.Checked(Edit):
  P.BeforeAfter{assignments, has_where, ts} = body
  op : M.Operation = M.Update{P.segments(assignments, Nil{}, Nil{})}
  condition = Bool.pick(Maybe<&2, L.Tokens>, has_where, Some{ts}, None{})
  alter(c, name, ModifyRows{op, condition}, False{})

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
    case L.Keyword{"DELETE"} <> L.Keyword{"FROM"} <> t: delete_rows(t, c)
    case L.Keyword{"UPDATE"} <> L.Name{name} <> L.Keyword{"SET"} <> t: update_rows(P.split(t, L.Keyword{"WHERE"}), name, c)
    case L.Keyword{"SELECT"} <> t:
      do L.Checked<Edit>:
        _ : T.Table <- SQL.query_tokens(L.Keyword{"SELECT"} <> t, List.append(&2, SQL.Entry, external, visible(c)))
        return Edit{c, False{}}
    case _: L.error(Edit, "unsupported SQL statement")
