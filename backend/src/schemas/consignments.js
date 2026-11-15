import { z } from 'zod';
import { QR_CODE_PATTERN } from '../services/stepPayload.js';

// :qrCode in GET /consignments/by-qr/:qrCode (plan B2.5). The consignments.qr_code rules,
// from the same pattern sync uses: 4 to 128 characters from A-Z a-z 0-9 . _ : / -.
//
// A "/" in a code must be sent percent-encoded (%2F): ":qrCode" matches one path segment,
// and Express 5 decodes the segment with decodeURIComponent before this schema sees it, so
// "MC%2F2026%2F001" arrives here as "MC/2026/001". A raw "/" would make a different path
// and get 404 NOT_FOUND. Checked before any SQL, so nothing else reaches the query.
export const qrCodeParamsSchema = z
  .object({
    qrCode: z.string().regex(QR_CODE_PATTERN, 'must be 4-128 characters from A-Z a-z 0-9 . _ : / -'),
  })
  .strict();
