import Base
import ./table.bend as T
import ./arrow_layout.bend as A
import ./utf8.bend as UTF8

# Resolve the schema once before checking externally supplied rows.
type ColumnType is Data:
  Flat{kind: A.Physical}
  Wide{signed: Bool}
  NullOnly{}

def flat(kind: Maybe<&2, A.Physical>, name: String) -> A.Outcome(ColumnType):
  match kind:
    case Some{p}: Done{Flat{p}}
    case None{}: Fail{(22, "unsupported table column type " ++ name)}

def column_type(name: String) -> A.Outcome(ColumnType):
  match name:
    case "HUGEINT": Done{Wide{True{}}}
    case "UHUGEINT": Done{Wide{False{}}}
    case "NULL": Done{NullOnly{}}
    case +n: flat(A.kind(n), n)

def schema(cols: List<&2, T.Column>) -> A.Outcome(List<&2, ColumnType>):
  match cols:
    case Nil{}: Done{Nil{}}
    case T.Column{_, typ} <> rest:
      do Result<&1, &1, U32 & String, List<&2, ColumnType>>:
        kind : ColumnType <- column_type(typ)
        kinds : List<&2, ColumnType> <- schema(rest)
        return kind <> kinds

def cell(value: T.Cell, kind: ColumnType) -> Bool:
  match value kind:
    case T.Null{} _: True{}
    case T.WideSigned{_, _, _, _} Wide{True{}}: True{}
    case T.WideUnsigned{_, _, _, _} Wide{False{}}: True{}
    case T.Signed{hi, lo} Flat{A.Integer{width, True{}}}: A.integer_fits(width, True{}, hi, lo)
    case T.Unsigned{hi, lo} Flat{A.Integer{width, False{}}}: A.integer_fits(width, False{}, hi, lo)
    case T.Float{_} Flat{A.Real{32}}: True{}
    case T.Double{_, _} Flat{A.Real{64}}: True{}
    case T.Boolean{_} Flat{A.Bit{}}: True{}
    case T.Utf8{text} Flat{A.Utf8Type{}}: UTF8.valid(text)
    case T.Bytes{bytes} Flat{A.Binary{}}: List.all(~&2, ~U32, ~(b => U32.is_le(b, 255)), bytes)
    case _ _: False{}

def row(kinds: List<&2, ColumnType>, values: List<&2, T.Cell>) -> A.Outcome(Unit):
  match kinds values:
    case Nil{} Nil{}: Done{Unit{}}
    case kind <> ks x <> xs:
      do Result<&1, &1, U32 & String, Unit>:
        _ : Unit <- Bool.pick(A.Outcome(Unit), cell(x, kind), Done{Unit{}}, Fail{(22, "cell disagrees with registered table schema")})
        row(ks, xs)
    case _ _: Fail{(22, "row width differs from registered table schema")}

def rows(values: T.Rows, +kinds: List<&2, ColumnType>) -> A.Outcome(Unit):
  match values:
    case Nil{}: Done{Unit{}}
    case r <> rest:
      do Result<&1, &1, U32 & String, Unit>:
        _ : Unit <- row(kinds, r)
        rows(rest, kinds)

def check(table: T.Table) -> A.Outcome(Unit):
  T.Table{cols, values} = table
  do Result<&1, &1, U32 & String, Unit>:
    kinds : List<&2, ColumnType> <- schema(cols)
    rows(values, kinds)
