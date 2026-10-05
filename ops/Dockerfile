FROM docker.io/library/elixir:1.18-alpine@sha256:caa6412c072c4b11e8c6798108388702c2791b4f8bad41e42c27ea5be881e2dc AS build

ARG WITH_EXTRA=0
ARG KEILA_CLOUD=0
ARG KEILA_CLOUD_LICENSE

ENV MIX_ENV=prod

RUN apk add git npm build-base openssl cmake

COPY mix.exs mix.lock ./
COPY config .
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get && \
    mix deps.compile

COPY assets/package.json assets/package-lock.json ./assets/
RUN npm ci --prefix ./assets

COPY . .
RUN mix deps.clean mime --build && \
    mix assets.deploy && \
    mix release

FROM docker.io/library/elixir:1.18-otp-27-alpine@sha256:34260a722c6a6fa659aad9dd09e73466f5692a899e7edb60d43b0d51d4738c4f
ENV HOME=/opt/app

WORKDIR ${HOME}
COPY --from=build _build/prod/rel/keila ${HOME}
RUN apk add --no-cache openssl curl
RUN mkdir -p ${HOME} && \
    adduser -s /bin/sh -u 1001 -G root -h ${HOME} -S -D default && \
    chown -R 1001:0 ${HOME}
ENTRYPOINT ["/opt/app/bin/keila"]
CMD ["start"]

ARG PORT=4000
ENV PORT=${PORT}
EXPOSE ${PORT}/tcp
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -f "http://localhost:${PORT}/" || exit 1
