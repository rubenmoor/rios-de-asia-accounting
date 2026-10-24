import { useQuery } from "@tanstack/react-query";
import { type FormEvent, useState } from "react";
import { Link, useParams, useSearchParams } from "react-router";
import { ApiError, api } from "../api";
import { ConfirmDelete } from "../components/ConfirmDelete";
import {
  type Column,
  DataTable,
  SheetFooterRow,
} from "../components/DataTable";
import { Field } from "../components/Field";
import { FormActions } from "../components/FormActions";
import { FormError } from "../components/FormError";
import { FormSlip } from "../components/FormSlip";
import {
  DateInput,
  MoneyInput,
  MonthInput,
  Select,
  TextField,
} from "../components/inputs";
import { PageTitle, SectionTitle } from "../components/Titles";
import { Toolbar, ToolbarField } from "../components/Toolbar";
import { formatMoney, showMoney } from "../format";
import { useSave } from "../useSave";

type Expense = {
  id: number;
  date: string;
  amount: number;
  category: string;
  booking_id: number | null;
  useful_life_days: number | null;
  description: string;
  recurring_expense_id: number | null;
};
type ExpenseOptions = {
  categories: string[];
  bookings: { id: number; label: string }[];
};
type Recurring = {
  id: number;
  description: string;
  amount: number;
  category: string;
  start_month: string;
  end_month: string | null;
};
type RecurringDetail = Recurring & { generated: Expense[] };

type Form = Record<string, string>;

function Loaded<T>({
  query,
  children,
}: {
  query: { data?: T; isError: boolean; error: Error | null };
  children: (data: T) => React.ReactNode;
}) {
  if (query.isError) {
    return (
      <div role="alert" className="alert alert-error">
        {query.error?.message}
      </div>
    );
  }
  if (!query.data) return <p className="opacity-70">Loading…</p>;
  return <>{children(query.data)}</>;
}

const EXPENSE_COLUMNS: Column<Expense>[] = [
  {
    header: "Date",
    cell: (e) => e.date,
    href: (e) => `/expenses/${e.id}/edit`,
  },
  { header: "Category", cell: (e) => e.category },
  { header: "Description", cell: (e) => e.description },
  { header: "Amount", cell: (e) => showMoney(e.amount), numeric: true },
  {
    header: "Source",
    cell: (e) => (e.recurring_expense_id != null ? "generated" : ""),
  },
];

export function ExpenseList() {
  const [params, setParams] = useSearchParams();
  const from = params.get("from") ?? "";
  const to = params.get("to") ?? "";
  const category = params.get("category") ?? "";
  const [draft, setDraft] = useState({ from, to, category });
  const query = new URLSearchParams();
  if (from) query.set("from", from);
  if (to) query.set("to", to);
  if (category) query.set("category", category);
  const expenses = useQuery({
    queryKey: ["expenses", from, to, category],
    queryFn: () => api<Expense[]>("GET", `/api/expenses?${query}`),
  });
  const options = useQuery({
    queryKey: ["expenses", "options"],
    queryFn: () => api<ExpenseOptions>("GET", "/api/expenses/options"),
  });
  const filterErrors =
    expenses.error instanceof ApiError ? expenses.error.fieldErrors : {};

  const apply = (e: FormEvent) => {
    e.preventDefault();
    const next = new URLSearchParams();
    if (draft.from) next.set("from", draft.from);
    if (draft.to) next.set("to", draft.to);
    if (draft.category) next.set("category", draft.category);
    setParams(next);
  };

  const rows = expenses.data ?? [];
  const total = rows.reduce((sum, e) => sum + e.amount, 0);

  return (
    <div>
      <PageTitle>Expenses</PageTitle>
      <Toolbar
        onSubmit={apply}
        errors={[filterErrors.from, filterErrors.to, filterErrors.category]}
        action={
          <Link className="btn btn-primary btn-sm" to="/expenses/new">
            New expense
          </Link>
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
        <ToolbarField label="Category">
          <Select
            className="select-sm"
            name="category"
            value={draft.category}
            onChange={(v) => setDraft({ ...draft, category: v })}
          >
            <option value="">all</option>
            {options.data?.categories.map((c) => (
              <option key={c}>{c}</option>
            ))}
          </Select>
        </ToolbarField>
        <button type="submit" className="btn btn-secondary btn-sm">
          Filter
        </button>
      </Toolbar>
      {expenses.isError &&
        !(
          expenses.error instanceof ApiError && expenses.error.status === 422
        ) && (
          <div role="alert" className="alert alert-error mb-4">
            {expenses.error.message}
          </div>
        )}
      <DataTable
        columns={EXPENSE_COLUMNS}
        rows={rows}
        rowKey={(e) => e.id}
        empty="No expenses."
        footer={
          <SheetFooterRow>
            <th colSpan={3}>Total</th>
            <th className="num">{showMoney(total)}</th>
            <th />
          </SheetFooterRow>
        }
      />
    </div>
  );
}

function ExpenseForm({
  expense,
  options,
}: {
  expense?: Expense;
  options: ExpenseOptions;
}) {
  const [form, setForm] = useState<Form>({
    date: expense?.date ?? "",
    amount: expense ? formatMoney(expense.amount) : "",
    category: expense?.category ?? options.categories[0] ?? "",
    booking_id: expense?.booking_id != null ? String(expense.booking_id) : "",
    useful_life_days:
      expense?.useful_life_days != null ? String(expense.useful_life_days) : "",
    description: expense?.description ?? "",
  });
  const set = (name: string) => (value: string) =>
    setForm((f) => ({ ...f, [name]: value }));

  const saver = useSave({
    method: expense ? "PUT" : "POST",
    path: expense ? `/api/expenses/${expense.id}` : "/api/expenses",
    resource: "expenses",
    redirectTo: () => "/expenses",
  });
  const remover = useSave({
    method: "DELETE",
    path: `/api/expenses/${expense?.id}`,
    resource: "expenses",
    redirectTo: () => "/expenses",
  });
  const { errors } = saver;

  return (
    <div>
      <PageTitle>{expense ? "Edit expense" : "New expense"}</PageTitle>
      {expense?.recurring_expense_id != null && (
        <p className="opacity-70 mb-4">
          Generated from a{" "}
          <Link
            className="link"
            to={`/recurring/${expense.recurring_expense_id}`}
          >
            recurring expense
          </Link>
          ; your edits are kept.
        </p>
      )}
      <FormError message={errors[""]} />
      <FormSlip label="Expense">
        <form
          onSubmit={(e) => {
            e.preventDefault();
            saver.save(form);
          }}
        >
          <Field label="Date" error={errors.date}>
            <DateInput name="date" value={form.date} onChange={set("date")} />
          </Field>
          <Field label="Amount (COP)" error={errors.amount}>
            <MoneyInput
              name="amount"
              value={form.amount}
              onChange={set("amount")}
            />
          </Field>
          <Field label="Category" error={errors.category}>
            <Select
              name="category"
              value={form.category}
              onChange={set("category")}
            >
              {options.categories.map((c) => (
                <option key={c}>{c}</option>
              ))}
            </Select>
          </Field>
          {form.category === "per_booking" && (
            <Field
              label="Booking"
              hint="only for per_booking"
              error={errors.booking_id}
            >
              <Select
                name="booking_id"
                value={form.booking_id}
                onChange={set("booking_id")}
              >
                <option value="">–</option>
                {options.bookings.map((b) => (
                  <option key={b.id} value={String(b.id)}>
                    {b.label}
                  </option>
                ))}
              </Select>
            </Field>
          )}
          {form.category === "capex" && (
            <Field
              label="Useful life in days"
              hint="only for capex; 3 years ≈ 1095"
              error={errors.useful_life_days}
            >
              <MoneyInput
                name="useful_life_days"
                value={form.useful_life_days}
                onChange={set("useful_life_days")}
              />
            </Field>
          )}
          <Field label="Description" error={errors.description}>
            <TextField
              name="description"
              value={form.description}
              onChange={set("description")}
              className="w-full"
            />
          </Field>
          <FormActions>
            <button
              type="submit"
              className="btn btn-primary"
              disabled={saver.pending}
            >
              Save
            </button>
            <Link className="btn btn-ghost" to="/expenses">
              Cancel
            </Link>
          </FormActions>
        </form>
        {expense && (
          <div className="mt-6 border-t border-base-300 pt-4">
            <ConfirmDelete
              label="Delete expense"
              question="Delete this expense?"
              pending={remover.pending}
              onConfirm={() => remover.save()}
            />
          </div>
        )}
      </FormSlip>
    </div>
  );
}

function useExpenseOptions() {
  return useQuery({
    queryKey: ["expenses", "options"],
    queryFn: () => api<ExpenseOptions>("GET", "/api/expenses/options"),
  });
}

export function ExpenseNew() {
  const options = useExpenseOptions();
  return <Loaded query={options}>{(o) => <ExpenseForm options={o} />}</Loaded>;
}

export function ExpenseEdit() {
  const { id } = useParams();
  const options = useExpenseOptions();
  const expense = useQuery({
    queryKey: ["expenses", id],
    queryFn: () => api<Expense>("GET", `/api/expenses/${id}`),
  });
  return (
    <Loaded query={expense}>
      {(e) => (
        <Loaded query={options}>
          {(o) => <ExpenseForm key={e.id} expense={e} options={o} />}
        </Loaded>
      )}
    </Loaded>
  );
}

const RECURRING_COLUMNS: Column<Recurring>[] = [
  {
    header: "Description",
    cell: (t) => t.description,
    href: (t) => `/recurring/${t.id}`,
  },
  { header: "Category", cell: (t) => t.category },
  { header: "Amount / month", cell: (t) => showMoney(t.amount), numeric: true },
  { header: "From", cell: (t) => t.start_month },
  { header: "Until", cell: (t) => t.end_month ?? "open" },
];

export function RecurringList() {
  const items = useQuery({
    queryKey: ["recurring"],
    queryFn: () => api<Recurring[]>("GET", "/api/recurring"),
  });
  return (
    <div>
      <PageTitle>Recurring expenses</PageTitle>
      <p className="mb-4">
        <Link className="btn btn-primary" to="/recurring/new">
          New recurring expense
        </Link>
      </p>
      <Loaded query={items}>
        {(rows) => (
          <DataTable
            columns={RECURRING_COLUMNS}
            rows={rows}
            rowKey={(t) => t.id}
            empty="No recurring expenses."
          />
        )}
      </Loaded>
    </div>
  );
}

const GENERATED_COLUMNS: Column<Expense>[] = [
  {
    header: "Date",
    cell: (e) => e.date,
    href: (e) => `/expenses/${e.id}/edit`,
  },
  { header: "Amount", cell: (e) => showMoney(e.amount), numeric: true },
];

function RecurringForm({
  item,
  categories,
}: {
  item?: RecurringDetail;
  categories: string[];
}) {
  const [form, setForm] = useState<Form>({
    description: item?.description ?? "",
    amount: item ? formatMoney(item.amount) : "",
    category: item?.category ?? categories[0] ?? "",
    start_month: item?.start_month ?? "",
    end_month: item?.end_month ?? "",
  });
  const set = (name: string) => (value: string) =>
    setForm((f) => ({ ...f, [name]: value }));

  const saver = useSave<RecurringDetail>({
    method: item ? "PUT" : "POST",
    path: item ? `/api/recurring/${item.id}` : "/api/recurring",
    resource: "recurring",
    redirectTo: (saved) => `/recurring/${saved.id}`,
  });
  const remover = useSave({
    method: "DELETE",
    path: `/api/recurring/${item?.id}`,
    resource: "recurring",
    redirectTo: () => "/recurring",
  });
  const { errors } = saver;

  return (
    <div>
      <PageTitle>
        {item ? "Edit recurring expense" : "New recurring expense"}
      </PageTitle>
      {item && (
        <p className="opacity-70 mb-4">
          Changes only affect months not generated yet; the expenses below stay
          as they are and are edited one by one.
        </p>
      )}
      <FormError message={errors[""]} />
      <FormSlip label="Recurring expense">
        <form
          onSubmit={(e) => {
            e.preventDefault();
            saver.save(form);
          }}
        >
          <Field label="Description" error={errors.description}>
            <TextField
              name="description"
              value={form.description}
              onChange={set("description")}
              className="w-full"
            />
          </Field>
          <Field label="Amount per month (COP)" error={errors.amount}>
            <MoneyInput
              name="amount"
              value={form.amount}
              onChange={set("amount")}
            />
          </Field>
          <Field label="Category" error={errors.category}>
            <Select
              name="category"
              value={form.category}
              onChange={set("category")}
            >
              {categories.map((c) => (
                <option key={c}>{c}</option>
              ))}
            </Select>
          </Field>
          <Field label="Start month" error={errors.start_month}>
            <MonthInput
              name="start_month"
              value={form.start_month}
              onChange={set("start_month")}
            />
          </Field>
          <Field label="End month" hint="optional" error={errors.end_month}>
            <MonthInput
              name="end_month"
              value={form.end_month}
              onChange={set("end_month")}
            />
          </Field>
          <FormActions>
            <button
              type="submit"
              className="btn btn-primary"
              disabled={saver.pending}
            >
              Save
            </button>
            <Link className="btn btn-ghost" to="/recurring">
              Cancel
            </Link>
          </FormActions>
        </form>
        {item && (
          <div className="mt-6 border-t border-base-300 pt-4">
            <ConfirmDelete
              label="Delete template"
              question="Delete this template? Its generated expenses are kept."
              pending={remover.pending}
              onConfirm={() => remover.save()}
            />
          </div>
        )}
      </FormSlip>
      {item && (
        <>
          <SectionTitle className="mt-6 mb-2">Generated expenses</SectionTitle>
          <DataTable
            columns={GENERATED_COLUMNS}
            rows={item.generated}
            rowKey={(e) => e.id}
            empty="None yet."
          />
        </>
      )}
    </div>
  );
}

function useRecurringOptions() {
  return useQuery({
    queryKey: ["recurring", "options"],
    queryFn: () =>
      api<{ categories: string[] }>("GET", "/api/recurring/options"),
  });
}

export function RecurringNew() {
  const options = useRecurringOptions();
  return (
    <Loaded query={options}>
      {(o) => <RecurringForm categories={o.categories} />}
    </Loaded>
  );
}

export function RecurringEdit() {
  const { id } = useParams();
  const options = useRecurringOptions();
  const item = useQuery({
    queryKey: ["recurring", id],
    queryFn: () => api<RecurringDetail>("GET", `/api/recurring/${id}`),
  });
  return (
    <Loaded query={item}>
      {(t) => (
        <Loaded query={options}>
          {(o) => (
            <RecurringForm key={t.id} item={t} categories={o.categories} />
          )}
        </Loaded>
      )}
    </Loaded>
  );
}
