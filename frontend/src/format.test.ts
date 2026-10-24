import { describe, expect, it } from "vitest";
import { formatMoney, formatRate, showMoney } from "./format";

describe("format", () => {
  it("formats money with dot thousands", () => {
    expect(formatMoney(0)).toBe("0");
    expect(formatMoney(999)).toBe("999");
    expect(formatMoney(1234567)).toBe("1.234.567");
    expect(formatMoney(-1000)).toBe("-1.000");
  });

  it("formats rates without a trailing .00", () => {
    expect(formatRate(410050)).toBe("4100.50");
    expect(formatRate(410000)).toBe("4100");
    expect(formatRate(5)).toBe("0.05");
  });

  it("shows null as a dash", () => {
    expect(showMoney(null)).toBe("–");
    expect(showMoney(1500)).toBe("1.500");
  });
});
