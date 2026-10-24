import { useQuery } from "@tanstack/react-query";
import { api } from "./api";
import { DASH, formatDisplay, toDisplay, USD_RATE } from "./format";

export type Display = {
  currency: string;
  rate: number;
  rate_date: string | null;
  currencies: string[];
};

export const displayQuery = {
  queryKey: ["display"],
  queryFn: () => api<Display>("GET", "/api/display"),
};

// The display currency (decisions 46-48): the server answers in US cents, the
// browser converts at the one stored rate. `money` is the only way figures are
// shown; `convert` gives minor units of the display currency for charts.
export function useDisplay() {
  const query = useQuery(displayQuery);
  const currency = query.data?.currency ?? "USD";
  const rate = query.data?.rate ?? USD_RATE;
  return {
    currency,
    rate,
    rate_date: query.data?.rate_date ?? null,
    currencies: query.data?.currencies ?? ["USD", "COP", "EUR"],
    convert: (cents: number) => toDisplay(cents, rate),
    // US cents as text; null (not computable, or waiting for a rate) is a dash.
    money: (cents: number | null) =>
      cents === null ? DASH : formatDisplay(toDisplay(cents, rate), currency),
  };
}
