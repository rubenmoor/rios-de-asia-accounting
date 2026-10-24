import { useRef } from "react";
import { SlipHeader } from "./FormSlip";

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
        className="btn btn-error btn-outline btn-sm"
        onClick={() => dialog.current?.showModal()}
      >
        {label}
      </button>
      <dialog ref={dialog} className="modal">
        <div className="modal-box overflow-hidden border border-base-300 p-0">
          <SlipHeader label="Void entry" />
          <div className="p-4">
            <p>{question}</p>
            {detail && <p className="mt-2 opacity-70">{detail}</p>}
          </div>
          <div className="modal-action mt-0 border-t border-base-300 p-4">
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
              className="btn btn-ghost"
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
