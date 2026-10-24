import { conversionTitle, showMoney } from "../format";

type Converted = {
  amount: number | null;
  original_minor: number;
  currency: string;
  rate: number | null;
  rate_date: string | null;
};

// USD cents of a converted entry; hover shows what was typed, the rate and its date.
export function AmountCell({ e }: { e: Converted }) {
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
      {showMoney(e.amount)}
    </span>
  );
}
