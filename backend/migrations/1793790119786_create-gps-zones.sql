-- Up Migration

-- Licensed extraction zones (FR-11). The GPS zone anomaly check reads these polygons, so
-- the database refuses any boundary that check could misread.
CREATE TABLE gps_zones (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name           text        NOT NULL,
  licence_number text,
  -- One polygon as [[lat, lng], ...]. Kept whole in jsonb because it is always read whole
  -- (D4). Note the order: GeoJSON and many map tools use [lng, lat] instead.
  boundary       jsonb       NOT NULL,
  -- Zones are deactivated, never deleted, so past transactions keep their zone.
  status         text        NOT NULL DEFAULT 'active',
  -- RESTRICT: the admin who configured a zone cannot be hard-deleted (D9).
  created_by     uuid        NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT gps_zones_name_not_blank
    CHECK (btrim(name) <> ''),
  CONSTRAINT gps_zones_status_valid
    CHECK (status IN ('active', 'inactive')),
  -- CASE, not AND: SQL does not promise to evaluate AND left to right, and
  -- jsonb_array_length on a non-array would raise an unrelated error instead of failing
  -- this CHECK. CASE is guaranteed to test the type first.
  CONSTRAINT gps_zones_boundary_min_3_points
    CHECK (CASE WHEN jsonb_typeof(boundary) = 'array'
                THEN jsonb_array_length(boundary) >= 3
                ELSE false END),
  -- A CHECK cannot loop with a subquery, so jsonpath selects every *bad* corner: not a
  -- 2-item array, not numbers, or out of range. There must be none.
  -- strict: in the default lax mode a ? filter unwraps arrays, so each [lat, lng] corner
  -- would be checked as two separate numbers, and every boundary would fail.
  -- CASE: strict $[*] raises an error (22039) on a non-array, so the type is tested first
  -- and a non-array fails this CHECK cleanly. No silent => true: a hidden error would make
  -- jsonb_path_exists return NULL, and a CHECK lets NULL through.
  CONSTRAINT gps_zones_boundary_points_valid
    CHECK (CASE WHEN jsonb_typeof(boundary) = 'array'
                THEN NOT jsonb_path_exists(boundary,
                  'strict $[*] ? (@.type() != "array" || @.size() != 2
                                  || @[0].type() != "number" || @[1].type() != "number"
                                  || @[0] < -90 || @[0] > 90 || @[1] < -180 || @[1] > 180)')
                ELSE false END)
);

-- 'Kasempa North' and 'kasempa north' would be the same zone to an admin.
CREATE UNIQUE INDEX gps_zones_name_lower_key ON gps_zones (lower(name));

CREATE TRIGGER gps_zones_set_updated_at
  BEFORE UPDATE ON gps_zones
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Down Migration

-- set_updated_at() belongs to the users migration, so it is not dropped here.
DROP TABLE gps_zones;
