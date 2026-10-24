import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { type FormEvent, useState } from "react";
import { Link, useSearchParams } from "react-router";
import { api, type Notice } from "../api";
import { BarChart } from "../charts/BarChart";
import { LineChart } from "../charts/LineChart";
import { BlankLedgerDoodle } from "../components/icons";
import { DateInput, MonthInput } from "../components/inputs";
import { PageTitle, SectionTitle } from "../components/Titles";
import { Toolbar, ToolbarField } from "../components/Toolbar";
import { WaitingNotice } from "../components/WaitingNotice";
import { DASH, formatDisplay } from "../format";
import { useDisplay } from "../useDisplay";

type Kind = "int" | "pct" | "money";

export type Dashboard = {
  form: { month: string; from: string; to: string };
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
function cell(
  value: number | null,
  kind: Kind,
  money: (cents: number | null) => string,
): [string, boolean] {
  if (value === null) return [DASH, false];
  switch (kind) {
    case "pct":
      return [`${(value * 100).toFixed(1)} %`, false];
    case "money":
      return [money(Math.trunc(value)).replace("-", MINUS), value < 0];
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
    <Toolbar onSubmit={apply} errors={errors.map((n) => n.text)}>
      <ToolbarField label="Month">
        <MonthInput
          name="month"
          value={month}
          onChange={setMonth}
          className="input-sm"
        />
      </ToolbarField>
      <ToolbarField label="From">
        <DateInput
          name="from"
          value={from}
          onChange={setFrom}
          className="input-sm"
        />
      </ToolbarField>
      <ToolbarField label="To">
        <DateInput name="to" value={to} onChange={setTo} className="input-sm" />
      </ToolbarField>
      <button type="submit" className="btn btn-primary btn-sm">
        Apply
      </button>
      <Link to="/" className="btn btn-ghost btn-sm">
        Reset
      </Link>
    </Toolbar>
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
      <PageTitle>Dashboard</PageTitle>
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
      <WaitingNotice />
      {data && (
        <PeriodForm
          key={JSON.stringify(data.form)}
          initial={data.form}
          errors={errors}
        />
      )}
      {data?.empty && (
        <div className="flex items-center gap-4 rounded-box border border-base-300 bg-base-200 p-4">
          <BlankLedgerDoodle className="size-20 shrink-0 opacity-70" />
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
        </div>
      )}
      {data && !data.empty && <DashboardBody data={data} />}
    </div>
  );
}

function DashboardBody({ data }: { data: Dashboard }) {
  const { breakdown } = data;
  const { currency, money, convert } = useDisplay();
  const hasCosts = breakdown?.items.some((item) => item.amount !== 0);
  const hasHistory = data.rolling_90.length > 0;

  return (
    <>
      <div className="overflow-x-auto">
        <table className="table sheet">
          <thead>
            <tr>
              <th className="sticky left-0 z-10">{currency} unless stated</th>
              {data.columns.map((c) => (
                <th key={c.label} className="num">
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
                <th className="sticky left-0 z-10">{row.label}</th>
                {row.values.map((value, i) => {
                  const [text, negative] = cell(value, row.kind, money);
                  return (
                    <td
                      // biome-ignore lint/suspicious/noArrayIndexKey: one value per column
                      key={i}
                      className={negative ? "num neg" : "num"}
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

      <SectionTitle className="mt-6 mb-2">
        Last 90 days, day by day
      </SectionTitle>
      {!hasHistory ? (
        <p>The 90-day chart starts once 90 days of history exist.</p>
      ) : (
        <>
          <h3 className="text-lg font-bold">ADR and RevPAR ({currency})</h3>
          {data.rolling_90.every((p) => p.adr === null && p.revpar === null) ? (
            <p>Nothing to chart.</p>
          ) : (
            <LineChart
              series={[
                {
                  label: "ADR",
                  points: data.rolling_90.map((p) => ({
                    date: p.date,
                    value: p.adr === null ? null : convert(p.adr),
                  })),
                },
                {
                  label: "RevPAR",
                  points: data.rolling_90.map((p) => ({
                    date: p.date,
                    value: p.revpar === null ? null : convert(p.revpar),
                  })),
                },
              ]}
              yFormat={(v) => formatDisplay(Math.round(v), currency)}
              yMin={0}
              width={800}
              height={280}
            />
          )}
          <h3 className="text-lg font-bold mt-4">Occupancy</h3>
          {data.rolling_90.every((p) => p.occupancy === null) ? (
            <p>Nothing to chart.</p>
          ) : (
            <LineChart
              series={[
                {
                  label: "Occupancy",
                  points: data.rolling_90.map((p) => ({
                    date: p.date,
                    value: p.occupancy,
                  })),
                },
              ]}
              yFormat={(v) => `${(v * 100).toFixed(0)} %`}
              yMin={0}
              yMax={1}
              width={800}
              height={220}
            />
          )}
        </>
      )}

      {breakdown && (
        <>
          <SectionTitle className="mt-6 mb-2">
            Expense breakdown{" "}
            <span className="text-sm font-normal opacity-70">
              {breakdown.start} – {breakdown.end}
            </span>
          </SectionTitle>
          {!hasCosts ? (
            <p>No costs in this period.</p>
          ) : (
            <>
              <BarChart
                items={breakdown.items.map((i) => ({
                  label: i.label,
                  value: convert(i.amount),
                }))}
                valueFormat={(v) => formatDisplay(Math.round(v), currency)}
              />
              <div className="overflow-x-auto">
                <table className="table sheet w-auto">
                  <thead>
                    <tr>
                      <th className="sticky left-0 z-10">Category</th>
                      <th className="num">{currency}</th>
                      <th className="num">Share</th>
                    </tr>
                  </thead>
                  <tbody>
                    {breakdown.items.map((item) => (
                      <tr key={item.key}>
                        <th className="sticky left-0 z-10">{item.label}</th>
                        <td className="num">
                          {money(Math.trunc(item.amount))}
                        </td>
                        <td className="num">
                          {item.share === null
                            ? DASH
                            : `${(item.share * 100).toFixed(1)} %`}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </>
          )}
        </>
      )}
    </>
  );
}
