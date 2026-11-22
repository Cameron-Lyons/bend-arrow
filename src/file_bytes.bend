import Base

def Bytes() -> Data:
  List<&2, U32>

def Outcome(-A: Type) -> Type:
  Result<&1, &1, (U32 & String), A>

def closed(-A: Type, pair: File & Outcome(A)) -> IO(Outcome(A)):
  (f, result) = pair
  do IO<Outcome(A)>:
    File.close(f)
    return result

def read_bounded(file: File, size: U32, ok: Bool) -> IO(Outcome(Bytes)):
  match ok:
    case True{}:
      do IO<Outcome(Bytes)>:
        pair : File & Outcome(Bytes) <- File.read_bytes(file, size)
        closed(Bytes, pair)
    case False{}:
      do IO<Outcome(Bytes)>:
        File.close(file)
        return Fail{(75, "file exceeds the supported 2 GiB read size")}

def read_sized(file: File, size: Outcome(U32)) -> IO(Outcome(Bytes)):
  match size:
    case Fail{err}:
      do IO<Outcome(Bytes)>:
        File.close(file)
        return Fail{err}
    case Done{+n}: read_bounded(file, n, U32.is_le(n, 2147483647))

def with_size(pair: File & Outcome(U32)) -> IO(Outcome(Bytes)):
  (file, size) = pair
  read_sized(file, size)

def read_opened(result: Outcome(File)) -> IO(Outcome(Bytes)):
  match result:
    case Fail{err}: IO.pure(Outcome(Bytes), Fail{err})
    case Done{file}:
      do IO<Outcome(Bytes)>:
        pair : File & Outcome(U32) <- File.size(file)
        with_size(pair)

def read(path: String) -> IO(Outcome(Bytes)):
  IO.bind(Outcome(File), Outcome(Bytes), File.open(path, "r"), read_opened)

def write_opened(result: Outcome(File), bytes: Bytes) -> IO(Outcome(Unit)):
  match result:
    case Fail{err}: IO.pure(Outcome(Unit), Fail{err})
    case Done{file}:
      do IO<Outcome(Unit)>:
        pair : File & Outcome(Unit) <- File.write_bytes(file, bytes)
        closed(Unit, pair)

# Finish encoding before creating the file. Exclusive creation protects existing outputs.
def create(path: String, encoded: Outcome(Bytes)) -> IO(Outcome(Unit)):
  match encoded:
    case Fail{err}: IO.pure(Outcome(Unit), Fail{err})
    case Done{bytes}:
      do IO<Outcome(Unit)>:
        file : Outcome(File) <- File.open(path, "x")
        write_opened(file, bytes)
