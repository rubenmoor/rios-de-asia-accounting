import { useMutation } from "@tanstack/react-query";
import { NavLink, Route, Routes } from "react-router";
import { api } from "./api";
import { Notices, NoticesProvider } from "./components/Notices";
import { NAV } from "./nav";
import { NotFound } from "./pages/NotFound";
import { Placeholder } from "./pages/Placeholder";
import { Stopped } from "./pages/Stopped";
import { TimeEdit, TimeList, TimeNew } from "./pages/Time";

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
          <Route path="/time" element={<TimeList />} />
          <Route path="/time/new" element={<TimeNew />} />
          <Route path="/time/:id/edit" element={<TimeEdit />} />
          {NAV.filter((entry) => entry.path !== "/time").map((entry) => (
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
          <Route path="/time" element={<TimeList />} />
          <Route path="/time/new" element={<TimeNew />} />
          <Route path="/time/:id/edit" element={<TimeEdit />} />
          {NAV.filter((entry) => entry.path !== "/time").map((entry) => (
            <Route
              key={entry.path}
              path={entry.path}
              element={<Placeholder title={entry.label} />}
            />
          ))}
          <Route path="*" element={<NotFound />} />
        </Routes>
      </main>
    </NoticesProvider>
  );
}
