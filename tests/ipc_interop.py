#!/usr/bin/env python3
"""Optional PyArrow interoperability checks against a compiled Bend driver.

    bend tests/ipc_interop.bend -o build/ipc-interop
    python tests/ipc_interop.py build/ipc-interop

Requires PyArrow; the normal Bend test suite has no Python dependency. A JS
driver also works after compiling with -o build/ipc-interop.mjs:
python tests/ipc_interop.py node tests/ipc_interop.mjs build/ipc-interop.mjs
"""

import argparse
import math
from pathlib import Path
import struct
import subprocess
import tempfile

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq


ROOT = Path(__file__).resolve().parent.parent


def scalar_table():
    """Every supported physical type, including exact integer/float edges."""
    specs = [("bool", pa.bool_(), [False, True, None])]
    for width in (8, 16, 32, 64):
        for signed in (True, False):
            kind = getattr(pa, f"{'int' if signed else 'uint'}{width}")()
            low = -(1 << (width - 1)) if signed else 0
            high = (1 << (width - int(signed))) - 1
            specs.append((str(kind), kind, [low, high, 0, 1, None]))
    for kind, smallest in ((pa.float32(), 2.0**-149), (pa.float64(), 2.0**-1074)):
        specs.append((str(kind), kind, [0.0, -0.0, smallest, -smallest, 1.25,
                                       float("inf"), float("-inf"), float("nan"), None]))
    specs.extend([
        ("text ☃", pa.string(), ["", "☃🙃", "e\u0301", "a\0b", "quoted'\"", None]),
        ("binary", pa.binary(), [b"", b"\0\xff", bytes(range(256)), None]),
    ])
    fields = [pa.field(name, kind, metadata={b"test:bytes": b"\xff\0"})
              for name, kind, _ in specs]
    arrays = [pa.array([values[i % len(values)] for i in range(37)], type=kind)
              for _, kind, values in specs]
    return pa.Table.from_arrays(arrays, schema=pa.schema(fields, metadata={b"test": b"interop"}))


def plain(table):
    arrays = [pc.cast(col, col.type.value_type) if pa.types.is_dictionary(col.type) else col
              for col in table.columns]
    return pa.Table.from_arrays(arrays, names=table.column_names)


def equivalent(expected, actual, label):
    expected, actual = plain(expected), plain(actual)
    if not expected.schema.equals(actual.schema, check_metadata=False):
        raise AssertionError(f"{label}: schema changed: {expected.schema} -> {actual.schema}")
    if expected.num_rows != actual.num_rows:
        raise AssertionError(f"{label}: row count changed")
    for field, want_col, got_col in zip(expected.schema, expected.columns, actual.columns):
        for row, (want, got) in enumerate(zip(want_col.to_pylist(), got_col.to_pylist())):
            if pa.types.is_floating(field.type) and want is not None and got is not None:
                fmt = "<f" if pa.types.is_float32(field.type) else "<d"
                same = (math.isnan(want) and math.isnan(got)) or struct.pack(fmt, want) == struct.pack(fmt, got)
            else:
                same = want == got
            if not same:
                raise AssertionError(f"{label}: {field.name} row {row}: {want!r} != {got!r}")


def write_ipc(path, table, version, legacy=False):
    options = pa.ipc.IpcWriteOptions(metadata_version=version, use_legacy_format=legacy)
    with pa.ipc.new_stream(path, table.schema, options=options) as writer:
        # Include empty batches and non-byte-aligned slices of validity/boolean
        # buffers; each variable-width slice also starts at a nonzero offset.
        for batch in table.to_batches(max_chunksize=17):
            writer.write_batch(batch.slice(0, 0))
            split = min(7, batch.num_rows)
            writer.write_batch(batch.slice(0, split))
            writer.write_batch(batch.slice(split))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("driver", nargs="+", help="compiled Bend driver, optionally preceded by node")
    args = parser.parse_args()
    table = scalar_table()
    count = 0
    with tempfile.TemporaryDirectory(prefix="bend-arrow-interop-") as directory:
        work = Path(directory)

        def check(path, expected, format):
            nonlocal count
            output = work / f"output-{count}"
            result = subprocess.run([*args.driver, format, str(path), str(output)],
                                    cwd=ROOT, capture_output=True, text=True, timeout=120)
            if result.returncode:
                raise RuntimeError(f"{path.name}: Bend exited {result.returncode}\n{result.stdout}{result.stderr}")
            with pa.ipc.open_stream(str(output) + ".arrows") as reader:
                equivalent(expected, reader.read_all(), f"{path.name} -> Bend IPC")
            equivalent(expected, pq.read_table(str(output) + ".parquet"), f"{path.name} -> Bend Parquet")
            count += 1

        for version, legacy in ((pa.ipc.MetadataVersion.V4, True),
                                (pa.ipc.MetadataVersion.V4, False),
                                (pa.ipc.MetadataVersion.V5, False)):
            for suffix, source in (("values", table), ("empty", table.slice(0, 0))):
                path = work / f"ipc-{version.name}-{legacy}-{suffix}.arrows"
                write_ipc(path, source, version, legacy)
                check(path, source, "ipc")

        # Null values may own nonempty payloads, including bytes that are not
        # UTF-8. Decoders must skip those spans and preserve subsequent values.
        offsets = pa.py_buffer(struct.pack("<iii", 0, 8192, 8194))
        payload = pa.py_buffer(b"\xff" * 8192 + b"ok")
        null_span = pa.Array.from_buffers(pa.string(), 2, [pa.py_buffer(b"\x02"), offsets, payload])
        source = pa.table({"null span": null_span})
        path = work / "null-payload.arrows"
        write_ipc(path, source, pa.ipc.MetadataVersion.V5)
        check(path, source, "ipc")

        dictionaries = []
        for column in table.columns:
            encoded = pc.dictionary_encode(column.combine_chunks())
            dictionaries.append(pa.DictionaryArray.from_arrays(encoded.indices.cast(pa.uint8()), encoded.dictionary))
        source = pa.Table.from_arrays(dictionaries, names=table.column_names)
        path = work / "scalar-dictionaries.arrows"
        write_ipc(path, source, pa.ipc.MetadataVersion.V5)
        check(path, source, "ipc")

        for version in ("1.0", "2.0"):
            for compression in ("NONE", "snappy"):
                for dictionary in (False, True):
                    path = work / f"parquet-{version}-{compression}-{dictionary}.parquet"
                    pq.write_table(table, path, compression=compression, use_dictionary=dictionary,
                                   data_page_version=version, row_group_size=17,
                                   data_page_size=128, write_page_checksum=True)
                    check(path, table, "parquet")

        # Exercise writer batching across the 2,048-row boundary.
        large = pa.table({"i": pa.array(range(2051), type=pa.int32()),
                          "b": [None if i % 11 == 0 else i % 2 == 0 for i in range(2051)]})
        path = work / "multiple-batches.arrows"
        write_ipc(path, large, pa.ipc.MetadataVersion.V5)
        check(path, large, "ipc")

        for name in ("pyarrow-v5.arrows", "pyarrow-dictionaries.arrows",
                     "pyarrow-metadata.arrows", "pyarrow-legacy-v4.arrows"):
            path = ROOT / "tests" / "fixtures" / name
            with pa.ipc.open_stream(path) as reader:
                check(path, reader.read_all(), "ipc")

    print(f"PyArrow {pa.__version__}: {count} interoperability cases passed (IPC and Parquet outputs)")


if __name__ == "__main__":
    main()
