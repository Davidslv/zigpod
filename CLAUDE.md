# ZigPod Project Guidelines for Claude

## Critical Rules

### Emulator Testing
**NEVER run emulators in the background without hard timeouts.**

The emulator can get stuck in infinite loops (e.g., COP synchronization spin loops) and will consume 100% CPU indefinitely. Always use:

```bash
# CORRECT: Run with timeout
timeout 30s zig build emulator -- [args] 2>&1

# WRONG: Never do this
zig build emulator -- [args] 2>&1 &
```

If you need to run longer tests, always use explicit timeouts:
```bash
timeout 60s zig build emulator -- [args] 2>&1
```

This rule exists because a previous agent left emulators running for 12 hours at 100% CPU.

## Project Context

This is an iPod emulator written in Zig. Key challenges:
- The iPod has dual-core ARM (CPU + COP) but we only emulate CPU
- Many spin loops in Rockbox firmware wait for COP synchronization
- These loops must be bypassed since COP is not emulated
