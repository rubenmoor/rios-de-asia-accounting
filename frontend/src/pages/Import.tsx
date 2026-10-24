import { useMutation, useQueryClient } from "@tanstack/react-query";
import { type FormEvent, useState } from "react";
import { Link } from "react-router";
import {
  ApiError,
  api,
  type FieldErrors,
  postFile,
  type Written,
} from "../api";
import { type Column, DataTable } from "../components/DataTable";
import { Field } from "../components/Field";
import { useNotices } from "../components/Notices";
import { PageTitle, SectionTitle } from "../components/Titles";

type Change = { field: string; old: string | null; new: string };
type PlannedBooking = {
  code: string;
  listing: string;
  guest: string;
  check_in: string;
  check_out: string;
  lines: number;
  changes: Change[];
};
type Problem = { line: number; message: string };
type ListingRows = { listing: string; rows: number };
type Skipped = {
  payouts: number;
  known_lines: number;
  listings: ListingRows[];
};
type Preview = {
  token: string;
  needs_listing_choice: boolean;
  listings_found: ListingRows[];
  listings: string[];
  new: PlannedBooking[];
  updated: PlannedBooking[];
  skipped: Skipped;
  problems: Problem[];
  warnings: string[];
};
type Summary = {
  new: number;
  updated: number;
  lines_added: number;
  needing_rate: number;
  skipped: Skipped;
  problems: Problem[];
  warnings: string[];
};

const NO_FILE = "choose the Airbnb CSV file";
const sum = (rows: ListingRows[]) => rows.reduce((n, r) => n + r.rows, 0);

function Alert({ children }: { children: string }) {
  return (
    <div role="alert" className="alert alert-error mb-4">
      {children}
    </div>
  );
}

function ProblemsAndWarnings({
  problems,
  warnings,
}: {
  problems: Problem[];
  warnings: string[];
}) {
  return (
    <>
      {problems.length > 0 && (
        <>
          <SectionTitle className="mt-4 mb-2">
            {problems.length} problem(s)
          </SectionTitle>
          <ul className="mb-2">
            {problems.map((p) => (
              <li key={`${p.line}:${p.message}`} className="text-error">
                line {p.line}: {p.message}
              </li>
            ))}
          </ul>
        </>
      )}
      {warnings.length > 0 && (
        <>
          <SectionTitle className="mt-4 mb-2">Warnings</SectionTitle>
          <ul className="mb-2">
            {warnings.map((w) => (
              <li key={w}>{w}</li>
            ))}
          </ul>
        </>
      )}
    </>
  );
}

function UploadStep({
  error,
  onPreview,
}: {
  error: string | null;
  onPreview: (preview: Preview) => void;
}) {
  const [fileError, setFileError] = useState<string | null>(null);
  const upload = useMutation({
    mutationFn: (body: FormData) =>
      postFile<Written<Preview>>("/api/import/airbnb", body),
    onSuccess: (result) => {
      setFileError(null);
      onPreview(result.data);
    },
    onError: (e) =>
      setFileError(
        e instanceof ApiError ? (e.fieldErrors.file ?? e.message) : e.message,
      ),
  });

  const submit = (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const body = new FormData(e.currentTarget);
    const file = body.get("file");
    if (!(file instanceof File) || !file.name) {
      setFileError(NO_FILE);
      return;
    }
    upload.mutate(body);
  };

  const shown = fileError ?? error;
  return (
    <section>
      <SectionTitle>Airbnb earnings CSV</SectionTitle>
      <p className="opacity-70 mb-2">
        You see what would change before anything is written.
      </p>
      {shown && <Alert>{shown}</Alert>}
      <form onSubmit={submit} className="flex flex-wrap items-end gap-2">
        <Field label="CSV file">
          <input
            type="file"
            name="file"
            accept=".csv,text/csv"
            className="file-input"
          />
        </Field>
        <button
          type="submit"
          className="btn btn-primary"
          disabled={upload.isPending}
        >
          Preview
        </button>
      </form>
    </section>
  );
}

const BOOKING_COLUMNS: Column<PlannedBooking>[] = [
  { header: "Code", cell: (p) => p.code },
  {
    header: "Check-in – check-out",
    cell: (p) => `${p.check_in} – ${p.check_out}`,
  },
  { header: "Guest", cell: (p) => p.guest },
  { header: "Listing", cell: (p) => p.listing },
  { header: "Lines", cell: (p) => p.lines, numeric: true },
];

const UPDATED_COLUMNS: Column<PlannedBooking>[] = [
  { header: "Code", cell: (p) => p.code },
  {
    header: "Change",
    cell: (p) =>
      p.changes.length === 0
        ? "new lines only"
        : p.changes.map((c) => (
            <div key={c.field}>
              {c.field}: {c.old || "-"} → {c.new}
            </div>
          )),
  },
  { header: "New lines", cell: (p) => p.lines, numeric: true },
];

function BookingTable({ rows }: { rows: PlannedBooking[] }) {
  return (
    <div className="mb-4">
      <DataTable
        columns={BOOKING_COLUMNS}
        rows={rows}
        rowKey={(p) => p.code}
        empty=""
      />
    </div>
  );
}

function UpdatedTable({ rows }: { rows: PlannedBooking[] }) {
  return (
    <div className="mb-4">
      <DataTable
        columns={UPDATED_COLUMNS}
        rows={rows}
        rowKey={(p) => p.code}
        empty=""
      />
    </div>
  );
}

function SkippedList({ skipped }: { skipped: Skipped }) {
  return (
    <ul className="mb-2">
      <li>{skipped.payouts} payout row(s)</li>
      <li>{skipped.known_lines} line(s) already imported</li>
      <li>
        {sum(skipped.listings)} row(s) of other listings
        {skipped.listings.map((l) => (
          <div key={l.listing}>
            {l.rows} row(s): {l.listing}
          </div>
        ))}
      </li>
    </ul>
  );
}

function PreviewStep({
  preview,
  onSummary,
  onBack,
}: {
  preview: Preview;
  onSummary: (summary: Summary) => void;
  onBack: (error: string | null) => void;
}) {
  const queryClient = useQueryClient();
  const { setNotices } = useNotices();
  const [chosen, setChosen] = useState<string[]>([]);
  const [other, setOther] = useState("");
  const [error, setError] = useState<string | null>(null);

  const apply = useMutation({
    mutationFn: () =>
      api<Written<Summary>>("POST", "/api/import/airbnb/apply", {
        token: preview.token,
        listings: chosen,
        other_listing: other,
      }),
    onSuccess: async (result) => {
      await queryClient.invalidateQueries();
      onSummary(result.data);
    },
    onError: (e) => {
      if (e instanceof ApiError && e.status === 422) {
        if (e.fieldErrors.token) {
          onBack(e.fieldErrors.token);
        } else {
          setError(e.fieldErrors.listings ?? e.message);
        }
      } else {
        setError(e.message);
      }
    },
  });

  const cancel = useMutation({
    mutationFn: () =>
      api<Written<null>>("DELETE", `/api/import/airbnb/${preview.token}`),
    onSuccess: (result) => {
      setNotices(result.notices);
      onBack(null);
    },
    onError: (e) => setError(e.message),
  });

  const toggle = (name: string) =>
    setChosen((c) =>
      c.includes(name) ? c.filter((n) => n !== name) : [...c, name],
    );
  const busy = apply.isPending || cancel.isPending;

  return (
    <div>
      <PageTitle>Import preview</PageTitle>
      {error && <Alert>{error}</Alert>}
      <form
        onSubmit={(e) => {
          e.preventDefault();
          apply.mutate();
        }}
      >
        {preview.needs_listing_choice ? (
          <>
            <p className="mb-2">
              No listings of this property are chosen yet. Tick the ones to
              import; the choice is saved in the settings. Nothing is imported
              until you press Import.
            </p>
            {preview.listings_found.map((l) => (
              <label key={l.listing} className="flex items-center gap-2 mb-1">
                <input
                  type="checkbox"
                  className="checkbox"
                  checked={chosen.includes(l.listing)}
                  onChange={() => toggle(l.listing)}
                />
                <span>
                  {l.listing}{" "}
                  <span className="opacity-60">({l.rows} row(s))</span>
                </span>
              </label>
            ))}
            <Field label="Another listing name">
              <input
                className="input"
                size={40}
                value={other}
                onChange={(e) => setOther(e.target.value)}
              />
            </Field>
          </>
        ) : (
          <>
            <p className="mb-2">
              Listings imported: {preview.listings.join(", ")}
            </p>
            <SectionTitle>{preview.new.length} new booking(s)</SectionTitle>
            {preview.new.length > 0 && <BookingTable rows={preview.new} />}
            <SectionTitle>
              {preview.updated.length} updated booking(s)
            </SectionTitle>
            {preview.updated.length > 0 && (
              <UpdatedTable rows={preview.updated} />
            )}
            <SectionTitle>Skipped</SectionTitle>
            <SkippedList skipped={preview.skipped} />
          </>
        )}
        <ProblemsAndWarnings
          problems={preview.problems}
          warnings={preview.warnings}
        />
        <div className="flex gap-2 mt-4">
          <button type="submit" className="btn btn-primary" disabled={busy}>
            Import
          </button>
          <button
            type="button"
            className="btn"
            disabled={busy}
            onClick={() => cancel.mutate()}
          >
            Cancel
          </button>
        </div>
      </form>
    </div>
  );
}

function SummaryStep({ summary }: { summary: Summary }) {
  return (
    <div>
      <PageTitle>Import done</PageTitle>
      <ul className="mb-2">
        <li>
          {summary.new} new booking(s), {summary.updated} updated,{" "}
          {summary.lines_added} line(s) added
        </li>
        <li>
          {summary.needing_rate} booking(s) need an exchange rate (
          <Link className="link" to="/rates">
            rates
          </Link>
          )
        </li>
        <li>
          Skipped: {summary.skipped.payouts} payout row(s),{" "}
          {summary.skipped.known_lines} known line(s),{" "}
          {sum(summary.skipped.listings)} row(s) of other listings
        </li>
      </ul>
      <ProblemsAndWarnings
        problems={summary.problems}
        warnings={summary.warnings}
      />
      <p className="mt-4">
        <Link className="link" to="/bookings">
          Bookings
        </Link>
      </p>
    </div>
  );
}

type RatesResult = {
  added: number;
  changed: number;
  lines_recomputed: number;
  needing_rate: number;
  problems: Problem[];
};

function RatesSection() {
  const queryClient = useQueryClient();
  const [currency, setCurrency] = useState("USD");
  const [errors, setErrors] = useState<FieldErrors>({});
  const [done, setDone] = useState<{
    currency: string;
    result: RatesResult;
  } | null>(null);

  const load = useMutation({
    mutationFn: (body: FormData) =>
      postFile<Written<RatesResult>>("/api/import/rates", body),
    onSuccess: async (result, body) => {
      setErrors({});
      setDone({ currency: String(body.get("currency")), result: result.data });
      await queryClient.invalidateQueries();
    },
    onError: (e) => {
      setDone(null);
      setErrors(
        e instanceof ApiError && e.status === 422
          ? e.fieldErrors
          : { "": e.message },
      );
    },
  });

  const submit = (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const body = new FormData(e.currentTarget);
    const file = body.get("file");
    if (!(file instanceof File) || !file.name) {
      setDone(null);
      setErrors({ file: "choose the exchange-rate CSV file" });
      return;
    }
    load.mutate(body);
  };

  return (
    <section className="mt-8">
      <SectionTitle>Exchange rates (TRM)</SectionTitle>
      <p className="opacity-70 mb-2">
        CSV from datos.gov.co with the columns VALOR and VIGENCIADESDE.
      </p>
      {errors[""] && <Alert>{errors[""]}</Alert>}
      <form onSubmit={submit} className="flex flex-wrap items-start gap-2">
        <Field label="CSV file" error={errors.file}>
          <input
            type="file"
            name="file"
            accept=".csv,text/csv"
            className="file-input"
          />
        </Field>
        <Field label="Currency" error={errors.currency}>
          <input
            className="input"
            name="currency"
            size={4}
            maxLength={3}
            value={currency}
            onChange={(e) => setCurrency(e.target.value)}
          />
        </Field>
        <button
          type="submit"
          className="btn btn-primary mt-8"
          disabled={load.isPending}
        >
          Load rates
        </button>
      </form>
      {done && (
        <div className="mt-4">
          <div role="alert" className="alert alert-success">
            {done.currency} rates: {done.result.added} added,{" "}
            {done.result.changed} changed; {done.result.lines_recomputed}{" "}
            line(s) recomputed; {done.result.needing_rate} booking(s) still need
            an exchange rate.
          </div>
          <ProblemsAndWarnings problems={done.result.problems} warnings={[]} />
        </div>
      )}
    </section>
  );
}

export function ImportPage() {
  const [preview, setPreview] = useState<Preview | null>(null);
  const [summary, setSummary] = useState<Summary | null>(null);
  const [error, setError] = useState<string | null>(null);

  if (summary) return <SummaryStep summary={summary} />;
  if (preview) {
    return (
      <PreviewStep
        preview={preview}
        onSummary={setSummary}
        onBack={(e) => {
          setError(e);
          setPreview(null);
        }}
      />
    );
  }
  return (
    <div>
      <PageTitle>Import</PageTitle>
      <UploadStep error={error} onPreview={setPreview} />
      <RatesSection />
    </div>
  );
}
