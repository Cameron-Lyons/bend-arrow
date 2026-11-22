import Base
import ./parquet_wire.bend as W
import ./table.bend as T
import ./utf8.bend as UTF8
import ./parquet_hybrid.bend as Hybrid
import ./random_access_list.bend as Index
import ./byte_index.bend as B
import ./parquet_snappy.bend as Snappy

def Rows() -> Data:
  List<&2, List<&2, T.Cell>>

type Leaf is Data:
  Leaf{name: String, physical: U32, annotation: U32, sql: String, optional: Bool}

# Normalize modern LogicalType annotations and deprecated ConvertedType values
# to the same Parquet enum, and verify both when a file carries both forms.
def signed_flag(v: W.Value) -> W.R(Bool):
  match v:
    case W.Flag{b}: Done{b}
    case _: W.fail(Bool, "invalid integer signedness")

def int_annotation(width: U32, signed: Bool) -> W.R(U32):
  match width signed:
    case 8 False{}: Done{11}
    case 16 False{}: Done{12}
    case 32 False{}: Done{13}
    case 64 False{}: Done{14}
    case 8 True{}: Done{15}
    case 16 True{}: Done{16}
    case 32 True{}: Done{17}
    case 64 True{}: Done{18}
    case _ _: W.fail(U32, "unsupported logical integer width")

def annotation(v: Maybe<&2, W.Value>) -> W.R(U32):
  match v:
    case None{}: Done{4294967295}
    case Some{W.Struct{W.Field{1, W.Struct{Nil{}}} <> Nil{}}}: Done{0}
    case Some{W.Struct{W.Field{10, W.Struct{+fs}} <> Nil{}}}:
      do W.R<U32>:
        width : U32 <- W.number(fs, 1)
        sign : W.Value <- W.get(fs, 2)
        signed : Bool <- signed_flag(sign)
        int_annotation(width, signed)
    case _: W.fail(U32, "unsupported logical type")

def physical_name(physical: U32) -> W.R(String):
  match physical:
    case 0: Done{"BOOLEAN"}
    case 1: Done{"INTEGER"}
    case 2: Done{"BIGINT"}
    case 4: Done{"FLOAT"}
    case 5: Done{"DOUBLE"}
    case 6: Done{"BLOB"}
    case _: W.fail(String, "unsupported Parquet physical type")

def annotated_name(physical: U32, expected: U32, sql: String) -> W.R(String):
  do W.R<String>:
    W.check(U32.is_eq(physical, expected), "inconsistent physical and logical types")
    return sql

def sql_type(physical: U32, annotation: U32) -> W.R(String):
  match annotation:
    case 0: annotated_name(physical, 6, "VARCHAR")
    case 11: annotated_name(physical, 1, "UTINYINT")
    case 12: annotated_name(physical, 1, "USMALLINT")
    case 13: annotated_name(physical, 1, "UINTEGER")
    case 14: annotated_name(physical, 2, "UBIGINT")
    case 15: annotated_name(physical, 1, "TINYINT")
    case 16: annotated_name(physical, 1, "SMALLINT")
    case 17: annotated_name(physical, 1, "INTEGER")
    case 18: annotated_name(physical, 2, "BIGINT")
    case other:
      do W.R<String>:
        W.check(U32.is_eq(other, 4294967295), "unsupported Parquet converted type")
        physical_name(physical)

def schema_leaf(v: W.Value) -> W.R(Leaf):
  do W.R<Leaf>:
    +fs : List<&2, W.Field> <- W.as_fields(v)
    +p : U32 <- W.number(fs, 1)
    +rep : U32 <- W.number(fs, 3)
    W.check(U32.is_le(rep, 1) && W.no_field(fs, 5), "only flat required or optional columns are supported")
    n : W.Value <- W.get(fs, 4)
    bytes : W.Bytes <- W.as_bytes(n)
    name : String <- UTF8.decode(bytes)
    +converted : U32 <- W.opt_num(fs, 6, 4294967295)
    +logical : U32 <- annotation(W.lookup(fs, 10))
    W.check(U32.is_eq(logical, 4294967295) || U32.is_eq(converted, 4294967295) || U32.is_eq(logical, converted), "inconsistent logical and converted types")
    +tag : U32 = U32.min(converted, logical)
    sql : String <- sql_type(p, tag)
    return Leaf{name, p, tag, sql, U32.is_eq(rep, 1)}

def schema_leaves(values: List<&2, W.Value>) -> W.R(List<&2, Leaf>):
  match values:
    case Nil{}: Done{Nil{}}
    case v <> rest:
      do W.R<List<&2, Leaf>>:
        leaf : Leaf <- schema_leaf(v)
        others : List<&2, Leaf> <- schema_leaves(rest)
        return leaf <> others

def schema(values: List<&2, W.Value>) -> W.R(List<&2, Leaf>):
  match values:
    case Nil{}: W.fail(List<&2, Leaf>, "missing root schema")
    case root <> +children:
      do W.R<List<&2, Leaf>>:
        +fs : List<&2, W.Field> <- W.as_fields(root)
        +n : U32 <- W.number(fs, 5)
        W.check(W.no_field(fs, 1) && U32.is_ne(n, 0) && U32.is_eq(n, W.count(W.Value, children)), "invalid or nested root schema")
        schema_leaves(children)

def columns(leaves: List<&2, Leaf>) -> List<&2, T.Column>:
  match leaves:
    case Nil{}: Nil{}
    case Leaf{name, _, _, sql, _} <> tail: T.Column{name, sql} <> columns(tail)

def binary_value(utf8: Bool, bytes: W.Bytes) -> W.R(T.Cell):
  match utf8:
    case False{}: Done{T.Bytes{bytes}}
    case True{}:
      do W.R<T.Cell>:
        s : String <- UTF8.decode(bytes)
        return T.Utf8{s}

def int32(+word: U32, tag: U32) -> W.R(T.Cell):
  match tag:
    case 11:
      do W.R<T.Cell>:
        W.check(U32.is_le(word, 255), "UTINYINT outside logical range")
        return T.Unsigned{0, word}
    case 12:
      do W.R<T.Cell>:
        W.check(U32.is_le(word, 65535), "USMALLINT outside logical range")
        return T.Unsigned{0, word}
    case 13: Done{T.Unsigned{0, word}}
    case 15:
      do W.R<T.Cell>:
        W.check(U32.is_le(word, 127) || U32.is_ge(word, 4294967168), "TINYINT outside logical range")
        return T.Signed{(0 - (word >> 31n) : U32), word}
    case 16:
      do W.R<T.Cell>:
        W.check(U32.is_le(word, 32767) || U32.is_ge(word, 4294934528), "SMALLINT outside logical range")
        return T.Signed{(0 - (word >> 31n) : U32), word}
    case _: Done{T.Signed{(0 - (word >> 31n) : U32), word}}

def real32(word: U32) -> F32:
  U32{bits} = word
  F32{bits}

def cell(physical: U32, tag: U32) -> W.P(T.Cell):
  match physical:
    case 1:
      do W.P<T.Cell>:
        lo : U32 <- W.le32
        W.lift(T.Cell, int32(lo, tag))
    case 2:
      do W.P<T.Cell>:
        +lo : U32 <- W.le32
        +hi : U32 <- W.le32
        return Bool.pick(T.Cell, U32.is_eq(tag, 14), T.Unsigned{hi, lo}, T.Signed{hi, lo})
    case 4:
      do W.P<T.Cell>:
        bits : U32 <- W.le32
        return T.Float{real32(bits)}
    case 5:
      do W.P<T.Cell>:
        lo : U32 <- W.le32
        hi : U32 <- W.le32
        return T.Double{hi, lo}
    case 6:
      do W.P<T.Cell>:
        n : U32 <- W.le32
        b : W.Bytes <- W.take(n)
        W.lift(T.Cell, binary_value(U32.is_zero(tag), b))
    case _: W.abort(T.Cell, "unsupported PLAIN physical type")

@unsafe def cells(n: U32, +p: U32, +tag: U32, acc: List<&2, T.Cell>) -> W.P(List<&2, T.Cell>):
  match n:
    case 0: W.P.pure(List<&2, T.Cell>, acc)
    case k:
      do W.P<List<&2, T.Cell>>:
        x : T.Cell <- cell(p, tag)
        cells((k - 1 : U32), p, tag, x <> acc)

def bool_cells(bits: W.Bytes) -> List<&2, T.Cell>:
  match bits:
    case Nil{}: Nil{}
    case v <> t: T.Boolean{U32.is_eq(v, 1)} <> bool_cells(t)

def required_values(n: U32, p: U32, tag: U32) -> W.P(List<&2, T.Cell>):
  match p:
    case 0:
      +count = n
      do W.P<List<&2, T.Cell>>:
        # BOOLEAN PLAIN stores only present values, least significant bit first.
        bytes : W.Bytes <- W.take(((count >> 3n) + Bool.pick(U32, U32.is_zero((count .&. 7 : U32)), 0, 1) : U32))
        bits : W.Bytes <- W.lift(W.Bytes, Hybrid.unpack(count, 1, Hybrid.Bits{bytes, 0, 0}, Nil{}))
        return bool_cells(bits)
    case k: cells(n, k, tag, Nil{})

def complete(-A: Type, pair: W.Bytes & A) -> W.R(A):
  (trailing, x) = pair
  do W.R<A>:
    W.check(W.empty(U32, trailing), "trailing bytes in a sized section")
    return x

def dictionary_index(reversed: List<&2, T.Cell>, index: Index.Index(T.Cell)) -> Index.Index(T.Cell):
  match reversed:
    case Nil{}: index
    case h <> t: dictionary_index(t, Index.push(T.Cell, h, index))

def get_entry(v: Maybe<&2, T.Cell>) -> W.R(T.Cell):
  match v:
    case Some{x}: Done{x}
    case None{}: W.fail(T.Cell, "dictionary ID outside dictionary")

def entries(ids: W.Bytes, +dict: Index.Index(T.Cell)) -> W.R(List<&2, T.Cell>):
  match ids:
    case Nil{}: Done{Nil{}}
    case id <> rest:
      do W.R<List<&2, T.Cell>>:
        x : T.Cell <- get_entry(Index.seek(T.Cell, dict, id))
        tail : List<&2, T.Cell> <- entries(rest, dict)
        return x <> tail

def dictionary_values(n: U32, dict: Index.Index(T.Cell), bs: W.Bytes) -> W.R(List<&2, T.Cell>):
  match bs:
    case Nil{}:
      do W.R<List<&2, T.Cell>>:
        W.check(U32.is_zero(n), "missing dictionary ID bit width")
        return Nil{}
    case width <> t:
      do W.R<List<&2, T.Cell>>:
        ids : W.Bytes <- Hybrid.decode(n, width, t)
        entries(ids, dict)

def present(bits: W.Bytes, n: U32) -> U32:
  match bits:
    case Nil{}: n
    case v <> rest: present(rest, (n + v : U32))

def fill(bits: W.Bytes, cells: List<&2, T.Cell>, acc: List<&2, T.Cell>) -> W.R(List<&2, T.Cell>):
  match bits cells:
    case Nil{} Nil{}: Done{acc}
    case 0 <> t vs: fill(t, vs, T.Null{} <> acc)
    case 1 <> t v <> vs: fill(t, vs, v <> acc)
    case _ _: W.fail(List<&2, T.Cell>, "decoded values differ from definition levels")

type Dictionary is Data:
  NoDict{}
  Dict{values: Index.Index(T.Cell)}

def dict_cells(n: U32, dict: Dictionary, bytes: W.Bytes) -> W.R(List<&2, T.Cell>):
  match dict:
    case NoDict{}: W.fail(List<&2, T.Cell>, "dictionary-encoded data without a dictionary")
    case Dict{index}: dictionary_values(n, index, bytes)

# Boolean values encoded with RLE carry their own length prefix in both page versions.
def boolean_cells(n: U32, physical: U32, bytes: W.Bytes) -> W.R(List<&2, T.Cell>):
  do W.R<List<&2, T.Cell>>:
    W.check(U32.is_zero(physical), "RLE value encoding requires a boolean column")
    +s : W.Step<U32> <- W.step(U32, W.le32(bytes))
    part : W.Bytes & W.Bytes <- W.take(W.parsed(U32, s), W.rest(U32, s))
    encoded : W.Bytes <- complete(W.Bytes, part)
    bits : W.Bytes <- Hybrid.decode(n, 1, encoded)
    return bool_cells(bits)

def page_values(enc: U32, n: U32, p: U32, tag: U32, dict: Dictionary, data: W.Bytes) -> W.R(List<&2, T.Cell>):
  match enc:
    case 0:
      do W.R<List<&2, T.Cell>>:
        parsed : W.Bytes & List<&2, T.Cell> <- required_values(n, p, tag, data)
        reversed : List<&2, T.Cell> <- complete(List<&2, T.Cell>, parsed)
        return List.reverse(&2, T.Cell, reversed)
    case 2: dict_cells(n, dict, data)
    case 3: boolean_cells(n, p, data)
    case 8: dict_cells(n, dict, data)
    case _: W.fail(List<&2, T.Cell>, "unsupported data page encoding")

type Levels is Data:
  Required{count: U32}
  Optional{count: U32, bits: W.Bytes}

def present_count(levels: Levels) -> U32:
  match levels:
    case Required{n}: n
    case Optional{n, _}: n

def add_values(levels: Levels, cells: List<&2, T.Cell>, acc: List<&2, T.Cell>) -> W.R(List<&2, T.Cell>):
  match levels:
    case Required{_}: Done{List.reverse.go(&2, T.Cell, cells, acc)}
    case Optional{_, bits}: fill(bits, cells, acc)

def levels(optional: Bool, n: U32, size: U32) -> W.P(Levels):
  match optional:
    case False{}:
      do W.P<Levels>:
        W.lift(Unit, W.check(U32.is_zero(size), "required column has definition levels"))
        return Required{n}
    case True{}:
      do W.P<Levels>:
        bytes : W.Bytes <- W.take(size)
        +bits : W.Bytes <- W.lift(W.Bytes, Hybrid.decode(n, 1, bytes))
        return Optional{present(bits, 0), bits}

def v1_levels(optional: Bool, n: U32) -> W.P(Levels):
  match optional:
    case False{}: W.P.pure(Levels, Required{n})
    case True{}:
      do W.P<Levels>:
        size : U32 <- W.le32
        levels(True{}, n, size)

type Payload is Data:
  Payload{count: U32, encoding: U32, levels: Levels, bytes: W.Bytes}

def decompress(codec: U32, expected: U32, +data: W.Bytes) -> W.R(W.Bytes):
  match codec:
    case 0:
      do W.R<W.Bytes>:
        W.check(U32.is_eq(expected, W.count(U32, data)), "uncompressed page size differs from its actual size")
        return data
    case 1: Snappy.decode(expected, data)
    case _: W.fail(W.Bytes, "unsupported Parquet compression codec")

type Page is Data:
  Page{header: List<&2, W.Field>, uncompressed: U32, bytes: W.Bytes}

def page() -> W.P(Page):
  do W.P<Page>:
    h : W.Value <- W.fields(64, 0, Nil{})
    +fs : List<&2, W.Field> <- W.lift(List<&2, W.Field>, W.as_fields(h))
    +uncompressed : U32 <- W.lift(U32, W.number(fs, 2))
    size : U32 <- W.lift(U32, W.number(fs, 3))
    W.lift(Unit, W.check(U32.is_lt(uncompressed, 2147483648), "invalid uncompressed page size"))
    bytes : W.Bytes <- W.take(size)
    return Page{fs, uncompressed, bytes}

def compressed_flag(v: Maybe<&2, W.Value>) -> W.R(Bool):
  match v:
    case None{}: Done{True{}}
    case Some{W.Flag{flag}}: Done{flag}
    case _: W.fail(Bool, "invalid is_compressed flag")

def payload(tag: U32, h: List<&2, W.Field>, +left: U32, +optional: Bool, codec: U32, +size: U32, bytes: W.Bytes) -> W.R(Payload):
  match tag:
    case 0:
      do W.R<Payload>:
        v : W.Value <- W.get(h, 5)
        +dh : List<&2, W.Field> <- W.as_fields(v)
        +n : U32 <- W.number(dh, 1)
        enc : U32 <- W.number(dh, 2)
        lev : U32 <- W.number(dh, 3)
        W.check(Bool.not(optional) || U32.is_eq(lev, 3), "only RLE definition levels are supported")
        W.check(U32.is_le(n, left), "page count exceeds column count")
        data : W.Bytes <- decompress(codec, size, bytes)
        +split : W.Step<Levels> <- W.step(Levels, v1_levels(optional, n, data))
        return Payload{n, enc, W.parsed(Levels, split), W.rest(Levels, split)}
    case 3:
      do W.R<Payload>:
        v : W.Value <- W.get(h, 8)
        +dh : List<&2, W.Field> <- W.as_fields(v)
        +n : U32 <- W.number(dh, 1)
        +nulls : U32 <- W.number(dh, 2)
        rows : U32 <- W.number(dh, 3)
        enc : U32 <- W.number(dh, 4)
        +defs : U32 <- W.number(dh, 5)
        reps : U32 <- W.number(dh, 6)
        compressed : Bool <- compressed_flag(W.lookup(dh, 7))
        W.check(U32.is_eq(rows, n) && U32.is_le(n, left) && U32.is_le(nulls, n), "invalid flat Data Page V2 counts")
        W.check(U32.is_zero(reps) && U32.is_le(defs, size), "invalid flat Data Page V2 level lengths")
        +split : W.Step<Levels> <- W.step(Levels, levels(optional, n, defs, bytes))
        +defined : Levels = W.parsed(Levels, split)
        W.check(U32.is_eq((n - nulls : U32), present_count(defined)), "Data Page V2 null count differs from definition levels")
        # Only the values section can be compressed in V2. Writers may leave it
        # uncompressed even when the column chunk specifies a compression codec.
        data : W.Bytes <- decompress(Bool.pick(U32, compressed, codec, 0), (size - defs : U32), W.rest(Levels, split))
        return Payload{n, enc, defined, data}
    case _: W.fail(Payload, "unsupported data page type")

def dictionary(page: Page, leaf: Leaf, codec: U32) -> W.R(Dictionary):
  Page{+h, size, stored} = page
  Leaf{_, p, tag, _, _} = leaf
  do W.R<Dictionary>:
    header_type : U32 <- W.number(h, 1)
    W.check(U32.is_eq(header_type, 2), "dictionary offset does not identify a dictionary page")
    bytes : W.Bytes <- decompress(codec, size, stored)
    header : W.Value <- W.get(h, 7)
    +fs : List<&2, W.Field> <- W.as_fields(header)
    n : U32 <- W.number(fs, 1)
    +enc : U32 <- W.number(fs, 2)
    W.check(U32.is_zero(enc) || U32.is_eq(enc, 2), "unsupported dictionary page encoding")
    parsed : W.Bytes & List<&2, T.Cell> <- required_values(n, p, tag, bytes)
    reversed : List<&2, T.Cell> <- complete(List<&2, T.Cell>, parsed)
    return Dict{dictionary_index(reversed, Nil{})}

@unsafe def pages(bs: W.Bytes, +codec: U32, +leaf: Leaf, +dict: Dictionary, +left: U32, acc: List<&2, T.Cell>) -> W.R(List<&2, T.Cell>):
  match bs:
    case Nil{}:
      do W.R<List<&2, T.Cell>>:
        W.check(U32.is_zero(left), "missing data pages")
        return List.reverse(&2, T.Cell, acc)
    case input:
      do W.R<List<&2, T.Cell>>:
        +step : W.Step<Page> <- W.step(Page, page(input))
        data_page(W.parsed(Page, step), W.rest(Page, step), codec, leaf, dict, left, acc)

@unsafe def data_page(part: Page, next: W.Bytes, +codec: U32, +leaf: Leaf, +dict: Dictionary, +left: U32, acc: List<&2, T.Cell>) -> W.R(List<&2, T.Cell>):
  Page{+fs, size, bytes} = part
  Leaf{_, p, annotation, _, optional} = leaf
  do W.R<List<&2, T.Cell>>:
    tag : U32 <- W.number(fs, 1)
    body : Payload <- payload(tag, fs, left, optional, codec, size, bytes)
    data_values(body, p, annotation, next, codec, leaf, dict, left, acc)

@unsafe def data_values(body: Payload, p: U32, tag: U32, next: W.Bytes, codec: U32, leaf: Leaf, +dict: Dictionary, left: U32, acc: List<&2, T.Cell>) -> W.R(List<&2, T.Cell>):
  Payload{n, enc, +defined, data} = body
  do W.R<List<&2, T.Cell>>:
    cells : List<&2, T.Cell> <- page_values(enc, present_count(defined), p, tag, dict, data)
    updated : List<&2, T.Cell> <- add_values(defined, cells, acc)
    pages(next, codec, leaf, dict, (left - n : U32), updated)

def offset_bytes(found: Maybe<&2, W.Bytes>) -> W.R(W.Bytes):
  match found:
    case Some{bs}: Done{bs}
    case None{}: W.fail(W.Bytes, "offset outside the file")

type Body is Data:
  Body{file: B.Index, length: U32}

def chunk_bytes(body: Body, +offset: U32, +size: U32) -> W.R(W.Bytes):
  Body{file, +length} = body
  do W.R<W.Bytes>:
    W.check(U32.is_le(offset, length) && U32.is_le(size, (length - offset : U32)), "chunk outside the data section")
    start : W.Bytes <- offset_bytes(B.suffix(file, offset))
    span : W.Bytes & W.Bytes <- W.take(size, start)
    return Pair.snd(W.Bytes, W.Bytes, span)

def read_chunk(has_dict: Bool, +start: U32, +data_start: U32, +size: U32, body: Body, +codec: U32, +leaf: Leaf, +n: U32) -> W.R(List<&2, T.Cell>):
  match has_dict:
    case False{}:
      do W.R<List<&2, T.Cell>>:
        W.check(U32.is_ge(start, 4) || (U32.is_zero(start) && U32.is_zero(size)), "invalid data page offset")
        chunk : W.Bytes <- chunk_bytes(body, (U32.max(start, 4) - 4 : U32), size)
        pages(chunk, codec, leaf, NoDict{}, n, Nil{})
    case True{}:
      do W.R<List<&2, T.Cell>>:
        # A zero-row chunk can consist solely of an empty dictionary page.
        +dict_only : Bool = U32.is_zero(n) && U32.is_zero(data_start)
        +dict_size : U32 = Bool.pick(U32, dict_only, size, (data_start - start : U32))
        W.check(U32.is_ge(start, 4) && (dict_only || U32.is_ge(data_start, start)) && U32.is_le(dict_size, size), "invalid dictionary/data offsets")
        chunk : W.Bytes <- chunk_bytes(body, (start - 4 : U32), size)
        +split : W.Step<W.Bytes> <- W.step(W.Bytes, W.take(dict_size, chunk))
        segment : W.Bytes & Page <- page(W.parsed(W.Bytes, split))
        dp : Page <- complete(Page, segment)
        dict : Dictionary <- dictionary(dp, leaf, codec)
        pages(W.rest(W.Bytes, split), codec, leaf, dict, n, Nil{})

def path_matches(path: List<&2, W.Value>, name: String) -> W.R(Unit):
  match path:
    case W.Bin{bytes} <> Nil{}:
      do W.R<Unit>:
        actual : String <- UTF8.decode(bytes)
        W.check(String.eq(actual, name), "column chunk path differs from its schema")
    case _: W.fail(Unit, "invalid column chunk path")

def read_column(+body: Body, +leaf: Leaf, chunk: W.Value, +n: U32) -> W.R(List<&2, T.Cell>):
  Leaf{name, p, _, _, _} = leaf
  do W.R<List<&2, T.Cell>>:
    +fs : List<&2, W.Field> <- W.as_fields(chunk)
    W.check(W.no_field(fs, 1) && W.no_field(fs, 8) && W.no_field(fs, 9), "external and encrypted column chunks are unsupported")
    v : W.Value <- W.get(fs, 3)
    +md : List<&2, W.Field> <- W.as_fields(v)
    typ : U32 <- W.number(md, 1)
    path : List<&2, W.Value> <- W.list(md, 3)
    path_matches(path, name)
    +codec : U32 <- W.number(md, 4)
    W.check(U32.is_le(codec, 1), "unsupported Parquet compression codec")
    values : U32 <- W.number(md, 5)
    W.check(U32.is_eq(typ, p) && U32.is_eq(values, n), "column type or count differs from its schema or row group")
    size : U32 <- W.number(md, 7)
    +start : U32 <- W.number(md, 9)
    dictionary_offset : U32 <- W.opt_num(md, 11, start)
    read_chunk(Bool.not(W.no_field(md, 11)), dictionary_offset, start, size, body, codec, leaf, n)

def singleton_rows(cells: List<&2, T.Cell>) -> Rows:
  match cells:
    case Nil{}: Nil{}
    case c <> tail: (c <> Nil{}) <> singleton_rows(tail)

def prepend_cells(cells: List<&2, T.Cell>, rows: Rows) -> W.R(Rows):
  match cells rows:
    case Nil{} Nil{}: Done{Nil{}}
    case c <> cs row <> rest:
      do W.R<Rows>:
        tail : Rows <- prepend_cells(cs, rest)
        return (c <> row) <> tail
    case _ _: W.fail(Rows, "column lengths differ")

def group_rows(leaves: List<&2, Leaf>, chunks: List<&2, W.Value>, +body: Body, +n: U32) -> W.R(Rows):
  match leaves chunks:
    case leaf <> Nil{} chunk <> Nil{}:
      do W.R<Rows>:
        cells : List<&2, T.Cell> <- read_column(body, leaf, chunk, n)
        return singleton_rows(cells)
    case leaf <> rest chunk <> others:
      do W.R<Rows>:
        cells : List<&2, T.Cell> <- read_column(body, leaf, chunk, n)
        rows : Rows <- group_rows(rest, others, body, n)
        prepend_cells(cells, rows)
    case _ _: W.fail(Rows, "row group column count differs from schema")

def groups(items: List<&2, W.Value>, +leaves: List<&2, Leaf>, +body: Body, +left: U32) -> W.R(Rows):
  match items:
    case Nil{}:
      do W.R<Rows>:
        W.check(U32.is_zero(left), "row groups do not cover the file row count")
        return Nil{}
    case v <> rest:
      do W.R<Rows>:
        +fs : List<&2, W.Field> <- W.as_fields(v)
        chunks : List<&2, W.Value> <- W.list(fs, 1)
        +n : U32 <- W.number(fs, 3)
        W.check(U32.is_le(n, left), "row group count exceeds file row count")
        rows : Rows <- group_rows(leaves, chunks, body, n)
        others : Rows <- groups(rest, leaves, body, (left - n : U32))
        return List.append(&2, List<&2, T.Cell>, rows, others)

def read_footer(metadata: W.Bytes, body: Body) -> W.R(T.Table):
  do W.R<T.Table>:
    parsed : W.Bytes & W.Value <- W.fields(64, 0, Nil{}, metadata)
    root : W.Value <- complete(W.Value, parsed)
    +fs : List<&2, W.Field> <- W.as_fields(root)
    +version : U32 <- W.number(fs, 1)
    W.check(U32.is_eq(version, 1) || U32.is_eq(version, 2), "unsupported file metadata version")
    raw_schema : List<&2, W.Value> <- W.list(fs, 2)
    +leaves : List<&2, Leaf> <- schema(raw_schema)
    num_rows : U32 <- W.number(fs, 3)
    row_groups : List<&2, W.Value> <- W.list(fs, 4)
    rows : Rows <- groups(row_groups, leaves, body, num_rows)
    return T.Table{columns(leaves), rows}

def trailer(bs: W.Bytes) -> W.R(U32):
  match bs:
    case a <> b <> c <> d <> 80 <> 65 <> 82 <> 49 <> Nil{}:
      Done{(a + b * 256 + c * 65536 + d * 16777216 : U32)}
    case _: W.fail(U32, "invalid Parquet trailer")

def decode(bytes: W.Bytes) -> W.R(T.Table):
  match bytes:
    case 80 <> 65 <> 82 <> 49 <> rest:
      +file = B.build(rest)
      +length = B.size(file)
      do W.R<T.Table>:
        W.check(U32.is_ge(length, 8), "file is too short")
        end : W.Bytes <- offset_bytes(B.suffix(file, (length - 8 : U32)))
        +size : U32 <- trailer(end)
        W.check(U32.is_le(size, (length - 8 : U32)), "footer length outside the file")
        +body_size : U32 = (length - 8 - size : U32)
        foot : W.Bytes <- offset_bytes(B.suffix(file, body_size))
        meta : W.Bytes & W.Bytes <- W.take(size, foot)
        read_footer(Pair.snd(W.Bytes, W.Bytes, meta), Body{file, body_size})
    case _: W.fail(T.Table, "missing PAR1 header")
