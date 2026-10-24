// TS port of format_amount in web/forms.py (same output, so what the server
// parses back is what it sent), plus display helpers. Money is US cents.

export const CURRENCIES = ["USD", "COP", "EUR"];

function groupThousands(digits: string): string {
  return digits.replace(/\B(?=(\d{3})+$)/g, ".");
}

// COP as whole pesos (1.234.567), other currencies with 2 decimals (1.234,56).
export function formatAmount(minor: number, currency = "USD"): string {
  const sign = minor < 0 ? "-" : "";
  const abs = Math.abs(minor);
  const grouped = groupThousands(String(Math.floor(abs / 100)));
  if (currency === "COP") return sign + grouped;
  return `${sign}${grouped},${String(abs % 100).padStart(2, "0")}`;
}

export const DASH = "–";

export const USD_RATE = 1_000_000;

// US cents in minor units of the display currency (rate: units per USD x
// 1 000 000), rounded half away from zero (decision 46).
export function toDisplay(cents: number, rate: number): number {
  const scaled = (Math.abs(cents) * rate) / USD_RATE;
  return Math.sign(cents) * Math.round(scaled);
}

// Minor units of the display currency as text (decision 47): COP in whole
// pesos, others with two decimals; the currency code is added by the caller.
export function formatDisplay(minor: number, currency: string): string {
  if (currency !== "COP") return formatAmount(minor, currency);
  return formatAmount(
    Math.sign(minor) * Math.round(Math.abs(minor) / 100) * 100,
    "COP",
  );
}

// What was typed: "4.500.000 COP".
export const showOriginal = (minor: number, currency: string) =>
  `${formatAmount(minor, currency)} ${currency}`;

// Hover text of a converted entry: the original amount, rate and rate date.
export function conversionTitle(e: {
  original_minor: number;
  currency: string;
  rate: number | null;
  rate_date: string | null;
}): string | undefined {
  if (e.currency === "USD") return undefined;
  const original = showOriginal(e.original_minor, e.currency);
  if (e.rate === null) return `${original}, waiting for an exchange rate`;
  const rate = formatAmount(Math.round(e.rate / 10_000), "USD");
  return `${original} at ${rate} ${e.currency}/USD on ${e.rate_date}`;
}
