"""Inline SVG charts drawn by hand: no JavaScript, no chart library.

Both functions are pure and return `Markup`, or `None` when there is nothing to
draw (no data, or every value is None); the template shows its own text then.
"""

import math
from collections.abc import Callable, Sequence
from datetime import date

from markupsafe import Markup, escape

PALETTE = ("#0072B2", "#D55E00", "#009E73", "#CC79A7")
DASHES = ("", "6 3", "2 3", "8 3 2 3")
_GRID = "#d0d0d0"
_TEXT = "#333"

Point = tuple[date, float | None]
Series = tuple[str, Sequence[Point]]


def nice_ticks(lo: float, hi: float, target: int = 5) -> list[float]:
    """Round tick values (1, 2 or 5 times a power of ten) covering lo..hi."""
    if hi <= lo:
        hi = lo + 1
    raw = (hi - lo) / target
    mag = 10 ** math.floor(math.log10(raw))
    step = next(m * mag for m in (1, 2, 5, 10) if m * mag >= raw)
    first = math.floor(lo / step)
    last = math.ceil(hi / step)
    return [i * step for i in range(first, last + 1)]


def _text(x: float, y: float, s: str, anchor: str = "start", size: int = 11) -> str:
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" text-anchor="{anchor}" '
        f'font-size="{size}" fill="{_TEXT}">{escape(s)}</text>'
    )


def _svg(width: int, height: int, body: list[str]) -> Markup:
    head = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" '
        f'width="100%" role="img" font-family="sans-serif">'
    )
    return Markup(head + "".join(body) + "</svg>")


def line_chart(
    series: Sequence[Series],
    *,
    y_format: Callable[[float], str],
    y_min: float | None = None,
    y_max: float | None = None,
    width: int,
    height: int,
) -> Markup | None:
    """Line chart over a shared date axis; a None value breaks the line."""
    points = [(d, v) for _, pts in series for d, v in pts]
    values = [v for _, v in points if v is not None]
    if not values:
        return None
    dates = [d for d, _ in points]
    d0, d1 = min(dates), max(dates)
    lo = min(values) if y_min is None else y_min
    hi = max(values) if y_max is None else y_max
    ticks = nice_ticks(lo, hi)
    if y_min is not None:
        lo = y_min
    else:
        lo = ticks[0]
    hi = y_max if y_max is not None else ticks[-1]
    if hi <= lo:
        hi = lo + 1
    ticks = [t for t in ticks if lo <= t <= hi]

    left, right, top = 70, 12, 10
    legend_h = 18 * len(series)
    bottom = 22 + legend_h
    pw, ph = width - left - right, height - top - bottom
    span_days = max((d1 - d0).days, 1)

    def px(d: date) -> float:
        return left + pw * (d - d0).days / span_days

    def py(v: float) -> float:
        return top + ph * (1 - (v - lo) / (hi - lo))

    out: list[str] = []
    for t in ticks:
        y = py(t)
        out.append(
            f'<line x1="{left}" x2="{left + pw}" y1="{y:.1f}" y2="{y:.1f}" '
            f'stroke="{_GRID}" stroke-width="1"/>'
        )
        out.append(_text(left - 6, y + 4, y_format(t), "end"))
    # x labels at month starts (the first day also gets one when it is not a 1st)
    labelled = [d0] if d0.day != 1 else []
    d = date(d0.year + (d0.month == 12), d0.month % 12 + 1, 1)
    while d <= d1:
        labelled.append(d)
        d = date(d.year + (d.month == 12), d.month % 12 + 1, 1)
    if d0.day == 1:
        labelled.insert(0, d0)
    stride = max(1, math.ceil(len(labelled) * 48 / pw))
    for d in labelled[::stride]:
        x = px(d)
        out.append(
            f'<line x1="{x:.1f}" x2="{x:.1f}" y1="{top + ph}" y2="{top + ph + 4}" '
            f'stroke="{_TEXT}"/>'
        )
        out.append(_text(x, top + ph + 16, d.strftime("%b %Y"), "middle"))

    for i, (label, pts) in enumerate(series):
        color = PALETTE[i % len(PALETTE)]
        dash = DASHES[i % len(DASHES)]
        dash_attr = f' stroke-dasharray="{dash}"' if dash else ""
        runs: list[list[tuple[date, float]]] = [[]]
        for d, v in pts:
            if v is None:
                if runs[-1]:
                    runs.append([])
            else:
                runs[-1].append((d, v))
        for run in runs:
            if not run:
                continue
            coords = " ".join(f"{px(d):.1f},{py(v):.1f}" for d, v in run)
            out.append(
                f'<polyline points="{coords}" fill="none" stroke="{color}" '
                f'stroke-width="2"{dash_attr}/>'
            )
            for d, v in run:
                out.append(
                    f'<circle cx="{px(d):.1f}" cy="{py(v):.1f}" r="2.5" fill="{color}">'
                    f"<title>{escape(label)} {d.isoformat()}: {escape(y_format(v))}"
                    f"</title></circle>"
                )
        ly = top + ph + 22 + 18 * i + 10
        out.append(
            f'<line x1="{left}" x2="{left + 28}" y1="{ly - 4}" y2="{ly - 4}" '
            f'stroke="{color}" stroke-width="2"{dash_attr}/>'
        )
        out.append(_text(left + 34, ly, label))
    return _svg(width, height, out)


def bar_chart(
    items: Sequence[tuple[str, float]],
    *,
    value_format: Callable[[float], str],
    width: int = 600,
) -> Markup | None:
    """Horizontal bars, widths proportional to the values (largest = full width)."""
    if not items:
        return None
    label_w, value_w, row_h = 150, 110, 26
    bar_max = width - label_w - value_w
    top_value = max(v for _, v in items)
    out: list[str] = []
    for i, (label, value) in enumerate(items):
        y = i * row_h + 4
        w = bar_max * value / top_value if top_value > 0 else 0
        color = PALETTE[0]
        out.append(_text(label_w - 6, y + 14, label, "end"))
        out.append(
            f'<rect x="{label_w}" y="{y}" width="{w:.1f}" height="{row_h - 8}" '
            f'fill="{color}"><title>{escape(label)}: {escape(value_format(value))}'
            f"</title></rect>"
        )
        out.append(_text(label_w + w + 6, y + 14, value_format(value)))
    return _svg(width, len(items) * row_h + 8, out)
