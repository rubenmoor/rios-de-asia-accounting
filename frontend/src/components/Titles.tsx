import type { ReactNode } from "react";

// Page and section headings; `icon` is the slot for the section icons.
export function PageTitle({
  children,
  icon,
  className = "mb-4",
}: {
  children: ReactNode;
  icon?: ReactNode;
  className?: string;
}) {
  return (
    <h1 className={`flex items-center gap-2 text-2xl font-bold ${className}`}>
      {icon}
      <span>{children}</span>
    </h1>
  );
}

export function SectionTitle({
  children,
  className = "mb-2",
}: {
  children: ReactNode;
  className?: string;
}) {
  return <h2 className={`text-xl font-bold ${className}`}>{children}</h2>;
}
