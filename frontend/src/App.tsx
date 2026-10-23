import { useMutation } from "@tanstack/react-query";
import { NavLink, Route, Routes } from "react-router";
import { api } from "./api";
import { NAV } from "./nav";
import { NotFound } from "./pages/NotFound";
import { Placeholder } from "./pages/Placeholder";
import { Stopped } from "./pages/Stopped";

export function App() {
  const quit = useMutation({ mutationFn: () => api("POST", "/api/quit") });

  if (quit.isSuccess) return <Stopped />;

  return (
    <>
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
        <Routes>
          <Route path="/" element={<Placeholder title="Dashboard" />} />
          {NAV.map((entry) => (
            <Route
              key={entry.path}
              path={entry.path}
              element={<Placeholder title={entry.label} />}
            />
          ))}
          <Route path="*" element={<NotFound />} />
        </Routes>
      </main>
    </>
  );
}
