export type PublicErrorCode =
  | "invalid_request"
  | "unauthorized"
  | "pairing_expired"
  | "pairing_locked"
  | "pairing_consumed"
  | "not_found"
  | "rate_limited"
  | "unavailable";

const SAFE_MESSAGES: Record<PublicErrorCode, string> = {
  invalid_request: "The request could not be accepted.",
  unauthorized: "Authentication failed.",
  pairing_expired: "The pairing code has expired.",
  pairing_locked: "Pairing is temporarily locked.",
  pairing_consumed: "The pairing code has already been used.",
  not_found: "The requested connector was not found.",
  rate_limited: "Too many requests. Try again later.",
  unavailable: "The bridge is temporarily unavailable.",
};

export class HttpError extends Error {
  readonly status: number;
  readonly code: PublicErrorCode;

  constructor(status: number, code: PublicErrorCode) {
    super(code);
    this.name = "HttpError";
    this.status = status;
    this.code = code;
  }
}

export function publicError(code: PublicErrorCode): {
  error: { code: PublicErrorCode; message: string };
} {
  return { error: { code, message: SAFE_MESSAGES[code] } };
}

export function invalidRequest(): never {
  throw new HttpError(400, "invalid_request");
}

export function unauthorized(): never {
  throw new HttpError(401, "unauthorized");
}
