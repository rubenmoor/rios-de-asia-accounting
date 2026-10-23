// Pure helpers of the charts, ported from web/charts.py. Dates are YYYY-MM-DD
// strings; day arithmetic goes through UTC so a timezone can't shift a day.

export const PALETTE = ["#0072B2", "#D55E00", "#009E73", "#CC79A7"];
export const DASHES = ["", "6 3", "2 3", "8 3 2 3"];

const MONTHS = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec",
];

// Round tick values (1, 2 or 5 times a power of ten) covering lo..hi.
export function niceTicks(lo: number, hi: number, target = 5): number[] {
  if (hi <= lo) hi = lo + 1;
  const raw = (hi - lo) / target;
  const mag = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 5, 10]
    .map((m) => m * mag)
    .find((s) => s >= raw) as number;
  const first = Math.floor(lo / step);
  const last = Math.ceil(hi / step);
  const ticks: number[] = [];
  for (let i = first; i <= last; i++) ticks.push(i * step);
  return ticks;
}

// The y-range of a line chart: lo/hi (explicit bounds win over the rounded
// ticks) and the ticks inside it.
export function yRange(
  values: number[],
  yMin?: number,
  yMax?: number,
): { lo: number; hi: number; ticks: number[] } {
  const ticks = niceTicks(
    yMin ?? Math.min(...values),
    yMax ?? Math.max(...values),
  );
  const lo = yMin ?? ticks[0];
  let hi = yMax ?? ticks[ticks.length - 1];
  if (hi <= lo) hi = lo + 1;
  return { lo, hi, ticks: ticks.filter((t) => lo <= t && t <= hi) };
}

function toUtc(day: string): number {
  const [y, m, d] = day.split("-").map(Number);
  return Date.UTC(y, m - 1, d);
}

export function daysBetween(from: string, to: string): number {
  return Math.round((toUtc(to) - toUtc(from)) / 86_400_000);
}

// "2026-03-01" -> "Mar 2026"
export function monthLabel(day: string): string {
  return `${MONTHS[Number(day.slice(5, 7)) - 1]} ${day.slice(0, 4)}`;
}

// Month starts within d0..d1, the first day too when it is not a 1st, thinned
// so labels are at least ~48px apart.
export function xLabelDays(
  d0: string,
  d1: string,
  plotWidth: number,
): string[] {
  const labelled: string[] = [d0];
  let y = Number(d0.slice(0, 4));
  let m = Number(d0.slice(5, 7));
  for (;;) {
    m += 1;
    if (m > 12) {
      m = 1;
      y += 1;
    }
    const d = `${y}-${String(m).padStart(2, "0")}-01`;
    if (d > d1) break;
    labelled.push(d);
  }
  const stride = Math.max(1, Math.ceil((labelled.length * 48) / plotWidth));
  return labelled.filter((_, i) => i % stride === 0);
}

// Consecutive non-null points; a null breaks the line.
export function splitRuns<T>(
  points: { value: number | null; item: T }[],
): { value: number; item: T }[][] {
  const runs: { value: number; item: T }[][] = [[]];
  for (const p of points) {
    if (p.value === null) {
      if (runs[runs.length - 1].length) runs.push([]);
    } else {
      runs[runs.length - 1].push({ value: p.value, item: p.item });
    }
  }
  return runs.filter((r) => r.length);
}
