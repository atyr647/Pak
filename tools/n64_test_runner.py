#!/usr/bin/env python3
"""
Headless N64 ROM test runner using mupen64plus debugger.

Uses DebugSetCallbacks to enable the debugger.  When init_cb fires we get
the RDRAM pointer and start a polling thread that checks the magic
completion marker every 10 ms (vi_cb never fires without a GFX plugin).

ROM protocol:
  *(0x80300000) = 0xDEADBEEF  ← entry reached
  *(0x80300010 + i*4) = result_i  ← results (i32, big-endian N64 hw)
  *(0x80300000) = 0xC0FFEE00  ← done

Notes:
  - EnableDebugger must be True in mupen64plus config; this runner creates
    a temp config directory automatically.
  - mupen64plus on a little-endian x86 host stores RDRAM words in host
    byte order (little-endian), so all RDRAM reads use 'little' endian.
  - vi_cb never fires without a GFX plugin; polling is done in a thread.
  - The ROM must use the mini IPL3 (tools/mini_ipl3.bin) so the game code
    actually executes.  Libdragon's default IPL3 stalls on 8 MB RDRAM.

Usage:
  python3 tools/n64_test_runner.py rom.z64 [--expect v0 v1 ...]
"""
import ctypes, ctypes.util, os, sys, tempfile, threading, time, argparse

CORE_LIB   = "/usr/lib/x86_64-linux-gnu/libmupen64plus.so.2"
PLUGIN_DIR = "/usr/lib/x86_64-linux-gnu/mupen64plus"

M64ERR_SUCCESS = 0
M64CMD_ROM_OPEN = 1; M64CMD_ROM_CLOSE = 2
M64CMD_EXECUTE  = 5; M64CMD_STOP      = 6
M64PLUGIN_RSP   = 1
M64P_DBG_PTR_RDRAM        = 1
M64P_DBG_RUNSTATE_RUNNING = 1
MAGIC_DONE    = 0xC0FFEE00
RDRAM_SIZE    = 8 * 1024 * 1024
POLL_INTERVAL = 0.01   # 10 ms

# mupen64plus on x86 stores each RDRAM word in little-endian host byte order.
_ENDIAN = 'little'

DebugCB   = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_int,
                              ctypes.POINTER(ctypes.c_char))
StateCB   = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_int, ctypes.c_int)
DbgInitCB = ctypes.CFUNCTYPE(None)
DbgUpdCB  = ctypes.CFUNCTYPE(None, ctypes.c_uint)
DbgViCB   = ctypes.CFUNCTYPE(None)


def _phys(va): return va & 0x1FFFFFFF


def _make_cfg_dir():
    """Create a temp mupen64plus config dir with EnableDebugger=True."""
    tmpdir  = tempfile.mkdtemp(prefix="m64p_")
    cfg_dir = os.path.join(tmpdir, "config")
    os.makedirs(cfg_dir)
    with open(os.path.join(cfg_dir, "mupen64plus.cfg"), "w") as f:
        f.write(
            "[Core]\n"
            "Version = 1.010000\n"
            "EnableDebugger = True\n"
            "R4300Emulator = 0\n"       # Pure Interpreter (debugger-compatible)
            "DisableExtraMem = False\n" # 8 MB RDRAM
        )
    return cfg_dir


class N64Runner:
    def __init__(self, rom, magic_addr, result_addr, count, timeout):
        self.rom         = rom
        self.magic_p     = _phys(magic_addr)
        self.result_p    = _phys(result_addr)
        self.count       = count
        self.timeout     = timeout
        self.results     = None
        self._core       = None
        self._rdram      = None
        self._done       = threading.Event()
        self._poll_stop  = threading.Event()

    # ── ctypes callbacks ────────────────────────────────────────────────────
    def _log(self, ctx, lvl, msg): pass

    def _state(self, ctx, param, val):
        if param == 1 and val == 1:   # EMU_STATE_STOPPED
            self._poll_stop.set()
            self._done.set()

    def _dbg_init(self):
        """Called once when the debugger initialises — get RDRAM and run."""
        self._core.DebugMemGetPointer.restype = ctypes.c_void_p
        ptr = self._core.DebugMemGetPointer(M64P_DBG_PTR_RDRAM)
        if ptr:
            self._rdram = (ctypes.c_uint8 * RDRAM_SIZE).from_address(ptr)
        self._core.DebugSetRunState(M64P_DBG_RUNSTATE_RUNNING)
        # vi_cb never fires without a GFX plugin — poll in a thread instead
        threading.Thread(target=self._poll_rdram, daemon=True).start()

    def _dbg_update(self, pc): pass
    def _dbg_vi(self): pass  # never fires without GFX plugin

    def _poll_rdram(self):
        """Background thread: poll magic address until done marker appears."""
        deadline = time.monotonic() + self.timeout
        while not self._poll_stop.is_set() and time.monotonic() < deadline:
            rdram = self._rdram
            if rdram is not None and self.results is None:
                raw    = bytes(rdram[self.magic_p:self.magic_p + 4])
                marker = int.from_bytes(raw, _ENDIAN)
                if marker == MAGIC_DONE:
                    res = []
                    for i in range(self.count):
                        off = self.result_p + i * 4
                        b   = bytes(rdram[off:off + 4])
                        res.append(int.from_bytes(b, _ENDIAN, signed=True))
                    self.results = res
                    self._core.CoreDoCommand(M64CMD_STOP, 0, None)
                    self._done.set()
                    return
            time.sleep(POLL_INTERVAL)
        # timed out
        if self.results is None:
            self._core.CoreDoCommand(M64CMD_STOP, 0, None)
            self._done.set()

    def run(self):
        core = ctypes.CDLL(CORE_LIB)
        self._core = core

        cfg_dir = _make_cfg_dir()

        self._log_ref   = DebugCB(self._log)
        self._state_ref = StateCB(self._state)
        rc = core.CoreStartup(0x020500,
                              cfg_dir.encode(),  # config dir with EnableDebugger=True
                              None,
                              None, self._log_ref,
                              None, self._state_ref)
        if rc != M64ERR_SUCCESS:
            print(f"CoreStartup: {rc}", file=sys.stderr); return False

        self._init_ref   = DbgInitCB(self._dbg_init)
        self._update_ref = DbgUpdCB(self._dbg_update)
        self._vi_ref     = DbgViCB(self._dbg_vi)
        core.DebugSetCallbacks(self._init_ref, self._update_ref, self._vi_ref)

        # Load ROM
        with open(self.rom, 'rb') as f:
            data = f.read()
        buf = ctypes.create_string_buffer(data, len(data))
        rc  = core.CoreDoCommand(M64CMD_ROM_OPEN, len(data),
                                 ctypes.cast(buf, ctypes.c_void_p))
        if rc != M64ERR_SUCCESS:
            print(f"ROM_OPEN: {rc}", file=sys.stderr)
            core.CoreShutdown(); return False

        # Attach RSP plugin; GFX/audio/input left NULL (headless)
        rsp_path = os.path.join(PLUGIN_DIR, "mupen64plus-rsp-hle.so")
        if os.path.exists(rsp_path):
            rsp = ctypes.CDLL(rsp_path)
            rsp.PluginStartup(core._handle, None, self._log_ref)
            core.CoreAttachPlugin(M64PLUGIN_RSP, rsp._handle)

        # Belt-and-suspenders watchdog
        def watchdog():
            if not self._done.wait(timeout=self.timeout + 2):
                self._poll_stop.set()
                core.CoreDoCommand(M64CMD_STOP, 0, None)
                self._done.set()
        threading.Thread(target=watchdog, daemon=True).start()

        # EXECUTE blocks until stopped
        core.CoreDoCommand(M64CMD_EXECUTE, 0, None)
        self._poll_stop.set()
        self._done.set()

        core.CoreDoCommand(M64CMD_ROM_CLOSE, 0, None)
        core.CoreShutdown()
        return self.results is not None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rom")
    ap.add_argument("--magic",   default="0x80300000")
    ap.add_argument("--results", default="0x80300010")
    ap.add_argument("--count",   type=int, default=8)
    ap.add_argument("--timeout", type=int, default=30)
    ap.add_argument("--expect",  nargs="*")
    args = ap.parse_args()

    runner = N64Runner(args.rom,
                       int(args.magic,   16), int(args.results, 16),
                       args.count, args.timeout)
    ok = runner.run()
    if not ok:
        print("FAIL: no completion marker seen within timeout"); sys.exit(1)

    print(f"Results: {runner.results}")

    if args.expect:
        expected = [int(x) for x in args.expect]
        n        = min(len(expected), len(runner.results))
        bad      = [(i, runner.results[i], expected[i])
                    for i in range(n) if runner.results[i] != expected[i]]
        if bad:
            for i, got, exp in bad:
                print(f"  [{i}] got={got}  expect={exp}  FAIL")
            sys.exit(1)
        print(f"PASS: all {len(expected)} results correct on real N64 hardware emulation")
    sys.exit(0)


if __name__ == "__main__":
    main()
