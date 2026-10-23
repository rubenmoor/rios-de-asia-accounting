import type { ReactNode } from "react";

export function Field({
  label,
  hint,
  error,
  children,
}: {
  label: string;
  hint?: string;
  error?: string;
  children: ReactNode;
}) {
  return (
    // biome-ignore lint/a11y/noLabelWithoutControl: the input is the child
    <label className="fieldset">
      <span className="fieldset-legend">
        {label}
        {hint && <span className="font-normal opacity-60"> {hint}</span>}
      </span>
      {children}
      {error && <span className="text-error">{error}</span>}
    </label>
  );
}
