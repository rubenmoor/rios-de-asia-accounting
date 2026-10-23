import { expect, test } from "vitest";
import { parseError } from "./api";

test("422 carries field errors", () => {
  const error = parseError(422, { errors: { amount: "must be a number" } });
  expect(error.status).toBe(422);
  expect(error.fieldErrors).toEqual({ amount: "must be a number" });
});

test("other errors carry the error text", () => {
  const error = parseError(404, { error: "not found" });
  expect(error.message).toBe("not found");
  expect(error.fieldErrors).toEqual({});
});
