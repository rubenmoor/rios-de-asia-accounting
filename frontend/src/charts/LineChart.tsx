import {
  DASHES,
  daysBetween,
  monthLabel,
  PALETTE,
  splitRuns,
  xLabelDays,
  yRange,
} from "./chartMath";

export type LineSeries = {
  label: string;
  points: { date: string; value: number | null }[];
};

const GRID = "#d0d0d0";
const TEXT = "#333";

export function Label({
  x,
  y,
  anchor = "start",
  children,
}: {
  x: number;
  y: number;
  anchor?: "start" | "middle" | "end";
  children: string;
}) {
  return (
    <text x={x} y={y} textAnchor={anchor} fontSize={11} fill={TEXT}>
      {children}
    </text>
  );
}

// Line chart over a shared date axis; a null value breaks the line. Null when
// there is nothing to draw.
export function LineChart({
  series,
  yFormat,
  yMin,
  yMax,
  width,
  height,
}: {
  series: LineSeries[];
  yFormat: (v: number) => string;
  yMin?: number;
  yMax?: number;
  width: number;
  height: number;
}) {
  const all = series.flatMap((s) => s.points);
  const values = all.flatMap((p) => (p.value === null ? [] : [p.value]));
  if (values.length === 0) return null;
  const dates = all.map((p) => p.date).sort();
  const d0 = dates[0];
  const d1 = dates[dates.length - 1];
  const { lo, hi, ticks } = yRange(values, yMin, yMax);

  const left = 70;
  const right = 12;
  const top = 10;
  const bottom = 22 + 18 * series.length;
  const pw = width - left - right;
  const ph = height - top - bottom;
  const spanDays = Math.max(daysBetween(d0, d1), 1);
  const px = (d: string) => left + (pw * daysBetween(d0, d)) / spanDays;
  const py = (v: number) => top + ph * (1 - (v - lo) / (hi - lo));

  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox={`0 0 ${width} ${height}`}
      width="100%"
      role="img"
      aria-label={series.map((s) => s.label).join(", ")}
      fontFamily="sans-serif"
    >
      {ticks.map((t) => (
        <g key={t}>
          <line
            x1={left}
            x2={left + pw}
            y1={py(t).toFixed(1)}
            y2={py(t).toFixed(1)}
            stroke={GRID}
            strokeWidth={1}
          />
          <Label x={left - 6} y={py(t) + 4} anchor="end">
            {yFormat(t)}
          </Label>
        </g>
      ))}
      {xLabelDays(d0, d1, pw).map((d) => (
        <g key={d}>
          <line
            x1={px(d).toFixed(1)}
            x2={px(d).toFixed(1)}
            y1={top + ph}
            y2={top + ph + 4}
            stroke={TEXT}
          />
          <Label x={px(d)} y={top + ph + 16} anchor="middle">
            {monthLabel(d)}
          </Label>
        </g>
      ))}
      {series.map((s, i) => {
        const color = PALETTE[i % PALETTE.length];
        const dash = DASHES[i % DASHES.length] || undefined;
        const ly = top + ph + 22 + 18 * i + 10;
        const runs = splitRuns(
          s.points.map((p) => ({ value: p.value, item: p.date })),
        );
        return (
          <g key={s.label}>
            {runs.map((run) => (
              <g key={run[0].item}>
                <polyline
                  points={run
                    .map(
                      (p) =>
                        `${px(p.item).toFixed(1)},${py(p.value).toFixed(1)}`,
                    )
                    .join(" ")}
                  fill="none"
                  stroke={color}
                  strokeWidth={2}
                  strokeDasharray={dash}
                />
                {run.map((p) => (
                  <circle
                    key={p.item}
                    cx={px(p.item).toFixed(1)}
                    cy={py(p.value).toFixed(1)}
                    r={2.5}
                    fill={color}
                  >
                    <title>{`${s.label} ${p.item}: ${yFormat(p.value)}`}</title>
                  </circle>
                ))}
              </g>
            ))}
            <line
              x1={left}
              x2={left + 28}
              y1={ly - 4}
              y2={ly - 4}
              stroke={color}
              strokeWidth={2}
              strokeDasharray={dash}
            />
            <Label x={left + 34} y={ly}>
              {s.label}
            </Label>
          </g>
        );
      })}
    </svg>
  );
}
