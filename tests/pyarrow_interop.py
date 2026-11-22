"""Check the native Arrow ABI against an independent producer and consumer."""

import ctypes as c
from pathlib import Path
import sys

import pyarrow as pa


class Stream(c.Structure):
    _fields_ = [(name, c.c_void_p) for name in (
        "get_schema", "get_next", "get_last_error", "release", "private_data"
    )]


def check(library_path):
    lib = c.CDLL(str(Path(library_path).resolve()))
    stream_ptr = c.POINTER(Stream)
    error_ptr = c.POINTER(c.c_char_p)
    lib.bd_open.argtypes = [c.c_char_p, c.POINTER(c.c_uint32), error_ptr]
    lib.bd_connection.argtypes = [c.c_uint32]
    lib.bd_connection.restype = c.c_void_p
    lib.bd_close.argtypes = [c.c_uint32]
    lib.bd_arrow_query.argtypes = [c.c_void_p, c.c_char_p, stream_ptr, error_ptr]
    lib.bd_arrow_import.argtypes = [c.c_void_p, c.c_char_p, stream_ptr, error_ptr]

    def call(fn, *args):
        error = c.c_char_p()
        code = fn(*args, c.byref(error))
        if code:
            raise RuntimeError(error.value.decode() if error.value else f"error {code}")

    token = c.c_uint32()
    call(lib.bd_open, b":memory:", c.byref(token))
    db = lib.bd_connection(token)
    try:
        # Both batches exceed DuckDB's default vector size. Slicing gives
        # the producer nonzero Arrow offsets, including for the null bitmap.
        length = 10004
        source = pa.record_batch({
            "id": pa.array(range(length), type=pa.int32()),
            "label": pa.array([None if i % 3 else "β" for i in range(length)]),
            "nested": pa.array([[1, None] if i % 2 else [] for i in range(length)]),
        })
        first = source.slice(1, 5001)
        second = source.slice(5002, 5001)
        batches = [first, source.slice(5002, 0), second]
        producer = pa.RecordBatchReader.from_batches(source.schema, batches)
        incoming = Stream()
        producer._export_to_c(c.addressof(incoming))
        try:
            call(lib.bd_arrow_import, db, b"external", c.byref(incoming))
        finally:
            # Import borrows the caller's stream.
            assert incoming.release
            c.CFUNCTYPE(None, stream_ptr)(incoming.release)(c.byref(incoming))
        assert not incoming.release

        outgoing = Stream()
        call(lib.bd_arrow_query, db, b'SELECT * FROM "external" ORDER BY id', c.byref(outgoing))
        reader = pa.RecordBatchReader._import_from_c(c.addressof(outgoing))
        assert not outgoing.release  # PyArrow moved the stream.
        try:
            actual = reader.read_all()
        finally:
            reader.close()
    finally:
        close_status = lib.bd_close(token)
        assert close_status == 0

    # Retained batches remain readable after releasing the stream and database.
    assert len(actual.to_batches()) > 1
    expected = pa.Table.from_batches([first, second])
    assert actual.equals(expected), (actual.schema, expected.schema)


if __name__ == "__main__":
    check(sys.argv[1])
    print("PyArrow C stream round trip passed")
