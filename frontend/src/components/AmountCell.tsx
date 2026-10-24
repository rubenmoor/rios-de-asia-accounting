import { conversionTitle } from "../format";
import { useDisplay } from "../useDisplay";

type Converted = {
  amount: number | null;
  original_minor: number;
  currency: string;
  rate: number | null;
  rate_date: string | null;
};

// A converted entry in the display currency; hover shows what was typed, the rate and its date.
export function AmountCell({ e }: { e: Converted }) {
  const { money } = useDisplay();
  const title = conversionTitle(e);
  if (e.amount === null) {
    return (
      <span className="text-warning" title={title}>
        waiting for rate
      </span>
    );
  }
  return (
    <span title={title} className={title ? "cursor-help" : undefined}>
      {money(e.amount)}
    </span>
  );
}
