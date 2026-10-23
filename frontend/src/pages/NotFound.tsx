import { Link } from "react-router";

export function NotFound() {
  return (
    <div>
      <h1 className="text-2xl font-bold">Page not found</h1>
      <Link className="link mt-2 inline-block" to="/">
        Back to the dashboard
      </Link>
    </div>
  );
}
