import { AppError } from '../errors.js';

// Checks one part of the request (body by default) against a Zod schema before the
// controller runs. The server validates everything, even when the app already has.
//
// On success the parsed data (trimmed, defaults applied, unknown fields refused by
// .strict() schemas) goes on req.validated[source]. It is not written back onto req, because
// Express 5 makes req.query read-only, and one place for all sources is simpler to read.
export function validate(schema, source = 'body') {
  return (req, res, next) => {
    const result = schema.safeParse(req[source]);

    if (!result.success) {
      return next(
        new AppError(400, 'VALIDATION_FAILED', 'Some fields are missing or invalid.', toDetails(result.error.issues, source)),
      );
    }

    req.validated = { ...req.validated, [source]: result.data };
    next();
  };
}

// One entry per problem, naming the field. Zod's messages describe the rule, not the value
// that was sent, so passwords and other input are never echoed back.
function toDetails(issues, source) {
  return issues.flatMap((issue) => {
    // .strict() reports all unknown fields in one issue; split it so each is named.
    if (issue.code === 'unrecognized_keys') {
      return issue.keys.map((key) => ({ field: key, message: 'is not allowed' }));
    }
    // An empty path means the whole thing was wrong (for example no body at all), so the
    // source itself ('body' or 'query') is named.
    return [{ field: issue.path.length > 0 ? issue.path.join('.') : source, message: issue.message }];
  });
}
