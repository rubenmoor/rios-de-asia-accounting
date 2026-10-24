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
import { DateInput, RateInput, TextField } from "../components/inputs";
import { PageTitle } from "../components/Titles";
import { formatRate } from "../format";
import { useSave } from "../useSave";

type Rate = { date: string; currency: string; rate: number };
type Form = Record<string, string>;

const COLUMNS: Column<Rate>[] = [
  {
    header: "Date",
    cell: (r) => r.date,
    href: (r) => `/rates/${r.date}/${r.currency}`,
  },
  { header: "Currency", cell: (r) => r.currency },
  { header: "COP per unit", cell: (r) => formatRate(r.rate), numeric: true },
];

export function RateList() {
  const [params, setParams] = useSearchParams();
  const currency = params.get("currency") ?? "";
  const [draft, setDraft] = useState(currency);
  const rates = useQuery({
    queryKey: ["rates", currency],
    queryFn: () =>
      api<Rate[]>(
        "GET",
        `/api/rates?${new URLSearchParams(currency ? { currency } : {})}`,
      ),
  });
  const filterErrors =
    rates.error instanceof ApiError ? rates.error.fieldErrors : {};

  const apply = (e: FormEvent) => {
    e.preventDefault();
    setParams(draft ? { currency: draft } : {});
  };

  return (
    <div>
      <PageTitle>Exchange rates</PageTitle>
      <form onSubmit={apply} className="flex flex-wrap items-end gap-2 mb-4">
        <Field label="Currency" error={filterErrors.currency}>
          <TextField name="currency" value={draft} onChange={setDraft} />
        </Field>
        <button type="submit" className="btn">
          Filter
        </button>
        <Link className="btn btn-primary" to="/rates/new">
          New rate
        </Link>
      </form>
      {rates.isError &&
        !(rates.error instanceof ApiError && rates.error.status === 422) && (
          <div role="alert" className="alert alert-error mb-4">
            {rates.error.message}
          </div>
        )}
      <DataTable
        columns={COLUMNS}
        rows={rates.data ?? []}
        rowKey={(r) => `${r.date}/${r.currency}`}
        empty="No exchange rates."
      />
    </div>
  );
}

function RateForm({ rate }: { rate?: Rate }) {
  const [form, setForm] = useState<Form>({
    date: rate?.date ?? "",
    currency: rate?.currency ?? "",
    rate: rate ? formatRate(rate.rate) : "",
  });
  const set = (name: string) => (value: string) =>
    setForm((f) => ({ ...f, [name]: value }));

  const path = rate ? `/api/rates/${rate.date}/${rate.currency}` : "/api/rates";
  const saver = useSave({
    method: rate ? "PUT" : "POST",
    path,
    resource: "rates",
    redirectTo: () => "/rates",
  });
  const remover = useSave({
    method: "DELETE",
    path,
    resource: "rates",
    redirectTo: () => "/rates",
  });
  const { errors } = saver;

  return (
    <div>
      <PageTitle>{rate ? "Edit exchange rate" : "New exchange rate"}</PageTitle>
      <FormError message={errors[""]} />
      <FormSlip label="Exchange rate">
        <form
          onSubmit={(e) => {
            e.preventDefault();
            saver.save(rate ? { rate: form.rate } : form);
          }}
        >
          {rate ? (
            <p className="inked mb-2">
              {rate.date} · {rate.currency}
            </p>
          ) : (
            <>
              <Field label="Date" error={errors.date}>
                <DateInput
                  name="date"
                  value={form.date}
                  onChange={set("date")}
                />
              </Field>
              <Field label="Currency" error={errors.currency}>
                <TextField
                  name="currency"
                  value={form.currency}
                  onChange={set("currency")}
                />
              </Field>
            </>
          )}
          <Field
            label="COP per unit"
            hint="up to 2 decimals after a dot, e.g. 4100.50"
            error={errors.rate}
          >
            <RateInput name="rate" value={form.rate} onChange={set("rate")} />
          </Field>
          <FormActions>
            <button
              type="submit"
              className="btn btn-primary"
              disabled={saver.pending}
            >
              Save
            </button>
            <Link className="btn btn-ghost" to="/rates">
              Cancel
            </Link>
          </FormActions>
        </form>
        {rate && (
          <div className="mt-6 border-t border-base-300 pt-4">
            <ConfirmDelete
              label="Delete rate"
              question="Delete this rate?"
              pending={remover.pending}
              onConfirm={() => remover.save()}
            />
          </div>
        )}
      </FormSlip>
    </div>
  );
}

export function RateNew() {
  return <RateForm />;
}

export function RateEdit() {
  const { day, currency } = useParams();
  // No single-item endpoint: the list filtered by currency.
  const item = useQuery({
    queryKey: ["rates", "one", day, currency],
    queryFn: async () => {
      const rows = await api<Rate[]>(
        "GET",
        `/api/rates?currency=${encodeURIComponent(currency ?? "")}`,
      );
      const found = rows.find((r) => r.date === day);
      if (!found) throw new Error("Exchange rate not found.");
      return found;
    },
  });
  if (item.isError) {
    return (
      <div role="alert" className="alert alert-error">
        {item.error.message}
      </div>
    );
  }
  if (!item.data) return <p className="opacity-70">Loading…</p>;
  return (
    <RateForm
      key={`${item.data.date}/${item.data.currency}`}
      rate={item.data}
    />
  );
}
