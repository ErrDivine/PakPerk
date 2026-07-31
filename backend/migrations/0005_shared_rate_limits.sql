CREATE TABLE shared_rate_limit_buckets (
    bucket text NOT NULL,
    scope_key text NOT NULL,
    window_started_at timestamptz NOT NULL,
    window_ends_at timestamptz NOT NULL,
    request_count bigint NOT NULL CHECK (request_count > 0),
    updated_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    PRIMARY KEY (bucket, scope_key),
    CONSTRAINT shared_rate_limit_bucket_valid CHECK (
        bucket = btrim(bucket)
        AND char_length(bucket) BETWEEN 1 AND 64
        AND bucket ~ '^[a-z0-9_:-]+$'
    ),
    CONSTRAINT shared_rate_limit_scope_valid CHECK (
        scope_key = btrim(scope_key)
        AND char_length(scope_key) BETWEEN 1 AND 256
    ),
    CONSTRAINT shared_rate_limit_window_valid CHECK (
        window_ends_at > window_started_at
        AND updated_at >= window_started_at
    )
);

CREATE INDEX shared_rate_limit_buckets_expiry_idx
    ON shared_rate_limit_buckets (window_ends_at);
