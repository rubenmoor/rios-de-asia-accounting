import { ClosedBooksDoodle, Logo } from "../components/icons";
import { PageTitle } from "../components/Titles";

export function Stopped() {
  return (
    <div className="min-h-screen bg-base-200 p-6">
      <main className="card bg-base-100 shadow mx-auto max-w-3xl items-center p-6 text-center">
        <Logo className="size-10" />
        <ClosedBooksDoodle className="my-2 size-24 opacity-80" />
        <PageTitle className="">
          rios-de-asia-accounting has stopped, you can close this tab
        </PageTitle>
        <p className="mt-2 text-sm italic opacity-60" aria-hidden="true">
          The books are closed for today.
        </p>
      </main>
    </div>
  );
}
