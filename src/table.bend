import Base

# The high and low words preserve every bit of 64-bit numbers, including signed
# two's-complement integers and IEEE 754 binary64 values.
type Cell is Data:
  Null{}
  Boolean{value: Bool}
  Signed{upper: U32, lower: U32}
  Unsigned{upper: U32, lower: U32}
  WideSigned{a: U32, b: U32, c: U32, d: U32}
  WideUnsigned{a: U32, b: U32, c: U32, d: U32}
  Float{value: F32}
  Double{upper: U32, lower: U32}
  Utf8{value: String}
  Bytes{value: List<&2, U32>}

type Column is Data:
  Column{name: String, sql_type: String}

type Table is Data:
  Table{columns: List<&2, Column>, rows: List<&2, List<&2, Cell>>}

def Rows() -> Data:
  List<&2, List<&2, Cell>>

type RowBatch is Data:
  RowBatch{rows: Rows, rest: Rows}

def take_rows(rows: Rows, n: U32, acc: Rows) -> RowBatch:
  match rows n:
    case rs 0: RowBatch{List.reverse(&2, List<&2, Cell>, acc), rs}
    case Nil{} _: RowBatch{List.reverse(&2, List<&2, Cell>, acc), Nil{}}
    case row <> tail count: take_rows(tail, (count - 1 : U32), row <> acc)

def batch_size() -> U32:
  2048
