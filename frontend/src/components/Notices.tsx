import { createContext, type ReactNode, useContext, useState } from "react";
import type { Notice } from "../api";

type NoticesValue = {
  notices: Notice[];
  setNotices: (notices: Notice[]) => void;
};

const NoticesContext = createContext<NoticesValue>({
  notices: [],
  setNotices: () => {},
});

export function NoticesProvider({ children }: { children: ReactNode }) {
  const [notices, setNotices] = useState<Notice[]>([]);
  return (
    <NoticesContext value={{ notices, setNotices }}>{children}</NoticesContext>
  );
}

export const useNotices = () => useContext(NoticesContext);

// The last write's notices, above the page, dismissable.
export function Notices() {
  const { notices, setNotices } = useNotices();
  return (
    <>
      {notices.map((n, i) => (
        <div
          // biome-ignore lint/suspicious/noArrayIndexKey: notices have no id
          key={i}
          role="alert"
          className={`alert alert-${n.level} mb-4`}
        >
          <span>{n.text}</span>
          <button
            type="button"
            className="btn btn-ghost btn-xs"
            onClick={() => setNotices(notices.filter((_, j) => j !== i))}
          >
            Dismiss
          </button>
        </div>
      ))}
    </>
  );
}
