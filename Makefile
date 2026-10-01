ODIN      ?= odin
SLANG     ?= vendor/slang/bin/slangc
GOOSE     := vendor/goose/src/tools/build
GOOSE_BIN := vendor/goose/goose-build
GOOSE_SRC := $(wildcard $(GOOSE)/*.odin)
SRC       := ./src
BIN       := main
BIN_DEBUG := main_debug

RELEASE_FLAGS := -o:aggressive -microarch:native -no-bounds-check -disable-assert
DEBUG_FLAGS   := -debug -o:none
HOT_FLAGS     := -define:HOT_RELOAD=true

.PHONY: all build shaders shaders-hot run run-optimized debug debug-optimized clean

all: build

$(GOOSE_BIN): $(GOOSE_SRC)
	$(ODIN) build $(GOOSE) -out:$(GOOSE_BIN) -o:aggressive -microarch:native -no-bounds-check -disable-assert

# Baked glue: shader blobs are #load-ed into the binary at compile time.
shaders: $(GOOSE_BIN)
	$(GOOSE_BIN) --manifest goose.json --slang $(SLANG)

# Hot-reload glue: procs read shader artifacts from disk per call; the app
# watches src/shaders and swaps pipelines on edit. Run from the project root.
shaders-hot: $(GOOSE_BIN)
	$(GOOSE_BIN) --manifest goose.json --slang $(SLANG) --hot-reload

build: shaders
	$(ODIN) build $(SRC) -out:$(BIN) $(RELEASE_FLAGS)

run: shaders-hot
	$(ODIN) run $(SRC) $(HOT_FLAGS) -- $(ARGS)

run-optimized: shaders-hot
	$(ODIN) run $(SRC) $(RELEASE_FLAGS) $(HOT_FLAGS) -- $(ARGS)

debug: shaders-hot
	$(ODIN) build $(SRC) -out:$(BIN_DEBUG) $(DEBUG_FLAGS) $(HOT_FLAGS)

debug-optimized: shaders-hot
	$(ODIN) build $(SRC) -out:$(BIN_DEBUG) $(RELEASE_FLAGS) $(HOT_FLAGS) -debug

clean:
	rm -f $(BIN) $(BIN_DEBUG)
