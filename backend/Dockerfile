# Update only through a reviewed dependency PR that records the upstream tag,
# index digest, SBOM delta, and vulnerability scan result.
FROM rust:1.97.1-bookworm@sha256:0e2bcaef56d041a486784e54104a81aebe0da44bd03019bd70bc0401e42e4a97 AS builder

WORKDIR /build
COPY backend ./backend
WORKDIR /build/backend
RUN cargo build --locked --release \
    --bin pakperk-api \
    --bin pakperk-worker \
    --bin pakperk-deletion-worker \
    --bin pakperk-migrate \
    --bin pakperk-telemetry-gateway \
    --bin pakperk-admin

# Dated Debian tag plus immutable multi-platform index digest.
FROM debian:bookworm-20260713-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818 AS runtime

RUN test -x /bin/sh && test -x /usr/bin/install
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

WORKDIR /app
COPY --chown=10001:10001 --chmod=0444 demo/seed_manifest.json demo/fallback_feed.json /app/demo/
COPY --from=builder --chown=10001:10001 --chmod=0555 /build/backend/target/release/pakperk-api /usr/local/bin/pakperk-api
COPY --from=builder --chown=10001:10001 --chmod=0555 /build/backend/target/release/pakperk-worker /usr/local/bin/pakperk-worker
COPY --from=builder --chown=10001:10001 --chmod=0555 /build/backend/target/release/pakperk-deletion-worker /usr/local/bin/pakperk-deletion-worker
COPY --from=builder --chown=10001:10001 --chmod=0555 /build/backend/target/release/pakperk-migrate /usr/local/bin/pakperk-migrate
COPY --from=builder --chown=10001:10001 --chmod=0555 /build/backend/target/release/pakperk-telemetry-gateway /usr/local/bin/pakperk-telemetry-gateway
COPY --from=builder --chown=10001:10001 --chmod=0555 /build/backend/target/release/pakperk-admin /usr/local/bin/pakperk-admin

USER 10001:10001
EXPOSE 8080
ENTRYPOINT []
CMD ["/usr/local/bin/pakperk-api"]
