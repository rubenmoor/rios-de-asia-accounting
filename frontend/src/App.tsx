import { useMutation } from "@tanstack/react-query";
import { NavLink, Route, Routes } from "react-router";
import { api } from "./api";
import { Logo } from "./components/icons";
import { Notices, NoticesProvider } from "./components/Notices";
import { NAV } from "./nav";
import {
  BookingDetail,
  BookingEdit,
  BookingList,
  BookingNew,
} from "./pages/Bookings";
import { DashboardPage } from "./pages/Dashboard";
import {
  ExpenseEdit,
  ExpenseList,
  ExpenseNew,
  RecurringEdit,
  RecurringList,
  RecurringNew,
} from "./pages/Expenses";
import { ImportPage } from "./pages/Import";
import { NotFound } from "./pages/NotFound";
import { RateEdit, RateList, RateNew } from "./pages/Rates";
import { SettingsPage } from "./pages/Settings";
import { Stopped } from "./pages/Stopped";
import { TimeEdit, TimeList, TimeNew } from "./pages/Time";

export function App() {
  const quit = useMutation({ mutationFn: () => api("POST", "/api/quit") });

  if (quit.isSuccess) return <Stopped />;

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
          <button
            type="button"
            className="btn btn-outline btn-sm mb-1"
            disabled={quit.isPending}
            onClick={() => quit.mutate()}
          >
            Quit
          </button>
        </header>
        <main className="card bg-base-100 shadow mx-4 mb-6 max-w-6xl p-6 xl:mx-auto">
          {quit.isError && (
            <div role="alert" className="alert alert-error mb-4">
              {quit.error.message}
            </div>
          )}
          <Notices />
          <Routes>
            <Route path="/" element={<DashboardPage />} />
            <Route path="/bookings" element={<BookingList />} />
            <Route path="/bookings/new" element={<BookingNew />} />
            <Route path="/bookings/:id" element={<BookingDetail />} />
            <Route path="/bookings/:id/edit" element={<BookingEdit />} />
            <Route path="/time" element={<TimeList />} />
            <Route path="/time/new" element={<TimeNew />} />
            <Route path="/time/:id/edit" element={<TimeEdit />} />
            <Route path="/expenses" element={<ExpenseList />} />
            <Route path="/expenses/new" element={<ExpenseNew />} />
            <Route path="/expenses/:id/edit" element={<ExpenseEdit />} />
            <Route path="/recurring" element={<RecurringList />} />
            <Route path="/recurring/new" element={<RecurringNew />} />
            <Route path="/recurring/:id" element={<RecurringEdit />} />
            <Route path="/rates" element={<RateList />} />
            <Route path="/rates/new" element={<RateNew />} />
            <Route path="/rates/:day/:currency" element={<RateEdit />} />
            <Route path="/import" element={<ImportPage />} />
            <Route path="/settings" element={<SettingsPage />} />
            <Route path="*" element={<NotFound />} />
          </Routes>
        </main>
      </div>
    </NoticesProvider>
  );
}
