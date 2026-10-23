import { PALETTE } from "./chartMath";
import { Label } from "./LineChart";

// Horizontal bars, widths proportional to the values (largest = full width).
export function BarChart({
  items,
  valueFormat,
  width = 600,
}: {
  items: { label: string; value: number }[];
  valueFormat: (v: number) => string;
  width?: number;
}) {
  if (items.length === 0) return null;
  const labelW = 150;
  const valueW = 110;
  const rowH = 26;
  const barMax = width - labelW - valueW;
  const topValue = Math.max(...items.map((i) => i.value));
  const height = items.length * rowH + 8;
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox={`0 0 ${width} ${height}`}
      width="100%"
      role="img"
      aria-label="Expense breakdown"
      fontFamily="sans-serif"
    >
      {items.map((item, i) => {
        const y = i * rowH + 4;
        const w = topValue > 0 ? (barMax * item.value) / topValue : 0;
        return (
          <g key={item.label}>
            <Label x={labelW - 6} y={y + 14} anchor="end">
              {item.label}
            </Label>
            <rect
              x={labelW}
              y={y}
              width={w.toFixed(1)}
              height={rowH - 8}
              fill={PALETTE[0]}
            >
              <title>{`${item.label}: ${valueFormat(item.value)}`}</title>
            </rect>
            <Label x={labelW + w + 6} y={y + 14}>
              {valueFormat(item.value)}
            </Label>
          </g>
        );
      })}
    </svg>
  );
}
