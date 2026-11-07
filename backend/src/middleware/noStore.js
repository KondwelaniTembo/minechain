// Tells every phone, browser and proxy not to keep a copy of the response. Put first on a
// route, so errors (401, 403, 409) carry the header too, not only the success. Used where a
// response holds personal or account data.
export function noStore(req, res, next) {
  res.set('Cache-Control', 'no-store');
  next();
}
