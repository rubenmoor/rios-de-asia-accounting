// TS ports of format_money, format_hours and format_rate in web/forms.py (same output, so
// what the server parses back is what it sent), plus display helpers.

function groupThousands(digits: string): string {
  return digits.replace(/\B(?=(\d{3})+$)/g, ".");
}

export function formatMoney(pesos: number): string {
  const sign = pesos < 0 ? "-" : "";
  return sign + groupThousands(String(Math.abs(pesos)));
}

function fixed2(hundredths: number): string {
  const sign = hundredths < 0 ? "-" : "";
  const abs = Math.abs(hundredths);
  return `${sign}${Math.floor(abs / 100)}.${String(abs % 100).padStart(2, "0")}`;
}

// Minutes as decimal hours, e.g. 90 -> "1.5".
export function formatHours(minutes: number): string {
  // minutes / 60 in hundredths is minutes * 5 / 3: never an exact tie.
  const text = fixed2(Math.round((minutes * 5) / 3));
  const trimmed = text.replace(/0+$/, "").replace(/\.$/, "");
  return trimmed === "-0" ? "0" : trimmed;
}

// The stored rate (COP x 100) as typed: up to 2 decimals.
export function formatRate(rate: number): string {
  const text = fixed2(rate);
  return text.endsWith(".00") ? text.slice(0, -3) : text;
}

export const DASH = "–";

// Money with dot thousands; null (not computable) is a dash.
export function showMoney(pesos: number | null): string {
  return pesos === null ? DASH : formatMoney(pesos);
}

export function showHours(minutes: number | null): string {
  return minutes === null ? DASH : `${formatHours(minutes)} h`;
}
