// An error the client is meant to see: it carries its own HTTP status, a stable code the
// app can branch on, and a plain-language message. Services throw it, and errorHandler
// turns it into the response, so services never need to know about req or res.
export class AppError extends Error {
  constructor(status, code, message, details) {
    super(message);
    this.name = 'AppError';
    this.status = status;
    this.code = code;
    // Optional list such as [{ field, message }] for validation failures.
    this.details = details;
  }
}
