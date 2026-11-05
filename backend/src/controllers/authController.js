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

    // By the time this runs, both login limiters and validate(loginSchema) have passed.
    // A 401 or 403 from authenticate goes to errorHandler unchanged.
    async login(req, res) {
      const { username, password } = req.validated.body;
      const { user, token, expiresIn } = await users.authenticate(username, password, { ipAddress: req.ip });

      // The response holds a token, so no phone, browser or proxy may keep a copy of it.
      // RFC 6749 (OAuth 2.0) requires this for token responses.
      res.set('Cache-Control', 'no-store');
      res.status(200).json({ token, tokenType: 'Bearer', expiresIn, user });
    },

    // requireAuth has already checked the token and loaded the current user.
    me(req, res) {
      // Personal details: no cache may keep a copy.
      res.set('Cache-Control', 'no-store');
      res.status(200).json({ user: req.user });
    },
  };
}
