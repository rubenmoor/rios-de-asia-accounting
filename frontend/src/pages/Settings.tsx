import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { api } from "../api";
import { Field } from "../components/Field";
import { FormActions } from "../components/FormActions";
import { FormError } from "../components/FormError";
import { FormSlip } from "../components/FormSlip";
import { SettingsIcon } from "../components/icons";
import {
  AmountInput,
  NumberInput,
  Select,
  TextField,
} from "../components/inputs";
import { PageTitle } from "../components/Titles";
import { formatAmount } from "../format";
import { useDisplay } from "../useDisplay";
import { useSave } from "../useSave";

type Settings = {
  last_backup: {
    time: string;
    file: string | null;
    error: string | null;
  } | null;
  long_term_rent_usd: number | null;
  long_term_rent_entered: {
    original_minor: number;
    currency: string;
    date: string;
    rate: number | null;
    rate_date: string | null;
  } | null;
  per_booking_allocation: string;
  backup_keep: number;
  listings: string[];
};
type Options = {
  allocations: string[];
  listings: string[];
  default_currency: string;
};

function SettingsForm({
  settings,
  options,
}: {
  settings: Settings;
  options: Options;
}) {
  const { currency, money } = useDisplay();
  const entered = settings.long_term_rent_entered;
  const [form, setForm] = useState<Record<string, string>>({
    long_term_rent: entered
      ? formatAmount(entered.original_minor, entered.currency)
      : "",
    long_term_rent_currency: entered?.currency ?? options.default_currency,
    per_booking_allocation: settings.per_booking_allocation,
    backup_keep: String(settings.backup_keep),
    other_listing: "",
  });
  const [chosen, setChosen] = useState<string[]>(settings.listings);
  const set = (name: string) => (value: string) =>
    setForm((f) => ({ ...f, [name]: value }));
  const names = [
    ...options.listings,
    ...settings.listings.filter((l) => !options.listings.includes(l)),
  ];

  const saver = useSave({
    method: "PUT",
    path: "/api/settings",
    resource: "settings",
    redirectTo: () => "/settings",
  });
  const { errors } = saver;
  const backup = settings.last_backup;

  return (
    <div>
      <PageTitle icon={<SettingsIcon />}>Settings</PageTitle>
      <FormError message={errors[""]} />
      <FormSlip label="Settings">
        <form
          onSubmit={(e) => {
            e.preventDefault();
            const { other_listing, ...rest } = form;
            const other = other_listing.trim();
            saver.save({
              ...rest,
              listings: other ? [...chosen, other] : chosen,
            });
          }}
        >
          <Field
            label="Long-term rental benchmark (per month)"
            error={errors.long_term_rent}
          >
            <AmountInput
              name="long_term_rent"
              value={form.long_term_rent}
              currency={form.long_term_rent_currency}
              onChange={set("long_term_rent")}
              onCurrencyChange={set("long_term_rent_currency")}
            />
            {entered && (
              <p className="mt-1 text-sm opacity-70">
                {settings.long_term_rent_usd === null
                  ? "Waiting for an exchange rate; left out of the figures."
                  : `${money(settings.long_term_rent_usd)} ${currency}${
                      entered.currency === "USD"
                        ? ""
                        : ` at the rate of ${entered.rate_date}`
                    }`}
              </p>
            )}
          </Field>
          <Field
            label="Per-booking costs are allocated"
            error={errors.per_booking_allocation}
          >
            <Select
              name="per_booking_allocation"
              value={form.per_booking_allocation}
              onChange={set("per_booking_allocation")}
            >
              {options.allocations.map((a) => (
                <option key={a}>{a}</option>
              ))}
            </Select>
          </Field>
          <fieldset className="fieldset">
            <legend className="fieldset-legend">
              Listings of this property
            </legend>
            {names.length === 0 && (
              <p className="opacity-60">
                No listings found in the bookings yet.
              </p>
            )}
            {names.map((name) => (
              <label
                key={name}
                className="flex cursor-pointer items-center gap-2"
              >
                <input
                  type="checkbox"
                  className="checkbox"
                  checked={chosen.includes(name)}
                  onChange={(e) =>
                    setChosen(
                      e.target.checked
                        ? [...chosen, name]
                        : chosen.filter((c) => c !== name),
                    )
                  }
                />
                {name}
              </label>
            ))}
            <Field label="Another listing name" error={errors.listings}>
              <TextField
                name="other_listing"
                value={form.other_listing}
                onChange={set("other_listing")}
                className="w-full"
              />
            </Field>
          </fieldset>
          <Field label="Backups to keep" error={errors.backup_keep}>
            <NumberInput
              name="backup_keep"
              value={form.backup_keep}
              onChange={set("backup_keep")}
            />
          </Field>
          <p className="mb-2">
            Last backup:{" "}
            {backup === null ? (
              <span className="opacity-70">none yet</span>
            ) : backup.error ? (
              <span className="text-error">
                {backup.time.replace("T", " ")} failed: {backup.error}
              </span>
            ) : (
              <span>
                {backup.time.replace("T", " ")}, {backup.file}
              </span>
            )}
          </p>
          <FormActions>
            <button
              type="submit"
              className="btn btn-primary"
              disabled={saver.pending}
            >
              Save
            </button>
          </FormActions>
        </form>
      </FormSlip>
    </div>
  );
}

export function SettingsPage() {
  const settings = useQuery({
    queryKey: ["settings"],
    queryFn: () => api<Settings>("GET", "/api/settings"),
  });
  const options = useQuery({
    queryKey: ["settings", "options"],
    queryFn: () => api<Options>("GET", "/api/settings/options"),
  });
  const error = settings.error ?? options.error;
  if (error) {
    return (
      <div role="alert" className="alert alert-error">
        {error.message}
      </div>
    );
  }
  if (!settings.data || !options.data) {
    return <p className="opacity-70">Loading…</p>;
  }
  return (
    <SettingsForm
      key={JSON.stringify(settings.data)}
      settings={settings.data}
      options={options.data}
    />
  );
}
