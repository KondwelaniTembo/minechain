// Fixed data for `npm run seed`. Passwords are never here: they come from .env
// (SEED_ADMIN_PASSWORD, SEED_DEMO_PASSWORD), so this file is safe to commit.

export const SEED_ADMIN_FULL_NAME = 'System Administrator';

// The ZCAS campus corners, collected by the developer and rounded to 6 decimal places.
// To change them later, keep to these rules. Each corner is [latitude, longitude]. Latitude comes FIRST, the order gps_zones uses (D4).
// GeoJSON and many map tools write [longitude, latitude], so do not paste from those
// without swapping. In Google Maps, right-clicking a spot shows "lat, lng" in this order.
// - At least 3 corners, listed in order around the edge (either direction, no zig-zag).
// - At most 6 decimal places each (about 11 cm); more is refused, not rounded.
// - Lusaka is near latitude -15.4, longitude 28.3, so every corner should look like that.
// Example shape only (NOT the campus):
//   [
//     [-15.391234, 28.321234],
//     [-15.392345, 28.325678],
//     [-15.396789, 28.324567],
//     [-15.395678, 28.320123],
//   ]
// If this is ever emptied, the seed refuses to run and says so.
// The seed never changes an existing zone, so a change here reaches only a fresh database.
export const ZCAS_CAMPUS_BOUNDARY = Object.freeze([
  [-15.419751, 28.287496],
  [-15.419429, 28.289674],
  [-15.418327, 28.289494],
  [-15.418544, 28.288000],
  [-15.418775, 28.286550],
  [-15.419293, 28.286608],
  [-15.419468, 28.286724],
  [-15.419347, 28.286817],
  [-15.419519, 28.287099],
]);

export const DEMO_ZONE = Object.freeze({
  name: 'ZCAS Campus (demo)',
  boundary: ZCAS_CAMPUS_BOUNDARY,
});

// One active account per custody or review role, for demonstrations and manual testing.
// Never created in production. The names avoid the existing demo_miner and demo_miner2
// accounts, which stay pending. Licence numbers are obviously fake.
export const DEMO_USERS = Object.freeze([
  { username: 'seed_miner', fullName: 'Demo Miner', role: 'miner', licenceNumber: 'DEMO-ASM-0001' },
  { username: 'seed_transporter', fullName: 'Demo Transporter', role: 'transporter', licenceNumber: null },
  { username: 'seed_buyer', fullName: 'Demo Buyer', role: 'buyer', licenceNumber: 'DEMO-BUY-0001' },
  { username: 'seed_officer', fullName: 'Demo Officer', role: 'officer', licenceNumber: null },
]);
