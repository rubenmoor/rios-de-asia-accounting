import { conversionTitle, showOriginal } from "../format";
import { useDisplay } from "../useDisplay";

type Converted = {
  amount: number | null;
  original_minor: number;
  currency: string;
  rate: number | null;
  rate_date: string | null;
};

// A converted entry in the display currency; hover shows what was typed, the rate and its date.
export function AmountCell({
  e,
  withOriginal = false,
}: {
  e: Converted;
  withOriginal?: boolean;
}) {
  const { money, currency } = useDisplay();
  // The original input, in its own currency, under the figure (unless the
  // figure is already in that currency).
  const original = withOriginal && e.currency !== currency && (
    <div className="text-xs opacity-60">
      {showOriginal(e.original_minor, e.currency)}
    </div>
  );
  const title = conversionTitle(e);
  if (e.amount === null) {
    return (
      <>
        <span className="text-warning" title={title}>
          waiting for rate
        </span>
        {original}
      </>
    );
  }
  return (
    <>
      <span title={title} className={title ? "cursor-help" : undefined}>
        {money(e.amount)}
      </span>
      {original}
    </>
  );
}
