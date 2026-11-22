import Base
import ./table.bend as T
import ./arrow_layout.bend as A
import ./utf8.bend as UTF8

def Bytes() -> Data:
  List<&2, U32>

def Rows() -> Data:
  List<&2, List<&2, T.Cell>>

def Error() -> Type:
  U32 & String

def join(parts: List<&2, Bytes()>) -> Bytes():
  List.concat(&2, U32, parts)

def byte_count(xs: Bytes(), acc: U32) -> U32:
  match xs:
    case Nil{}: acc
    case _ <> rest: byte_count(rest, (acc + 1 : U32))

def le32(+x: U32) -> Bytes():
  [(x .&. 255 : U32), ((x >> 8n) .&. 255 : U32), ((x >> 16n) .&. 255 : U32), (x >> 24n : U32)]

# A U32 varint needs at most five bytes. Compact Thrift zigzags signed integers.
def varint.go(fuel: Nat, +n: U32, small: Bool) -> Bytes():
  match fuel small:
    case 0n _: [n]
    case _ True{}: [n]
    case 1n+p False{}:
      +next = (n >> 7n : U32)
      ((n .&. 127) .|. 128 : U32) <> varint.go(p, next, U32.is_lt(next, 128))

def varint(+n: U32) -> Bytes():
  varint.go(4n, n, U32.is_lt(n, 128))

def number(n: U32) -> Bytes():
  varint((n << 1n : U32))

def list_header(+num: U32, item: U32, short: Bool) -> Bytes():
  match short:
    case True{}: [((num << 4n) .|. item : U32)]
    case False{}: (240 .|. item : U32) <> varint(num)

def structs(+count: U32) -> Bytes():
  list_header(count, 12, U32.is_lt(count, 15))

def physical(kind: Maybe<&2, A.Physical>, name: String) -> Result<&1, &1, Error(), A.Physical>:
  match kind:
    case Some{p}: Done{p}
    case None{}: Fail{(22, "Unsupported Parquet column type " ++ name)}

def type_id(kind: A.Physical) -> U32:
  match kind:
    case A.Bit{}: 0
    case A.Integer{64, _}: 2
    case A.Integer{_, _}: 1
    case A.Real{32}: 4
    case A.Real{64}: 5
    case _: 6

def integer(+w: U32, signed: Bool, +hi: U32, +lo: U32) -> Result<&1, &1, Error(), Bytes()>:
  bytes = Bool.pick(Bytes(), U32.is_eq(w, 64), join([le32(lo), le32(hi)]), le32(lo))
  Bool.pick(Result<&1, &1, Error(), Bytes()>, A.integer_fits(w, signed, hi, lo), Done{bytes}, Fail{(22, "Parquet integer out of range")})

def binary(+bytes: Bytes(), ok: Bool) -> Result<&1, &1, Error(), Bytes()>:
  match ok:
    case False{}: Fail{(22, "BLOB cell contains a non-byte value")}
    case True{}: Done{List.append(&2, U32, le32(byte_count(bytes, 0)), bytes)}

# Boolean values are packed together after null cells have been omitted.
def plain(cell: T.Cell, kind: A.Physical) -> Result<&1, &1, Error(), Bytes()>:
  match cell kind:
    case T.Null{} _: Done{Nil{}}
    case T.Signed{hi, lo} A.Integer{w, True{}}: integer(w, True{}, hi, lo)
    case T.Unsigned{hi, lo} A.Integer{w, False{}}: integer(w, False{}, hi, lo)
    case T.Boolean{b} A.Bit{}: Done{[A.flag(b)]}
    case T.Float{value} A.Real{32}: Done{le32(F32.bits(value))}
    case T.Double{hi, lo} A.Real{64}: Done{join([le32(lo), le32(hi)])}
    case T.Bytes{+bs} A.Binary{}:
      binary(bs, List.all(~&2, ~U32, ~(b => U32.is_le(b, 255)), bs))
    case T.Utf8{s} A.Utf8Type{}:
      do Result<&1, &1, Error(), Bytes()>:
        bytes : Bytes() <- UTF8.encode(s)
        binary(bytes, True{})
    case _ _: Fail{(22, "Parquet cell does not match its column type")}

def defined(cell: T.Cell) -> U32:
  match cell:
    case T.Null{}: 0
    case _: 1

type Slice is Data:
  Slice{levels: Bytes(), values: Bytes(), tails: Rows()}

# Peel one cell from each row. Passing the remaining row tails to the next
# column keeps total traversal proportional to the number of cells.
def prepend_cell(others: Slice, cell: T.Cell, tail: List<&2, T.Cell>, bytes: Bytes()) -> Slice:
  Slice{levels, values, tails} = others
  Slice{defined(cell) <> levels, List.append(&2, U32, bytes, values), tail <> tails}

def slice(rows: Rows(), +kind: A.Physical) -> Result<&1, &1, Error(), Slice>:
  match rows:
    case Nil{}: Done{Slice{Nil{}, Nil{}, Nil{}}}
    case Nil{} <> _: Fail{(22, "Parquet row has too few cells")}
    case (+cell <> tail) <> rest:
      do Result<&1, &1, Error(), Slice>:
        bytes : Bytes() <- plain(cell, kind)
        others : Slice <- slice(rest, kind)
        return prepend_cell(others, cell, tail, bytes)

# Definition levels use RLE for uniform groups and packed bytes for mixed
# groups. Grouping at eight-value boundaries avoids padding before a later
# run while keeping alternating nulls to one bit per row.
def level_run(n: U32, value: U32) -> Bytes():
  join([varint((n << 1n : U32)), [value]])

type LevelRun is Data:
  NoLevels{}
  RepeatedLevels{count: U32, value: U32}
  PackedLevels{groups: U32, reversed: Bytes()}

def level_flush(run: LevelRun, parts: List<&2, Bytes()>) -> List<&2, Bytes()>:
  match run:
    case NoLevels{}: parts
    case RepeatedLevels{n, value}: level_run(n, value) <> parts
    case PackedLevels{n, bytes}:
      join([varint(((n << 1n) .|. 1 : U32)), List.reverse(&2, U32, bytes)]) <> parts

type LevelState is Data:
  LevelState{run: LevelRun, parts: List<&2, Bytes()>}

def level_repeat(count: U32, bits: U32, n: U32, value: U32, parts: List<&2, Bytes()>, same: Bool) -> LevelState:
  match same:
    case True{}: LevelState{RepeatedLevels{(n + count : U32), value}, parts}
    case False{}: LevelState{RepeatedLevels{count, (bits .&. 1 : U32)}, level_flush(RepeatedLevels{n, value}, parts)}

def level_push(count: U32, +bits: U32, state: LevelState, uniform: Bool) -> LevelState:
  match state uniform:
    case LevelState{RepeatedLevels{n, +value}, parts} True{}:
      level_repeat(count, bits, n, value, parts, U32.is_eq(value, (bits .&. 1 : U32)))
    case LevelState{old, parts} True{}: LevelState{RepeatedLevels{count, (bits .&. 1 : U32)}, level_flush(old, parts)}
    case LevelState{PackedLevels{n, bytes}, parts} False{}: LevelState{PackedLevels{(n + 1 : U32), bits <> bytes}, parts}
    case LevelState{old, parts} False{}: LevelState{PackedLevels{1, [bits]}, level_flush(old, parts)}

def level_emit(+count: U32, +bits: U32, state: LevelState) -> LevelState:
  uniform = U32.is_zero(bits) || U32.is_eq(bits, ((1 << U32.to_nat(count)) - 1 : U32))
  level_push(count, bits, state, uniform)

def level_ready(bits: U32, state: LevelState, full: Bool) -> LevelState:
  match full:
    case True{}: level_emit(8, bits, state)
    case False{}: state

def level_result(state: LevelState) -> Bytes():
  LevelState{run, parts} = state
  join(List.reverse(&2, Bytes(), level_flush(run, parts)))

def level_finish(count: U32, bits: U32, state: LevelState) -> Bytes():
  match count:
    case 0: level_result(state)
    case n: level_result(level_emit(n, bits, state))

def levels.go(xs: Bytes(), +count: U32, bits: U32, state: LevelState) -> Bytes():
  match xs:
    case Nil{}: level_finish(count, bits, state)
    case h <> t:
      +word = (bits .|. (h << U32.to_nat(count)) : U32)
      +next = ((count + 1) .&. 7 : U32)
      +full = U32.is_zero(next)
      levels.go(t, next, Bool.pick(U32, full, 0, word), level_ready(word, state, full))

def level_bytes(xs: Bytes()) -> Bytes():
  levels.go(xs, 0, 0, LevelState{NoLevels{}, Nil{}})

def data_page(rows: U32, +payload: Bytes()) -> Bytes():
  +size = number(byte_count(payload, 0))
  # PageHeader, then DataPageHeader with PLAIN values and RLE levels.
  join([[21, 0, 21], size, [21], size, [44, 21], number(rows), [21, 0, 21, 6, 21, 6, 0, 0], payload])

# Compact field tags contain the field-ID delta and the wire type.
def i32_field(delta: U32, n: U32) -> Bytes():
  ((delta << 4n) .|. 5 : U32) <> number(n)

def i64_field(delta: U32, n: U32) -> Bytes():
  ((delta << 4n) .|. 6 : U32) <> number(n)

def converted_int(width: U32, signed: Bool) -> U32:
  match width signed:
    case 8 False{}: 11
    case 16 False{}: 12
    case 32 False{}: 13
    case 64 False{}: 14
    case 8 True{}: 15
    case _ True{}: 16
    case _ _: 0

def annotation(kind: A.Physical) -> Bytes():
  match kind:
    case A.Utf8Type{}:
      # ConvertedType.UTF8 and LogicalType.STRING.
      join([i32_field(2, 0), [76, 28, 0, 0]])
    case A.Integer{32, True{}}: Nil{}
    case A.Integer{64, True{}}: Nil{}
    case A.Integer{+width, +signed}:
      # LogicalType.INTEGER contains a bitWidth byte and isSigned boolean.
      bool_field = Bool.pick(U32, signed, 17, 18)
      join([i32_field(2, converted_int(width, signed)), [76, 172, 19, width, bool_field, 0, 0]])
    case _: Nil{}

def leaf(+kind: A.Physical, name: Bytes()) -> Bytes():
  # SchemaElement with OPTIONAL repetition, a name and any type annotation.
  join([i32_field(1, type_id(kind)), i32_field(2, 1), [24], name, annotation(kind), [0]])

def column_chunk(kind: A.Physical, name: Bytes(), count: U32, +size: U32, offset: U32) -> Bytes():
  # ColumnChunk.file_offset (deprecated) and inline ColumnMetaData: type,
  # [PLAIN,RLE], path, UNCOMPRESSED, count, sizes and data-page offset.
  join([i64_field(2, 0), [28], i32_field(1, type_id(kind)), [25, 37, 0, 6, 25, 24], name,
        i32_field(1, 0), i64_field(1, count), i64_field(1, size), i64_field(1, size), i64_field(2, offset), [0, 0]])

type Parts is Data:
  Parts{schema: List<&2, Bytes()>, chunks: List<&2, Bytes()>, pages: List<&2, Bytes()>, end: U32}

def remaining(rows: Rows()) -> Result<&1, &1, Error(), Unit>:
  match rows:
    case Nil{}: Done{Unit{}}
    case Nil{} <> rest: remaining(rest)
    case _: Fail{(22, "Parquet row has too many cells")}

def within_limit(ok: Bool) -> Result<&1, &1, Error(), Unit>:
  match ok:
    case True{}: Done{Unit{}}
    case False{}: Fail{(75, "Parquet writer supports files smaller than 2 GiB")}

type Page is Data:
  Page{bytes: Bytes(), tails: Rows()}

def bool_bytes(xs: Bytes()) -> List<&2, Bool>:
  match xs:
    case Nil{}: Nil{}
    case h <> t: U32.is_ne(h, 0) <> bool_bytes(t)

def packed_values(kind: A.Physical, bs: Bytes()) -> Bytes():
  match kind:
    case A.Bit{}: A.bits(bool_bytes(bs), 0, 0)
    case _: bs

def make_page(kind: A.Physical, count: U32, cells: Slice) -> Page:
  Slice{level_list, values, tails} = cells
  +levels = level_bytes(level_list)
  Page{data_page(count, join([le32(byte_count(levels, 0)), levels, packed_values(kind, values)])), tails}

def get_page(pair: Page) -> Bytes():
  Page{page, _} = pair
  page

def get_tails(pair: Page) -> Rows():
  Page{_, tails} = pair
  tails

def prepend_column(others: Parts, +kind: A.Physical, +path: Bytes(), count: U32, size: U32, offset: U32, page: Bytes()) -> Parts:
  Parts{schema, chunks, pages, end} = others
  Parts{leaf(kind, path) <> schema, column_chunk(kind, path, count, size, offset) <> chunks, page <> pages, end}

def columns(cols: List<&2, T.Column>, rows: Rows(), +count: U32, +offset: U32) -> Result<&1, &1, Error(), Parts>:
  match cols:
    case Nil{}:
      do Result<&1, &1, Error(), Parts>:
        remaining(rows)
        return Parts{Nil{}, Nil{}, Nil{}, offset}
    case T.Column{name, +sql_type} <> rest:
      do Result<&1, &1, Error(), Parts>:
        +kind : A.Physical <- physical(A.kind(sql_type), sql_type)
        +raw : Bytes() <- UTF8.encode(name)
        +path : Bytes() = join([varint(byte_count(raw, 0)), raw])
        cells : Slice <- slice(rows, kind)
        +result : Page = make_page(kind, count, cells)
        +page : Bytes() = get_page(result)
        +size : U32 = byte_count(page, 0)
        within_limit(U32.is_le(size, (2147483647 - offset : U32)))
        others : Parts <- columns(rest, get_tails(result), count, (offset + size : U32))
        return prepend_column(others, kind, path, count, size, offset, page)

def row_count(rows: Rows(), acc: U32) -> U32:
  match rows:
    case Nil{}: acc
    case _ <> tail: row_count(tail, (acc + 1 : U32))

def col_count(cols: List<&2, T.Column>, acc: U32) -> U32:
  match cols:
    case Nil{}: acc
    case _ <> tail: col_count(tail, (acc + 1 : U32))

def body(chunks: List<&2, Bytes()>, pages: List<&2, Bytes()>, end: U32, cols: U32, +rows: U32) -> Bytes() & Bytes():
  match rows:
    case 0: (Nil{}, [12])
    case _:
      group = join([[28, 25], structs(cols), join(chunks), [22], number((end - 4 : U32)), [22], number(rows), [0]])
      (join(pages), group)

def magic() -> Bytes():
  [80, 65, 82, 49]

def footer(schema: List<&2, Bytes()>, +cols: U32, rows: U32, end: U32, content: Bytes() & Bytes()) -> Result<&1, &1, Error(), Bytes()>:
  (data, groups) = content
  # FileMetaData.schema starts with the root group, then one leaf per column.
  +footer = join([[21, 2, 25], structs((cols + 1 : U32)), [72, 6, 115, 99, 104, 101, 109, 97, 21], number(cols), [0], join(schema), [22], number(rows), [25], groups, [0]])
  +length = byte_count(footer, 0)
  do Result<&1, &1, Error(), Bytes()>:
    within_limit(U32.is_le((length + 8 : U32), (2147483647 - end : U32)))
    return join([magic(), data, footer, le32(length), magic()])

def assemble(parts: Parts, +cols: U32, +rows: U32) -> Result<&1, &1, Error(), Bytes()>:
  Parts{schema, chunks, pages, +end} = parts
  footer(schema, cols, rows, end, body(chunks, pages, end, cols, rows))

def encode(table: T.Table) -> Result<&1, &1, (U32 & String), List<&2, U32>>:
  match table:
    case T.Table{Nil{}, _}: Fail{(22, "Parquet requires at least one column")}
    case T.Table{+cols, +rows}:
      +count = row_count(rows, 0)
      do Result<&1, &1, Error(), Bytes()>:
        within_limit(U32.is_lt(count, 2147483648))
        parts : Parts <- columns(cols, rows, count, 4)
        assemble(parts, col_count(cols, 0), count)
