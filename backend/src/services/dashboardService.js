import { AppError } from '../errors.js';
import { utcDayRange } from '../schemas/reports.js';
import { STEP_TYPES } from './stepPayload.js';
import { ALERT_TYPES, ALERT_SEVERITIES } from './anomalyChecks.js';

// The regulatory officer's dashboard (FR-14; docs/plans/dashboard-plan.md): counts only, for
// a period and optionally one mineral. Read-only, so nothing is audited (as with GET
// /alerts), and nothing personal is returned: no names, no ids of people, no coordinates.
//
// Rules:
//   - A step belongs to the UTC day its phone recorded it (captured_at), as in the
//     transactions report, so a figure here can be checked against that report.
//   - An alert belongs to its step's day, so an alert and its step are always in the same
//     period. "Now" ignores the period and follows the mineral.
//   - Every stored step counts, whatever its review status: the dashboard shows activity,
//     and the anomaly part shows what was flagged. Registered weight counts only accepted
//     registrations (passed, cleared), so a flagged duplicate does not count a load twice.
//   - Fixed SQL with every value as a $n parameter; the optional mineral is the fixed
//     fragment "($3::text IS NULL OR ...)". Counts come back as int, weights as text (a
//     numeric sum), never as JavaScript numbers.
//   - All five queries run in one REPEATABLE READ transaction, so the figures agree with each
//     other (a step that arrives meanwhile is in all of them or none).
//   - The day is worked out in SQL as (captured_at AT TIME ZONE 'UTC')::date, which does not
//     depend on the session's time zone setting; the empty days are filled in here.

const DASHBOARD_ROLES = Object.freeze(['officer']);
const CONSIGNMENT_STAGES = Object.freeze(['registered', 'in_transit', 'purchased']);
const MS_PER_DAY = 86_400_000;

// The steps in the period, shared by three queries. $1, $2 the range from utcDayRange,
// $3 the mineral or NULL.
const STEPS_IN_PERIOD = `
  FROM transactions t
  JOIN consignments c ON c.id = t.consignment_id
  WHERE t.captured_at >= $1 AND t.captured_at < $2
    AND ($3::text IS NULL OR c.mineral_type = $3)`;

// "Now": open alerts and consignments by stage, whatever the period. $1 the mineral or NULL.
const NOW_ALERTS = `
  SELECT count(*)::int AS open_alerts
    FROM alerts a
    JOIN transactions t ON t.id = a.transaction_id
    JOIN consignments c ON c.id = t.consignment_id
   WHERE a.status = 'open' AND ($1::text IS NULL OR c.mineral_type = $1)`;

const NOW_STAGES = `
  SELECT c.stage, count(*)::int AS consignments
    FROM consignments c
   WHERE ($1::text IS NULL OR c.mineral_type = $1)
   GROUP BY c.stage`;

const STEPS_BY_DAY = `
  SELECT to_char((t.captured_at AT TIME ZONE 'UTC')::date, 'YYYY-MM-DD') AS day,
         t.type,
         count(*)::int AS steps
  ${STEPS_IN_PERIOD}
  GROUP BY 1, 2`;

const STEPS_BY_MINERAL = `
  SELECT c.mineral_type AS mineral,
         count(*)::int AS steps,
         COALESCE(sum(t.weight_mg) FILTER (
           WHERE t.type = 'registration' AND t.review_status IN ('passed', 'cleared')), 0)::text
           AS registered_weight_mg
  ${STEPS_IN_PERIOD}
  GROUP BY c.mineral_type
  ORDER BY steps DESC, mineral`;

// A NULL zone_id is "outside every active zone" at the time the step arrived. A zone
// deactivated since then still has its name, with active false.
const STEPS_BY_ZONE = `
  SELECT z.id AS zone_id, z.name AS zone_name, z.status = 'active' AS active,
         count(*)::int AS steps
    FROM transactions t
    JOIN consignments c ON c.id = t.consignment_id
    LEFT JOIN gps_zones z ON z.id = t.zone_id
   WHERE t.captured_at >= $1 AND t.captured_at < $2
     AND ($3::text IS NULL OR c.mineral_type = $3)
  GROUP BY z.id, z.name, z.status
  ORDER BY steps DESC, z.name, z.id`;

const ALERTS_IN_PERIOD = `
  SELECT a.type, a.severity, a.status, count(*)::int AS alerts
    FROM alerts a
    JOIN transactions t ON t.id = a.transaction_id
    JOIN consignments c ON c.id = t.consignment_id
   WHERE t.captured_at >= $1 AND t.captured_at < $2
     AND ($3::text IS NULL OR c.mineral_type = $3)
   GROUP BY 1, 2, 3`;

const forbidden = () => new AppError(403, 'FORBIDDEN', 'You do not have permission to do this.');

// An object with every key set to 0, so the app never has to guess at a missing key.
const zeros = (keys) => Object.fromEntries(keys.map((key) => [key, 0]));

// Every UTC day from `from` to `to`, both included, as YYYY-MM-DD.
function daysOf({ from, to }) {
  const days = [];
  const last = Date.parse(`${to}T00:00:00.000Z`);
  for (let time = Date.parse(`${from}T00:00:00.000Z`); time <= last; time += MS_PER_DAY) {
    days.push(new Date(time).toISOString().slice(0, 10));
  }
  return days;
}

export function createDashboardService({ db }) {
  return {
    // query: already passed dashboardQuerySchema. requester: req.user ({ id, role }).
    async summary(query, requester) {
      // The route's guard checks the same; this is the second line, as in the reports.
      if (!DASHBOARD_ROLES.includes(requester.role)) throw forbidden();

      const mineral = query.mineral ?? null;
      const { start, endExclusive } = utcDayRange(query);
      const period = [start, endExclusive, mineral];

      const results = await db.transaction(
        async (tx) => ({
          openAlerts: (await tx.query(NOW_ALERTS, [mineral])).rows[0].open_alerts,
          stages: (await tx.query(NOW_STAGES, [mineral])).rows,
          byDay: (await tx.query(STEPS_BY_DAY, period)).rows,
          byMineral: (await tx.query(STEPS_BY_MINERAL, period)).rows,
          byZone: (await tx.query(STEPS_BY_ZONE, period)).rows,
          alerts: (await tx.query(ALERTS_IN_PERIOD, period)).rows,
        }),
        { isolation: 'repeatable read' },
      );

      const days = daysOf(query);
      const consignments = zeros(CONSIGNMENT_STAGES);
      for (const row of results.stages) consignments[row.stage] = row.consignments;

      const steps = { total: 0, ...zeros(STEP_TYPES) };
      const byDayMap = new Map(days.map((day) => [day, { day, ...zeros(STEP_TYPES) }]));
      for (const row of results.byDay) {
        byDayMap.get(row.day)[row.type] += row.steps;
        steps[row.type] += row.steps;
        steps.total += row.steps;
      }

      const byMineral = results.byMineral.map((row) => ({
        mineral: row.mineral,
        steps: row.steps,
        registeredWeightMg: row.registered_weight_mg,
      }));
      // BigInt, never Number: a total weight in milligrams can pass 2^53.
      const registeredWeightMg = byMineral.reduce((sum, row) => sum + BigInt(row.registeredWeightMg), 0n).toString();

      let outsideZones = 0;
      const byZone = [];
      for (const row of results.byZone) {
        if (row.zone_id === null) outsideZones = row.steps;
        else byZone.push({ zoneId: row.zone_id, zoneName: row.zone_name, active: row.active, steps: row.steps });
      }

      const anomalies = { total: 0, open: 0, byType: zeros(ALERT_TYPES), bySeverity: zeros(ALERT_SEVERITIES) };
      for (const row of results.alerts) {
        anomalies.total += row.alerts;
        if (row.status === 'open') anomalies.open += row.alerts;
        anomalies.byType[row.type] += row.alerts;
        anomalies.bySeverity[row.severity] += row.alerts;
      }

      return {
        period: { from: query.from, to: query.to, days: days.length },
        mineral,
        now: { openAlerts: results.openAlerts, consignments },
        steps,
        registeredWeightMg,
        byDay: [...byDayMap.values()],
        byMineral,
        byZone,
        outsideZones,
        anomalies,
      };
    },
  };
}
