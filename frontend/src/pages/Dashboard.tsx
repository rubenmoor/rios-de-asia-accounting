import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { type FormEvent, useState } from "react";
import { Link, useSearchParams } from "react-router";
import { api, type Notice } from "../api";
import { Field } from "../components/Field";
import { DateInput, MonthInput } from "../components/inputs";
import { DASH, formatMoney } from "../format";

type Kind = "int" | "pct" | "money" | "minutes";

export type Dashboard = {
  form: { month: string; from: string; to: string };
  needing_rate: number;
  empty: boolean;
  columns: { label: string; start: string; end: string }[];
  rows: { key: string; label: string; kind: Kind; values: (number | null)[] }[];
  rolling_90: {
    date: string;
    adr: number | null;
    revpar: number | null;
    occupancy: number | null;
  }[];
  breakdown: {
    start: string;
    end: string;
    items: {
      key: string;
      label: string;
      amount: number;
      share: number | null;
    }[];
  } | null;
  notices: Notice[];
};

const MINUS = "−";

// Text and sign of one table cell; null (not computable) is a dash.
function cell(value: number | null, kind: Kind): [string, boolean] {
  if (value === null) return [DASH, false];
  switch (kind) {
    case "pct":
      return [`${(value * 100).toFixed(1)} %`, false];
    case "minutes":
      return [(value / 60).toFixed(1), false];
    case "money":
      return [formatMoney(Math.trunc(value)).replace("-", MINUS), value < 0];
    default:
      return [String(value), false];
  }
}

function PeriodForm({
  initial,
  errors,
}: {
  initial: Dashboard["form"];
  errors: Notice[];
}) {
  const [, setParams] = useSearchParams();
  const [month, setMonth] = useState(initial.month);
  const [from, setFrom] = useState(initial.from);
  const [to, setTo] = useState(initial.to);

  const apply = (e: FormEvent) => {
    e.preventDefault();
    const next: Record<string, string> = {};
    if (month) next.month = month;
    if (from) next.from = from;
    if (to) next.to = to;
    setParams(next);
  };

  return (
    <form onSubmit={apply} className="mb-4">
      <div className="flex flex-wrap items-end gap-2">
        <Field label="Month">
          <MonthInput name="month" value={month} onChange={setMonth} />
        </Field>
        <Field label="From">
          <DateInput name="from" value={from} onChange={setFrom} />
        </Field>
        <Field label="To">
          <DateInput name="to" value={to} onChange={setTo} />
        </Field>
        <button type="submit" className="btn btn-primary">
          Apply
        </button>
        <Link to="/" className="btn">
          Reset
        </Link>
      </div>
      {errors.map((n) => (
        <p key={n.text} className="text-error mt-2">
          {n.text}
        </p>
      ))}
    </form>
  );
}

export function DashboardPage() {
  const [params] = useSearchParams();
  const qs = new URLSearchParams();
  for (const key of ["month", "from", "to"]) {
    const value = params.get(key);
    if (value) qs.set(key, value);
  }
  const query = qs.toString();
  const dash = useQuery({
    queryKey: ["dashboard", query],
    queryFn: () => api<Dashboard>("GET", `/api/dashboard?${query}`),
    placeholderData: keepPreviousData,
  });
  const data = dash.data;
  const errors = data?.notices.filter((n) => n.level === "error") ?? [];
  const others = data?.notices.filter((n) => n.level !== "error") ?? [];

  return (
    <div>
      <h1 className="text-2xl font-bold mb-4">Dashboard</h1>
      {dash.isError && (
        <div role="alert" className="alert alert-error mb-4">
          {dash.error.message}
        </div>
      )}
      {others.map((n) => (
        <div
          key={n.text}
          role="alert"
          className={`alert alert-${n.level} mb-4`}
        >
          {n.text}
        </div>
      ))}
      {data && data.needing_rate > 0 && (
        <div role="alert" className="alert alert-warning mb-4">
          <Link to="/rates">
            {data.needing_rate} booking{data.needing_rate === 1 ? "" : "s"}{" "}
            {data.needing_rate === 1 ? "needs" : "need"} an exchange rate
          </Link>
        </div>
      )}
      {data && (
        <PeriodForm
          key={JSON.stringify(data.form)}
          initial={data.form}
          errors={errors}
        />
      )}
      {data?.empty && (
        <p>
          Nothing here yet:{" "}
          <Link className="link" to="/import">
            import the Airbnb CSV
          </Link>{" "}
          or{" "}
          <Link className="link" to="/bookings/new">
            add a booking
          </Link>
          .
        </p>
      )}
      {data && !data.empty && <DashboardBody data={data} />}
    </div>
  );
}

function DashboardBody({ data }: { data: Dashboard }) {
  const { breakdown } = data;
  const hasCosts = breakdown?.items.some((item) => item.amount !== 0);
  const hasHistory = data.rolling_90.length > 0;

  return (
    <>
      <div className="overflow-x-auto">
        <table className="table">
          <thead>
            <tr>
              <th>COP unless stated</th>
              {data.columns.map((c) => (
                <th key={c.label} className="text-right">
                  {c.label}
                  <br />
                  <span className="font-normal opacity-70">
                    {c.start} – {c.end}
                  </span>
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {data.rows.map((row) => (
              <tr key={row.key}>
                <td>{row.label}</td>
                {row.values.map((value, i) => {
                  const [text, negative] = cell(value, row.kind);
                  return (
                    <td
                      // biome-ignore lint/suspicious/noArrayIndexKey: one value per column
                      key={i}
                      className={`text-right ${negative ? "text-error" : ""}`}
                    >
                      {text}
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <h2 className="text-xl font-bold mt-6 mb-2">Last 90 days, day by day</h2>
      {!hasHistory ? (
        <p>The 90-day chart starts once 90 days of history exist.</p>
      ) : (
        <>
          <h3 className="font-bold">ADR and RevPAR (COP)</h3>
          {data.rolling_90.every((p) => p.adr === null && p.revpar === null) ? (
            <p>Nothing to chart.</p>
          ) : (
            <div data-chart="money" />
          )}
          <h3 className="font-bold mt-4">Occupancy</h3>
          {data.rolling_90.every((p) => p.occupancy === null) ? (
            <p>Nothing to chart.</p>
          ) : (
            <div data-chart="occupancy" />
          )}
        </>
      )}

      {breakdown && (
        <>
          <h2 className="text-xl font-bold mt-6 mb-2">
            Expense breakdown{" "}
            <span className="text-sm font-normal opacity-70">
              {breakdown.start} – {breakdown.end}
            </span>
          </h2>
          {!hasCosts ? (
            <p>No costs in this period.</p>
          ) : (
            <>
              <div data-chart="breakdown" />
              <table className="table w-auto">
                <thead>
                  <tr>
                    <th>Category</th>
                    <th className="text-right">COP</th>
                    <th className="text-right">Share</th>
                  </tr>
                </thead>
                <tbody>
                  {breakdown.items.map((item) => (
                    <tr key={item.key}>
                      <td>{item.label}</td>
                      <td className="text-right">
                        {formatMoney(Math.trunc(item.amount))}
                      </td>
                      <td className="text-right">
                        {item.share === null
                          ? DASH
                          : `${(item.share * 100).toFixed(1)} %`}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </>
          )}
        </>
      )}
    </>
  );
}
