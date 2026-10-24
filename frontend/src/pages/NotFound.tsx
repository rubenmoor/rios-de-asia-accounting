import { Link } from "react-router";
import { PageTitle } from "../components/Titles";

export function NotFound() {
  return (
    <div>
      <PageTitle className="">Page not found</PageTitle>
      <Link className="link mt-2 inline-block" to="/">
        Back to the dashboard
      </Link>
    </div>
  );
}
