import { useQuery } from "@tanstack/react-query";
import { type FormEvent, useState } from "react";
import { Link, useParams, useSearchParams } from "react-router";
import { ApiError, api } from "../api";
import { ConfirmDelete } from "../components/ConfirmDelete";
import { type Column, DataTable } from "../components/DataTable";
import { Field } from "../components/Field";
import { FormActions } from "../components/FormActions";
import { FormError } from "../components/FormError";
import { FormSlip } from "../components/FormSlip";
import { DateInput, Select, TextField } from "../components/inputs";
import { PageTitle } from "../components/Titles";
import { useSave } from "../useSave";

type BlockedDay = { date: string; reason: string; note: string | null };
type Options = { reasons: string[] };
type Form = Record<string, string>;

const COLUMNS: Column<BlockedDay>[] = [
  {
    header: "Date",
    cell: (d) => d.date,
    href: (d) => `/blocked-days/${d.date}`,
  },
  { header: "Reason", cell: (d) => d.reason },
  { header: "Note", cell: (d) => d.note },
];

function useOptions() {
  return useQuery({
    queryKey: ["blocked-days", "options"],
    queryFn: () => api<Options>("GET", "/api/blocked-days/options"),
  });
}

export function BlockedList() {
  const [params, setParams] = useSearchParams();
  const from = params.get("from") ?? "";
  const to = params.get("to") ?? "";
  const [draft, setDraft] = useState({ from, to });
  const query = new URLSearchParams();
  if (from) query.set("from", from);
  if (to) query.set("to", to);
  const days = useQuery({
    queryKey: ["blocked-days", from, to],
    queryFn: () => api<BlockedDay[]>("GET", `/api/blocked-days?${query}`),
  });
  const filterErrors =
    days.error instanceof ApiError ? days.error.fieldErrors : {};

  const apply = (e: FormEvent) => {
    e.preventDefault();
    const next = new URLSearchParams();
    if (draft.from) next.set("from", draft.from);
    if (draft.to) next.set("to", draft.to);
    setParams(next);
  };

  return (
    <div>
      <PageTitle>Blocked days</PageTitle>
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
        <Link className="btn btn-primary" to="/blocked-days/new">
          Block days
        </Link>
      </form>
      {days.isError &&
        !(days.error instanceof ApiError && days.error.status === 422) && (
          <div role="alert" className="alert alert-error mb-4">
            {days.error.message}
          </div>
        )}
      <DataTable
        columns={COLUMNS}
        rows={days.data ?? []}
        rowKey={(d) => d.date}
        empty="No blocked days."
      />
    </div>
  );
}

function BlockedForm({
  day,
  reasons,
}: {
  day?: BlockedDay;
  reasons: string[];
}) {
  const [form, setForm] = useState<Form>({
    from: "",
    to: "",
    reason: day?.reason ?? reasons[0] ?? "",
    note: day?.note ?? "",
  });
  const set = (name: string) => (value: string) =>
    setForm((f) => ({ ...f, [name]: value }));

  const saver = useSave({
    method: day ? "PUT" : "POST",
    path: day ? `/api/blocked-days/${day.date}` : "/api/blocked-days",
    resource: "blocked-days",
    redirectTo: () => "/blocked-days",
  });
  const remover = useSave({
    method: "DELETE",
    path: `/api/blocked-days/${day?.date}`,
    resource: "blocked-days",
    redirectTo: () => "/blocked-days",
  });
  const { errors } = saver;

  return (
    <div>
      <PageTitle>{day ? `Blocked day ${day.date}` : "Block days"}</PageTitle>
      {!day && (
        <p className="opacity-70 mb-4">
          Days that are already blocked are skipped.
        </p>
      )}
      <FormError message={errors[""]} />
      <FormSlip label="Blocked days">
        <form
          onSubmit={(e) => {
            e.preventDefault();
            saver.save(day ? { reason: form.reason, note: form.note } : form);
          }}
        >
          {!day && (
            <>
              <Field label="From" error={errors.from}>
                <DateInput
                  name="from"
                  value={form.from}
                  onChange={set("from")}
                />
              </Field>
              <Field label="To (inclusive)" error={errors.to}>
                <DateInput name="to" value={form.to} onChange={set("to")} />
              </Field>
            </>
          )}
          <Field label="Reason" error={errors.reason}>
            <Select name="reason" value={form.reason} onChange={set("reason")}>
              {reasons.map((r) => (
                <option key={r}>{r}</option>
              ))}
            </Select>
          </Field>
          <Field label="Note" error={errors.note}>
            <TextField
              name="note"
              value={form.note}
              onChange={set("note")}
              className="w-full"
            />
          </Field>
          <FormActions>
            <button
              type="submit"
              className="btn btn-primary"
              disabled={saver.pending}
            >
              {day ? "Save" : "Block"}
            </button>
            <Link className="btn btn-ghost" to="/blocked-days">
              Cancel
            </Link>
          </FormActions>
        </form>
        {day && (
          <div className="mt-6 border-t border-base-300 pt-4">
            <ConfirmDelete
              label="Delete blocked day"
              question="Unblock this day?"
              pending={remover.pending}
              onConfirm={() => remover.save()}
            />
          </div>
        )}
      </FormSlip>
    </div>
  );
}

export function BlockedNew() {
  const options = useOptions();
  if (options.isError) {
    return (
      <div role="alert" className="alert alert-error">
        {options.error.message}
      </div>
    );
  }
  if (!options.data) return <p className="opacity-70">Loading…</p>;
  return <BlockedForm reasons={options.data.reasons} />;
}

export function BlockedEdit() {
  const { day } = useParams();
  const options = useOptions();
  // No single-item endpoint: the list filtered to that one day.
  const item = useQuery({
    queryKey: ["blocked-days", "day", day],
    queryFn: async () => {
      const rows = await api<BlockedDay[]>(
        "GET",
        `/api/blocked-days?from=${day}&to=${day}`,
      );
      const found = rows.find((d) => d.date === day);
      if (!found) throw new Error("Blocked day not found.");
      return found;
    },
  });
  const error = item.error ?? options.error;
  if (error) {
    return (
      <div role="alert" className="alert alert-error">
        {error.message}
      </div>
    );
  }
  if (!item.data || !options.data) {
    return <p className="opacity-70">Loading…</p>;
  }
  return (
    <BlockedForm
      key={item.data.date}
      day={item.data}
      reasons={options.data.reasons}
    />
  );
}
