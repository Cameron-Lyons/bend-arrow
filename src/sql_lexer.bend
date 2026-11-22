import Base

type Token is Data:
  Name{text: String}
  Keyword{text: String}
  Number{text: String}
  StringLiteral{text: String}
  Symbol{code: U32}

def Tokens() -> Data:
  List<&2, Token>

def Checked(-A: Type) -> Type:
  Result<&1, &1, U32 & String, A>

def Checked.pure(-A: Type, value: A) -> Checked(A):
  Done{value}

def Checked.bind(-A: Type, -B: Type, r: Checked(A), f: A -> Checked(B)) -> Checked(B):
  match r:
    case Fail{err}: Fail{err}
    case Done{x}: f(x)

def error(-A: Type, message: String) -> Checked(A):
  Fail{(22, message)}

def keywords() -> List<&2, String>:
  ["CREATE", "INSERT", "INTO", "TABLE", "TEMP", "TEMPORARY", "BEGIN", "COMMIT",
   "ROLLBACK", "GROUP", "ORDER", "BY", "ASC", "DESC", "SELECT", "FROM",
   "WHERE", "AS", "VALUES", "IS", "NOT", "NULL", "OR", "AND",
   "TRUE", "FALSE"]

def keyword(+upper: String, original: String) -> Token:
  reserved = List.contains(~String, ~String.eq, keywords, upper)
  Bool.pick(Token, reserved, Keyword{upper}, Name{original})

def word(+value: String, digit: Bool) -> Token:
  match digit:
    case True{}: Number{value}
    case False{}: keyword(String.to_upper(value), value)

def flush(reversed: String, acc: Tokens) -> Tokens:
  match reversed:
    case SNil{}: acc
    case SCon{h, t}:
      +value = String.reverse(SCon{h, t})
      word(value, Char.is_digit(Maybe.default(&2, Char, String.get(value, 0n), Chr{32}))) <> acc

type LexState is Data:
  Bare{word: String, acc: Tokens}
  Quoted{quote: U32, text: String, acc: Tokens}
  AfterQuote{quote: U32, text: String, acc: Tokens}

def quoted_token(text: String, quote: U32) -> Token:
  match quote:
    case 39: StringLiteral{text}
    case _: Name{text}

def bare_char(+code: U32, +reversed: String, +acc: Tokens, space: Bool, word_char: Bool) -> LexState:
  match space word_char:
    case True{} _: Bare{"", flush(reversed, acc)}
    case _ True{}: Bare{SCon{Chr{code}, reversed}, acc}
    case _ _:
      +out = flush(reversed, acc)
      Bool.pick(LexState, U32.is_eq(code, 39) || U32.is_eq(code, 34), Quoted{code, "", out}, Bare{"", Symbol{code} <> out})

def bare(+code: U32, buf: String, acc: Tokens) -> LexState:
  ident = Char.is_alpha(Chr{code}) || Char.is_digit(Chr{code}) || U32.is_eq(code, 95) || U32.is_ge(code, 128)
  bare_char(code, buf, acc, Char.is_space(Chr{code}), ident)

# A doubled quote represents one quote inside an identifier or string.
def advance(state: LexState, +code: U32) -> LexState:
  match state:
    case Bare{buf, acc}: bare(code, buf, acc)
    case Quoted{+q, +buf, +acc}:
      Bool.pick(LexState, U32.is_eq(q, code), AfterQuote{q, buf, acc}, Quoted{q, SCon{Chr{code}, buf}, acc})
    case AfterQuote{+q, +buf, +acc}:
      Bool.pick(LexState, U32.is_eq(q, code), Quoted{q, SCon{Chr{q}, buf}, acc}, bare(code, "", quoted_token(String.reverse(buf), q) <> acc))

def finish(state: LexState) -> Checked(Tokens):
  match state:
    case Bare{word, acc}: Done{List.reverse(&2, Token, flush(word, acc))}
    case AfterQuote{+q, buf, acc}: Done{List.reverse(&2, Token, quoted_token(String.reverse(buf), q) <> acc)}
    case Quoted{_, _, _}: error(Tokens, "unterminated SQL quote")

def scan(s: String, state: LexState) -> Checked(Tokens):
  match s:
    case SNil{}: finish(state)
    case SCon{Chr{0}, _}: error(Tokens, "NUL in SQL")
    case SCon{Chr{code}, rest}: scan(rest, advance(state, code))

def tokenize(sql: String) -> Checked(Tokens):
  scan(sql, Bare{"", Nil{}})
