import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { useNavigate } from "react-router";
import { ApiError, api, type FieldErrors, type Written } from "./api";
import { useNotices } from "./components/Notices";

// A write: success → notices, refresh the resource's queries, go to `then`;
// 422 → field errors for the form (key "" above it); other errors → error notice.
export function useSave<T>({
  method,
  path,
  resource,
  redirectTo,
}: {
  method: "POST" | "PUT" | "DELETE";
  path: string;
  resource: string;
  redirectTo: (data: T) => string;
}) {
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const { setNotices } = useNotices();
  const [errors, setErrors] = useState<FieldErrors>({});

  const mutation = useMutation({
    mutationFn: (body?: unknown) => api<Written<T>>(method, path, body),
    onSuccess: async (result) => {
      setErrors({});
      setNotices(result.notices);
      await queryClient.invalidateQueries({ queryKey: [resource] });
      navigate(redirectTo(result.data));
    },
    onError: (error) => {
      if (error instanceof ApiError && error.status === 422) {
        setErrors(error.fieldErrors);
      } else {
        setNotices([{ level: "error", text: error.message }]);
      }
    },
  });

  return { save: mutation.mutate, pending: mutation.isPending, errors };
}
