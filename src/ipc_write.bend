import Base
import ./table.bend as T
import ./arrow_layout.bend as L
import ./utf8.bend as UTF8

def Bytes() -> Data:
  L.Bytes

def R(-A: Type) -> Type:
  L.Outcome(A)

def R.pure(-A: Type, value: A) -> R(A):
  Done{value}

def R.bind(-A: Type, -B: Type, r: R(A), f: A -> R(B)) -> R(B):
  Result.bind(&1, &1, U32 & String, A, B, r, f)

def chunks(xs: List<&2, Bytes>) -> Bytes:
  List.concat(&2, U32, xs)

def physical(m: Maybe<&2, L.Physical>, name: String) -> R(L.Physical):
  match m:
    case Some{p}: Done{p}
    case None{}: Fail{(22, "unsupported Arrow type: " ++ name)}

# FlatBuffers tables follow their vtables. All uoffsets point forward from
# the word containing the offset. The schema and batch headers share Message.
def message(tag: U32, header_offset: U32, body_size: U32) -> Bytes:
  chunks([L.u32(16), [12,0,24,0,4,0,6,0,8,0,16,0], L.u32(12),
          [4,0,tag,0], L.u32(header_offset), L.u32(0), L.u64(body_size)])

def tag(p: L.Physical) -> U32:
  match p:
    case L.Integer{_, _}: 2
    case L.Real{_}: 3
    case L.Binary{}: 4
    case L.Utf8Type{}: 5
    case L.Bit{}: 6

def type_table(p: L.Physical) -> Bytes:
  match p:
    case L.Integer{width, signed}:
      chunks([[8,0,12,0,4,0,8,0], L.u32(8), L.u32(width), [L.flag(signed),0,0,0]])
    case L.Real{width}:
      chunks([[6,0,8,0,4,0,0,0], L.u32(8), L.u32(Bool.pick(U32, U32.is_eq(width, 32), 1, 2))])
    case _: [4,0,4,0,4,0,0,0]

def type_vtable_size(p: L.Physical) -> U32:
  match p:
    case L.Integer{_, _}: 8
    case L.Real{_}: 8
    case _: 4

def field(+name: Bytes, +p: L.Physical) -> Bytes:
  +label = L.padded(chunks([L.u32(L.length(U32, name)), name, [0]]), 4)
  type_offset = (4 + (L.length(U32, label) + type_vtable_size(p) : U32) : U32)
  chunks([[12,0,16,0,4,0,8,0,9,0,12,0], L.u32(12), L.u32(12), [1,tag(p),0,0],
          L.u32(type_offset), label, type_table(p)])

def fields(cols: List<&2, T.Column>) -> R(List<&2, Bytes>):
  match cols:
    case Nil{}: Done{Nil{}}
    case T.Column{name, +sql_type} <> tail:
      do R<List<&2, Bytes>>:
        p : L.Physical <- physical(L.kind(sql_type), sql_type)
        bytes : Bytes <- UTF8.encode(name)
        rest : List<&2, Bytes> <- fields(tail)
        return field(bytes, p) <> rest

def field_refs(blobs: List<&2, Bytes>, +offset: U32) -> Bytes:
  match blobs:
    case Nil{}: Nil{}
    case blob <> tail:
      L.join(L.u32((offset + 12 : U32)), field_refs(tail, ((offset - 4 : U32) + L.length(U32, blob) : U32)))

def frame(+meta: Bytes, body: Bytes) -> Bytes:
  +m = L.padded(meta, 8)
  chunks([[255,255,255,255], L.u32(L.length(U32, m)), m, body])

def schema(+blobs: List<&2, Bytes>) -> Bytes:
  +n = L.length(Bytes, blobs)
  frame(chunks([message(1, 24, 0), [8,0,8,0,0,0,4,0], L.u32(8), L.u32(4),
    L.u32(n), field_refs(blobs, (4 * n : U32)), chunks(blobs)]), Nil{})

def map_data(~A: Data, ~B: Data, ~f: A -> B, xs: List<&2, A>) -> List<&2, B>:
  match xs:
    case Nil{}: Nil{}
    case h <> t: f(h) <> map_data(~A, ~B, ~f, t)

def is_valid(c: T.Cell) -> Bool:
  match c:
    case T.Null{}: False{}
    case _: True{}

def null_count(xs: List<&2, Bool>) -> U32:
  match xs:
    case Nil{}: 0
    case False{} <> t: (1 + null_count(t) : U32)
    case True{} <> t: null_count(t)

def bools(xs: List<&2, T.Cell>) -> R(List<&2, Bool>):
  match xs:
    case Nil{}: Done{Nil{}}
    case T.Null{} <> t:
      do R<List<&2, Bool>>:
        rest : List<&2, Bool> <- bools(t)
        return False{} <> rest
    case T.Boolean{b} <> t:
      do R<List<&2, Bool>>:
        rest : List<&2, Bool> <- bools(t)
        return b <> rest
    case _: Fail{(22, "expected a boolean cell")}

def var_value(c: T.Cell, text: Bool) -> R(Bytes):
  match c:
    case T.Null{}: Done{Nil{}}
    case T.Utf8{s}:
      match text:
        case True{}: UTF8.encode(s)
        case False{}: Fail{(22, "expected a binary cell")}
    case T.Bytes{+b}:
      ok = Bool.not(text) && List.all(~&2, ~U32, ~(v => U32.is_le(v, 255)), b)
      Bool.pick(R(Bytes), ok, Done{b}, Fail{(22, "invalid binary cell")})
    case _: Fail{(22, "expected a variable-width cell")}

type VarData is Data:
  Var{offsets: Bytes, data: Bytes}

def var_prepend(offset: U32, value: Bytes, v: VarData) -> VarData:
  Var{offsets, data} = v
  Var{L.join(L.u32(offset), offsets), L.join(value, data)}

def variable(xs: List<&2, T.Cell>, +text: Bool, +off: U32) -> R(VarData):
  match xs:
    case Nil{}: Done{Var{L.u32(off), Nil{}}}
    case c <> t:
      do R<VarData>:
        +v : Bytes <- var_value(c, text)
        rest : VarData <- variable(t, text, (off + L.length(U32, v) : U32))
        return var_prepend(off, v, rest)

def var_buffers(v: VarData) -> List<&2, Bytes>:
  Var{off, data} = v
  [off, data]

def int_bytes(w: U32, s: Bool, +h: U32, +l: U32) -> R(Bytes):
  +width = w
  ok = L.integer_fits(width, s, h, l)
  bytes = List.take(&2, U32, L.join(L.u32(l), L.u32(h)), U32.to_nat((width / 8 : U32)))
  Bool.pick(R(Bytes), ok, Done{bytes}, Fail{(22, "integer exceeds Arrow field width")})

def fixed(c: T.Cell, p: L.Physical) -> R(Bytes):
  match c p:
    case T.Null{} L.Integer{w, _}: Done{L.zeros((w / 8 : U32))}
    case T.Null{} L.Real{w}: Done{L.zeros((w / 8 : U32))}
    case T.Signed{h, l} L.Integer{w, True{}}: int_bytes(w, True{}, h, l)
    case T.Unsigned{h, l} L.Integer{w, False{}}: int_bytes(w, False{}, h, l)
    case T.Float{f} L.Real{32}: Done{L.u32(F32.bits(f))}
    case T.Double{h, l} L.Real{64}: Done{L.join(L.u32(l), L.u32(h))}
    case _ _: Fail{(22, "cell disagrees with Arrow field type")}

def fixed_data(xs: List<&2, T.Cell>, +p: L.Physical) -> R(Bytes):
  match xs:
    case Nil{}: Done{Nil{}}
    case h <> t:
      do R<Bytes>:
        v : Bytes <- fixed(h, p)
        rest : Bytes <- fixed_data(t, p)
        return L.join(v, rest)

def payload(p: L.Physical, xs: List<&2, T.Cell>) -> R(List<&2, Bytes>):
  match p:
    case L.Bit{}:
      do R<List<&2, Bytes>>:
        b : List<&2, Bool> <- bools(xs)
        return [L.bits(b, 0, 0)]
    case L.Utf8Type{}:
      do R<List<&2, Bytes>>:
        v : VarData <- variable(xs, True{}, 0)
        return var_buffers(v)
    case L.Binary{}:
      do R<List<&2, Bytes>>:
        v : VarData <- variable(xs, False{}, 0)
        return var_buffers(v)
    case f:
      do R<List<&2, Bytes>>:
        data : Bytes <- fixed_data(xs, f)
        return [data]

type Batch is Data:
  Batch{nodes: List<&2, U32>, buffers: List<&2, Bytes>}

def prepend_column(+valid: List<&2, Bool>, data: List<&2, Bytes>, b: Batch) -> Batch:
  Batch{nodes, buffers} = b
  +nulls = null_count(valid)
  bitmap = Bool.pick(Bytes, U32.is_zero(nulls), Nil{}, L.bits(valid, 0, 0))
  Batch{nulls <> nodes, bitmap <> List.append(&2, Bytes, data, buffers)}

def empty_rows(xs: List<&2, List<&2, T.Cell>>) -> Bool:
  List.all(~&2, ~(List<&2, T.Cell>), ~(r => List.is_empty(&2, T.Cell, r)), xs)

def split_cells(s: L.Split) -> List<&2, T.Cell>:
  L.Parts{cells, _} = s
  cells

def split_rows(s: L.Split) -> List<&2, List<&2, T.Cell>>:
  L.Parts{_, rows} = s
  rows

def columns(cols: List<&2, T.Column>, rows: List<&2, List<&2, T.Cell>>) -> R(Batch):
  match cols:
    case Nil{}:
      Bool.pick(R(Batch), empty_rows(rows), Done{Batch{Nil{}, Nil{}}}, Fail{(22, "row has more cells than fields")})
    case T.Column{_, +t} <> tail:
      do R<Batch>:
        p : L.Physical <- physical(L.kind(t), t)
        +split : L.Split <- L.first_column(rows)
        +xs : List<&2, T.Cell> = split_cells(split)
        bufs : List<&2, Bytes> <- payload(p, xs)
        rest : Batch <- columns(tail, split_rows(split))
        return prepend_column(map_data(~T.Cell, ~Bool, ~is_valid, xs), bufs, rest)

def field_nodes(nodes: List<&2, U32>, +nrows: U32) -> Bytes:
  match nodes:
    case Nil{}: Nil{}
    case h <> t: chunks([L.u64(nrows), L.u64(h), field_nodes(t, nrows)])

def descriptors(bufs: List<&2, Bytes>, +off: U32) -> Bytes:
  match bufs:
    case Nil{}: Nil{}
    case b <> t:
      +n = L.length(U32, b)
      chunks([L.u64(off), L.u64(n), descriptors(t, ((off + n : U32) + L.pad_size(n, 8) : U32))])

def pad_buffer(b: Bytes) -> Bytes:
  L.padded(b, 8)

def record(b: Batch, +nrows: U32) -> Bytes:
  Batch{+nodes, +buffers} = b
  +n = L.length(U32, nodes)
  +body = chunks(map_data(~Bytes, ~Bytes, ~pad_buffer, buffers))
  # The vectors of 16-byte structs begin on an eight-byte boundary after their counts.
  meta = chunks([message(3, 32, L.length(U32, body)), [10,0,24,0,8,0,16,0,20,0,0,0,0,0,0,0],
    L.u32(16), L.u32(0), L.u64(nrows), L.u32(12), L.u32((16 + (16 * n : U32) : U32)),
    L.u32(0), L.u32(n), field_nodes(nodes, nrows), L.u32(0), L.u32(L.length(Bytes, buffers)),
    descriptors(buffers, 0)])
  frame(meta, body)

def last_group(acc: T.Rows) -> List<&2, T.Rows>:
  match acc:
    case Nil{}: Nil{}
    case rows: [List.reverse(&2, List<&2, T.Cell>, rows)]

def row_groups(rows: T.Rows, acc: T.Rows, remaining: U32) -> List<&2, T.Rows>:
  match rows remaining:
    case Nil{} _: last_group(acc)
    case Con{row, tail} 1:
      List.reverse(&2, List<&2, T.Cell>, row <> acc) <> row_groups(tail, Nil{}, T.batch_size())
    case Con{row, tail} n: row_groups(tail, row <> acc, (n - 1 : U32))

def records(groups: List<&2, T.Rows>, +cols: List<&2, T.Column>) -> R(Bytes):
  match groups:
    case Nil{}: Done{Nil{}}
    case +rows <> rest:
      do R<Bytes>:
        batch : Batch <- columns(cols, rows)
        later : Bytes <- records(rest, cols)
        return L.join(record(batch, L.length(List<&2, T.Cell>, rows)), later)

def encode(table: T.Table) -> R(Bytes):
  T.Table{+cols, rows} = table
  do R<Bytes>:
    defs : List<&2, Bytes> <- fields(cols)
    data : Bytes <- records(row_groups(rows, Nil{}, T.batch_size()), cols)
    return chunks([schema(defs), data, [255,255,255,255,0,0,0,0]])
