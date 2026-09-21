# Free-hosting deploy (Render/Fly/etc.) -- same app the Mac runs locally,
# just containerized so it doesn't depend on a laptop staying awake.
FROM erlang:27-alpine AS build
WORKDIR /app
COPY src ./src
# oauth_config.erl is gitignored (real credentials never committed) -- the
# example template is env-var-driven (see its own comments), so it's a
# safe, valid stand-in whenever the real file isn't present, which is
# always true in a fresh clone/CI build like this one.
RUN mkdir -p ebin && \
    cp src/oauth_config.erl.example src/oauth_config.erl && \
    erlc -o ebin src/*.erl

FROM erlang:27-alpine
WORKDIR /app
COPY --from=build /app/ebin ./ebin
COPY web ./web
EXPOSE 8080
# No -sname/-name: that's only needed locally for the hot-reload dev
# workflow (RPC into a named node) and adds epmd complexity with no
# benefit in a container that just gets redeployed on every change.
# start_web_only, not start: a hosted deploy only ever exposes one port
# to the internet, and opening the raw TCP port too just gives the
# platform's port auto-detection a second target to potentially pick
# instead -- see chat_app:start_web_only/1's doc comment.
CMD ["sh", "-c", "erl -noshell -pa ebin -s chat_app start_web_only ${PORT:-8080}"]
