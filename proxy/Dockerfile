# Pin exact base image digest for reproducibility/security
FROM nginx:1.25-alpine@sha256:516475cc129da42866742567714ddc681e5eed7b9ee0b9e9c015e464b4221a00

RUN apk add --no-cache openssl bash

# Nginx envsubst templating
ENV NGINX_ENVSUBST_TEMPLATE_DIR=/etc/nginx/templates
ENV NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx/conf.d
ENV SSL_PROTOCOLS="TLSv1.2 TLSv1.3"
ENV UPSTREAM_SSL_PROTOCOLS="TLSv1.3"
ENV REDIRECT_HTTP_TO_HTTPS="false"
ENV EXPOSE_HEALTH_ON_HTTP="true"
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN mkdir -p /etc/nginx/templates /etc/nginx/includes /etc/nginx/certs /docker-entrypoint.d

COPY default.conf.template /etc/nginx/templates/default.conf.template
COPY docker-entrypoint.d/18-mode-env.sh /docker-entrypoint.d/18-mode-env.sh
COPY docker-entrypoint.d/20-generate-self-signed.sh /docker-entrypoint.d/20-generate-self-signed.sh
# Normalize line endings from Windows to Unix
RUN sed -i 's/\r$//' /docker-entrypoint.d/18-mode-env.sh /docker-entrypoint.d/20-generate-self-signed.sh \
    && chmod +x /docker-entrypoint.d/18-mode-env.sh /docker-entrypoint.d/20-generate-self-signed.sh

EXPOSE 80 443
