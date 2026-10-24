import { describe, expect, it } from "vitest";
import { formatAmount, formatDisplay, toDisplay } from "./format";

describe("format", () => {
  it("formats USD with dot thousands and a decimal comma", () => {
    expect(formatDisplay(0, "USD")).toBe("0,00");
    expect(formatDisplay(5, "USD")).toBe("0,05");
    expect(formatDisplay(123456, "USD")).toBe("1.234,56");
    expect(formatDisplay(-100000, "USD")).toBe("-1.000,00");
  });

  it("formats pesos as whole numbers", () => {
    expect(formatAmount(123456700, "COP")).toBe("1.234.567");
    expect(formatDisplay(123456750, "COP")).toBe("1.234.568");
  });

  it("converts US cents at a rate, half away from zero", () => {
    expect(toDisplay(12345, 1_000_000)).toBe(12345);
    expect(toDisplay(10000, 4_000_000_000)).toBe(40_000_000);
    expect(toDisplay(1, 800_000)).toBe(1);
    expect(toDisplay(-1, 500_000)).toBe(-1);
    expect(toDisplay(1, 400_000)).toBe(0);
  });
});
