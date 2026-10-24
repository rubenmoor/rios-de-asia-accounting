import { useQuery } from "@tanstack/react-query";
import { type FormEvent, useEffect, useState } from "react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router";
import { ApiError, api } from "../api";
import { ConfirmDelete } from "../components/ConfirmDelete";
import { type Column, DataTable } from "../components/DataTable";
import { Field } from "../components/Field";
import {
  DateInput,
  MoneyInput,
  Select,
  TextArea,
  TextField,
} from "../components/inputs";
import { useNotices } from "../components/Notices";
import { PageTitle, SectionTitle } from "../components/Titles";
import { formatMoney, showMoney } from "../format";
import { useSave } from "../useSave";

type Summary = {
  id: number;
  check_in: string;
  check_out: string;
  guest_name: string;
  listing: string;
  nights: number;
  net_payout: number | null;
  needs_rate: boolean;
};
type Line = {
  date: string;
  type: string;
  currency: string;
  amount_minor: number;
  amount_cop: number | null;
};
type Detail = Summary & {
  airbnb_code: string;
  guests: number | null;
  notes: string;
  imported: boolean;
  gross: number | null;
  airbnb_fee: number | null;
  cohost_cost: number | null;
  manual_amount: number | null;
  lines: Line[];
};
type Options = { listings: string[] };

const dash = (text: string | number | null | undefined) =>
  text === null || text === undefined || text === "" ? "-" : String(text);

const COLUMNS: Column<Summary>[] = [
  {
    header: "Check-in",
    cell: (b) => b.check_in,
    href: (b) => `/bookings/${b.id}`,
  },
  { header: "Check-out", cell: (b) => b.check_out },
  { header: "Guest", cell: (b) => dash(b.guest_name) },
  { header: "Listing", cell: (b) => dash(b.listing) },
  { header: "Nights", cell: (b) => b.nights, numeric: true },
  { header: "Net payout", cell: (b) => showMoney(b.net_payout), numeric: true },
  {
    header: "",
    cell: (b) =>
      b.needs_rate && <span className="text-error">needs exchange rate</span>,
  },
];

function useOptions() {
  return useQuery({
    queryKey: ["bookings", "options"],
    queryFn: () => api<Options>("GET", "/api/bookings/options"),
  });
}

export function BookingList() {
  const [params, setParams] = useSearchParams();
  const from = params.get("from") ?? "";
  const to = params.get("to") ?? "";
  const listing = params.get("listing") ?? "";
  const [draft, setDraft] = useState({ from, to, listing });
  const options = useOptions();
  const query = new URLSearchParams();
  if (from) query.set("from", from);
  if (to) query.set("to", to);
  if (listing) query.set("listing", listing);
  const bookings = useQuery({
    queryKey: ["bookings", "list", from, to, listing],
    queryFn: () => api<Summary[]>("GET", `/api/bookings?${query}`),
  });
  const filterErrors =
    bookings.error instanceof ApiError ? bookings.error.fieldErrors : {};
  const invalid =
    bookings.error instanceof ApiError && bookings.error.status === 422;

  const apply = (e: FormEvent) => {
    e.preventDefault();
    const next = new URLSearchParams();
    if (draft.from) next.set("from", draft.from);
    if (draft.to) next.set("to", draft.to);
    if (draft.listing) next.set("listing", draft.listing);
    setParams(next);
  };

  return (
    <div>
      <PageTitle>Bookings</PageTitle>
      <form onSubmit={apply} className="flex flex-wrap items-end gap-2 mb-4">
        <Field label="From" error={filterErrors.from}>
          <DateInput
            name="from"
            value={draft.from}
            onChange={(v) => setDraft({ ...draft, from: v })}
          />
        </Field>
        <Field label="To" error={filterErrors.to}>
          <DateInput
            name="to"
            value={draft.to}
            onChange={(v) => setDraft({ ...draft, to: v })}
          />
        </Field>
        <Field label="Listing">
          <Select
            name="listing"
            value={draft.listing}
            onChange={(v) => setDraft({ ...draft, listing: v })}
          >
            <option value="">all</option>
            {options.data?.listings.map((name) => (
              <option key={name} value={name}>
                {name}
              </option>
            ))}
          </Select>
        </Field>
        <button type="submit" className="btn">
          Filter
        </button>
        <Link className="btn btn-primary" to="/bookings/new">
          New booking
        </Link>
      </form>
      {bookings.isError && !invalid && (
        <div role="alert" className="alert alert-error mb-4">
          {bookings.error.message}
        </div>
      )}
      <DataTable
        columns={COLUMNS}
        rows={bookings.data ?? []}
        rowKey={(b) => b.id}
        empty="No bookings."
      />
    </div>
  );
}

const amount = (minor: number) =>
  (minor / 100).toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });

const LINE_COLUMNS: Column<Line>[] = [
  { header: "Date", cell: (l) => l.date },
  { header: "Type", cell: (l) => l.type },
  { header: "Currency", cell: (l) => l.currency },
  {
    header: "Amount",
    cell: (l) => amount(l.amount_minor),
    numeric: true,
    negative: (l) => l.amount_minor < 0,
  },
  {
    header: "COP",
    cell: (l) =>
      l.amount_cop === null ? "needs rate" : formatMoney(l.amount_cop),
    numeric: true,
    negative: (l) => l.amount_cop !== null && l.amount_cop < 0,
  },
];

function useBooking(id: string | undefined) {
  return useQuery({
    queryKey: ["bookings", "detail", id],
    queryFn: () => api<Detail>("GET", `/api/bookings/${id}`),
  });
}

function Loading({
  query,
}: {
  query: { isError: boolean; error: Error | null };
}) {
  return query.isError ? (
    <div role="alert" className="alert alert-error">
      {query.error?.message}
    </div>
  ) : (
    <p className="opacity-70">Loading…</p>
  );
}

const deleteQuestion = (imported: boolean) =>
  imported
    ? "It was imported from Airbnb; a re-import brings it back."
    : undefined;

export function BookingDetail() {
  const { id } = useParams();
  const booking = useBooking(id);
  if (!booking.data) return <Loading query={booking} />;
  const b = booking.data;
  const money = (label: string, v: number | null) => (
    <tr>
      <th>{label}</th>
      <td>{v === null ? "–" : `${formatMoney(v)} COP`}</td>
    </tr>
  );
  return (
    <div>
      <PageTitle>
        Booking {b.check_in} – {b.check_out}
      </PageTitle>
      {b.needs_rate && (
        <div role="alert" className="alert alert-warning mb-4">
          <span>
            Some lines need an exchange rate; totals are incomplete.{" "}
            <Link className="link" to="/rates">
              Rates
            </Link>
          </span>
        </div>
      )}
      <table className="table w-auto">
        <tbody>
          <tr>
            <th>Guest</th>
            <td>{dash(b.guest_name)}</td>
          </tr>
          <tr>
            <th>Listing</th>
            <td>{dash(b.listing)}</td>
          </tr>
          <tr>
            <th>Confirmation code</th>
            <td>{dash(b.airbnb_code)}</td>
          </tr>
          <tr>
            <th>Guests</th>
            <td>{dash(b.guests)}</td>
          </tr>
          <tr>
            <th>Notes</th>
            <td>{dash(b.notes)}</td>
          </tr>
          <tr>
            <th>Nights</th>
            <td>{b.nights}</td>
          </tr>
          {money("Net payout", b.net_payout)}
          {money("Gross", b.gross)}
          {money("Airbnb fee", b.airbnb_fee)}
          {money("Co-host cost", b.cohost_cost)}
        </tbody>
      </table>
      <SectionTitle className="mt-6 mb-2">Lines</SectionTitle>
      <DataTable
        columns={LINE_COLUMNS}
        rows={b.lines}
        rowKey={(l) => `${l.date}${l.type}${l.currency}${l.amount_minor}`}
        empty="No lines."
      />
      <div className="flex gap-2 mt-4">
        <Link className="btn btn-primary" to={`/bookings/${b.id}/edit`}>
          Edit
        </Link>
        <Link className="btn" to="/bookings">
          Back to bookings
        </Link>
      </div>
    </div>
  );
}

type Form = Record<string, string>;

function BookingForm({ booking }: { booking?: Detail }) {
  const imported = booking?.imported ?? false;
  const options = useOptions();
  const navigate = useNavigate();
  const { setNotices } = useNotices();
  const [form, setForm] = useState<Form>({
    check_in: booking?.check_in ?? "",
    check_out: booking?.check_out ?? "",
    net_payout:
      booking?.manual_amount != null ? formatMoney(booking.manual_amount) : "",
    airbnb_code: booking?.airbnb_code ?? "",
    listing: booking?.listing ?? "",
    guest_name: booking?.guest_name ?? "",
    guests: booking?.guests != null ? String(booking.guests) : "",
    notes: booking?.notes ?? "",
  });
  const set = (name: string) => (value: string) =>
    setForm((f) => ({ ...f, [name]: value }));

  const saver = useSave<Detail>({
    method: booking ? "PUT" : "POST",
    path: booking ? `/api/bookings/${booking.id}` : "/api/bookings",
    resource: "bookings",
    redirectTo: (saved) => `/bookings/${saved.id}`,
  });
  const remover = useSave({
    method: "DELETE",
    path: `/api/bookings/${booking?.id}`,
    resource: "bookings",
    redirectTo: () => "/bookings",
  });
  const { errors } = saver;
  // A refused delete shows its error on the detail page, as the server-rendered page does.
  const refused = remover.errors[""];
  useEffect(() => {
    if (refused && booking) {
      setNotices([{ level: "error", text: refused }]);
      navigate(`/bookings/${booking.id}`);
    }
  }, [refused, booking, setNotices, navigate]);
  // Imported bookings: only guests and notes are sent.
  const body = imported ? { guests: form.guests, notes: form.notes } : form;

  return (
    <div>
      <PageTitle>{booking ? "Edit booking" : "New booking"}</PageTitle>
      {imported && (
        <p className="mb-4 opacity-70">
          Imported from Airbnb: dates, listing, guest name and amounts are
          read-only; only guests and notes can change.
        </p>
      )}
      <form
        className="max-w-lg"
        onSubmit={(e) => {
          e.preventDefault();
          saver.save(body);
        }}
      >
        {errors[""] && (
          <div role="alert" className="alert alert-error mb-4">
            {errors[""]}
          </div>
        )}
        {booking && imported ? (
          <p className="mb-2">
            {booking.check_in} – {booking.check_out} ·{" "}
            {dash(booking.guest_name)} · {dash(booking.listing)} ·{" "}
            {showMoney(booking.net_payout)} COP
          </p>
        ) : (
          <>
            <Field label="Check-in" error={errors.check_in}>
              <DateInput
                name="check_in"
                value={form.check_in}
                onChange={set("check_in")}
              />
            </Field>
            <Field label="Check-out" error={errors.check_out}>
              <DateInput
                name="check_out"
                value={form.check_out}
                onChange={set("check_out")}
              />
            </Field>
            <Field label="Net payout (COP)" error={errors.net_payout}>
              <MoneyInput
                name="net_payout"
                value={form.net_payout}
                onChange={set("net_payout")}
              />
            </Field>
            <Field
              label="Confirmation code"
              hint="optional, unique"
              error={errors.airbnb_code}
            >
              <TextField
                name="airbnb_code"
                value={form.airbnb_code}
                onChange={set("airbnb_code")}
              />
            </Field>
            <Field label="Listing" error={errors.listing}>
              <TextField
                name="listing"
                list="listings"
                value={form.listing}
                onChange={set("listing")}
              />
              <datalist id="listings">
                {options.data?.listings.map((name) => (
                  <option key={name} value={name} />
                ))}
              </datalist>
            </Field>
            <Field label="Guest name" error={errors.guest_name}>
              <TextField
                name="guest_name"
                value={form.guest_name}
                onChange={set("guest_name")}
              />
            </Field>
          </>
        )}
        <Field label="Guests" error={errors.guests}>
          <MoneyInput
            name="guests"
            value={form.guests}
            onChange={set("guests")}
          />
        </Field>
        <Field label="Notes" error={errors.notes}>
          <TextArea name="notes" value={form.notes} onChange={set("notes")} />
        </Field>
        <div className="flex gap-2 mt-4">
          <button
            type="submit"
            className="btn btn-primary"
            disabled={saver.pending}
          >
            Save
          </button>
          <Link
            className="btn"
            to={booking ? `/bookings/${booking.id}` : "/bookings"}
          >
            Cancel
          </Link>
        </div>
      </form>
      {booking && (
        <div className="mt-6">
          <ConfirmDelete
            label="Delete booking"
            question="Delete this booking?"
            detail={deleteQuestion(imported)}
            pending={remover.pending}
            onConfirm={() => remover.save()}
          />
        </div>
      )}
    </div>
  );
}

export function BookingNew() {
  return <BookingForm />;
}

export function BookingEdit() {
  const { id } = useParams();
  const booking = useBooking(id);
  if (!booking.data) return <Loading query={booking} />;
  return <BookingForm key={booking.data.id} booking={booking.data} />;
}
