import type { ReactNode } from "react";
import { Link } from "react-router";

export type Column<T> = {
  header: string;
  cell: (row: T) => ReactNode;
  numeric?: boolean;
  // Makes the cell a link to this path.
  href?: (row: T) => string;
};

export function DataTable<T>({
  columns,
  rows,
  rowKey,
  empty,
  footer,
}: {
  columns: Column<T>[];
  rows: T[];
  rowKey: (row: T) => string | number;
  empty: string;
  footer?: ReactNode;
}) {
  return (
    <table className="table">
      <thead>
        <tr>
          {columns.map((c) => (
            <th key={c.header} className={c.numeric ? "text-right" : ""}>
              {c.header}
            </th>
          ))}
        </tr>
      </thead>
      <tbody>
        {rows.length === 0 && (
          <tr>
            <td colSpan={columns.length}>{empty}</td>
          </tr>
        )}
        {rows.map((row) => (
          <tr key={rowKey(row)}>
            {columns.map((c) => (
              <td key={c.header} className={c.numeric ? "text-right" : ""}>
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
      </tbody>
      {footer && <tfoot>{footer}</tfoot>}
    </table>
  );
}
