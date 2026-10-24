import { useQuery } from "@tanstack/react-query";
import { type FormEvent, useState } from "react";
import { Link, useParams, useSearchParams } from "react-router";
import { ApiError, api } from "../api";
import { AmountCell } from "../components/AmountCell";
import { ConfirmDelete } from "../components/ConfirmDelete";
import {
  type Column,
  DataTable,
  SheetEntryRow,
  SheetFooterRow,
} from "../components/DataTable";
import { FieldError } from "../components/FieldError";
import { ExpensesIcon, RecurringIcon } from "../components/icons";
import {
  AmountInput,
  DateInput,
  MonthInput,
  NumberInput,
  Select,
  TextField,
} from "../components/inputs";
import { PageTitle, SectionTitle } from "../components/Titles";
import { Toolbar, ToolbarField } from "../components/Toolbar";
import { WaitingNotice } from "../components/WaitingNotice";
import { formatAmount, showOriginal } from "../format";
import { useDisplay } from "../useDisplay";
import { useSave } from "../useSave";

type Expense = {
  id: number;
  date: string;
  amount: number | null;
  original_minor: number;
  currency: string;
  rate: number | null;
  rate_date: string | null;
  category: string;
  booking_id: number | null;
  useful_life_days: number | null;
  description: string;
  recurring_expense_id: number | null;
};
type ExpenseOptions = {
  categories: string[];
  bookings: { id: number; label: string }[];
  default_currency: string;
};
type Recurring = {
  id: number;
  description: string;
  amount_minor: number;
  currency: string;
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

const expenseColumns = (currency: string): Column<Expense>[] => [
  { header: "Date", cell: (e) => e.date },
  { header: "Category", cell: (e) => e.category },
  { header: "Description", cell: (e) => e.description },
  {
    header: `Amount (${currency})`,
    cell: (e) => <AmountCell e={e} />,
    numeric: true,
  },
  {
    header: "Source",
    cell: (e) =>
      e.recurring_expense_id != null ? (
        <Link className="link" to={`/recurring/${e.recurring_expense_id}`}>
          generated
        </Link>
      ) : (
        ""
      ),
  },
];

// What is open in a sheet: a new entry, the row with this id, or nothing.
type Open = "new" | number | null;

export function ExpenseList() {
  const { currency, money } = useDisplay();
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
  const options = useExpenseOptions();
  const [open, setOpen] = useState<Open>(null);
  const close = () => setOpen(null);
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
  const total = rows.reduce((sum, e) => sum + (e.amount ?? 0), 0);

  return (
    <div>
      <PageTitle icon={<ExpensesIcon />}>Expenses</PageTitle>
      <Toolbar
        onSubmit={apply}
        errors={[filterErrors.from, filterErrors.to, filterErrors.category]}
        action={
          <button
            type="button"
            className="btn btn-primary btn-sm btn-square"
            aria-label="Add expense"
            title="Add expense"
            disabled={open !== null}
            onClick={() => setOpen("new")}
          >
            +
          </button>
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
      <WaitingNotice />
      {expenses.isError &&
        !(
          expenses.error instanceof ApiError && expenses.error.status === 422
        ) && (
          <div role="alert" className="alert alert-error mb-4">
            {expenses.error.message}
          </div>
        )}
      <DataTable
        columns={expenseColumns(currency)}
        rows={rows}
        rowKey={(e) => e.id}
        empty="No expenses."
        onEdit={
          open === null && options.data ? (e) => setOpen(e.id) : undefined
        }
        editing={open}
        editRow={(e) =>
          options.data && (
            <ExpenseEntryRow
              expense={e}
              options={options.data}
              onClose={close}
            />
          )
        }
        entry={
          open === "new" &&
          options.data && (
            <ExpenseEntryRow options={options.data} onClose={close} />
          )
        }
        footer={
          <SheetFooterRow>
            <th colSpan={3}>Total</th>
            <th className="num total">{money(total)}</th>
            <th />
          </SheetFooterRow>
        }
      />
    </div>
  );
}

// Today as YYYY-MM-DD in local time (toISOString would give the UTC day).
function localToday() {
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

const ENTRY_FORM = "expense-entry";

// The row for typing an expense: empty (today) to add, prefilled to edit.
function ExpenseEntryRow({
  expense,
  options,
  onClose,
}: {
  expense?: Expense;
  options: ExpenseOptions;
  onClose: () => void;
}) {
  const [form, setForm] = useState<Form>(
    expense
      ? {
          date: expense.date,
          amount: formatAmount(expense.original_minor, expense.currency),
          currency: expense.currency,
          category: expense.category,
          booking_id:
            expense.booking_id != null ? String(expense.booking_id) : "",
          useful_life_days:
            expense.useful_life_days != null
              ? String(expense.useful_life_days)
              : "",
          description: expense.description,
        }
      : {
          date: localToday(),
          amount: "",
          currency: options.default_currency,
          category: options.categories[0] ?? "",
          booking_id: "",
          useful_life_days: "",
          description: "",
        },
  );
  const set = (name: string) => (value: string) =>
    setForm((f) => ({ ...f, [name]: value }));
  const saver = useSave({
    method: expense ? "PUT" : "POST",
    path: expense ? `/api/expenses/${expense.id}` : "/api/expenses",
    resource: "expenses",
    onSaved: onClose,
  });
  const remover = useSave({
    method: "DELETE",
    path: `/api/expenses/${expense?.id}`,
    resource: "expenses",
    onSaved: onClose,
  });
  const { errors } = saver;
  const err = (name: string) =>
    errors[name] && <FieldError small>{errors[name]}</FieldError>;
  const generated = expense?.recurring_expense_id != null;

  return (
    <SheetEntryRow mark={expense ? "✎" : "+"} onEscape={onClose}>
      <td>
        <form
          id={ENTRY_FORM}
          onSubmit={(e) => {
            e.preventDefault();
            saver.save(form);
          }}
        />
        <DateInput
          className="input-sm"
          name="date"
          form={ENTRY_FORM}
          ariaLabel="Date"
          value={form.date}
          onChange={set("date")}
        />
        {err("date")}
      </td>
      <td>
        <Select
          className="select-sm"
          name="category"
          form={ENTRY_FORM}
          ariaLabel="Category"
          value={form.category}
          onChange={set("category")}
        >
          {options.categories.map((c) => (
            <option key={c}>{c}</option>
          ))}
        </Select>
        {err("category")}
        {form.category === "per_booking" && (
          <div className="mt-1">
            <Select
              className="select-sm"
              name="booking_id"
              form={ENTRY_FORM}
              ariaLabel="Booking"
              value={form.booking_id}
              onChange={set("booking_id")}
            >
              <option value="">– booking –</option>
              {options.bookings.map((b) => (
                <option key={b.id} value={String(b.id)}>
                  {b.label}
                </option>
              ))}
            </Select>
            {err("booking_id")}
          </div>
        )}
        {form.category === "capex" && (
          <div className="mt-1">
            <NumberInput
              name="useful_life_days"
              form={ENTRY_FORM}
              ariaLabel="Useful life in days"
              value={form.useful_life_days}
              onChange={set("useful_life_days")}
            />
            {err("useful_life_days")}
          </div>
        )}
      </td>
      <td>
        <TextField
          className="input-sm"
          name="description"
          form={ENTRY_FORM}
          ariaLabel="Description"
          value={form.description}
          onChange={set("description")}
        />
        {err("description")}
      </td>
      <td>
        <AmountInput
          small
          name="amount"
          form={ENTRY_FORM}
          ariaLabel="Amount"
          value={form.amount}
          currency={form.currency}
          onChange={set("amount")}
          onCurrencyChange={set("currency")}
        />
        {err("amount")}
        {err("currency")}
      </td>
      <td>
        {generated && (
          <div className="mb-1 text-sm opacity-70">
            generated · your edits are kept
          </div>
        )}
        <div className="flex gap-2">
          <button
            type="submit"
            form={ENTRY_FORM}
            className="btn btn-primary btn-sm"
            disabled={saver.pending}
          >
            Save
          </button>
          <button
            type="button"
            className="btn btn-ghost btn-sm"
            onClick={onClose}
          >
            Cancel
          </button>
          {expense && (
            <ConfirmDelete
              label="Delete"
              question="Delete this expense?"
              detail={
                generated
                  ? "It was generated from a recurring expense, so it comes back the next time months are generated."
                  : undefined
              }
              pending={remover.pending}
              onConfirm={() => remover.save()}
            />
          )}
        </div>
        {err("")}
      </td>
    </SheetEntryRow>
  );
}

function useExpenseOptions() {
  return useQuery({
    queryKey: ["expenses", "options"],
    queryFn: () => api<ExpenseOptions>("GET", "/api/expenses/options"),
  });
}

const RECURRING_COLUMNS: Column<Recurring>[] = [
  { header: "Description", cell: (t) => t.description },
  { header: "Category", cell: (t) => t.category },
  {
    header: "Amount / month",
    cell: (t) => showOriginal(t.amount_minor, t.currency),
    numeric: true,
  },
  { header: "From", cell: (t) => t.start_month },
  { header: "Until", cell: (t) => t.end_month ?? "open" },
];

// This month as YYYY-MM in local time.
function localMonth() {
  return localToday().slice(0, 7);
}

const RECURRING_ENTRY_FORM = "recurring-entry";

// The row for typing a recurring expense: empty (this month) to add,
// prefilled to edit.
function RecurringEntryRow({
  item,
  options,
  onClose,
}: {
  item?: Recurring;
  options: RecurringOptions;
  onClose: () => void;
}) {
  const [form, setForm] = useState<Form>(
    item
      ? {
          description: item.description,
          category: item.category,
          amount: formatAmount(item.amount_minor, item.currency),
          currency: item.currency,
          start_month: item.start_month,
          end_month: item.end_month ?? "",
        }
      : {
          description: "",
          category: options.categories[0] ?? "",
          amount: "",
          currency: options.default_currency,
          start_month: localMonth(),
          end_month: "",
        },
  );
  const set = (name: string) => (value: string) =>
    setForm((f) => ({ ...f, [name]: value }));
  const saver = useSave({
    method: item ? "PUT" : "POST",
    path: item ? `/api/recurring/${item.id}` : "/api/recurring",
    resource: "recurring",
    onSaved: onClose,
  });
  const remover = useSave({
    method: "DELETE",
    path: `/api/recurring/${item?.id}`,
    resource: "recurring",
    onSaved: onClose,
  });
  const { errors } = saver;
  const err = (name: string) =>
    errors[name] && <FieldError small>{errors[name]}</FieldError>;

  return (
    <SheetEntryRow mark={item ? "✎" : "+"} onEscape={onClose}>
      <td>
        <form
          id={RECURRING_ENTRY_FORM}
          onSubmit={(e) => {
            e.preventDefault();
            saver.save(form);
          }}
        />
        <TextField
          className="input-sm"
          name="description"
          form={RECURRING_ENTRY_FORM}
          ariaLabel="Description"
          value={form.description}
          onChange={set("description")}
        />
        {err("description")}
      </td>
      <td>
        <Select
          className="select-sm"
          name="category"
          form={RECURRING_ENTRY_FORM}
          ariaLabel="Category"
          value={form.category}
          onChange={set("category")}
        >
          {options.categories.map((c) => (
            <option key={c}>{c}</option>
          ))}
        </Select>
        {err("category")}
      </td>
      <td>
        <AmountInput
          small
          name="amount"
          form={RECURRING_ENTRY_FORM}
          ariaLabel="Amount per month"
          value={form.amount}
          currency={form.currency}
          onChange={set("amount")}
          onCurrencyChange={set("currency")}
        />
        {err("amount")}
        {err("currency")}
      </td>
      <td>
        <MonthInput
          className="input-sm"
          name="start_month"
          form={RECURRING_ENTRY_FORM}
          ariaLabel="Start month"
          value={form.start_month}
          onChange={set("start_month")}
        />
        {err("start_month")}
      </td>
      <td>
        <div className="flex items-center gap-2">
          <MonthInput
            className="input-sm min-w-36"
            name="end_month"
            form={RECURRING_ENTRY_FORM}
            ariaLabel="Until (empty = open)"
            value={form.end_month}
            onChange={set("end_month")}
          />
          <button
            type="submit"
            form={RECURRING_ENTRY_FORM}
            className="btn btn-primary btn-sm"
            disabled={saver.pending}
          >
            Save
          </button>
          <button
            type="button"
            className="btn btn-ghost btn-sm"
            onClick={onClose}
          >
            Cancel
          </button>
          {item && (
            <ConfirmDelete
              label="Delete"
              question="Delete this template? Its generated expenses are kept."
              pending={remover.pending}
              onConfirm={() => remover.save()}
            />
          )}
        </div>
        {err("end_month")}
        {err("")}
        {item && (
          <p className="mt-1 text-sm opacity-70">
            Changes only affect months not generated yet.{" "}
            <Link className="link" to={`/recurring/${item.id}`}>
              Generated expenses
            </Link>
          </p>
        )}
      </td>
    </SheetEntryRow>
  );
}

type RecurringOptions = { categories: string[]; default_currency: string };

function useRecurringOptions() {
  return useQuery({
    queryKey: ["recurring", "options"],
    queryFn: () => api<RecurringOptions>("GET", "/api/recurring/options"),
  });
}

export function RecurringList() {
  const items = useQuery({
    queryKey: ["recurring"],
    queryFn: () => api<Recurring[]>("GET", "/api/recurring"),
  });
  const options = useRecurringOptions();
  const [open, setOpen] = useState<Open>(null);
  const close = () => setOpen(null);
  return (
    <div>
      <PageTitle icon={<RecurringIcon />}>Recurring expenses</PageTitle>
      <p className="mb-4 flex justify-end">
        <button
          type="button"
          className="btn btn-primary btn-sm btn-square"
          aria-label="Add recurring expense"
          title="Add recurring expense"
          disabled={open !== null}
          onClick={() => setOpen("new")}
        >
          +
        </button>
      </p>
      <Loaded query={items}>
        {(rows) => (
          <DataTable
            columns={RECURRING_COLUMNS}
            rows={rows}
            rowKey={(t) => t.id}
            empty="No recurring expenses."
            onEdit={
              open === null && options.data ? (t) => setOpen(t.id) : undefined
            }
            editing={open}
            editRow={(t) =>
              options.data && (
                <RecurringEntryRow
                  item={t}
                  options={options.data}
                  onClose={close}
                />
              )
            }
            entry={
              open === "new" &&
              options.data && (
                <RecurringEntryRow options={options.data} onClose={close} />
              )
            }
          />
        )}
      </Loaded>
    </div>
  );
}

// Dates link to the expenses list narrowed to that day, where they are edited.
const generatedColumns = (currency: string): Column<Expense>[] => [
  {
    header: "Date",
    cell: (e) => e.date,
    href: (e) => `/expenses?from=${e.date}&to=${e.date}`,
  },
  {
    header: `Amount (${currency})`,
    cell: (e) => <AmountCell e={e} />,
    numeric: true,
  },
];

// Read-only: the template's terms and the expenses generated from it.
export function RecurringDetailPage() {
  const { id } = useParams();
  const { currency } = useDisplay();
  const item = useQuery({
    queryKey: ["recurring", id],
    queryFn: () => api<RecurringDetail>("GET", `/api/recurring/${id}`),
  });
  return (
    <Loaded query={item}>
      {(t) => (
        <div>
          <PageTitle icon={<RecurringIcon />}>{t.description}</PageTitle>
          <p className="mb-4">
            {showOriginal(t.amount_minor, t.currency)} per month · {t.category}{" "}
            · from {t.start_month} until {t.end_month ?? "open"}.{" "}
            <Link className="link" to="/recurring">
              Edit it in the list
            </Link>
            ; changes only affect months not generated yet.
          </p>
          <SectionTitle className="mb-2">Generated expenses</SectionTitle>
          <DataTable
            columns={generatedColumns(currency)}
            rows={t.generated}
            rowKey={(e) => e.id}
            empty="None yet."
          />
        </div>
      )}
    </Loaded>
  );
}
