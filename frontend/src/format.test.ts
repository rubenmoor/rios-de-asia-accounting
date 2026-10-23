import { describe, expect, it } from "vitest";
import {
  formatHours,
  formatMoney,
  formatRate,
  showHours,
  showMoney,
} from "./format";

describe("format", () => {
  it("formats money with dot thousands", () => {
    expect(formatMoney(0)).toBe("0");
    expect(formatMoney(999)).toBe("999");
    expect(formatMoney(1234567)).toBe("1.234.567");
    expect(formatMoney(-1000)).toBe("-1.000");
  });

  it("formats minutes as decimal hours", () => {
    expect(formatHours(0)).toBe("0");
    expect(formatHours(90)).toBe("1.5");
    expect(formatHours(60)).toBe("1");
    expect(formatHours(20)).toBe("0.33");
    expect(formatHours(100)).toBe("1.67");
    expect(formatHours(600)).toBe("10");
  });

  it("formats rates without a trailing .00", () => {
    expect(formatRate(410050)).toBe("4100.50");
    expect(formatRate(410000)).toBe("4100");
    expect(formatRate(5)).toBe("0.05");
  });

  it("shows null as a dash", () => {
    expect(showMoney(null)).toBe("–");
    expect(showMoney(1500)).toBe("1.500");
    expect(showHours(null)).toBe("–");
    expect(showHours(90)).toBe("1.5 h");
  });
});
