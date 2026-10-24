import type { ReactNode } from "react";

// The row under a form: primary action first, then the secondary ones.
export function FormActions({ children }: { children: ReactNode }) {
  return (
    <div className="mt-6 flex flex-wrap gap-2 border-t border-base-300 pt-4">
      {children}
    </div>
  );
}
