ODIN      ?= odin
SLANG     ?= vendor/slang/bin/slangc
GOOSE_DIR ?= ../goose
GOOSE     := $(GOOSE_DIR)/src/tools/build
GOOSE_BIN := $(GOOSE_DIR)/goose-build
GOOSE_SRC := $(wildcard $(GOOSE)/*.odin)
SRC       := ./src
BIN       := main
BIN_DEBUG := main_debug

RELEASE_FLAGS := -o:aggressive -microarch:native -no-bounds-check -disable-assert
DEBUG_FLAGS   := -debug -o:none
HOT_FLAGS     := -define:HOT_RELOAD=true

.PHONY: all build shaders shaders-hot run run-optimized debug debug-optimized clean

# The integrated ImGui editor (src/imgui_editor.odin) links the
# ImGuiColorTextEdit wrapper; every app build needs it. The wrapper MUST use
# the same IMGUI_DISABLE_OBSOLETE_* defines as the premake-built imgui lib.
APP_DEPS := vendor/ImGuiColorTextEdit/libite.a vendor/imnodes/libine.a
IMGUI_DEFINES := -DIMGUI_DISABLE_OBSOLETE_FUNCTIONS -DIMGUI_DISABLE_OBSOLETE_KEYIO
IMGUI_INC := vendor/odin-imgui/build/deps/imgui
ITE_SRC := vendor/ImGuiColorTextEdit/TextEditor.cpp vendor/ImGuiColorTextEdit/TextEditor.h vendor/ImGuiColorTextEdit/ite/ite.cpp vendor/ImGuiColorTextEdit/ite/ite.h

vendor/ImGuiColorTextEdit/libite.a: $(ITE_SRC)
	clang++ -std=c++17 -O2 $(IMGUI_DEFINES) -c vendor/ImGuiColorTextEdit/TextEditor.cpp -I$(IMGUI_INC) -Ivendor/ImGuiColorTextEdit -o /tmp/TextEditor.o
	clang++ -std=c++17 -O2 $(IMGUI_DEFINES) -c vendor/ImGuiColorTextEdit/ite/ite.cpp -I$(IMGUI_INC) -Ivendor/ImGuiColorTextEdit -o /tmp/ite.o
	rm -f $@
	ar rc $@ /tmp/TextEditor.o /tmp/ite.o
	ranlib $@

# The node graph panel (src/imgui_nodes.odin) links the imnodes wrapper
# (vendor/imnodes pinned to eb36902, "Fix AddRect call for ImGui 1.92.8").
INE_SRC := vendor/imnodes/imnodes.cpp vendor/imnodes/imnodes.h vendor/imnodes/imnodes_internal.h vendor/imnodes/ine/ine.cpp vendor/imnodes/ine/ine.h

vendor/imnodes/libine.a: $(INE_SRC)
	clang++ -std=c++17 -O2 $(IMGUI_DEFINES) -c vendor/imnodes/imnodes.cpp -I$(IMGUI_INC) -Ivendor/imnodes -o /tmp/imnodes.o
	clang++ -std=c++17 -O2 $(IMGUI_DEFINES) -c vendor/imnodes/ine/ine.cpp -I$(IMGUI_INC) -Ivendor/imnodes -Ivendor/imnodes/ine -o /tmp/ine.o
	rm -f $@
	ar rc $@ /tmp/imnodes.o /tmp/ine.o
	ranlib $@

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

build: shaders $(APP_DEPS)
	$(ODIN) build $(SRC) -out:$(BIN) $(RELEASE_FLAGS)

run: shaders-hot $(APP_DEPS)
	$(ODIN) run $(SRC) $(HOT_FLAGS) -- $(ARGS)

run-optimized: shaders-hot $(APP_DEPS)
	$(ODIN) run $(SRC) $(RELEASE_FLAGS) $(HOT_FLAGS) -- $(ARGS)

debug: shaders-hot $(APP_DEPS)
	$(ODIN) build $(SRC) -out:$(BIN_DEBUG) $(DEBUG_FLAGS) $(HOT_FLAGS)

debug-optimized: shaders-hot $(APP_DEPS)
	$(ODIN) build $(SRC) -out:$(BIN_DEBUG) $(RELEASE_FLAGS) $(HOT_FLAGS) -debug

clean:
	rm -f $(BIN) $(BIN_DEBUG)
