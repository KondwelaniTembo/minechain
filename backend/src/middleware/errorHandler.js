import { AppError } from '../errors.js';

// Errors raised by express.json() carry a `type`. These are the client's fault, so they get
// a specific 4xx response instead of a generic 500.
const BODY_PARSER_ERRORS = {
  'entity.parse.failed': { status: 400, code: 'INVALID_JSON', message: 'Request body is not valid JSON' },
  'entity.too.large': { status: 413, code: 'PAYLOAD_TOO_LARGE', message: 'Request body is too large' },
};

// Express recognises an error handler by its four parameters, so `next` must stay in the
// signature even when it is not called on every path.
export function errorHandler(err, req, res, next) {
  // If part of the response is already sent, the status cannot change. Express's own
  // handler then closes the connection.
  if (res.headersSent) {
    return next(err);
  }

  // Deliberate errors from our own code: their message was written for the client.
  if (err instanceof AppError) {
    const body = { code: err.code, message: err.message };
    if (err.details) body.details = err.details;
    return res.status(err.status).json({ error: body });
  }

  const known = BODY_PARSER_ERRORS[err.type];
  if (known) {
    return res.status(known.status).json({ error: { code: known.code, message: known.message } });
  }

  // A route parameter with a malformed percent-escape, such as /alerts/%E0. Express 5's
  // router decodes each parameter with decodeURIComponent while matching the route, and on
  // failure rethrows the URIError with status 400 and the raw value in its message
  // (node_modules/router/lib/layer.js, decodeParam). It is the client's mistake, so it is a
  // 400, and it is not logged: the message holds whatever the client typed, and repeating a
  // bad link would only fill the log. no-store is set here because not every router sets it.
  if (err instanceof URIError && err.status === 400) {
    res.set('Cache-Control', 'no-store');
    return res.status(400).json({ error: { code: 'VALIDATION_FAILED', message: 'The request path is not valid.' } });
  }

  // Anything else is unexpected. The full error goes to the server log so the fault can be
  // traced (NFR-07), while the client gets a generic message: stack traces and SQL errors
  // tell an attacker how the system is built.
  console.error('Unhandled error:', err);
  res.status(500).json({ error: { code: 'INTERNAL_ERROR', message: 'Something went wrong' } });
}
