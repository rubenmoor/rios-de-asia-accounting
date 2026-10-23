import { useMutation } from "@tanstack/react-query";
import { NavLink, Route, Routes } from "react-router";
import { api } from "./api";
import { Notices, NoticesProvider } from "./components/Notices";
import { NAV } from "./nav";
import { BlockedEdit, BlockedList, BlockedNew } from "./pages/Blocked";
import {
  BookingDetail,
  BookingEdit,
  BookingList,
  BookingNew,
} from "./pages/Bookings";
import {
  ExpenseEdit,
  ExpenseList,
  ExpenseNew,
  RecurringEdit,
  RecurringList,
  RecurringNew,
} from "./pages/Expenses";
import { NotFound } from "./pages/NotFound";
import { Placeholder } from "./pages/Placeholder";
import { RateEdit, RateList, RateNew } from "./pages/Rates";
import { SettingsPage } from "./pages/Settings";
import { Stopped } from "./pages/Stopped";
import { TimeEdit, TimeList, TimeNew } from "./pages/Time";

const IMPLEMENTED = [
  "/bookings",
  "/time",
  "/expenses",
  "/recurring",
  "/blocked-days",
  "/rates",
  "/settings",
];

export function App() {
  const quit = useMutation({ mutationFn: () => api("POST", "/api/quit") });

  if (quit.isSuccess) return <Stopped />;

  return (
    <NoticesProvider>
      <header className="navbar bg-base-200 gap-2">
        <NavLink to="/" className="btn btn-ghost text-lg">
          rios-de-asia-accounting
        </NavLink>
        <ul className="menu menu-horizontal flex-1 gap-1">
          {NAV.map((entry) => (
            <li key={entry.path}>
              <NavLink
                to={entry.path}
                className={({ isActive }) => (isActive ? "menu-active" : "")}
              >
                {entry.label}
              </NavLink>
            </li>
          ))}
        </ul>
        <button
          type="button"
          className="btn btn-outline btn-sm"
          disabled={quit.isPending}
          onClick={() => quit.mutate()}
        >
          Quit
        </button>
      </header>
      <main className="p-6">
        {quit.isError && (
          <div role="alert" className="alert alert-error mb-4">
            {quit.error.message}
          </div>
        )}
        <Notices />
        <Routes>
          <Route path="/" element={<Placeholder title="Dashboard" />} />
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
          <Route path="/blocked-days" element={<BlockedList />} />
          <Route path="/blocked-days/new" element={<BlockedNew />} />
          <Route path="/blocked-days/:day" element={<BlockedEdit />} />
          <Route path="/rates" element={<RateList />} />
          <Route path="/rates/new" element={<RateNew />} />
          <Route path="/rates/:day/:currency" element={<RateEdit />} />
          <Route path="/settings" element={<SettingsPage />} />
          {NAV.filter((entry) => !IMPLEMENTED.includes(entry.path)).map(
            (entry) => (
              <Route
                key={entry.path}
                path={entry.path}
                element={<Placeholder title={entry.label} />}
              />
            ),
          )}
          <Route path="*" element={<NotFound />} />
        </Routes>
      </main>
    </NoticesProvider>
  );
}
