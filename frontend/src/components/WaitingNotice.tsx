import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, type Written } from "../api";
import { useNotices } from "./Notices";

// Entries without a USD value yet (decision 37), with the retry button.
export function WaitingNotice() {
  const queryClient = useQueryClient();
  const { setNotices } = useNotices();
  const waiting = useQuery({
    queryKey: ["rates", "waiting"],
    queryFn: () => api<{ waiting: number }>("GET", "/api/rates/waiting"),
  });
  const fetchNow = useMutation({
    mutationFn: () =>
      api<Written<{ waiting: number }>>("POST", "/api/rates/fetch"),
    onSuccess: async (result) => {
      setNotices(result.notices);
      await queryClient.invalidateQueries();
    },
    onError: (error) => setNotices([{ level: "error", text: error.message }]),
  });
  const count = waiting.data?.waiting ?? 0;
  if (count === 0) return null;
  return (
    <div role="alert" className="alert alert-warning mb-4">
      <span>
        {count} {count === 1 ? "entry waits" : "entries wait"} for an exchange
        rate and {count === 1 ? "is" : "are"} left out of the figures.
      </span>
      <button
        type="button"
        className="btn btn-sm"
        disabled={fetchNow.isPending}
        onClick={() => fetchNow.mutate()}
      >
        Fetch rates now
      </button>
    </div>
  );
}
