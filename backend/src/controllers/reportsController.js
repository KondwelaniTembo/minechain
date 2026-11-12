import { toCsv } from '../services/csv.js';

// Controllers translate HTTP into service calls and back. The rules (the buyer limit, the
// row cap, the audit entry) live in reportService; the file format lives in csv.js.
//
// By the time these run, the router has checked the token, the role and the query. Errors
// are not caught: Express 5 passes a rejected promise to errorHandler, so a 403, 404 or 422
// from the service is answered in the normal JSON error format, and anything unexpected
// (including a cell toCsv refuses) becomes the generic 500. toCsv's messages name the column
// and the row, never the value, so the server log never receives a cell's contents.

// The filename goes into a response header, so it must never carry anything that could end
// the header or start another (a quote, a CR or LF, a semicolon). The service builds it from
// fixed words, validated dates and lower-case uuids, which all fit this; the check makes sure
// it stays that way.
const SAFE_FILENAME = /^[a-z0-9.-]+$/;

export function createReportsController({ reports }) {
  // The requester comes from req.user, which requireAuth loaded from the database, never from
  // anything the client sent. req.ip is the client address as Express resolved it with
  // TRUST_PROXY, for the audit entry.
  const options = (req) => ({ ipAddress: req.ip });

  // The whole file is built before anything is sent, so a failure here still gets a proper
  // error response: nothing has been written yet.
  function sendCsv(res, { columns, rows, filename }) {
    if (typeof filename !== 'string' || !SAFE_FILENAME.test(filename)) {
      // The filename is not repeated in the message.
      throw new Error('Report filename is not in the safe form');
    }
    const body = toCsv(columns, rows);
    res
      .status(200)
      .set('Content-Type', 'text/csv; charset=utf-8')
      // attachment: the browser or app saves the file rather than showing it.
      .set('Content-Disposition', `attachment; filename="${filename}"`)
      .send(body);
  }

  return {
    async transactions(req, res) {
      sendCsv(res, await reports.transactions(req.validated.query, req.user, options(req)));
    },

    async auditTrail(req, res) {
      sendCsv(res, await reports.auditTrail(req.validated.query, req.user, options(req)));
    },
  };
}
