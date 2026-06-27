# ============================================================================
# Makefile — ASM-AGENT Build System (v0.3.0 — with VisiBox)
# ============================================================================
# Usage:
#   make          — Build the agent + fetch VisiBox (release, stripped)
#   make debug    — Build with debug symbols
#   make run      — Build and run
#   make clean    — Remove build artifacts
# ============================================================================

ASM       = nasm
ASMFLAGS  = -f elf64 -I include/
LD        = ld
LDFLAGS   =
TARGET    = asm-agent

# VisiBox settings
VISIBOX_VERSION = 0.3.0
VISIBOX_URL     = https://github.com/kelvinzer0/visibox/releases/download/v$(VISIBOX_VERSION)/visibox-x86_64-linux-gnu.tar.gz
VISIBOX_BIN     = bin/visibox

# Source files (order matters for linking)
SRCS = src/main.asm \
       src/strings.asm \
       src/timestamp.asm \
       src/signals.asm \
       src/worklog.asm \
       src/json.asm \
       src/parser.asm \
       src/executor.asm \
       src/visibox_client.asm \
       src/tool_exec.asm \
       src/tool_fetch_page.asm \
       src/tool_search.asm \
       src/tool_session.asm \
       src/api.asm \
       src/conductor.asm \
       src/instruments.asm \
       src/channels.asm \
       src/orchestration.asm \
       src/checkpoint.asm

OBJS = $(SRCS:.asm=.o)

# Default: release build (stripped), includes VisiBox
.PHONY: all debug _debug_link clean run visibox visibox-clean

all: visibox $(TARGET)
	@echo ""
	@echo "  Build complete: ./$(TARGET)"
	@echo "  Size: $$(stat -c %s $(TARGET)) bytes (asm-agent) + $$(stat -c %s $(VISIBOX_BIN)) bytes (visibox)"
	@echo "  VisiBox: $(VISIBOX_BIN) (v$(VISIBOX_VERSION))"
	@echo "  Dependencies: $$(ldd $(TARGET) 2>&1 | head -1)"
	@echo ""

$(TARGET): $(OBJS)
	$(LD) -o $@ $^
	strip $@

# Pattern rule: .asm -> .o
src/%.o: src/%.asm include/constants.inc include/macros.inc include/config.inc include/musical.inc include/orchestration.inc
	$(ASM) $(ASMFLAGS) -o $@ $<

# ============================================================================
# VisiBox — Download prebuilt binary if not present
# ============================================================================
visibox: $(VISIBOX_BIN)

$(VISIBOX_BIN):
	@echo "  Downloading VisiBox v$(VISIBOX_VERSION)..."
	@mkdir -p bin
	@curl -sL $(VISIBOX_URL) -o /tmp/visibox.tar.gz
	@tar xzf /tmp/visibox.tar.gz -C bin/
	@chmod +x $(VISIBOX_BIN)
	@rm -f /tmp/visibox.tar.gz
	@echo "  VisiBox v$(VISIBOX_VERSION) installed to $(VISIBOX_BIN)"

visibox-clean:
	rm -rf bin/
	@echo "  VisiBox removed."

# Debug build (with DWARF symbols, no strip)
debug: ASMFLAGS += -g -F dwarf
debug: clean
	@$(MAKE) ASMFLAGS="$(ASMFLAGS)" LDFLAGS="" _debug_link

_debug_link: $(OBJS)
	$(LD) -o $(TARGET) $^
	@echo ""
	@echo "  Debug build complete: ./$(TARGET)"
	@echo ""

# Run
run: all
	@echo "  Launching ASM-AGENT..."
	@echo ""
	@./$(TARGET)

# Clean
clean: visibox-clean
	rm -f src/*.o $(TARGET)
	rm -f /tmp/.asm_agent_payload.json
	@echo "  Cleaned."