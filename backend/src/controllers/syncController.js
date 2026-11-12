// Controllers translate HTTP into service calls and back. Every sync rule (the pipeline,
// idempotency, stages, alerts) lives in syncService.
export function createSyncController({ sync }) {
  return {
    // By the time this runs, requireAuth, requireRole, the sync limiter and
    // validate(syncStepsBodySchema) have passed. req.user is the account as the database
    // has it now; it is the only source of the actor, so a step can never be stored for
    // anyone else.
    //
    // Always 200 when the batch was processed, whatever each item's outcome: the results
    // say what happened to every item, in the order sent. A database fault rejects, and
    // Express 5 passes it to errorHandler as a 500; resending the batch is then safe,
    // because items already stored come back as duplicate.
    async syncSteps(req, res) {
      const results = await sync.syncSteps(req.user, req.validated.body.steps, { ipAddress: req.ip });
      res.status(200).json({ results });
    },
  };
}
