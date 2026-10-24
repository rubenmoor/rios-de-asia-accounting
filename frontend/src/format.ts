// TS ports of format_money and format_rate in web/forms.py (same output, so
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
