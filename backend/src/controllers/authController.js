// Controllers translate HTTP into service calls and back. Nothing here knows about SQL,
// hashing or audit rules; that all lives in the services.
export function createAuthController({ users }) {
  return {
    // By the time this runs, the rate limiter and validate(registerSchema) have passed, so
    // req.validated.body is clean. Errors are not caught: Express 5 passes a rejected
    // promise to errorHandler, which turns an AppError into its 400 or 409.
    async register(req, res) {
      const user = await users.register(req.validated.body, { ipAddress: req.ip });

      res.status(201).json({
        user,
        message: 'Your account has been requested. An administrator must approve it before you can log in.',
      });
    },
  };
}
