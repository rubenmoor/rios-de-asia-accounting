import type { ReactNode } from "react";
import { CURRENCIES } from "../format";

type InputProps = {
  name: string;
  value: string;
  onChange: (value: string) => void;
  // Ties the input to a <form> elsewhere (a form can't wrap a table row).
  form?: string;
  ariaLabel?: string;
};

// Text inputs only: what was typed goes to the server as is (no client parsing).
function TextInput({
  name,
  value,
  onChange,
  inputMode,
  type = "text",
  className = "",
  list,
  form,
  ariaLabel,
}: InputProps & {
  list?: string;
  inputMode?: "numeric" | "decimal";
  type?: "text" | "date" | "month";
  className?: string;
}) {
  return (
    <input
      className={`input w-full ${className}`}
      type={type}
      name={name}
      form={form}
      aria-label={ariaLabel}
      value={value}
      inputMode={inputMode}
      list={list}
      onChange={(e) => onChange(e.target.value)}
    />
  );
}

export const NumberInput = (p: InputProps) => (
  <TextInput {...p} inputMode="numeric" className="num" />
);
export const HoursInput = (p: InputProps) => (
  <TextInput {...p} className="num" />
);
export const DateInput = (p: InputProps & { className?: string }) => (
  <TextInput {...p} type="date" />
);
export const MonthInput = (p: InputProps & { className?: string }) => (
  <TextInput {...p} type="month" />
);
export const TextField = (
  p: InputProps & { className?: string; list?: string },
) => <TextInput {...p} />;

export function Select({
  name,
  value,
  onChange,
  children,
  className = "",
  form,
  ariaLabel,
}: InputProps & { children: ReactNode; className?: string }) {
  return (
    <select
      className={`select w-full ${className}`}
      name={name}
      form={form}
      aria-label={ariaLabel}
      value={value}
      onChange={(e) => onChange(e.target.value)}
    >
      {children}
    </select>
  );
}

export function TextArea({ name, value, onChange }: InputProps) {
  return (
    <textarea
      className="textarea w-full"
      name={name}
      rows={3}
      value={value}
      onChange={(e) => onChange(e.target.value)}
    />
  );
}

// An amount typed as is, with the currency it is in (decision 39: USD, COP, EUR).
// The server parses the text by the chosen currency.
export function AmountInput({
  name,
  value,
  currency,
  onChange,
  onCurrencyChange,
  form,
  ariaLabel,
  small,
}: InputProps & {
  currency: string;
  onCurrencyChange: (currency: string) => void;
  small?: boolean;
}) {
  return (
    <div className="flex gap-2">
      <TextInput
        name={name}
        value={value}
        onChange={onChange}
        inputMode="decimal"
        className={small ? "num input-sm" : "num"}
        form={form}
        ariaLabel={ariaLabel}
      />
      <select
        className={`select shrink-0 ${small ? "select-sm w-24" : "w-28"}`}
        name="currency"
        form={form}
        aria-label="Currency"
        value={currency}
        onChange={(e) => onCurrencyChange(e.target.value)}
      >
        {CURRENCIES.map((c) => (
          <option key={c}>{c}</option>
        ))}
      </select>
    </div>
  );
}
