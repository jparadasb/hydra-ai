# hydra-ai coordinator — production image (Postgres backend).
# Multi-stage: build an Elixir release, then run it on a slim Debian runtime.

ARG ELIXIR_IMAGE=elixir:1.19-otp-26
ARG RUNTIME_IMAGE=debian:bookworm-slim

# ---- build ----
FROM ${ELIXIR_IMAGE} AS build

# Compile against Postgres (the repo adapter is selected at compile time from DB_ADAPTER).
ENV MIX_ENV=prod \
    DB_ADAPTER=postgres

WORKDIR /app

# Build tools for native NIFs (exqlite is a dependency even in Postgres builds).
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

# Deps first for layer caching.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY config config
RUN mix deps.compile

# App sources + release.
COPY lib lib
COPY priv priv
RUN mix compile && mix release

# ---- runtime ----
FROM ${RUNTIME_IMAGE} AS app

ENV LANG=C.UTF-8 \
    DB_ADAPTER=postgres

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       libstdc++6 openssl libncurses6 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/_build/prod/rel/coordinator ./
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && groupadd -r hydra && useradd -r -g hydra hydra \
    && chown -R hydra:hydra /app
USER hydra

EXPOSE 4000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
