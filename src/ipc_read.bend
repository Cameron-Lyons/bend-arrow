import Base
import ./table.bend as T
import ./arrow_layout.bend as A
import ./ipc_flatbuffer.bend as F
import ./ipc_array.bend as ArrayData
import ./utf8.bend as UTF8

type Field is Data:
  Field{name: String, kind: A.Physical, nullable: Bool}

def Fields() -> Data:
  List<&2, Field>

def Rows() -> Data:
  List<&2, List<&2, T.Cell>>

def integer_name(width: U32, signed: Bool) -> String:
  match width signed:
    case 8 True{}: "TINYINT"
    case 8 False{}: "UTINYINT"
    case 16 True{}: "SMALLINT"
    case 16 False{}: "USMALLINT"
    case 32 True{}: "INTEGER"
    case 32 False{}: "UINTEGER"
    case 64 True{}: "BIGINT"
    case _ _: "UBIGINT"

def sql_type(kind: A.Physical) -> String:
  match kind:
    case A.Integer{w, s}: integer_name(w, s)
    case A.Real{32}: "FLOAT"
    case A.Real{_}: "DOUBLE"
    case A.Utf8Type{}: "VARCHAR"
    case A.Binary{}: "BLOB"
    case A.Bit{}: "BOOLEAN"

def columns(fields: Fields) -> List<&2, T.Column>:
  match fields:
    case Nil{}: Nil{}
    case Field{name, k, _} <> t: T.Column{name, sql_type(k)} <> columns(t)

def physical(tag: U32, +o: F.Object) -> F.R(A.Physical):
  match tag:
    case 2:
      do F.R<A.Physical>:
        +w : U32 <- F.scalar(o, 0, 4)
        +s : U32 <- F.scalar(o, 1, 1)
        F.check(U32.is_eq(w, 8) || U32.is_eq(w, 16) || U32.is_eq(w, 32) || U32.is_eq(w, 64), "unsupported integer width")
        F.check(U32.is_le(s, 1), "invalid integer signedness")
        return A.Integer{w, U32.is_eq(s, 1)}
    case 3:
      do F.R<A.Physical>:
        +precision : U32 <- F.scalar(o, 0, 2)
        F.check(U32.is_eq(precision, 1) || U32.is_eq(precision, 2), "unsupported floating-point precision")
        return A.Real{(32 * precision : U32)}
    case 4: Done{A.Binary{}}
    case 5: Done{A.Utf8Type{}}
    case 6: Done{A.Bit{}}
    case _: F.fail(A.Physical, "unsupported field type")

def field(+r: F.Region, target: U32) -> F.R(Field):
  do F.R<Field>:
    +o : F.Object <- F.object(r, target)
    dict : U32 <- F.slot(o, 4, 4)
    F.check(U32.is_zero(dict), "dictionary encoding is unsupported")
    F.no_vector(o, 5, 4, "nested fields are unsupported")
    F.no_vector(o, 6, 4, "custom field metadata is unsupported")
    name_pos : U32 <- F.ref(o, 0)
    name_bytes : F.Bytes <- F.text(r, name_pos)
    name : String <- UTF8.decode(name_bytes)
    +nullable : U32 <- F.scalar(o, 1, 1)
    F.check(U32.is_le(nullable, 1), "invalid nullable flag")
    tag : U32 <- F.scalar(o, 2, 1)
    spec : U32 <- F.ref(o, 3)
    ty : F.Object <- F.object(r, spec)
    kind : A.Physical <- physical(tag, ty)
    return Field{name, kind, U32.is_ne(nullable, 0)}

@unsafe def read_fields(+r: F.Region, +pos: U32, n: U32, acc: Fields) -> F.R(Fields):
  match n:
    case 0: Done{List.reverse(&2, Field, acc)}
    case k:
      do F.R<Fields>:
        target : U32 <- F.indirect(r, pos)
        f : Field <- field(r, target)
        read_fields(r, (pos + 4 : U32), (k - 1 : U32), f <> acc)

def schema_fields(r: F.Region, vec: F.Vector) -> F.R(Fields):
  F.Vector{start, count} = vec
  read_fields(r, start, count, Nil{})

def schema(+o: F.Object) -> F.R(Fields):
  do F.R<Fields>:
    endian : U32 <- F.scalar(o, 0, 2)
    F.check(U32.is_zero(endian), "only little-endian schemas are supported")
    F.no_vector(o, 2, 4, "custom schema metadata is unsupported")
    F.no_vector(o, 3, 8, "schema requests unsupported features")
    fields : F.Vector <- F.vector(o, 1, 4)
    schema_fields(F.data(o), fields)

type Pair64 is Data:
  Pair64{first: U32, second: U32}

def Pairs() -> Data:
  List<&2, Pair64>

# Both FieldNode and Buffer are pairs of little-endian signed 64-bit values.
# F.word checks that a length or offset fits the reader's U32 representation.
@unsafe def pairs.go(+bs: F.Bytes, n: U32, acc: Pairs) -> F.R(Pairs):
  match n:
    case 0: Done{List.reverse(&2, Pair64, acc)}
    case k:
      do F.R<Pairs>:
        a : U32 <- F.word(bs, 8)
        +second : F.Bytes <- F.drop(bs, 8)
        b : U32 <- F.word(second, 8)
        rest : F.Bytes <- F.drop(second, 8)
        pairs.go(rest, (k - 1 : U32), Pair64{a, b} <> acc)

def pairs(r: F.Region, v: F.Vector) -> F.R(Pairs):
  F.Region{bs, _} = r
  F.Vector{pos, n} = v
  do F.R<Pairs>:
    bytes : F.Bytes <- F.drop(bs, pos)
    pairs.go(bytes, n, Nil{})

def Buffers() -> Data:
  List<&2, F.Bytes>

# Buffers occur in schema order. Advance through the body once, skipping the
# padding between buffers, and give each decoder only its declared bytes.
def buffers(refs: Pairs, bs: F.Bytes, +prev_end: U32) -> F.R(Buffers):
  match refs:
    case Nil{}: Done{Nil{}}
    case Pair64{+off, +size} <> t:
      do F.R<Buffers>:
        F.check(U32.is_ge(off, prev_end) && U32.is_zero((off % 8 : U32)), "invalid buffer offset")
        at : F.Bytes <- F.drop(bs, (off - prev_end : U32))
        +span : F.Span <- F.split(at, size)
        rest : Buffers <- buffers(t, F.tail(span), (off + size : U32))
        return F.head(span) <> rest

type ColumnData is Data:
  ColumnData{cells: ArrayData.Cells, remaining: Buffers}

def var_column(text: Bool, n: U32, nulls: U32, valid: F.Bytes, offsets: F.Bytes, bufs: Buffers) -> F.R(ColumnData):
  match bufs:
    case Nil{}: F.fail(ColumnData, "missing variable-width data buffer")
    case data <> t:
      do F.R<ColumnData>:
        cells : ArrayData.Cells <- ArrayData.var_values(text, n, nulls, valid, offsets, data)
        return ColumnData{cells, t}

def read_column(kind: A.Physical, n: U32, nulls: U32, bufs: Buffers) -> F.R(ColumnData):
  match kind bufs:
    case A.Utf8Type{} valid <> offsets <> t: var_column(True{}, n, nulls, valid, offsets, t)
    case A.Binary{} valid <> offsets <> t: var_column(False{}, n, nulls, valid, offsets, t)
    case k valid <> data <> t:
      do F.R<ColumnData>:
        cells : ArrayData.Cells <- ArrayData.fixed_values(k, n, nulls, valid, data)
        return ColumnData{cells, t}
    case _ _: F.fail(ColumnData, "missing column buffers")

def prepend(cells: ArrayData.Cells, rows: Rows) -> Rows:
  match cells rows:
    case Nil{} _: Nil{}
    case h <> t Nil{}: [h] <> prepend(t, Nil{})
    case h <> t row <> rest: (h <> row) <> prepend(t, rest)

def get_cells(c: ColumnData) -> ArrayData.Cells:
  ColumnData{cells, _} = c
  cells

def get_rest(c: ColumnData) -> Buffers:
  ColumnData{_, rest} = c
  rest

def rows(fields: Fields, nodes: Pairs, bufs: Buffers, +n: U32) -> F.R(Rows):
  match fields nodes:
    case Nil{} Nil{}:
      do F.R<Rows>:
        F.check(List.is_empty(&2, F.Bytes, bufs), "extra record batch buffers")
        return Nil{}
    case Field{_, k, nullable} <> rest Pair64{length, +nulls} <> trailing:
      do F.R<Rows>:
        F.check(U32.is_eq(length, n) && U32.is_le(nulls, n), "inconsistent field node")
        F.check(nullable || U32.is_zero(nulls), "null in a required field")
        +c : ColumnData <- read_column(k, n, nulls, bufs)
        more : Rows <- rows(rest, trailing, get_rest(c), n)
        return prepend(get_cells(c), more)
    case _ _: F.fail(Rows, "field node count differs from schema")

# A zero-column batch can advertise any row count in a few metadata bytes.
# Bound that expansion while preserving empty rows from ordinary streams.
def batch_rows(fields: Fields, nodes: Pairs, bs: Buffers, +n: U32) -> F.R(Rows):
  match fields:
    case Nil{}:
      do F.R<Rows>:
        F.check(List.is_empty(&2, Pair64, nodes) && List.is_empty(&2, F.Bytes, bs), "unexpected data for zero-column batch")
        F.check(U32.is_le(n, 1048576), "zero-column batch exceeds empty-row materialization limit")
        return List.replicate(List<&2, T.Cell>, U32.to_nat(n), Nil{})
    case _: rows(fields, nodes, bs, n)

def batch(+o: F.Object, +fields: Fields, body: F.Bytes) -> F.R(Rows):
  do F.R<Rows>:
    +n : U32 <- F.scalar(o, 0, 8)
    F.check(U32.is_le(n, 2147483647), "row count exceeds supported range")
    comp : U32 <- F.slot(o, 3, 4)
    F.check(U32.is_zero(comp), "compressed record batches are unsupported")
    F.no_vector(o, 4, 8, "variadic buffers are unsupported")
    nodes : F.Vector <- F.vector(o, 1, 16)
    refs : F.Vector <- F.vector(o, 2, 16)
    ns : Pairs <- pairs(F.data(o), nodes)
    offsets : Pairs <- pairs(F.data(o), refs)
    bs : Buffers <- buffers(offsets, body, 0)
    batch_rows(fields, ns, bs, n)

type Frame is Data:
  End{}
  Frame{tag: U32, header: F.Object, body: F.Bytes, rest: F.Bytes}

def message(+meta: F.Region, remaining: F.Bytes) -> F.R(Frame):
  do F.R<Frame>:
    root : U32 <- F.indirect(meta, 0)
    +o : F.Object <- F.object(meta, root)
    version : U32 <- F.scalar(o, 0, 2)
    F.check(U32.is_eq(version, 4), "expected V5 metadata")
    F.no_vector(o, 4, 4, "custom message metadata is unsupported")
    tag : U32 <- F.scalar(o, 1, 1)
    header : U32 <- F.ref(o, 2)
    obj : F.Object <- F.object(meta, header)
    +body_len : U32 <- F.scalar(o, 3, 8)
    F.check(U32.is_zero((body_len % 8 : U32)), "misaligned body length")
    +part : F.Span <- F.split(remaining, body_len)
    return Frame{tag, obj, F.head(part), F.tail(part)}

def frame_data(bs: F.Bytes, n: U32, prefix: U32) -> F.R(Frame):
  match n:
    case 0:
      do F.R<Frame>:
        F.check(List.is_empty(&2, U32, bs), "trailing bytes after end of stream")
        return End{}
    case +size:
      do F.R<Frame>:
        F.check(U32.is_le(size, 2147483647) && U32.is_zero(((size + prefix) % 8 : U32)), "invalid IPC metadata length")
        +part : F.Span <- F.split(bs, size)
        message(F.region(F.head(part)), F.tail(part))

def prefix(+bs: F.Bytes, first: U32) -> F.R(Frame):
  match first:
    case 4294967295:
      do F.R<Frame>:
        n : U32 <- F.u32(bs)
        rest : F.Bytes <- F.drop(bs, 4)
        frame_data(rest, n, 8)
    case n: frame_data(bs, n, 4)

def next(+bs: F.Bytes) -> F.R(Frame):
  match bs:
    case Nil{}: Done{End{}}
    case _:
      do F.R<Frame>:
        first : U32 <- F.u32(bs)
        rest : F.Bytes <- F.drop(bs, 4)
        prefix(rest, first)

@unsafe def batches(f: Frame, +fields: Fields) -> F.R(Rows):
  match f:
    case End{}: Done{Nil{}}
    case Frame{3, header, body, rest}:
      do F.R<Rows>:
        data : Rows <- batch(header, fields, body)
        frame : Frame <- next(rest)
        more : Rows <- batches(frame, fields)
        return List.append(&2, List<&2, T.Cell>, data, more)
    case _: F.fail(Rows, "expected record batch or end of stream")

def first(f: Frame) -> F.R(T.Table):
  match f:
    case Frame{1, header, Nil{}, rest}:
      do F.R<T.Table>:
        +fields : Fields <- schema(header)
        frame : Frame <- next(rest)
        data : Rows <- batches(frame, fields)
        return T.Table{columns(fields), data}
    case _: F.fail(T.Table, "expected initial schema message")

def decode(+bytes: List<&2, U32>) -> Result<&1, &1, (U32 & String), T.Table>:
  do F.R<T.Table>:
    F.check(List.all(~&2, ~U32, ~(b => U32.is_le(b, 255)), bytes), "non-byte input")
    f : Frame <- next(bytes)
    first(f)
