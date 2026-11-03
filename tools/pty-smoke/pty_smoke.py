"""Scripted PTY smoke test for zay's real terminal build (draw-purity plan, Phase D;
focus-transition scenarios added by the #292 part 2 work).

Drives the freshly built zay.exe through a Windows ConPTY and asserts on the
rendered byte stream for the states that need a live terminal: at-search with
results / empty / no-matches, Esc close, a mid-session resize, and — the
#292/#313 crash class — mode transitions that must leave typed input alive:
open the command menu / transcript search / help, close each, then require a
unique token to echo in the main prompt.

Not covered here (needs an agent/LLM to spawn background jobs): the Ctrl+O
modal states — those are covered deterministically by the scripted in-process
smoke tests in src/tui/tests.zig ("scripted smoke: ...") which run the real
drawRoot + event router against real pwsh child processes.

Usage:
    uv run --with pywinpty python tools/pty-smoke/pty_smoke.py [exe] [cwd]

Exit code: 0 iff every check passed.
"""

import os
import queue
import sys
import threading
import time

from winpty import PtyProcess

EXE = sys.argv[1] if len(sys.argv) > 1 else os.path.join("zig-out", "bin", "zay.exe")
CWD = sys.argv[2] if len(sys.argv) > 2 else "."

results = []


def start_reader(p, q):
    """pywinpty's read() blocks forever when no data flows, so pump it from
    a thread and let consumers wait on a queue with a timeout."""

    def pump():
        while True:
            try:
                chunk = p.read(65536)
            except (EOFError, OSError):
                break
            if not chunk:
                break
            q.put(chunk)
        q.put(None)  # EOF sentinel

    t = threading.Thread(target=pump, daemon=True)
    t.start()
    return t


def read_for(q, seconds):
    buf = ""
    end = time.time() + seconds
    while time.time() < end:
        try:
            chunk = q.get(timeout=0.05)
        except queue.Empty:
            continue
        if chunk is None:
            break
        buf += chunk
    return buf


def check(seq, name, blob, *needles):
    missing = [n for n in needles if n not in blob]
    ok = not missing
    results.append(ok)
    suffix = "" if ok else f"  -- missing: {missing}"
    print(f"[{'PASS' if ok else 'FAIL'}] {seq}. {name}{suffix}", flush=True)
    return ok


def main():
    print(f"spawning {EXE} (cwd={CWD}) under ConPTY 120x34 ...", flush=True)
    # Isolate the child from the developer's real zay home (roaming session
    # store, MCP servers, plugins): boot the smoke against default config in
    # a throwaway APPDATA so the first frame is fast and side-effect free.
    import tempfile
    isolated = tempfile.mkdtemp(prefix="zay-pty-smoke-")
    os.environ["APPDATA"] = isolated
    os.environ["HOME"] = isolated
    p = PtyProcess.spawn(EXE, dimensions=(34, 120), cwd=CWD)
    q = queue.Queue()
    start_reader(p, q)
    try:
        # Startup (models.dev registry, session-store resume lookups) can
        # legitimately take ~25s under ConPTY before the first frame.
        boot = read_for(q, 45.0)
        if "\x1b[?1049h" not in boot:
            print(f"[FAIL] 0. app never entered the alternate screen ({len(boot)} bytes)")
            return 1
        print(f"[PASS] 0. app booted and rendered ({len(boot)} bytes)", flush=True)
        results.append(True)

        # -- at-search: empty query -----------------------------------------
        # The very first `@` starts the index walk: the popup legitimately
        # shows the transient "Indexing…" until the backend is ready.
        p.write("@")
        blob = read_for(q, 2.5)
        if "Files" not in blob:
            check(1, "at-search opens", blob, "Files")
        elif "Type a path after @" in blob or "Indexing" in blob:
            results.append(True)
            print("[PASS] 1. at-search opens (empty message or transient indexing)", flush=True)
        else:
            results.append(False)
            print("[FAIL] 1. at-search opened but shows neither the empty"
                  " message nor Indexing", flush=True)

        # -- at-search: results ---------------------------------------------
        p.write("layout")
        blob = read_for(q, 6.0)
        check(2, "at-search shows results for 'layout'", blob, "layout.zig")

        # -- at-search: no matches ------------------------------------------
        # (The plan's smoke list: results, no-results, backend failure. The
        # backend-failure notice cannot be triggered from outside — it needs
        # the search backend to fail — so it is covered by the scripted
        # drain test in tests.zig plus the notice-render unit tests in
        # widgets/at_search.zig.)
        p.write("zzqqxx99")
        blob = read_for(q, 4.0)
        check(3, "at-search shows 'No matches' for a junk query", blob, "No matches")

        # -- Esc closes the popup -------------------------------------------
        p.write("\x1b")
        read_for(q, 1.5)
        # Esc hides the popup, but at-search is DERIVED state:
        # updateAtSearch re-derives the trigger from the input on every
        # keystroke (no dismissal latch), so typing 'x' with the stale
        # "@query" still in the input legitimately re-opens the popup on the
        # stale query. What must never happen is the EMPTY-query hint after
        # typing — a reopen, if any, carries the stale query's results.
        p.write("x")
        after_type = read_for(q, 1.5)
        clean = "Type a path after @" not in after_type
        results.append(clean)
        print(f"[{'PASS' if clean else 'FAIL'}] 4. Esc closes at-search (stale-query"
              f" reopen, if any,{' stayed clean' if clean else ' showed the EMPTY hint'} while typing)",
              flush=True)

        # -- resize mid-session, then reopen at-search ----------------------
        p.setwinsize(40, 100)
        blob = read_for(q, 2.0)
        p.write("\x7f")  # drop the typed 'x'
        p.write("@")
        blob += read_for(q, 2.5)
        check(5, "after resize the app repaints and at-search reopens", blob,
              "Files")
        p.write("\x1b")
        read_for(q, 0.8)

        # -- focus-critical mode transitions (#292 part 2 / #313 class) ------
        # Each scenario: open an overlay through its stock transition, close
        # it, then type a unique token and require it echoed in the main
        # prompt. If a transition leaves the focus path empty (the vendored
        # FocusHandler crash class — typed input dead until another key
        # re-syncs), the token never renders. Tokens are deliberately
        # gibberish so they can only come from the echo.
        def clear_input():
            # Esc first: if at-search is (invisibly) still active it owns Esc
            # and leaves the query text in the main input — only backspaces
            # actually empty the prompt. 20 covers the at-search history the
            # earlier scenarios can leave behind.
            p.write("\x1b")
            read_for(q, 0.6)
            p.write("\x7f" * 20)
            read_for(q, 0.8)

        # 6/7. command menu: "/" opens (needle is an always-visible command
        # row; only multi-lane commands are filtered out; rows render as
        # "/Timeline" with the leading slash), Esc closes.
        clear_input()
        p.write("/")
        blob = read_for(q, 3.0)
        check(6, "slash opens the command menu", blob, "/Timeline")
        p.write("\x1b")
        read_for(q, 1.0)
        clear_input()
        p.write("zkq")
        check(7, "typed input echoes after leaving the command menu",
              read_for(q, 1.5), "zkq")
        clear_input()

        # 8/9. transcript search: Ctrl+F opens, Esc closes.
        p.write("\x06")
        blob = read_for(q, 2.0)
        check(8, "Ctrl+F opens transcript search", blob,
              "Type to search this transcript")
        p.write("\x1b")
        read_for(q, 1.0)
        p.write("zmq")
        check(9, "typed input echoes after leaving transcript search",
              read_for(q, 1.5), "zmq")
        clear_input()

        # 10/11. help: "/" opens the menu first and the focus hand-off only
        # applies between events, so the filter bytes must NOT share a chunk
        # with the opening "/" — batched, they land in the main input and
        # submit a literal "/help" turn instead of resolving the command.
        p.write("/")
        read_for(q, 1.0)
        p.write("help\r")
        blob = read_for(q, 2.5)
        check(10, "/help opens the help overlay", blob,
              "KEYBOARD SHORTCUTS")
        p.write("q")
        read_for(q, 1.0)
        p.write("zpw")
        check(11, "typed input echoes after leaving help",
              read_for(q, 1.5), "zpw")
        clear_input()
    finally:
        try:
            p.terminate(force=True)
        except Exception:
            pass

    passed = sum(results)
    print(f"\n{passed}/{len(results)} checks passed", flush=True)
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
