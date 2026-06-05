#!/usr/bin/env python3
"""
Seamless-loop ASCII black-hole frame generator for Nova's startup animation.

Regenerate the frames consumed by `src/tui/blackhole.zig` with:

    uv run python utils/gen_blackhole.py --outdir src/assets/blackhole

Writes numbered plain-ASCII frames (frame_000.txt ...). Frame N wraps cleanly to
frame 0: all time-varying terms are integer harmonics of a single
phase = 2*pi*frame/FRAMES. Each frame file is ROWS lines, each exactly COLS
chars, LF-separated, no trailing newline, printable ASCII only.

Adapted from the bonus generator that shipped with the frame pack. The one
deliberate change: the disk's bright "hotspot" tracks the phase (`phi - phase`)
instead of being pinned to the left (`phi - pi`), so the white highlight
revolves all the way around the ring instead of only flaring on one side.
"""
import argparse, math, os, random

GLYPHS = ".~ox+=*%$@"   # 10 brightness levels, ASCII (dim -> bright)
STAR   = "."
BG     = 0.06

def smooth(a, b, x):
    t = max(0.0, min(1.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)

def make_field(open_, jet, viewsign):
    def field(X, Y, phase):
        r = math.hypot(X, Y); ang = math.atan2(Y, X)
        R_bh, R_ring = 0.34, 0.355
        rin, rout = 0.40, 1.05
        Yp = Y / open_; rho = math.hypot(X, Yp); phi = math.atan2(Yp, X)
        near = (Yp > 0) if viewsign > 0 else (Yp < 0)

        a = phi - phase                                   # rotate texture with phase
        azim = 0.55*math.sin(3*a) + 0.30*math.sin(7*a + 1.3) + 0.18*math.sin(11*a + 0.7)
        flow = 0.35 + 0.65*(0.5 + 0.5*azim) + 0.08*math.sin(rho*10 - 2*phase)
        band = smooth(rin*0.85, rin, rho) * (1 - smooth(rout - 0.18, rout, rho))
        radial = min((rin / max(rho, 1e-3)) ** 0.7, 1.7)
        disk = band * radial * flow
        disk *= 1 + 0.5*math.cos(phi - phase)             # beaming hotspot, now revolving
        occl = 1.0 if near else smooth(R_bh - 0.04, R_bh + 0.03, r)
        disk *= occl

        shim = 0.6*math.sin(6*(ang - phase)) + 0.4*math.sin(9*(ang - phase))
        ring = math.exp(-((r - R_ring) / 0.018) ** 2) * (0.85 + 0.15*shim)

        v = max(disk * 0.95, ring)
        if jet:
            w = 0.015 + 0.06*abs(Y)
            jc = math.exp(-(X / w) ** 2)
            along = smooth(0.28, 0.40, abs(Y)) * math.exp(-max(0.0, abs(Y) - 0.30) / 0.20)
            fl = 0.6 + 0.25*math.sin(2*phase + abs(Y)*7) + 0.15*math.sin(5*phase + abs(Y)*4)
            v = max(v, jc * along * fl * 0.5)
        return min(1.0, v)
    return field

def main():
    ap = argparse.ArgumentParser(description="Generate seamless-loop ASCII black-hole frames.")
    ap.add_argument("--cols", type=int, default=80)
    ap.add_argument("--rows", type=int, default=24)
    ap.add_argument("--frames", type=int, default=120)
    ap.add_argument("--aspect", type=float, default=2.0, help="terminal cell height:width (~2.0)")
    ap.add_argument("--open", type=float, default=0.46, dest="open_", help="disk tilt: 1=face-on, ~0.05=edge-on")
    ap.add_argument("--view", choices=["above", "below"], default="above")
    ap.add_argument("--no-jet", action="store_true")
    ap.add_argument("--stars", type=int, default=70)
    ap.add_argument("--outdir", default="src/assets/blackhole")
    args = ap.parse_args()

    COLS, ROWS, FRAMES, ASPECT = args.cols, args.rows, args.frames, args.aspect
    field = make_field(args.open_, not args.no_jet, 1 if args.view == "above" else -1)
    cx, cy, half = (COLS - 1) / 2, (ROWS - 1) / 2, COLS / 2

    random.seed(7)
    stars = [(random.uniform(-1.05, 1.05), random.uniform(-0.6, 0.6), random.random())
             for _ in range(args.stars)]
    def star_cell(sx, sy):
        d = math.hypot(sx, sy); f = 1 + 0.045 / (d*d + 0.02)   # lensing deflection (outward)
        ax, ay = sx*f, sy*f
        if math.hypot(ax, ay) < 0.36: return None              # hidden behind shadow
        col = round(ax*half + cx); row = round((ay/ASPECT)*half + cy)
        return (row, col) if (0 <= col < COLS and 0 <= row < ROWS) else None

    os.makedirs(args.outdir, exist_ok=True)
    pad = max(3, len(str(FRAMES - 1)))
    for f in range(FRAMES):
        phase = 2*math.pi*f / FRAMES
        sm = set()
        for sx, sy, sp in stars:
            c = star_cell(sx, sy)
            if c and math.sin(phase + sp*6.283) > -0.3: sm.add(c)
        lines = []
        for row in range(ROWS):
            Y = ((row - cy)/half) * ASPECT
            buf = []
            for col in range(COLS):
                X = (col - cx)/half
                b = field(X, Y, phase)
                if b < BG:
                    buf.append(STAR if (row, col) in sm else " ")
                else:
                    i = int((b - BG)*(len(GLYPHS) - 1)/(1 - BG))
                    buf.append(GLYPHS[max(0, min(len(GLYPHS) - 1, i))])
            lines.append("".join(buf))
        # ROWS lines, each exactly COLS chars, no trailing newline
        with open(os.path.join(args.outdir, f"frame_{f:0{pad}d}.txt"), "w", encoding="ascii") as fh:
            fh.write("\n".join(lines))
    print(f"wrote {FRAMES} frames ({COLS}x{ROWS}) to {args.outdir}/")

if __name__ == "__main__":
    main()
