BEND ?= bend
PYTHON ?= python3
LIB = $(wildcard src/*.bend)
TESTS = $(filter-out tests/ipc_interop.bend,$(wildcard tests/*.bend))

# Keep native compiler memory bounded, including when invoked with -j.
.NOTPARALLEL:

.PHONY: all test test-interop
all: build/roundtrip

build:
	@mkdir -p $@

build/roundtrip: examples/roundtrip.bend $(LIB) | build
	$(BEND) $< -o $@

build/test: tests/all.bend $(TESTS) $(LIB) | build
	$(BEND) $< -o $@

build/ipc-interop: tests/ipc_interop.bend $(LIB) | build
	$(BEND) $< -o $@

# Optional independent codec verification; requires PyArrow in PYTHON's environment.
test-interop: build/ipc-interop
	$(PYTHON) tests/ipc_interop.py ./build/ipc-interop

test: build/roundtrip build/test
	@set -eu; work=$$(mktemp -d); trap 'rm -rf "$$work"' EXIT; \
	  ./build/test "$$work/sessions.benddb"; \
	  output=$$(./build/roundtrip "$$work/Bénd's scores.parquet"); \
	  test "$$output" = 'Score total: 19'; \
	  echo "$$output"
