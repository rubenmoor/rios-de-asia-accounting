import { NoticeIcon } from "./Notices";

// Page-level error above a form; renders nothing when there is no message.
export function FormError({ message }: { message?: string }) {
  if (!message) return null;
  return (
    <div role="alert" className="alert alert-error mb-4">
      <NoticeIcon level="error" />
      <span>{message}</span>
    </div>
  );
}
