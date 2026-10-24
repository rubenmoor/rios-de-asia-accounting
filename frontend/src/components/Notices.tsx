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

const ALERT_CLASS = {
  info: "alert-info",
  warning: "alert-warning",
  error: "alert-error",
} as const;

export function NoticeIcon({ level }: { level: Notice["level"] }) {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 24 24"
      className="h-5 w-5 shrink-0"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      {level === "error" ? (
        <>
          <circle cx="12" cy="12" r="9" />
          <path d="M12 7v6M12 16.5v.5" />
        </>
      ) : level === "info" ? (
        <>
          <circle cx="12" cy="12" r="9" />
          <path d="M12 11v6M12 7.5v.5" />
        </>
      ) : (
        <>
          <path d="M12 3 2.5 20h19L12 3Z" />
          <path d="M12 10v4M12 17v.5" />
        </>
      )}
    </svg>
  );
}

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
          className={`alert ${ALERT_CLASS[n.level]} mb-4`}
        >
          <NoticeIcon level={n.level} />
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
