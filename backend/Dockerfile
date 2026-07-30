FROM rust:1.91.1-bookworm AS builder

WORKDIR /build
COPY backend ./backend
WORKDIR /build/backend
RUN cargo build --locked --release --bin pakperk-api --bin pakperk-worker

FROM debian:bookworm-slim AS runtime

RUN apt-get update \
    && apt-get install --no-install-recommends -y ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin pakperk
WORKDIR /app
COPY --from=builder /build/backend/target/release/pakperk-api /usr/local/bin/pakperk-api
COPY --from=builder /build/backend/target/release/pakperk-worker /usr/local/bin/pakperk-worker
COPY demo /app/demo

USER pakperk
EXPOSE 8080
ENTRYPOINT []
CMD ["/usr/local/bin/pakperk-api"]

