import type { FormEventHandler, ReactNode } from "react";

// The formula-bar strip above a list or sheet: short labelled controls, the
// buttons, and `action` (the "New …" link) pushed to the right. Errors go
// below the strip.
export function Toolbar({
  onSubmit,
  action,
  errors = [],
  children,
}: {
  onSubmit: FormEventHandler<HTMLFormElement>;
  action?: ReactNode;
  errors?: (string | undefined)[];
  children: ReactNode;
}) {
  return (
    <form onSubmit={onSubmit} className="mb-4">
      <div className="flex flex-wrap items-center gap-x-3 gap-y-2 border border-base-300 bg-base-200 rounded-box px-3 py-2">
        <span
          aria-hidden="true"
          className="italic font-serif font-bold text-primary border-r border-base-300 pr-3 select-none"
        >
          fx
        </span>
        {children}
        {action && <span className="ml-auto flex gap-2">{action}</span>}
      </div>
      {errors.map(
        (text) =>
          text && (
            <p key={text} className="text-error mt-2">
              {text}
            </p>
          ),
      )}
    </form>
  );
}

// A short label next to its control.
export function ToolbarField({
  label,
  children,
}: {
  label: string;
  children: ReactNode;
}) {
  return (
    // biome-ignore lint/a11y/noLabelWithoutControl: the input is the child
    <label className="flex items-center gap-1 text-xs font-semibold">
      {label}
      {children}
    </label>
  );
}
