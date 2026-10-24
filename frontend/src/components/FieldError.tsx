// A field's error: warning mark and text, shared by form fields and sheet cells.
export function FieldError({
  children,
  small,
}: {
  children: string;
  small?: boolean;
}) {
  return (
    <span
      className={`flex items-center gap-1 text-error ${small ? "text-xs" : "text-sm"}`}
    >
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
      {children}
    </span>
  );
}
