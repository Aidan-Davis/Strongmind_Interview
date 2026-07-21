# syntax=docker/dockerfile:1
# Local/reviewer image: includes development+test gems so ingest/sidekiq/test all work.

ARG RUBY_VERSION=3.3.12
FROM docker.io/library/ruby:${RUBY_VERSION}-slim

WORKDIR /rails

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      curl \
      git \
      libjemalloc2 \
      libpq-dev \
      libyaml-dev \
      pkg-config \
      postgresql-client && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV BUNDLE_PATH="/usr/local/bundle" \
    LD_PRELOAD="libjemalloc.so.2" \
    RAILS_ENV="development" \
    RAILS_LOG_TO_STDOUT="1"

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

RUN chmod +x bin/* bin/docker-entrypoint

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

EXPOSE 3000
CMD ["./bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
