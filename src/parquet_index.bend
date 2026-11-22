import Base

# A skew binary random-access list. Prepending a byte or dictionary entry costs
# O(1); looking up a decoded Snappy back-reference or dictionary ID costs O(log n).
type Tree<-A: Data> is Data:
  Tip{v: A}
  Branch{v: A, l: Tree<A>, r: Tree<A>}

type Block<-A: Data> is Data:
  Block{size: U32, tree: Tree<A>}

def Index(-A: Data) -> Data:
  List<&2, Block<A>>

def merge(-A: Data, x: A, +n: U32, l: Tree<A>, m: U32, r: Tree<A>, tail: Index(A), equal: Bool) -> Index(A):
  match equal:
    case True{}: Block{(1 + 2 * n : U32), Branch{x, l, r}} <> tail
    case False{}: Block{1, Tip{x}} <> Block{n, l} <> Block{m, r} <> tail

def push(-A: Data, x: A, blocks: Index(A)) -> Index(A):
  match blocks:
    case Block{+n, l} <> Block{+m, r} <> tail:
      merge(A, x, n, l, m, r, tail, U32.is_eq(n, m))
    case rest: Block{1, Tip{x}} <> rest

@unsafe def in_tree(-A: Data, t: Tree<A>, size: U32, i: U32) -> Maybe<&2, A>:
  match t i:
    case Tip{v} 0: Some{v}
    case Tip{_} _: None{}
    case Branch{v, _, _} 0: Some{v}
    case Branch{_, l, r} +k:
      +half = (size >> 1n : U32)
      in_tree(A, Bool.pick(Tree<A>, U32.is_le(k, half), l, r), half, ((k - 1) % half : U32))

@unsafe def seek(-A: Data, blocks: Index(A), +i: U32) -> Maybe<&2, A>:
  match blocks:
    case Nil{}: None{}
    case Block{+n, t} <> tail: seek.block(A, tail, i, n, t, U32.is_lt(i, n))

@unsafe def seek.block(-A: Data, tail: Index(A), i: U32, n: U32, t: Tree<A>, inside: Bool) -> Maybe<&2, A>:
  match inside:
    case True{}: in_tree(A, t, n, i)
    case False{}: seek(A, tail, (i - n : U32))
