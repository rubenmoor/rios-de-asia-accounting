import type { ReactNode } from "react";

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

export type IconProps = { className?: string };

function StrokeIcon({
  className = "size-5",
  children,
}: IconProps & { children: ReactNode }) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden="true"
    >
      {children}
    </svg>
  );
}

/** Calendar page. */
export function BookingsIcon(props: IconProps) {
  return (
    <StrokeIcon {...props}>
      <rect x="3.5" y="5" width="17" height="15" rx="2" />
      <path d="M3.5 10h17M8 3v4M16 3v4" />
    </StrokeIcon>
  );
}

/** Receipt with a torn edge. */
export function ExpensesIcon(props: IconProps) {
  return (
    <StrokeIcon {...props}>
      <path d="M6 3h12v18l-2-1.5-2 1.5-2-1.5-2 1.5-2-1.5L6 21z" />
      <path d="M9 8h6M9 12h6" />
    </StrokeIcon>
  );
}

/** Circular arrows. */
export function RecurringIcon(props: IconProps) {
  return (
    <StrokeIcon {...props}>
      <path d="M19 12a7 7 0 0 0-12-4.9L5 9M5 12a7 7 0 0 0 12 4.9L19 15" />
      <path d="M5 4v5h5M19 20v-5h-5" />
    </StrokeIcon>
  );
}

/** Clock. */
export function TimeIcon(props: IconProps) {
  return (
    <StrokeIcon {...props}>
      <circle cx="12" cy="12" r="9" />
      <path d="M12 7v5l3 2" />
    </StrokeIcon>
  );
}

/** Two coins. */
export function RatesIcon(props: IconProps) {
  return (
    <StrokeIcon {...props}>
      <circle cx="9" cy="9" r="5.5" />
      <path d="M14.5 9.6A5.5 5.5 0 1 1 9.6 14.5" />
      <path d="M9 7v4" />
    </StrokeIcon>
  );
}

/** Tray with a down arrow. */
export function ImportIcon(props: IconProps) {
  return (
    <StrokeIcon {...props}>
      <path d="M12 3v11M8 10l4 4 4-4" />
      <path d="M4 14v5h16v-5" />
    </StrokeIcon>
  );
}

/** Gear. */
export function SettingsIcon(props: IconProps) {
  return (
    <StrokeIcon {...props}>
      <circle cx="12" cy="12" r="3" />
      <path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1M16.6 16.6l2.1 2.1M18.7 5.3l-2.1 2.1M7.4 16.6l-2.1 2.1" />
      <circle cx="12" cy="12" r="6.5" />
    </StrokeIcon>
  );
}

/** A blank ledger page with a pencil: the empty-state doodle. */
export function BlankLedgerDoodle({
  className = "size-10",
}: {
  className?: string;
}) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 48 48"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden="true"
    >
      <path d="M9 6h24a2 2 0 0 1 2 2v32a2 2 0 0 1-2 2H9a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2z" />
      <path d="M14 6v36" stroke="var(--color-error)" opacity="0.7" />
      <path
        d="M19 15h12M19 21h12M19 27h12M19 33h7"
        stroke="var(--ledger-rule-green)"
      />
      <path
        d="M44 14l-14 14-1 5 5-1 14-14a2.1 2.1 0 0 0-4-4z"
        fill="var(--color-base-100)"
      />
      <path d="M40 18l4 4" />
    </svg>
  );
}

/** A closed ledger with a ribbon bookmark: the "books closed" doodle. */
export function ClosedBooksDoodle({
  className = "size-24",
}: {
  className?: string;
}) {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 48 48"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden="true"
    >
      <rect
        x="9"
        y="5"
        width="30"
        height="38"
        rx="2"
        fill="var(--color-primary)"
        fillOpacity="0.15"
      />
      <path d="M14 5v38" stroke="var(--color-error)" opacity="0.7" />
      <rect x="19" y="12" width="14" height="8" rx="1" />
      <path d="M22 16h8" stroke="var(--ledger-rule-green)" />
      <path
        d="M32 43V30l3 2.5 3-2.5v13"
        stroke="var(--color-error)"
        fill="var(--color-error)"
        fillOpacity="0.25"
      />
    </svg>
  );
}
