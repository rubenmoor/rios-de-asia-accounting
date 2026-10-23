import { useRef } from "react";

export function ConfirmDelete({
  label,
  question,
  detail,
  pending,
  onConfirm,
}: {
  label: string;
  question: string;
  detail?: string;
  pending?: boolean;
  onConfirm: () => void;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  return (
    <>
      <button
        type="button"
        className="btn btn-error btn-outline"
        onClick={() => dialog.current?.showModal()}
      >
        {label}
      </button>
      <dialog ref={dialog} className="modal">
        <div className="modal-box">
          <p>{question}</p>
          {detail && <p className="mt-2 opacity-70">{detail}</p>}
          <div className="modal-action">
            <button
              type="button"
              className="btn btn-error"
              disabled={pending}
              onClick={() => {
                dialog.current?.close();
                onConfirm();
              }}
            >
              Delete
            </button>
            <button
              type="button"
              className="btn"
              onClick={() => dialog.current?.close()}
            >
              Cancel
            </button>
          </div>
        </div>
      </dialog>
    </>
  );
}
