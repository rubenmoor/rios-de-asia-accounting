import type { ReactNode } from "react";

type InputProps = {
  name: string;
  value: string;
  onChange: (value: string) => void;
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
      value={value}
      inputMode={inputMode}
      list={list}
      onChange={(e) => onChange(e.target.value)}
    />
  );
}

export const MoneyInput = (p: InputProps) => (
  <TextInput {...p} inputMode="numeric" className="num" />
);
export const HoursInput = (p: InputProps) => (
  <TextInput {...p} className="num" />
);
export const RateInput = (p: InputProps) => (
  <TextInput {...p} inputMode="decimal" className="num" />
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
}: InputProps & { children: ReactNode; className?: string }) {
  return (
    <select
      className={`select w-full ${className}`}
      name={name}
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
