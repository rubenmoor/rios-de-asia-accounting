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
      <span className="fieldset-legend">{label}</span>
      {children}
      {hint && <span className="label whitespace-normal">{hint}</span>}
      {error && (
        <span className="flex items-center gap-1 text-sm text-error">
          <svg
            aria-hidden="true"
            viewBox="0 0 24 24"
            className="h-4 w-4 shrink-0"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <path d="M12 3 2.5 20h19L12 3Z" />
            <path d="M12 10v4M12 17v.5" />
          </svg>
          {error}
        </span>
      )}
    </label>
  );
}
