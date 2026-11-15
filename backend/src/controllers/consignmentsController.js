// HTTP in, service call, HTTP out. Every rule (who may see what, the chain check, the
// record_tampered alert) lives in consignmentService and consignmentDisclosure.
//
// By the time this runs, the router has checked the token, the role and the QR code. Errors
// are not caught: Express 5 passes a rejected promise to errorHandler, which turns the
// service's AppError into its 404.
export function createConsignmentsController({ consignments }) {
  return {
    // The viewer comes from req.user, which requireAuth loaded from the database, never from
    // anything the client sent: the role decides what the body may contain. Only id and
    // role are passed, so nothing else about the account can reach the service.
    async viewByQr(req, res) {
      const viewer = { id: req.user.id, role: req.user.role };
      res.status(200).json(await consignments.viewByQr(viewer, req.validated.params.qrCode));
    },
  };
}
