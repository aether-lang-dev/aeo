# silly_addition_app — the `/add` service image

The prebuilt app image referenced by `image("localhost/aeo-examples/silly-add:latest")`
in the container/vm example compositions. A stock-library Python HTTP server:
`GET /add/<a>/<b>` → `a+b`, cached in redis (`REDIS_HOST`).

Build it (the examples reference the tag, they don't build it — a real shop builds
in CI):

    podman build -t localhost/aeo-examples/silly-add:latest examples/silly_addition_app/

This replaces the inline `entrypoint(){ python(<<PY … PY) }` script form:
application source lives here, the composition just references the tag — pure
orchestration. (The block form is still available for one-file services — see
`compose`'s `entrypoint()` + the `python`/`ruby`/`javascript`/`perl`/`php` verbs.)
