FROM ghcr.io/nginx/nginx-unprivileged:1.31.5-alpine-slim@sha256:c94666682d7ecbfa0a1767fbe882cd1d82509333d15716c765f42bbef0d3809f

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
