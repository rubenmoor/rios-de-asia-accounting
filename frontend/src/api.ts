// The only place that calls fetch: relative URLs (same origin), JSON in and out.

export type Notice = { level: "info" | "warning" | "error"; text: string };
export type Written<T> = { data: T; notices: Notice[] };
export type FieldErrors = Record<string, string>;

export class ApiError extends Error {
  status: number;
  fieldErrors: FieldErrors;

  constructor(status: number, message: string, fieldErrors: FieldErrors = {}) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.fieldErrors = fieldErrors;
  }
}

// 422 {errors: {field: message}}, anything else {error: text}.
export function parseError(status: number, body: unknown): ApiError {
  const obj =
    typeof body === "object" && body !== null
      ? (body as Record<string, unknown>)
      : {};
  if (status === 422 && typeof obj.errors === "object" && obj.errors !== null) {
    return new ApiError(
      status,
      "Some fields are invalid",
      obj.errors as FieldErrors,
    );
  }
  const text =
    typeof obj.error === "string" ? obj.error : `Request failed (${status})`;
  return new ApiError(status, text);
}

export async function api<T>(
  method: string,
  path: string,
  body?: unknown,
): Promise<T> {
  const response = await fetch(path, {
    method,
    headers:
      body === undefined ? undefined : { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const parsed: unknown = await response.json().catch(() => null);
  if (!response.ok) throw parseError(response.status, parsed);
  return parsed as T;
}

// A multipart upload: no Content-Type header, the browser sets the boundary.
export async function postFile<T>(path: string, body: FormData): Promise<T> {
  const response = await fetch(path, { method: "POST", body });
  const parsed: unknown = await response.json().catch(() => null);
  if (!response.ok) throw parseError(response.status, parsed);
  return parsed as T;
}
