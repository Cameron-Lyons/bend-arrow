import Base
import ./table.bend as T
import ./arrow_layout.bend as A
import ./ipc_flatbuffer.bend as F
import ./ipc_array.bend as ArrayData
import ./ipc_dictionary.bend as D
import ./utf8.bend as UTF8

type Field is Data:
  Field{name: String, kind: A.Physical, nullable: Bool, encoding: D.Encoding}

def Fields() -> Data:
  List<&2, Field>

def Rows() -> Data:
  List<&2, List<&2, T.Cell>>

def columns(fields: Fields) -> List<&2, T.Column>:
  match fields:
    case Nil{}: Nil{}
    case Field{name, k, _, _} <> t: T.Column{name, A.sql_type(k)} <> columns(t)

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

def index_type(+r: F.Region, pos: U32) -> F.R(A.Physical):
  match pos:
    case 0: Done{A.Integer{32, True{}}}
    case p:
      do F.R<A.Physical>:
        target : U32 <- F.indirect(r, p)
        obj : F.Object <- F.object(r, target)
        physical(2, obj)

def encoding(+r: F.Region, pos: U32) -> F.R(D.Encoding):
  match pos:
    case 0: Done{D.Plain{}}
    case p:
      do F.R<D.Encoding>:
        target : U32 <- F.indirect(r, p)
        +obj : F.Object <- F.object(r, target)
        id : String <- D.id(obj)
        tag : U32 <- F.scalar(obj, 3, 2)
        F.check(U32.is_zero(tag), "unsupported dictionary kind")
        idx : U32 <- F.slot(obj, 1, 4)
        ty : A.Physical <- index_type(r, idx)
        return D.Encoded{id, ty}

def ascii_equal(s: String, bs: F.Bytes, length: U32) -> Bool:
  match s bs length:
    case SNil{} _ 0: True{}
    case _ _ 0: False{}
    case SCon{Chr{c}, t} b <> rest k: U32.is_eq(c, b) && ascii_equal(t, rest, (k - 1 : U32))
    case _ _ _: False{}

def metadata_key(r: F.Region, pos: U32, length: U32, unsupported: String) -> F.R(Unit):
  match unsupported:
    case SNil{}: Done{Unit{}}
    case +key:
      do F.R<Unit>:
        bs : F.Bytes <- F.suffix(r, (pos + 4 : U32))
        F.check(Bool.not(ascii_equal(key, bs, length)), "unsupported metadata key " ++ key)

# T.Table has no metadata slots. Check every key/value reference and string
# boundary without copying application payloads (which may contain any bytes).
@unsafe def metadata_entries(+r: F.Region, +pos: U32, n: U32, +unsupported: String) -> F.R(Unit):
  match n:
    case 0: Done{Unit{}}
    case k:
      do F.R<Unit>:
        target : U32 <- F.indirect(r, pos)
        +entry : F.Object <- F.object(r, target)
        +key : U32 <- F.ref(entry, 0)
        key_len : U32 <- F.text_length(r, key)
        metadata_key(r, key, key_len, unsupported)
        value : U32 <- F.ref(entry, 1)
        _ : U32 <- F.text_length(r, value)
        metadata_entries(r, (pos + 4 : U32), (k - 1 : U32), unsupported)

def metadata_vector(r: F.Region, vec: F.Vector, unsupported: String) -> F.R(Unit):
  F.Vector{pos, n} = vec
  metadata_entries(r, pos, n, unsupported)

def metadata(+o: F.Object, slot: U32, unsupported: String) -> F.R(Unit):
  do F.R<Unit>:
    vec : F.Vector <- F.vector(o, slot, 4)
    metadata_vector(F.data(o), vec, unsupported)

def field(+r: F.Region, target: U32) -> F.R(Field):
  do F.R<Field>:
    +o : F.Object <- F.object(r, target)
    dict : U32 <- F.slot(o, 4, 4)
    enc : D.Encoding <- encoding(r, dict)
    F.no_vector(o, 5, 4, "nested fields are unsupported")
    metadata(o, 6, "ARROW:extension:name")
    name_pos : U32 <- F.ref(o, 0)
    name_bytes : F.Bytes <- F.text(r, name_pos)
    name : String <- UTF8.decode(name_bytes)
    +nullable : U32 <- F.scalar(o, 1, 1)
    F.check(U32.is_le(nullable, 1), "invalid nullable flag")
    tag : U32 <- F.scalar(o, 2, 1)
    spec : U32 <- F.ref(o, 3)
    ty : F.Object <- F.object(r, spec)
    kind : A.Physical <- physical(tag, ty)
    return Field{name, kind, U32.is_ne(nullable, 0), enc}

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

@unsafe def check_features(+r: F.Region, +pos: U32, n: U32) -> F.R(Unit):
  match n:
    case 0: Done{Unit{}}
    case k:
      do F.R<Unit>:
        feature : U32 <- F.at(r, pos, 8)
        F.check(U32.is_le(feature, 1), "schema requests unsupported features")
        check_features(r, (pos + 8 : U32), (k - 1 : U32))

def feature_vector(r: F.Region, v: F.Vector) -> F.R(Unit):
  F.Vector{pos, n} = v
  check_features(r, pos, n)

def features(+o: F.Object) -> F.R(Unit):
  do F.R<Unit>:
    v : F.Vector <- F.vector(o, 3, 8)
    feature_vector(F.data(o), v)

def schema(+o: F.Object) -> F.R(Fields):
  do F.R<Fields>:
    endian : U32 <- F.scalar(o, 0, 2)
    F.check(U32.is_zero(endian), "only little-endian schemas are supported")
    metadata(o, 2, "")
    features(o)
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
  F.Vector{pos, n} = v
  do F.R<Pairs>:
    bytes : F.Bytes <- F.suffix(r, pos)
    pairs.go(bytes, n, Nil{})

def Buffers() -> Data:
  List<&2, ArrayData.Buffer>

# Buffers occur in schema order. Advance through the body once, skipping the
# padding between buffers, and give each decoder only its declared bytes.
def buffers(refs: Pairs, bs: F.Bytes, prev_offset: U32, +prev_end: U32, +body_len: U32) -> F.R(Buffers):
  match refs:
    case Nil{}: Done{Nil{}}
    case Pair64{+off, +size} <> t:
      do F.R<Buffers>:
        F.check(U32.is_ge(off, prev_end) && U32.is_zero((off % 8 : U32)), "invalid buffer offset")
        F.check(F.fits(body_len, off, size), "buffer extends past message body")
        +at : F.Bytes <- F.drop(bs, (off - prev_offset : U32))
        rest : Buffers <- buffers(t, at, off, (off + size : U32), body_len)
        return ArrayData.Buffer{at, size} <> rest

type ColumnData is Data:
  ColumnData{cells: ArrayData.Cells, remaining: Buffers}

def var_column(text: Bool, n: U32, nulls: U32, valid: ArrayData.Buffer, offsets: ArrayData.Buffer, bufs: Buffers) -> F.R(ColumnData):
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

def read_field(enc: D.Encoding, kind: A.Physical, n: U32, nulls: U32, bufs: Buffers, reg: D.Registry) -> F.R(ColumnData):
  match enc:
    case D.Plain{}: read_column(kind, n, nulls, bufs)
    case D.Encoded{id, idx}:
      do F.R<ColumnData>:
        dict : D.Dictionary <- D.require(D.lookup(reg, id))
        +c : ColumnData <- read_column(idx, n, nulls, bufs)
        values : ArrayData.Cells <- D.expand(dict, get_cells(c))
        return ColumnData{values, get_rest(c)}

def rows(fields: Fields, nodes: Pairs, bufs: Buffers, +n: U32, +reg: D.Registry) -> F.R(Rows):
  match fields nodes:
    case Nil{} Nil{}:
      do F.R<Rows>:
        F.check(List.is_empty(&2, ArrayData.Buffer, bufs), "extra record batch buffers")
        return Nil{}
    case Field{_, k, nullable, enc} <> rest Pair64{length, +nulls} <> trailing:
      do F.R<Rows>:
        F.check(U32.is_eq(length, n) && U32.is_le(nulls, n), "inconsistent field node")
        F.check(nullable || U32.is_zero(nulls), "null in a required field")
        +c : ColumnData <- read_field(enc, k, n, nulls, bufs, reg)
        more : Rows <- rows(rest, trailing, get_rest(c), n, reg)
        return prepend(get_cells(c), more)
    case _ _: F.fail(Rows, "field node count differs from schema")

# A zero-column batch can advertise any row count in a few metadata bytes.
# Bound that expansion while preserving empty rows from ordinary streams.
def batch_rows(fields: Fields, nodes: Pairs, bs: Buffers, +n: U32, reg: D.Registry) -> F.R(Rows):
  match fields:
    case Nil{}:
      do F.R<Rows>:
        F.check(List.is_empty(&2, Pair64, nodes) && List.is_empty(&2, ArrayData.Buffer, bs), "unexpected data for zero-column batch")
        F.check(U32.is_le(n, 1048576), "zero-column batch exceeds empty-row materialization limit")
        return List.replicate(List<&2, T.Cell>, U32.to_nat(n), Nil{})
    case _: rows(fields, nodes, bs, n, reg)

type Batch is Data:
  Batch{n: U32, nodes: Pairs, buffers: Buffers}

# Keep a view of the incoming list. Each buffer is bounded by body_len before
# extraction, so framing does not need to copy a whole record batch.
type Body is Data:
  Body{bytes: F.Bytes, length: U32}

def batch(+o: F.Object, body: Body) -> F.R(Batch):
  Body{bytes, length} = body
  do F.R<Batch>:
    +n : U32 <- F.scalar(o, 0, 8)
    F.check(U32.is_le(n, 2147483647), "row count exceeds supported range")
    comp : U32 <- F.slot(o, 3, 4)
    F.check(U32.is_zero(comp), "compressed record batches are unsupported")
    F.no_vector(o, 4, 8, "variadic buffers are unsupported")
    nodes : F.Vector <- F.vector(o, 1, 16)
    refs : F.Vector <- F.vector(o, 2, 16)
    ns : Pairs <- pairs(F.data(o), nodes)
    offsets : Pairs <- pairs(F.data(o), refs)
    bs : Buffers <- buffers(offsets, bytes, 0, 0, length)
    return Batch{n, ns, bs}

type Frame is Data:
  End{}
  Frame{tag: U32, header: F.Object, body: Body, rest: F.Bytes}

def message(+meta: F.Region, +remaining: F.Bytes) -> F.R(Frame):
  do F.R<Frame>:
    root : U32 <- F.indirect(meta, 0)
    +o : F.Object <- F.object(meta, root)
    +version : U32 <- F.scalar(o, 0, 2)
    # V4 and V5 share the wire layout for the supported flat scalar types.
    F.check(U32.is_eq(version, 3) || U32.is_eq(version, 4), "expected V4 or V5 metadata")
    # Arrow 0.17 signaled compressed V4 bodies through a message-level key.
    metadata(o, 4, Bool.pick(String, U32.is_eq(version, 3), "ARROW:experimental_compression", ""))
    tag : U32 <- F.scalar(o, 1, 1)
    header : U32 <- F.ref(o, 2)
    obj : F.Object <- F.object(meta, header)
    +body_len : U32 <- F.scalar(o, 3, 8)
    F.check(U32.is_le(body_len, 2147483647) && U32.is_zero((body_len % 8 : U32)), "invalid body length")
    rest : F.Bytes <- F.drop(remaining, body_len)
    return Frame{tag, obj, Body{remaining, body_len}, rest}

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

def declarations(fields: Fields, +reg: D.Registry) -> F.R(D.Registry):
  match fields:
    case Nil{}: Done{reg}
    case Field{_, k, _, D.Encoded{+id, _}} <> t:
      do F.R<D.Registry>:
        next : D.Registry <- D.declare(reg, id, k, D.lookup(reg, id))
        declarations(t, next)
    case _ <> t: declarations(t, reg)

def dictionary_cells(b: Batch, kind: A.Physical) -> F.R(ArrayData.Cells):
  match b:
    case Batch{+n, Pair64{len, +nulls} <> Nil{}, bs}:
      do F.R<ArrayData.Cells>:
        F.check(U32.is_eq(n, len) && U32.is_le(nulls, n), "inconsistent dictionary field node")
        +c : ColumnData <- read_column(kind, n, nulls, bs)
        F.check(List.is_empty(&2, ArrayData.Buffer, get_rest(c)), "extra dictionary buffers")
        return get_cells(c)
    case _: F.fail(ArrayData.Cells, "expected one dictionary field node")

def dictionary(+o: F.Object, body: Body, +reg: D.Registry) -> F.R(D.Registry):
  do F.R<D.Registry>:
    +id : String <- D.id(o)
    +dict : D.Dictionary <- D.require(D.lookup(reg, id))
    +delta : U32 <- F.scalar(o, 2, 1)
    F.check(U32.is_le(delta, 1), "invalid dictionary delta flag")
    base : D.Values <- D.base(dict, U32.is_ne(delta, 0))
    pos : U32 <- F.ref(o, 1)
    header : F.Object <- F.object(F.data(o), pos)
    b : Batch <- batch(header, body)
    +kind : A.Physical = D.kind(dict)
    cells : ArrayData.Cells <- dictionary_cells(b, kind)
    return Map.set(&2, Maybe<&2, D.Dictionary>, reg, id, Some{D.Dictionary{kind, Some{D.extend(cells, base)}}})

def materialize(b: Batch, fields: Fields, reg: D.Registry) -> F.R(Rows):
  Batch{n, ns, bs} = b
  batch_rows(fields, ns, bs, n, reg)

@unsafe def batches(f: Frame, +fields: Fields, +reg: D.Registry, acc: Rows) -> F.R(Rows):
  match f:
    case End{}: Done{List.reverse(&2, List<&2, T.Cell>, acc)}
    case Frame{2, header, body, rest}:
      do F.R<Rows>:
        updated : D.Registry <- dictionary(header, body, reg)
        frame : Frame <- next(rest)
        batches(frame, fields, updated, acc)
    case Frame{3, header, body, rest}:
      do F.R<Rows>:
        b : Batch <- batch(header, body)
        data : Rows <- materialize(b, fields, reg)
        frame : Frame <- next(rest)
        batches(frame, fields, reg, List.reverse.go(&2, List<&2, T.Cell>, data, acc))
    case _: F.fail(Rows, "expected dictionary, record batch or end of stream")

def first(f: Frame) -> F.R(T.Table):
  match f:
    case Frame{1, header, Body{_, 0}, rest}:
      do F.R<T.Table>:
        +fields : Fields <- schema(header)
        frame : Frame <- next(rest)
        reg : D.Registry <- declarations(fields, MTip{})
        data : Rows <- batches(frame, fields, reg, Nil{})
        return T.Table{columns(fields), data}
    case _: F.fail(T.Table, "expected initial schema message")

def decode(+bytes: List<&2, U32>) -> Result<&1, &1, (U32 & String), T.Table>:
  do F.R<T.Table>:
    F.check(List.all(~&2, ~U32, ~(b => U32.is_le(b, 255)), bytes), "non-byte input")
    f : Frame <- next(bytes)
    first(f)
