# Alpine-based Elixir/Phoenix container for self-hosted deployment
#
# https://hub.docker.com/r/hexpm/elixir/tags?name=alpine
# https://hub.docker.com/_/alpine/tags
#
ARG ELIXIR_VERSION=1.19.4
ARG OTP_VERSION=28.2
ARG ALPINE_VERSION=3.23.2

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-alpine-${ALPINE_VERSION}"
ARG RUNNER_IMAGE="docker.io/alpine:${ALPINE_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apk add --no-cache build-base git

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv

COPY lib lib

# Compile the release
RUN mix compile

COPY assets assets

# compile assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE} AS final

RUN apk add --no-cache \
  libstdc++ \
  openssl \
  ncurses-libs \
  ca-certificates \
  curl \
  python3 \
  ffmpeg

# Install yt-dlp
RUN curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp \
  && chmod a+rx /usr/local/bin/yt-dlp

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/chomp ./

USER nobody

CMD ["/app/bin/server"]
