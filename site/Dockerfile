FROM ghcr.io/nginx/nginx-unprivileged:1.31.2-alpine-slim@sha256:eed3e4c2f3f9285e80610238e0b18fe1bf311c50559434db1969b1cfabd5518b

USER root
RUN mkdir -p /usr/share/nginx/html/.well-known && chown 101:101 /usr/share/nginx/html/.well-known

COPY --chown=101:101 site/nginx.conf /etc/nginx/conf.d/default.conf
# `prepare_release_site.sh` creates this allowlisted tree and injects the
# generated notices. Runtime config.js and association documents are mounted
# by Helm; their absence here makes a failed mount fail closed.
COPY --chown=101:101 release/site/ /usr/share/nginx/html/
RUN test -s /usr/share/nginx/html/open-source-licenses/notices.txt \
    && ! grep -Eiq 'placeholder|must replace|not the release inventory' \
      /usr/share/nginx/html/open-source-licenses/notices.txt \
    && test ! -e /usr/share/nginx/html/config.js \
    && test ! -e /usr/share/nginx/html/tests

USER 101:101
EXPOSE 8080
