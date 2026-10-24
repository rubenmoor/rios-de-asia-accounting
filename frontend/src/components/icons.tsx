/** Inline SVG icons: no icon fonts, no CDN. Colours come from the theme. */

/** The app mark (an open ledger, as in the favicon); named by the text beside it. */
export function Logo({ className = "size-7" }: { className?: string }) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 32 32"
      className={className}
      aria-hidden="true"
    >
      <rect width="32" height="32" rx="6" fill="var(--color-primary)" />
      <path d="M4.5 8 L15.5 9.5 V25.5 L4.5 24 Z" fill="var(--color-base-100)" />
      <path
        d="M16.5 9.5 L27.5 8 V24 L16.5 25.5 Z"
        fill="var(--color-base-100)"
      />
      <path d="M8 9 V24.5" stroke="var(--color-error)" strokeWidth="1.6" />
      <path
        d="M10.5 13 H14 M10.5 16.5 H14 M10.5 20 H14 M18.5 13 H25 M18.5 16.5 H25 M18.5 20 H25"
        stroke="var(--color-primary)"
        strokeWidth="1.3"
        strokeLinecap="round"
      />
    </svg>
  );
}
