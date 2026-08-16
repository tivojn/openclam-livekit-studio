export class HttpError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string) {
    super(code);
    this.name = "HttpError";
    this.status = status;
    this.code = code;
  }
}

export function badRequest(code: string): never {
  throw new HttpError(400, code);
}

export function unauthorized(): never {
  throw new HttpError(401, "unauthorized");
}

export function unprocessable(code: string): never {
  throw new HttpError(422, code);
}
