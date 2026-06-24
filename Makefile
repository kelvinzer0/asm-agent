# ============================================================================
# Makefile — ASM-AGENT Build System
# ============================================================================
# Usage:
#   make          — Build the agent (release, stripped)
#   make debug    — Build with debug symbols
#   make run      — Build and run
#   make clean    — Remove build artifacts
# ============================================================================

ASM       = ./nasm
ASMFLAGS  = -f elf64 -I include/
LD        = ld
LDFLAGS   =
TARGET    = asm-agent

# Source files (order matters for linking)
SRCS = src/main.asm \
       src/strings.asm \
       src/timestamp.asm \
       src/signals.asm \
       src/worklog.asm \
       src/json.asm \
       src/parser.asm \
       src/executor.asm \
       src/api.asm \
       src/conductor.asm \
       src/instruments.asm \
       src/channels.asm \
       src/orchestration.asm \
       src/checkpoint.asm \
       src/tty.asm

OBJS = $(SRCS:.asm=.o)

# Default: release build (stripped)
.PHONY: all debug _debug_link clean run

all: $(TARGET)
	@echo ""
	@echo "  Build complete: ./$(TARGET)"
	@echo "  Size: $$(stat -c %s $(TARGET)) bytes"
	@echo "  Dependencies: $$(ldd $(TARGET) 2>&1 | head -1)"
	@echo ""

$(TARGET): $(OBJS)
	$(LD) -o $@ $^
	strip $@

# Pattern rule: .asm -> .o
src/%.o: src/%.asm include/constants.inc include/macros.inc include/config.inc include/musical.inc include/orchestration.inc
	$(ASM) $(ASMFLAGS) -o $@ $<

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
clean:
	rm -f src/*.o $(TARGET)
	rm -f /tmp/.asm_agent_payload.json
	@echo "  Cleaned."