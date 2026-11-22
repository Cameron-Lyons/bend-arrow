import Base
import ../src/sql.bend as SQL
import ../src/table.bend as T

def assert(ok: Bool, text: String) -> IO(Unit):
  match ok:
    case True{}: IO.pure(Unit, Unit{})
    case False{}: IO.die(Unit, 1, text)

def checked(sql: String) -> IO(T.Table):
  IO.try(T.Table, IO.pure(Result<&1, &1, U32 & String, T.Table>, SQL.query(sql, Nil{})))

def fails(s: String) -> Bool:
  Result.is_fail(&1, &1, U32 & String, T.Table, SQL.query(s, Nil{}))

def aggregate(t: T.Table) -> Bool:
  match t:
    case T.Table{T.Column{"total", "BIGINT"} <> T.Column{"count(*)", "BIGINT"} <> Nil{}, (T.Signed{0, 19} <> T.Signed{0, 3} <> Nil{}) <> Nil{}}: True{}
    case _: False{}

def ordered(t: T.Table) -> Bool:
  match t:
    case T.Table{_, (T.Utf8{"Z'β"} <> Nil{}) <> (T.Utf8{"A"} <> Nil{}) <> (T.Null{} <> Nil{}) <> Nil{}}: True{}
    case _: False{}

def limits(t: T.Table) -> Bool:
  match t:
    case T.Table{_, (T.Signed{2147483648, 0} <> T.Signed{2147483647, 4294967295} <> Nil{}) <> Nil{}}: True{}
    case _: False{}

def empty_sum(t: T.Table) -> Bool:
  match t:
    case T.Table{_, (T.Null{} <> T.Signed{0, 0} <> Nil{}) <> Nil{}}: True{}
    case _: False{}

def ordered_real(t: T.Table) -> Bool:
  match t:
    case T.Table{_, (T.Double{3219128320, 0} <> Nil{}) <> (T.Double{1072693248, 0} <> Nil{}) <> Nil{}}: True{}
    case _: False{}

def numeric(t: T.Table) -> Bool:
  match t:
    case T.Table{_, (T.Unsigned{4294967295, 4294967295} <> T.Float{f} <> T.Double{1069128089, 2576980378} <> T.Double{2147483648, 0} <> Nil{}) <> Nil{}}:
      F32.is_eq(f, 2.5)
    case _: False{}

def cancelled(t: T.Table) -> Bool:
  match t:
    case T.Table{_, (T.Signed{2147483647, 4294967295} <> Nil{}) <> Nil{}}: True{}
    case _: False{}

def grouped(t: T.Table) -> Bool:
  match t:
    case T.Table{_, (T.Utf8{"east"} <> T.Signed{0, 12} <> Nil{}) <> (T.Null{} <> T.Signed{0, 8} <> Nil{}) <> Nil{}}: True{}
    case _: False{}

def counts(t: T.Table, non_null: U32, total: U32) -> Bool:
  match t:
    case T.Table{_ <> T.Column{name, kind} <> _ <> Nil{}, (T.Utf8{label} <> T.Signed{0, n} <> T.Signed{0, rows} <> Nil{}) <> Nil{}}:
      String.eq(name, "count(n)") && String.eq(kind, "BIGINT") && String.eq(label, "total") && U32.is_eq(n, non_null) && U32.is_eq(rows, total)
    case _: False{}

def null_types(t: T.Table) -> Bool:
  match t:
    case T.Table{T.Column{"n", "INTEGER"} <> T.Column{"s", "VARCHAR"} <> Nil{}, (T.Null{} <> T.Null{} <> Nil{}) <> Nil{}}: True{}
    case _: False{}

def two_rows(result: Result<&1, &1, U32 & String, T.Table>) -> Bool:
  match result:
    case Done{T.Table{_, (T.Signed{0, 2} <> Nil{}) <> Nil{}}}: True{}
    case _: False{}

def unsigned_predicate() -> Bool:
  table : T.Table = T.Table{[T.Column{"v", "UTINYINT"}], [[T.Unsigned{0, 0}], [T.Unsigned{0, 255}], [T.Null{}]]}
  two_rows(SQL.query("SELECT count(*) FROM bytes WHERE v < 256 AND v > -1", [SQL.Entry{"bytes", table}]))

def check_predicates_and_counts() -> IO(Unit):
  do IO<Unit>:
    paired : T.Table <- checked("select 'total', count(n), count(*) from (values (null), (3), (7), (2)) as t(n) where ((n < 5 or n is null) and (n > 2 or n is null))")
    assert(counts(paired, 1, 2), "grouped WHERE or nullable COUNT returned the wrong rows")
    precedence : T.Table <- checked("select 'total', count(n), count(*) from range(4) t(n) where n = 0 or n >= 2 and n < 3")
    assert(counts(precedence, 2, 2), "AND must bind more tightly than OR")
    none : T.Table <- checked("select 'total', count(n), count(*) from range(0) t(n)")
    assert(counts(none, 0, 0), "COUNT or constant projection failed on empty input")
    nulls : T.Table <- checked("select null as n, null::varchar as s")
    assert(null_types(nulls), "untyped or explicitly typed NULL projection lost its type")
    assert(unsigned_predicate(), "unsigned comparison truncated its literal to the column width")
    assert(fails("select count(missing) from range(0)"), "COUNT accepted an unknown column")
    assert(fails("select range, count(*) from range(0)"), "aggregate mixed with an ungrouped column")
    assert(fails("select * from range(0) where true or missing = 1"), "short-circuited WHERE skipped binding")
    assert(fails("select 1 where (true and)"), "missing WHERE operand accepted")
    assert(fails("select 1 where true)"), "unmatched WHERE ')' accepted")
    assert(fails("select 1 where (true"), "unmatched WHERE '(' accepted")
    assert(fails("select 1 where (true) false"), "missing WHERE operator accepted")

def row_ids(rows: T.Rows, expected: List<&2, U32>) -> Bool:
  match rows expected:
    case Nil{} Nil{}: True{}
    case (T.Signed{0, id} <> _) <> tail n <> ns: U32.is_eq(id, n) && row_ids(tail, ns)
    case _ _: False{}

def ordered_ids(table: T.Table, expected: List<&2, U32>) -> Bool:
  T.Table{_, rows} = table
  row_ids(rows, expected)

def ordered_wide(result: Result<&1, &1, U32 & String, T.Table>) -> Bool:
  match result:
    case Done{t}: ordered_ids(t, [4, 3, 1, 2, 5, 6])
    case Fail{_}: False{}

def wide_order() -> Bool:
  +low : T.Cell = T.WideUnsigned{0, 4294967295, 4294967295, 4294967295}
  +high : T.Cell = T.WideUnsigned{2147483648, 0, 0, 0}
  +pos : T.Cell = T.WideSigned{0, 0, 0, 1}
  +neg : T.Cell = T.WideSigned{4294967295, 4294967295, 4294967295, 4294967295}
  cols : List<&2, T.Column> = [T.Column{"id", "INTEGER"}, T.Column{"b", "BLOB"}, T.Column{"s", "HUGEINT"}, T.Column{"u", "UHUGEINT"}]
  rows : T.Rows = [[T.Signed{0, 1}, T.Bytes{[2]}, neg, high],
          [T.Signed{0, 2}, T.Bytes{[2]}, pos, low],
          [T.Signed{0, 3}, T.Bytes{[2]}, neg, low],
          [T.Signed{0, 4}, T.Bytes{[2, 0]}, neg, low],
          [T.Signed{0, 5}, T.Bytes{[]}, pos, high],
          [T.Signed{0, 6}, T.Null{}, neg, high]]
  ordered_wide(SQL.query("select * from w order by b desc, s, u", [SQL.Entry{"w", T.Table{cols, rows}}]))

def grouped_pairs(t: T.Table) -> Bool:
  match t:
    case T.Table{_,
      [ [T.Signed{0, 1}, T.Null{}, T.Signed{0, 2}],
        [T.Signed{0, 1}, T.Signed{0, 2}, T.Signed{0, 1}],
        [T.Signed{0, 1}, T.Signed{0, 1}, T.Signed{0, 1}],
        [T.Null{}, T.Signed{0, 1}, T.Signed{0, 1}] ]}: True{}
    case _: False{}

def check_keys() -> IO(Unit):
  do IO<Unit>:
    ordered : T.Table <- checked("select id, x, y from (values (1,2,null),(2,2,3),(3,null,0),(4,2,3),(5,1,0),(6,2,1)) as t(id,x,y) order by x desc, y asc")
    assert(ordered_ids(ordered, [6, 2, 4, 1, 5, 3]), "ORDER BY tie-breaks, NULL placement or stability failed")
    grouped : T.Table <- checked("select x, y, count(*) as n from (values (1,null),(1,2),(null,1),(1,1),(1,null)) as t(x,y) group by x, y order by x, n desc, y desc")
    assert(grouped_pairs(grouped), "composite GROUP BY lost a key or merged distinct NULL groups")
    assert(wide_order(), "binary or wide integer sort order changed")
    assert(fails("select * from range(0) as t(x) order by x, missing"), "unknown secondary sort key on empty input accepted")
    assert(fails("select x from range(0) as t(x) group by x,"), "trailing comma in GROUP BY accepted")
    assert(fails("select x from range(0) as t(x) group by x desc"), "direction in GROUP BY accepted")
    assert(fails("select c from (values(1,2,3)) as t(a,b,c) group by a,b"), "ungrouped projection accepted")

def check_untyped_values() -> IO(Unit):
  do IO<Unit>:
    result : T.Table <- checked("select n, n::varchar as s from (values (null)) as t(n)")
    assert(null_types(result), "untyped VALUES NULL failed to acquire its output or cast type")
    sums : T.Table <- checked("select sum(n), count(n) from (values (null)) as t(n) where n = 'missing'")
    assert(empty_sum(sums), "all-NULL VALUES column failed comparison or aggregation")

def star_pair(t: T.Table) -> Bool:
  match t:
    case T.Table{_, [[T.Signed{0, 1}, T.Signed{0, 2}]]}: True{}
    case _: False{}

def int_casts(t: T.Table) -> Bool:
  match t:
    case T.Table{[T.Column{_, "BIGINT"}, T.Column{_, "INTEGER"}, T.Column{_, "INTEGER"}, T.Column{_, "INTEGER"}], [[T.Signed{0, 42}, T.Signed{0, 1}, T.Null{}, T.Signed{0, 42}]]}: True{}
    case _: False{}

def check_bindings() -> IO(Unit):
  do IO<Unit>:
    assert(fails("select x from (values (1,2)) as t(x,X)"), "ambiguous case-insensitive field accepted")
    assert(fails("select 1 as n, 2 as N order by n"), "ambiguous output alias accepted")
    result : T.Table <- checked("select * from (values(1,2)) as t(x,X)")
    assert(star_pair(result), "star lost positional fields with colliding names")
    grouped : T.Table <- checked("select * from (values (1,2),(1,2)) as t(x,y) group by y,x")
    assert(star_pair(grouped), "grouped star did not expand all positions")
    assert(fails("select * from (values(1,2)) as t(x,y) group by x"), "grouped star accepted an ungrouped column")
    counted : T.Table <- checked("select count(*) from (values(1,2)) as t(x,X)")
    assert(ordered_ids(counted, [1]), "COUNT(*) failed on duplicate field names")
    ages : T.Table = T.Table{[T.Column{"age", "INT"}], [[T.Signed{0, 42}]]}
    cast : T.Table <- IO.try(T.Table, IO.pure(Result<&1, &1, U32 & String, T.Table>, SQL.query("select age::bigint, 1::int, null::int, age::integer from ages", [SQL.Entry{"ages", ages}])))
    assert(int_casts(cast), "INT and INTEGER casts disagree")

def main() -> IO(Unit):
  do IO<Unit>:
    a : T.Table <- checked("select sum(n)::bigint AS total, count(*) from (values (12), (7), (NULL), (2)) as t(n) where n >= 7 OR n is null;")
    assert(aggregate(a), "aggregate or WHERE result changed")
    b : T.Table <- checked("select v AS label from (values ('A'),(NULL),('Z''β')) AS t(v) order by label desc")
    assert(ordered(b), "ORDER BY or SQL string escaping failed")
    c : T.Table <- checked("select -9223372036854775808, 9223372036854775807")
    assert(limits(c), "BIGINT endpoints changed")
    d : T.Table <- checked("select sum(i), count(*) from range(12) t(i) where i < 0")
    assert(empty_sum(d), "aggregates over empty input changed")
    g : T.Table <- checked("select region, sum(n) as amount from (values ('east', 9), (NULL, 8), ('east', 3)) as t(region, n) group by region order by amount desc")
    assert(grouped(g), "grouped aggregates changed")
    r : T.Table <- checked("select r from (values (-0.5), (1.0), (-3.0)) as t(r) where r >= -0.5 order by r")
    assert(ordered_real(r), "DOUBLE comparison or ordering changed")
    n : T.Table <- checked("select 18446744073709551615::ubigint, 2.5::float, 0.1::double, -0.0")
    assert(numeric(n), "numeric literal precision changed")
    assert(fails("select 65536::usmallint"), "unsigned cast overflow accepted")
    z : T.Table <- checked("select sum(n) from (values (9223372036854775807), (1), (-1)) AS t(n)")
    assert(cancelled(z), "SUM overflowed before cancellation")
    assert(fails("select 9223372036854775808"), "out-of-range BIGINT accepted")
    assert(fails("select sum(n) from (values (9223372036854775807),(1)) as t(n)"), "overflowing SUM accepted")
    assert(fails("select missing from range(0) as t(i)"), "unknown column on empty input accepted")
    assert(fails("select * from (values ('a'), (2)) as t(v)"), "incompatible VALUES types accepted")
    assert(fails("select 'unterminated"), "unterminated SQL string accepted")
    check_predicates_and_counts()
    check_keys()
    check_bindings()
    check_untyped_values()
    IO.print("SQL queries passed")
