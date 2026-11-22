CC = clang
DUCKDB_DIR ?= $(CURDIR)/.deps/duckdb
PYTHON ?= python3
NATIVE = native/engine.c native/arrow.c native/streams.c
HEADERS = native/engine.h native/arrow.h native/streams.h native/registry.h
BEND_LIB = $(wildcard src/*.bend src/*.c src/*.js)
LINK_DUCKDB = -L"$(DUCKDB_DIR)" -Xlinker -rpath -Xlinker "$$(CDPATH= cd "$(DUCKDB_DIR)" && pwd)" -lduckdb
C_TEST_FLAGS = -O2 -g -pthread -Wall -Wextra -I native -I"$(DUCKDB_DIR)"
ifeq ($(shell uname -s),Darwin)
SHARED = build/libbendarrow.dylib
SHARED_FLAG = -dynamiclib -Wl,-install_name,@rpath/libbendarrow.dylib
else
SHARED = build/libbendarrow.so
SHARED_FLAG = -shared
endif

.PHONY: all deps native test test-pyarrow
all: build/roundtrip

native: $(SHARED)

deps:
ifeq ($(DUCKDB_DIR),$(CURDIR)/.deps/duckdb)
	@./scripts/fetch-duckdb
else
	@test -f "$(DUCKDB_DIR)/duckdb.h"
endif

build:
	@mkdir -p build

vpath %.bend examples tests
build/roundtrip build/bindings build/database: build/%: %.bend $(BEND_LIB) $(SHARED) scripts/build | build deps
	BEND_ARROW_LIB_DIR="$(CURDIR)/build" DUCKDB_DIR="$(DUCKDB_DIR)" CC="$(CC)" ./scripts/build $< $@

build/arrow-test: tests/arrow.c native/arrow.c native/arrow.h | build deps
	$(CC) $(C_TEST_FLAGS) $(filter %.c,$^) $(LINK_DUCKDB) -o $@

build/streams-test: tests/streams.c native/streams.c native/streams.h native/registry.h native/arrow.h | build deps
	$(CC) $(C_TEST_FLAGS) $(filter %.c,$^) -o $@

build/engine-test: tests/engine.c native/engine.c native/engine.h native/registry.h | build deps
	$(CC) $(C_TEST_FLAGS) $(filter %.c,$^) $(LINK_DUCKDB) -o $@

test: build/roundtrip build/bindings build/database build/arrow-test build/streams-test build/engine-test
	./build/arrow-test
	./build/streams-test
	./build/bindings
	@set -e; tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	  ./build/engine-test "$$tmp/concurrent.duckdb"; \
	  ./build/database "$$tmp/reopen.duckdb"; \
	  file="$$tmp/Bénd's scores.parquet"; \
	  output=$$(./build/roundtrip "$$file"); \
	  test "$$output" = 'Score total: 19'; \
	  test "$$(head -c 4 "$$file")" = PAR1; test "$$(tail -c 4 "$$file")" = PAR1; \
	  echo "Parquet round trip passed"

$(SHARED): $(NATIVE) $(HEADERS) | build deps
	$(CC) -O2 -fPIC $(SHARED_FLAG) -pthread -I native -I"$(DUCKDB_DIR)" $(NATIVE) $(LINK_DUCKDB) -o $@

test-pyarrow: $(SHARED)
	"$(PYTHON)" tests/pyarrow_interop.py "$(SHARED)"
