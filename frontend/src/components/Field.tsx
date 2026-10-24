import type { ReactNode } from "react";
import { FieldError } from "./FieldError";

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
      <span className="fieldset-legend">{label}</span>
      {children}
      {hint && <span className="label whitespace-normal">{hint}</span>}
      {error && <FieldError>{error}</FieldError>}
    </label>
  );
}
