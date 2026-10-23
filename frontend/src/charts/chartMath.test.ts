import { describe, expect, it } from "vitest";
import { niceTicks, splitRuns, xLabelDays, yRange } from "./chartMath";

// Expected values come from nice_ticks in web/charts.py.
describe("niceTicks", () => {
  it("matches the Python function", () => {
    expect(niceTicks(0, 1)).toEqual([0, 0.2, 0.4, 0.6000000000000001, 0.8, 1]);
    expect(niceTicks(0, 1234567)).toEqual([0, 500000, 1000000, 1500000]);
    expect(niceTicks(-5, 80)).toEqual([-20, 0, 20, 40, 60, 80]);
    expect(niceTicks(120000, 980000)).toEqual([
      0, 200000, 400000, 600000, 800000, 1000000,
    ]);
  });
});

describe("yRange", () => {
  it("clips the ticks to explicit bounds", () => {
    expect(yRange([0.2, 0.4], 0, 1)).toEqual({
      lo: 0,
      hi: 1,
      ticks: [0, 0.2, 0.4, 0.6000000000000001, 0.8, 1],
    });
    expect(yRange([120000, 980000], 0).hi).toBe(1000000);
  });
});

describe("xLabelDays", () => {
  it("labels the first day and each month start", () => {
    expect(xLabelDays("2026-01-15", "2026-03-20", 700)).toEqual([
      "2026-01-15",
      "2026-02-01",
      "2026-03-01",
    ]);
    expect(xLabelDays("2025-12-01", "2026-01-31", 700)).toEqual([
      "2025-12-01",
      "2026-01-01",
    ]);
  });
  it("thins crowded labels", () => {
    expect(xLabelDays("2026-01-01", "2026-12-31", 400)).toHaveLength(6);
  });
});

describe("splitRuns", () => {
  it("breaks at null", () => {
    const pts = [1, null, null, 2, 3].map((value, i) => ({ value, item: i }));
    expect(splitRuns(pts).map((r) => r.map((p) => p.item))).toEqual([
      [0],
      [3, 4],
    ]);
  });
});
