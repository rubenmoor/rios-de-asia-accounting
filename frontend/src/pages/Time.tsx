import { useQuery } from "@tanstack/react-query";
import { type FormEvent, useState } from "react";
import { Link, useParams, useSearchParams } from "react-router";
import { ApiError, api } from "../api";
import { ConfirmDelete } from "../components/ConfirmDelete";
import { type Column, DataTable } from "../components/DataTable";
import { Field } from "../components/Field";
import { DateInput, HoursInput, Select, TextField } from "../components/inputs";
import { formatHours, showHours } from "../format";
import { useSave } from "../useSave";

type TimeEntry = {
  id: number;
  date: string;
  minutes: number;
  booking_id: number | null;
  description: string;
};
type TimeOptions = { bookings: { id: number; label: string }[] };

const COLUMNS: Column<TimeEntry>[] = [
  {
    header: "Date",
    cell: (e) => e.date,
    href: (e) => `/time/${e.id}/edit`,
  },
  { header: "Description", cell: (e) => e.description },
  { header: "Hours", cell: (e) => showHours(e.minutes), numeric: true },
];

export function TimeList() {
  const [params, setParams] = useSearchParams();
  const from = params.get("from") ?? "";
  const to = params.get("to") ?? "";
  const [draft, setDraft] = useState({ from, to });
  const query = new URLSearchParams();
  if (from) query.set("from", from);
  if (to) query.set("to", to);
  const entries = useQuery({
    queryKey: ["time", from, to],
    queryFn: () => api<TimeEntry[]>("GET", `/api/time?${query}`),
  });
  const filterErrors =
    entries.error instanceof ApiError ? entries.error.fieldErrors : {};

  const apply = (e: FormEvent) => {
    e.preventDefault();
    const next = new URLSearchParams();
    if (draft.from) next.set("from", draft.from);
    if (draft.to) next.set("to", draft.to);
    setParams(next);
  };

  const rows = entries.data ?? [];
  const total = rows.reduce((sum, e) => sum + e.minutes, 0);

  return (
    <div>
      <h1 className="text-2xl font-bold mb-4">Time</h1>
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
        <button type="submit" className="btn">
          Filter
        </button>
        <Link className="btn btn-primary" to="/time/new">
          New time entry
        </Link>
      </form>
      {entries.isError &&
        !(
          entries.error instanceof ApiError && entries.error.status === 422
        ) && (
          <div role="alert" className="alert alert-error mb-4">
            {entries.error.message}
          </div>
        )}
      <DataTable
        columns={COLUMNS}
        rows={rows}
        rowKey={(e) => e.id}
        empty="No time entries."
        footer={
          <tr>
            <th colSpan={2}>Total</th>
            <th className="text-right">{showHours(total)}</th>
          </tr>
        }
      />
    </div>
  );
}

type Form = Record<string, string>;

function TimeForm({ entry }: { entry?: TimeEntry }) {
  const options = useQuery({
    queryKey: ["time", "options"],
    queryFn: () => api<TimeOptions>("GET", "/api/time/options"),
  });
  const [form, setForm] = useState<Form>({
    date: entry?.date ?? "",
    hours: entry ? formatHours(entry.minutes) : "",
    booking_id: entry?.booking_id != null ? String(entry.booking_id) : "",
    description: entry?.description ?? "",
  });
  const set = (name: string) => (value: string) =>
    setForm((f) => ({ ...f, [name]: value }));

  const saver = useSave({
    method: entry ? "PUT" : "POST",
    path: entry ? `/api/time/${entry.id}` : "/api/time",
    resource: "time",
    redirectTo: () => "/time",
  });
  const remover = useSave({
    method: "DELETE",
    path: `/api/time/${entry?.id}`,
    resource: "time",
    redirectTo: () => "/time",
  });
  const { errors } = saver;

  return (
    <div>
      <h1 className="text-2xl font-bold mb-4">
        {entry ? "Edit time entry" : "New time entry"}
      </h1>
      <form
        className="max-w-lg"
        onSubmit={(e) => {
          e.preventDefault();
          saver.save(form);
        }}
      >
        {errors[""] && (
          <div role="alert" className="alert alert-error mb-4">
            {errors[""]}
          </div>
        )}
        <Field label="Date" error={errors.date}>
          <DateInput name="date" value={form.date} onChange={set("date")} />
        </Field>
        <Field label="Hours" hint="1.5, 1,5 or 1:30" error={errors.hours}>
          <HoursInput name="hours" value={form.hours} onChange={set("hours")} />
        </Field>
        <Field label="Booking" hint="optional" error={errors.booking_id}>
          <Select
            name="booking_id"
            value={form.booking_id}
            onChange={set("booking_id")}
          >
            <option value="">–</option>
            {options.data?.bookings.map((b) => (
              <option key={b.id} value={String(b.id)}>
                {b.label}
              </option>
            ))}
          </Select>
        </Field>
        <Field label="Description" error={errors.description}>
          <TextField
            name="description"
            value={form.description}
            onChange={set("description")}
            className="w-full"
          />
        </Field>
        <div className="flex gap-2 mt-4">
          <button
            type="submit"
            className="btn btn-primary"
            disabled={saver.pending}
          >
            Save
          </button>
          <Link className="btn" to="/time">
            Cancel
          </Link>
        </div>
      </form>
      {entry && (
        <div className="mt-6">
          <ConfirmDelete
            label="Delete time entry"
            question="Delete this time entry?"
            pending={remover.pending}
            onConfirm={() => remover.save()}
          />
        </div>
      )}
    </div>
  );
}

export function TimeNew() {
  return <TimeForm />;
}

export function TimeEdit() {
  const { id } = useParams();
  const entry = useQuery({
    queryKey: ["time", id],
    queryFn: () => api<TimeEntry>("GET", `/api/time/${id}`),
  });
  if (entry.isError) {
    return (
      <div role="alert" className="alert alert-error">
        {entry.error.message}
      </div>
    );
  }
  if (!entry.data) return <p className="opacity-70">Loading…</p>;
  return <TimeForm key={entry.data.id} entry={entry.data} />;
}
