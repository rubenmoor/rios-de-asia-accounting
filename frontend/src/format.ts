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

// US cents as 1.234,56.
export const formatMoney = (cents: number) => formatAmount(cents, "USD");

export const DASH = "–";

// US cents; null (not computable, or waiting for a rate) is a dash.
export function showMoney(cents: number | null): string {
  return cents === null ? DASH : formatMoney(cents);
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
