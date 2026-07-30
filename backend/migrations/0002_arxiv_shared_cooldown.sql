-- A legacy API 429/Retry-After applies to the deployment, not only to the
-- process which observed it. Every API and worker reservation locks this row.
ALTER TABLE external_rate_limits
ADD COLUMN blocked_until timestamptz NOT NULL
    DEFAULT '1970-01-01T00:00:00Z'::timestamptz;
