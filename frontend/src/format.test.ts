import { describe, expect, it } from "vitest";
import { formatAmount, formatMoney, showMoney } from "./format";

describe("format", () => {
  it("formats US cents with dot thousands and a decimal comma", () => {
    expect(formatMoney(0)).toBe("0,00");
    expect(formatMoney(5)).toBe("0,05");
    expect(formatMoney(123456)).toBe("1.234,56");
    expect(formatMoney(-100000)).toBe("-1.000,00");
  });

  it("formats pesos as whole numbers", () => {
    expect(formatAmount(123456700, "COP")).toBe("1.234.567");
  });

  it("shows null as a dash", () => {
    expect(showMoney(null)).toBe("–");
    expect(showMoney(150000)).toBe("1.500,00");
  });
});
