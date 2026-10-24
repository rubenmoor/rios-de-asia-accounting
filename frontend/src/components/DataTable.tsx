import type { ReactNode } from "react";
import { Link } from "react-router";
import { BlankLedgerDoodle } from "./icons";

export type Column<T> = {
  header: string;
  cell: (row: T) => ReactNode;
  numeric?: boolean;
  // Makes the cell a link to this path.
  href?: (row: T) => string;
  // Adds the `neg` colour to the cell when true; the text is unchanged.
  negative?: (row: T) => boolean;
};

const letter = (i: number) => String.fromCharCode(65 + (i % 26));

// An empty row-number cell for hand-written footer rows.
export function Gutter() {
  return <td className="gutter" aria-hidden="true" />;
}

// A footer row of a `DataTable` with the spreadsheet gutter cell in front.
export function SheetFooterRow({ children }: { children: ReactNode }) {
  return (
    <tr>
      <Gutter />
      {children}
    </tr>
  );
}

// The entry row of a `DataTable` (pass as `entry`): a "+" gutter cell, then
// one cell per column, styled for typing in place.
export function SheetEntryRow({ children }: { children: ReactNode }) {
  return (
    <tr className="entry">
      <td className="gutter" aria-hidden="true">
        +
      </td>
      {children}
    </tr>
  );
}

const cls = (...c: (string | false | undefined)[]) =>
  c.filter(Boolean).join(" ") || undefined;

export function DataTable<T>({
  columns,
  rows,
  rowKey,
  empty,
  footer,
  entry,
}: {
  columns: Column<T>[];
  rows: T[];
  rowKey: (row: T) => string | number;
  empty: string;
  footer?: ReactNode;
  // A `SheetEntryRow` shown as the last body row.
  entry?: ReactNode;
}) {
  return (
    <div className="overflow-x-auto">
      <table className="table sheet">
        <thead>
          <tr className="letters">
            <td className="gutter" aria-hidden="true" />
            {columns.map((c, i) => (
              <td key={c.header} aria-hidden="true">
                {letter(i)}
              </td>
            ))}
          </tr>
          <tr>
            <td className="gutter" aria-hidden="true" />
            {columns.map((c) => (
              <th key={c.header} className={c.numeric ? "num" : undefined}>
                {c.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.length === 0 && (
            <tr>
              <td className="gutter" aria-hidden="true">
                1
              </td>
              <td colSpan={columns.length}>
                <div className="flex items-center gap-3 py-2">
                  <BlankLedgerDoodle className="size-10 shrink-0 opacity-70" />
                  <div>
                    <div
                      className="text-xs italic opacity-60"
                      aria-hidden="true"
                    >
                      The ledger is blank
                    </div>
                    <div>{empty}</div>
                  </div>
                </div>
              </td>
            </tr>
          )}
          {rows.map((row, i) => (
            <tr key={rowKey(row)}>
              <td className="gutter" aria-hidden="true">
                {i + 1}
              </td>
              {columns.map((c) => (
                <td
                  key={c.header}
                  className={cls(
                    c.numeric && "num",
                    c.negative?.(row) && "neg",
                  )}
                >
                  {c.href ? (
                    <Link className="link" to={c.href(row)}>
                      {c.cell(row)}
                    </Link>
                  ) : (
                    c.cell(row)
                  )}
                </td>
              ))}
            </tr>
          ))}
          {entry}
        </tbody>
        {footer && <tfoot>{footer}</tfoot>}
      </table>
    </div>
  );
}
