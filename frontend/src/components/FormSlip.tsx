import type { ReactNode } from "react";

// The "journal entry slip" around a form: ledger paper with a header strip
// and a red margin rule. `stamp` is a decorative slot (entry number, date).
export function SlipHeader({
  label,
  stamp,
}: {
  label: string;
  stamp?: ReactNode;
}) {
  return (
    <div className="flex items-center justify-between border-b border-base-300 bg-base-200 px-4 py-1.5 text-xs font-semibold uppercase tracking-widest">
      <span>{label}</span>
      {stamp && (
        <span aria-hidden="true" className="num font-normal opacity-60">
          {stamp}
        </span>
      )}
    </div>
  );
}

export function FormSlip({
  label = "Entry",
  stamp,
  children,
}: {
  label?: string;
  stamp?: ReactNode;
  children: ReactNode;
}) {
  return (
    <div className="max-w-lg overflow-hidden rounded-box border border-base-300 bg-base-100">
      <SlipHeader label={label} stamp={stamp} />
      <div className="slip-margin p-4 pl-12">{children}</div>
    </div>
  );
}
