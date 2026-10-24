import { useQuery } from "@tanstack/react-query";
import { type FormEvent, useEffect, useState } from "react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router";
import { ApiError, api } from "../api";
import { AirbnbImport } from "../components/AirbnbImport";
import { ConfirmDelete } from "../components/ConfirmDelete";
import { type Column, DataTable } from "../components/DataTable";
import { Field } from "../components/Field";
import { FormActions } from "../components/FormActions";
import { FormError } from "../components/FormError";
import { FormSlip } from "../components/FormSlip";
import { BookingsIcon } from "../components/icons";
import {
  AmountInput,
  DateInput,
  NumberInput,
  Select,
  TextArea,
  TextField,
} from "../components/inputs";
import { useNotices } from "../components/Notices";
import { PageTitle, SectionTitle } from "../components/Titles";
import { Toolbar, ToolbarField } from "../components/Toolbar";
import { WaitingNotice } from "../components/WaitingNotice";
import { DASH, formatAmount, showOriginal } from "../format";
import { useDisplay } from "../useDisplay";
import { useSave } from "../useSave";

type Summary = {
  id: number;
  check_in: string;
  check_out: string;
  guest_name: string;
  listing: string;
  nights: number;
  net_payout: number | null;
  waiting: boolean;
};
type Line = {
  date: string;
  type: string;
  currency: string;
  amount_minor: number;
  amount_usd: number | null;
  rate: number | null;
  rate_date: string | null;
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
  manual_currency: string | null;
  lines: Line[];
};
type Options = { listings: string[]; default_currency: string };

type Money = (cents: number | null) => string;

const dash = (text: string | number | null | undefined) =>
  text === null || text === undefined || text === "" ? "-" : String(text);

const columns = (currency: string, money: Money): Column<Summary>[] => [
  {
    header: "Check-in",
    cell: (b) => b.check_in,
    href: (b) => `/bookings/${b.id}`,
  },
  { header: "Check-out", cell: (b) => b.check_out },
  { header: "Guest", cell: (b) => dash(b.guest_name) },
  { header: "Listing", cell: (b) => dash(b.listing) },
  { header: "Nights", cell: (b) => b.nights, numeric: true },
  {
    header: `Net payout (${currency})`,
    cell: (b) =>
      b.waiting ? (
        <span className="text-warning">waiting for rate</span>
      ) : (
        money(b.net_payout)
      ),
    numeric: true,
  },
];

function useOptions() {
  return useQuery({
    queryKey: ["bookings", "options"],
    queryFn: () => api<Options>("GET", "/api/bookings/options"),
  });
}

export function BookingList() {
  const { currency, money } = useDisplay();
  const [params, setParams] = useSearchParams();
  const from = params.get("from") ?? "";
  const to = params.get("to") ?? "";
  const listing = params.get("listing") ?? "";
  const [draft, setDraft] = useState({ from, to, listing });
  const [importing, setImporting] = useState(false);
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
      <PageTitle icon={<BookingsIcon />}>Bookings</PageTitle>
      <p className="mb-3 text-sm opacity-70">
        Airbnb stays come in through the CSV export (Import CSV); adding one by
        hand is only for stays booked elsewhere.
      </p>
      <Toolbar
        onSubmit={apply}
        errors={[filterErrors.from, filterErrors.to]}
        action={
          <>
            <button
              type="button"
              className="btn btn-secondary btn-sm"
              disabled={importing}
              onClick={() => setImporting(true)}
            >
              Import CSV
            </button>
            <Link className="btn btn-primary btn-sm" to="/bookings/new">
              Add a stay booked outside Airbnb
            </Link>
          </>
        }
      >
        <ToolbarField label="From">
          <DateInput
            className="input-sm"
            name="from"
            value={draft.from}
            onChange={(v) => setDraft({ ...draft, from: v })}
          />
        </ToolbarField>
        <ToolbarField label="To">
          <DateInput
            className="input-sm"
            name="to"
            value={draft.to}
            onChange={(v) => setDraft({ ...draft, to: v })}
          />
        </ToolbarField>
        <ToolbarField label="Listing">
          <Select
            className="select-sm"
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
        </ToolbarField>
        <button type="submit" className="btn btn-secondary btn-sm">
          Filter
        </button>
      </Toolbar>
      {importing && <AirbnbImport onClose={() => setImporting(false)} />}
      <WaitingNotice />
      {bookings.isError && !invalid && (
        <div role="alert" className="alert alert-error mb-4">
          {bookings.error.message}
        </div>
      )}
      <DataTable
        columns={columns(currency, money)}
        rows={bookings.data ?? []}
        rowKey={(b) => b.id}
        empty="No bookings."
      />
    </div>
  );
}

const lineColumns = (currency: string, money: Money): Column<Line>[] => [
  { header: "Date", cell: (l) => l.date },
  { header: "Type", cell: (l) => l.type },
  {
    header: "Original",
    cell: (l) => showOriginal(l.amount_minor, l.currency),
    numeric: true,
    negative: (l) => l.amount_minor < 0,
  },
  {
    header: "Rate (per USD)",
    cell: (l) =>
      l.currency === "USD"
        ? DASH
        : l.rate === null
          ? DASH
          : `${formatAmount(Math.round(l.rate / 10_000))} on ${l.rate_date}`,
    numeric: true,
  },
  {
    header: currency,
    cell: (l) =>
      l.amount_usd === null ? (
        <span className="text-warning">waiting for rate</span>
      ) : (
        money(l.amount_usd)
      ),
    numeric: true,
    negative: (l) => l.amount_usd !== null && l.amount_usd < 0,
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
  const { currency, money } = useDisplay();
  const { id } = useParams();
  const booking = useBooking(id);
  if (!booking.data) return <Loading query={booking} />;
  const b = booking.data;
  const row = (label: string, v: number | null) => (
    <tr>
      <th>{label}</th>
      <td className="num">{v === null ? "–" : `${money(v)} ${currency}`}</td>
    </tr>
  );
  return (
    <div>
      <PageTitle icon={<BookingsIcon />}>
        Booking {b.check_in} – {b.check_out}
      </PageTitle>
      {b.waiting && <WaitingNotice />}
      <div className="overflow-x-auto">
        <table className="table sheet w-auto">
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
            {row("Net payout", b.net_payout)}
            {row("Gross", b.gross)}
            {row("Airbnb fee", b.airbnb_fee)}
            {row("Co-host cost", b.cohost_cost)}
          </tbody>
        </table>
      </div>
      <SectionTitle className="mt-6 mb-2">Lines</SectionTitle>
      <DataTable
        columns={lineColumns(currency, money)}
        rows={b.lines}
        rowKey={(l) => `${l.date}${l.type}${l.currency}${l.amount_minor}`}
        empty="No lines."
      />
      <FormActions>
        <Link className="btn btn-primary" to={`/bookings/${b.id}/edit`}>
          Edit
        </Link>
        <Link className="btn btn-ghost" to="/bookings">
          Back to bookings
        </Link>
      </FormActions>
    </div>
  );
}

type Form = Record<string, string>;

function BookingForm({ booking }: { booking?: Detail }) {
  const { currency, money } = useDisplay();
  const imported = booking?.imported ?? false;
  const options = useOptions();
  const navigate = useNavigate();
  const { setNotices } = useNotices();
  const [form, setForm] = useState<Form>({
    check_in: booking?.check_in ?? "",
    check_out: booking?.check_out ?? "",
    amount:
      booking?.manual_amount != null
        ? formatAmount(booking.manual_amount, booking.manual_currency ?? "USD")
        : "",
    currency:
      booking?.manual_currency ?? options.data?.default_currency ?? "USD",
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
      <PageTitle icon={<BookingsIcon />}>
        {booking ? "Edit booking" : "Add a stay booked outside Airbnb"}
      </PageTitle>
      {imported && (
        <p className="mb-4 opacity-70">
          Imported from Airbnb: dates, listing, guest name and amounts are
          read-only; only guests and notes can change.
        </p>
      )}
      <FormError message={errors[""]} />
      <FormSlip label="Booking">
        <form
          onSubmit={(e) => {
            e.preventDefault();
            saver.save(body);
          }}
        >
          {booking && imported ? (
            <p className="inked mb-2">
              {booking.check_in} – {booking.check_out} ·{" "}
              {dash(booking.guest_name)} · {dash(booking.listing)} ·{" "}
              {money(booking.net_payout)} {currency}
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
              <Field label="Net payout" error={errors.amount}>
                <AmountInput
                  name="amount"
                  value={form.amount}
                  currency={form.currency}
                  onChange={set("amount")}
                  onCurrencyChange={set("currency")}
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
            <NumberInput
              name="guests"
              value={form.guests}
              onChange={set("guests")}
            />
          </Field>
          <Field label="Notes" error={errors.notes}>
            <TextArea name="notes" value={form.notes} onChange={set("notes")} />
          </Field>
          <FormActions>
            <button
              type="submit"
              className="btn btn-primary"
              disabled={saver.pending}
            >
              Save
            </button>
            <Link
              className="btn btn-ghost"
              to={booking ? `/bookings/${booking.id}` : "/bookings"}
            >
              Cancel
            </Link>
          </FormActions>
        </form>
        {booking && (
          <div className="mt-6 border-t border-base-300 pt-4">
            <ConfirmDelete
              label="Delete booking"
              question="Delete this booking?"
              detail={deleteQuestion(imported)}
              pending={remover.pending}
              onConfirm={() => remover.save()}
            />
          </div>
        )}
      </FormSlip>
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
