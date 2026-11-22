import Base

def continuation(n: U32) -> U32:
  ((n .&. 63) .|. 128 : U32)

def scalar(+n: U32, ascii: Bool, two: Bool, three: Bool, valid: Bool) -> Result<&1, &1, (U32 & String), List<&2, U32>>:
  match ascii two three valid:
    case _ _ _ False{}: Fail{(22, "Invalid Unicode scalar in string")}
    case True{} _ _ _: Done{[n]}
    case _ True{} _ _: Done{[((n >> 6n) .|. 192 : U32), continuation(n)]}
    case _ _ True{} _: Done{[((n >> 12n) .|. 224 : U32), continuation((n >> 6n : U32)), continuation(n)]}
    case _ _ _ _: Done{[((n >> 18n) .|. 240 : U32), continuation((n >> 12n : U32)), continuation((n >> 6n : U32)), continuation(n)]}

def encode(s: String) -> Result<&1, &1, (U32 & String), List<&2, U32>>:
  match s:
    case SNil{}: Done{Nil{}}
    case SCon{Chr{+n}, tail}:
      valid = U32.is_le(n, 1114111) && (U32.is_lt(n, 55296) || U32.is_gt(n, 57343))
      do Result<&1, &1, (U32 & String), List<&2, U32>>:
        bytes : List<&2, U32> <- scalar(n, U32.is_lt(n, 128), U32.is_lt(n, 2048), U32.is_lt(n, 65536), valid)
        rest : List<&2, U32> <- encode(tail)
        return List.append(&2, U32, bytes, rest)

def decode.check(ok: Bool, msg: String) -> Result<&1, &1, (U32 & String), Unit>:
  match ok:
    case True{}: Done{Unit{}}
    case False{}: Fail{(22, msg)}

# Decode text strictly, including checks for overlong forms and surrogate code points.
@unsafe def decode.go(bs: List<&2, U32>, acc: String) -> Result<&1, &1, (U32 & String), String>:
  match bs:
    case Nil{}: Done{String.reverse(acc)}
    case +h <> t:
      decode.lead(h, t, acc, U32.is_lt(h, 128), U32.is_lt(h, 224), U32.is_lt(h, 240))

@unsafe def decode.lead(+h: U32, tail: List<&2, U32>, acc: String, ascii: Bool, two: Bool, three: Bool) -> Result<&1, &1, (U32 & String), String>:
  match ascii two three:
    case True{} _ _: decode.go(tail, SCon{Chr{h}, acc})
    case _ True{} _:
      do Result<&1, &1, (U32 & String), String>:
        decode.check(U32.is_ge(h, 194), "invalid UTF-8 leading byte")
        decode.cont(1, U32.and(h, 31), 128, tail, acc)
    case _ _ True{}: decode.cont(2, U32.and(h, 15), 2048, tail, acc)
    case _ _ _:
      do Result<&1, &1, (U32 & String), String>:
        decode.check(U32.is_le(h, 244), "invalid UTF-8 leading byte")
        decode.cont(3, U32.and(h, 7), 65536, tail, acc)

@unsafe def decode.cont(n: U32, +word: U32, minimum: U32, bs: List<&2, U32>, acc: String) -> Result<&1, &1, (U32 & String), String>:
  match n:
    case 0:
      do Result<&1, &1, (U32 & String), String>:
        decode.check(U32.is_ge(word, minimum) && U32.is_le(word, 1114111) && (U32.is_lt(word, 55296) || U32.is_gt(word, 57343)), "invalid UTF-8 code point")
        decode.go(bs, SCon{Chr{word}, acc})
    case k:
      match bs:
        case Nil{}: Fail{(22, "truncated UTF-8")}
        case +h <> t:
          do Result<&1, &1, (U32 & String), String>:
            decode.check(U32.is_eq(U32.and(h, 192), 128), "invalid UTF-8 continuation")
            decode.cont((k - 1 : U32), (word * 64 + (h .&. 63) : U32), minimum, t, acc)

def decode(bs: List<&2, U32>) -> Result<&1, &1, (U32 & String), String>:
  decode.go(bs, "")
