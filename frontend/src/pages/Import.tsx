import { useMutation, useQueryClient } from "@tanstack/react-query";
import { type FormEvent, useState } from "react";
import { Link } from "react-router";
import { ApiError, api, postFile, type Written } from "../api";
import { type Column, DataTable } from "../components/DataTable";
import { Field } from "../components/Field";
import { FormActions } from "../components/FormActions";
import { FormError } from "../components/FormError";
import { FormSlip } from "../components/FormSlip";
import { ImportIcon } from "../components/icons";
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
  waiting: number;
  skipped: Skipped;
  problems: Problem[];
  warnings: string[];
};

const NO_FILE = "choose the Airbnb CSV file";
const sum = (rows: ListingRows[]) => rows.reduce((n, r) => n + r.rows, 0);

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
      <FormError message={shown ?? undefined} />
      <FormSlip label="Airbnb CSV">
        <form onSubmit={submit}>
          <Field label="CSV file">
            <input
              type="file"
              name="file"
              accept=".csv,text/csv"
              className="file-input w-full"
            />
          </Field>
          <FormActions>
            <button
              type="submit"
              className="btn btn-primary"
              disabled={upload.isPending}
            >
              Preview
            </button>
          </FormActions>
        </form>
      </FormSlip>
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
      <PageTitle icon={<ImportIcon />}>Import preview</PageTitle>
      <FormError message={error ?? undefined} />
      <form
        onSubmit={(e) => {
          e.preventDefault();
          apply.mutate();
        }}
      >
        {preview.needs_listing_choice ? (
          <FormSlip label="Listings">
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
                className="input w-full"
                value={other}
                onChange={(e) => setOther(e.target.value)}
              />
            </Field>
          </FormSlip>
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
        <FormActions>
          <button type="submit" className="btn btn-primary" disabled={busy}>
            Import
          </button>
          <button
            type="button"
            className="btn btn-ghost"
            disabled={busy}
            onClick={() => cancel.mutate()}
          >
            Cancel
          </button>
        </FormActions>
      </form>
    </div>
  );
}

function SummaryStep({ summary }: { summary: Summary }) {
  return (
    <div>
      <div className="mb-4 flex flex-wrap items-center gap-4">
        <PageTitle icon={<ImportIcon />} className="">
          Import done
        </PageTitle>
        <span className="stamp" aria-hidden="true">
          Posted ✓
        </span>
      </div>
      <ul className="ledger-list mb-2">
        <li>
          {summary.new} new booking(s), {summary.updated} updated,{" "}
          {summary.lines_added} line(s) added
        </li>
        <li>
          {summary.waiting} line(s) wait for an exchange rate and are left out
          of the figures
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
      <PageTitle icon={<ImportIcon />}>Import</PageTitle>
      <UploadStep error={error} onPreview={setPreview} />
    </div>
  );
}
