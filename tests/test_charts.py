import xml.etree.ElementTree as ET
from datetime import date, timedelta

from airbnb_books.web.charts import bar_chart, line_chart, nice_ticks

NS = "{http://www.w3.org/2000/svg}"


def parse(markup):
    return ET.fromstring(str(markup))


def days(values, start=date(2026, 1, 15)):
    return [(start + timedelta(days=i), v) for i, v in enumerate(values)]


def fmt(v):
    return f"{v:,.0f}"


def test_line_chart_gap_and_labels():
    svg = line_chart(
        [("ADR <&>", days([1, 2, None, 4, 5])), ("RevPAR", days([1, 1, 1, 1, 1]))],
        y_format=fmt,
        width=600,
        height=300,
    )
    root = parse(svg)
    assert root.get("viewBox") == "0 0 600 300"
    assert len(root.findall(f".//{NS}polyline")) == 3
    assert "ADR &lt;&amp;&gt;" in str(svg)
    assert "Jan 2026" in str(svg)


def test_ticks_round():
    assert nice_ticks(0, 1_234_567) == [0, 500_000, 1_000_000, 1_500_000]
    svg = line_chart([("x", days([0, 1_234_567]))], y_format=fmt, y_min=0, width=600, height=300)
    texts = [t.text for t in parse(svg).iter(f"{NS}text")]
    assert "500,000" in texts and "1,000,000" in texts


def test_bars_proportional_and_degenerate():
    root = parse(bar_chart([("a", 100), ("b", 50)], value_format=fmt))
    w = [float(r.get("width")) for r in root.iter(f"{NS}rect")]
    assert w[0] == 2 * w[1]
    assert parse(bar_chart([("a", 0)], value_format=fmt)) is not None
    assert bar_chart([], value_format=fmt) is None


def test_empty_and_flat_lines():
    assert line_chart([], y_format=fmt, width=600, height=300) is None
    assert line_chart([("a", days([None]))], y_format=fmt, width=600, height=300) is None
    parse(line_chart([("a", days([0, 0]))], y_format=fmt, width=600, height=300))
    parse(line_chart([("a", days([5]))], y_format=fmt, width=600, height=300))
