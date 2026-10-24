import { useMutation, useQueryClient } from "@tanstack/react-query";
import { NavLink, Route, Routes } from "react-router";
import { api, type Written } from "./api";
import { Logo } from "./components/icons";
import { Notices, NoticesProvider, useNotices } from "./components/Notices";
import { formatAmount } from "./format";
import { NAV } from "./nav";
import {
  BookingDetail,
  BookingEdit,
  BookingList,
  BookingNew,
} from "./pages/Bookings";
import { DashboardPage } from "./pages/Dashboard";
import {
  ExpenseList,
  RecurringDetailPage,
  RecurringList,
} from "./pages/Expenses";
import { NotFound } from "./pages/NotFound";
import { SettingsPage } from "./pages/Settings";
import { type Display, useDisplay } from "./useDisplay";

// The display currency switch (decision 48): choosing COP or EUR fetches today's
// rate on the server; on a refusal the select stays at the stored value.
function CurrencySwitch() {
  const display = useDisplay();
  const client = useQueryClient();
  const { setNotices } = useNotices();
  const change = useMutation({
    mutationFn: (currency: string) =>
      api<Written<Display>>("PUT", "/api/display", { currency }),
    onSuccess: (result) => {
      setNotices(result.notices);
      client.invalidateQueries({ queryKey: ["display"] });
    },
    onError: (error) => setNotices([{ level: "error", text: error.message }]),
  });
  return (
    <div className="flex items-center gap-2 mb-1 text-sm">
      {display.currency !== "USD" && (
        <span className="opacity-70">
          1 USD = {formatAmount(Math.round(display.rate / 10_000), "USD")}{" "}
          {display.currency} · rate of {display.rate_date}
        </span>
      )}
      <select
        aria-label="Display currency"
        className="select select-sm w-auto"
        value={display.currency}
        disabled={change.isPending}
        onChange={(e) => change.mutate(e.target.value)}
      >
        {display.currencies.map((c) => (
          <option key={c}>{c}</option>
        ))}
      </select>
    </div>
  );
}

export function App() {
  return (
    <NoticesProvider>
      <div className="min-h-screen bg-base-200">
        <header className="flex flex-wrap items-end gap-x-2 px-4 pt-3">
          <NavLink to="/" className="btn btn-ghost text-lg mb-1">
            <Logo />
            rios-de-asia-accounting
          </NavLink>
          <nav className="tabs tabs-lift flex-1 overflow-x-auto">
            {NAV.map((entry) => (
              <NavLink
                key={entry.path}
                to={entry.path}
                className={({ isActive }) =>
                  `tab gap-1.5 whitespace-nowrap ${isActive ? "tab-active" : ""}`
                }
              >
                <entry.icon className="size-4" />
                {entry.label}
              </NavLink>
            ))}
          </nav>
          <CurrencySwitch />
        </header>
        <main className="card bg-base-100 shadow mx-4 mb-6 max-w-6xl p-6 xl:mx-auto">
          <Notices />
          <Routes>
            <Route path="/" element={<DashboardPage />} />
            <Route path="/bookings" element={<BookingList />} />
            <Route path="/bookings/new" element={<BookingNew />} />
            <Route path="/bookings/:id" element={<BookingDetail />} />
            <Route path="/bookings/:id/edit" element={<BookingEdit />} />
            <Route path="/expenses" element={<ExpenseList />} />
            <Route path="/recurring" element={<RecurringList />} />
            <Route path="/recurring/:id" element={<RecurringDetailPage />} />
            <Route path="/settings" element={<SettingsPage />} />
            <Route path="*" element={<NotFound />} />
          </Routes>
        </main>
      </div>
    </NoticesProvider>
  );
}
