BEND ?= bend
LIB = $(wildcard src/*.bend)
TESTS = $(wildcard tests/*.bend)

.PHONY: all test
all: build/roundtrip

build:
	@mkdir -p $@

build/roundtrip: examples/roundtrip.bend $(LIB) | build
	$(BEND) $< -o $@

build/test: tests/all.bend $(TESTS) $(LIB) | build
	$(BEND) $< -o $@

test: build/roundtrip build/test
	@set -eu; work=$$(mktemp -d); trap 'rm -rf "$$work"' EXIT; \
	  ./build/test "$$work/sessions.benddb"; \
	  output=$$(./build/roundtrip "$$work/Bénd's scores.parquet"); \
	  test "$$output" = 'Score total: 19'; \
	  echo "$$output"
