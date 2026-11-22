import Base
import ./random_access_list.bend as ListIndex

def Bytes() -> Data:
  List<&2, U32>

# Store the list tail at each 256-byte boundary, including EOF when aligned.
# A seek needs one tree lookup and at most 255 list steps regardless of offset.
type Index is Data:
  Index{length: U32, blocks: ListIndex.Index(Bytes)}

def scan(bs: Bytes, left: U32, offset: U32, blocks: ListIndex.Index(Bytes)) -> Index:
  match bs left:
    case Nil{} 0: Index{offset, ListIndex.push(Bytes, Nil{}, blocks)}
    case Nil{} _: Index{offset, blocks}
    case h <> +tail 0:
      scan(tail, 255, U32.inc(offset), ListIndex.push(Bytes, h <> tail, blocks))
    case _ <> tail k: scan(tail, (k - 1 : U32), U32.inc(offset), blocks)

def build(bs: Bytes) -> Index:
  scan(bs, 0, 0, Nil{})

def size(index: Index) -> U32:
  Index{n, _} = index
  n

def drop(bs: Bytes, offset: U32) -> Maybe<&2, Bytes>:
  match bs offset:
    case rest 0: Some{rest}
    case _ <> tail k: drop(tail, (k - 1 : U32))
    case Nil{} _: None{}

def suffix(index: Index, +offset: U32) -> Maybe<&2, Bytes>:
  Index{n, blocks} = index
  # Blocks are stored newest first. An offset past the last block misses the
  # index; one past EOF within the final block is rejected by drop.
  i = ((n >> 8n) - (offset >> 8n) : U32)
  block = ListIndex.seek(Bytes, blocks, i)
  Maybe.bind(&2, Bytes, Bytes, block, bs => drop(bs, (offset .&. 255 : U32)))
