# Hermes on Heroku — Reference Deployment

This is the **reference/test runtime** described in Section 12A of the WAO
Bootstrapper specification. It exists to establish a known-good, reproducible
Hermes deployment recipe on Heroku. It is not a production WAO runtime, and
`bootstrapper-wao` must never clone this app's mutable state — it reuses the
deployment *definition* only.

Upstream Hermes is kept intact. The Heroku layer is four files:

| File | Purpose |
|---|---|
| `heroku.yml` | Build/run recipe; passes `HERMES_DATA_MODE=0777` |
| `docker/heroku-entrypoint.sh` | Non-root boot path; replaces s6 + `main-wrapper.sh` |
| `Dockerfile` (2 small additions) | `HERMES_DATA_MODE` build arg; final `heroku` stage |
| `HEROKU.md` | This document |

---

## 1. Why the upstream image cannot run unmodified

Heroku's container runtime **ignores `USER` and runs the image as a random,
unprivileged UID** with no `/etc/passwd` entry and no root. The upstream boot
path is incompatible with that in three specific places:

1. `docker/stage2-hook.sh` **exits 1** when started as an arbitrary non-root,
   non-`hermes` UID (it needs root for `usermod`/`groupmod`/`chown`).
2. `docker/main-wrapper.sh` has the **same hard rejection**, plus a
   `s6-setuidgid` privilege drop that requires root.
3. s6-overlay's `/init` requires PID 1. The upstream dispatcher does have a
   non-PID-1 fallback, but it still routes into `stage2-hook.sh` +
   `main-wrapper.sh`, so it hits rejections (1) and (2) anyway.

`docker/heroku-entrypoint.sh` sidesteps all three: no `/init`, no
`s6-setuidgid`, no user remapping. It re-implements the **non-privileged
subset** of `stage2-hook.sh` inline — data-tree seeding, config seeding,
`API_SERVER_KEY` generation, config migration, skills sync, and Chromium
discovery — then execs the web process directly.

### The `/opt/data` permission fix is a build arg, not a `chmod`

`/opt/data` is declared a `VOLUME`, and **Docker discards any build-step write
to a path after it has been declared a volume**. A `chmod` in a later stage is
silently voided — the container then fails at boot with `EACCES` and the image
looks correct on inspection. The fix is therefore applied *before* the `VOLUME`
instruction, via the `HERMES_DATA_MODE` build arg (default `0755`, unchanged
for normal Docker; `heroku.yml` passes `0777`).

### What this deployment gives up (deliberately)

- **No supervised services.** No s6 tree, so per-profile gateway supervision
  and the auto-restart behavior are absent here.
- **No persistence.** `/opt/data` is ordinary ephemeral dyno filesystem.
  Heroku discards it on every restart/replace **and cycles dynos roughly every
  24 hours**. Cataloguing exactly what disappears is the point of this
  deployment (spec Section 16).

---

## 2. Pinning the version

This repository is a **fork with its own history**, not a mirror tracking
upstream. Two different things are worth pinning, and they are not the same:

| Pin | Value | Meaning |
|---|---|---|
| **Hermes version** | `0.20.1` (from `pyproject.toml`) | The upstream Hermes code this recipe was validated against. This is the pin the `HermesRuntimeSpecification` records. |
| **Recipe baseline commit** | `1fc3975` | The commit in *this* repo that established the Heroku layer. A documentation anchor for "what the recipe looked like when validated" — not a build input. |

The upstream `NousResearch/hermes-agent` commit SHA is **not recoverable**: this
tree was imported from an extracted snapshot rather than cloned, so no upstream
history exists here. If exact upstream provenance matters later, diff this tree
against upstream tag `v0.20.1` and record the result.

Do not track upstream `main`. Take upstream changes as deliberate, reviewed
merges, and re-validate the exit criteria in §8 after each one.

### Why `HERMES_GIT_SHA` is deliberately not set in `heroku.yml`

`hermes_cli/build_info.py` reads a baked `HERMES_GIT_SHA` build arg so
`hermes dump` and the startup banner can report the running commit. It is
tempting to hardcode it in `heroku.yml`, but a static value there goes stale on
the very next commit and then **actively misreports** which code is running —
worse than the honest `(unknown)` it replaces.

If you want an accurate baked SHA for a specific deploy, pass it at build time
instead of committing it:

```bash
heroku config:set -a hermes-agent-wao-heroku HEROKU_BUILD_SHA="$(git rev-parse HEAD)"
```

Otherwise rely on `heroku releases`, which records the deployed commit per
release without any risk of drift.

---

## 3. Create the app

The container stack + `heroku.yml` build is a **Cedar-generation** mechanism.
Create the app explicitly on Cedar so the recipe is reproducible:

```bash
heroku create hermes-agent-wao-heroku --stack container
heroku stack:set container -a hermes-agent-wao-heroku
```

Then either connect the GitHub repo in the Heroku Dashboard, or push directly:

```bash
git push heroku main
```

**Dyno size:** start at **Performance-M**. Chromium/Playwright plus the Python
and Node runtimes will not fit a 512 MB Standard-1X dyno.

```bash
heroku ps:type web=performance-m -a hermes-agent-wao-heroku
```

Eco/Basic dynos sleep on inactivity and must not be used.

---

## 4. Required config vars

Secrets go here, never into the repo. `.env.example` is reference only. The
entrypoint writes a `.env` containing only a generated loopback
`API_SERVER_KEY`, and skips even that when you supply one as a config var
(see §6).

**Dashboard authentication (required — it fails closed).** The dashboard's
auth gate engages automatically on a non-loopback bind and refuses to start
without a provider. `HERMES_DASHBOARD_INSECURE` no longer disables it.

```bash
heroku config:set -a hermes-agent-wao-heroku \
  HERMES_DASHBOARD=1 \
  HERMES_DASHBOARD_BASIC_AUTH_USERNAME=<user> \
  HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=<strong-password>
```

(Or `HERMES_DASHBOARD_OAUTH_CLIENT_ID` for the bundled Nous OAuth provider.)

**Model/provider selection (required).** The seeded `config.yaml` comes from
upstream's `cli-config.yaml.example`, which ships
`model.default: anthropic/claude-opus-4.6`, `model.provider: "auto"` **and**
`model.base_url: https://openrouter.ai/api/v1`. That combination is wrong for
any direct-provider deployment — `auto` resolves against whichever key it
finds, and the leftover OpenRouter base URL can send a direct provider's key to
OpenRouter and 401.

There is no Hermes environment variable for provider/model (`LLM_MODEL` is a
dead var; `HERMES_MODEL` is CLI/cron plumbing), so the entrypoint patches
`config.yaml` from two Heroku-layer vars. Naming a provider also removes
`model.base_url` so the provider registry's own base URL is used.

| Var | Anthropic (default path) | OpenAI equivalent |
|---|---|---|
| `HERMES_MODEL_PROVIDER` | `anthropic` | `openai-api` |
| `HERMES_MODEL_DEFAULT` | `claude-sonnet-5` | `gpt-5.6-sol` |
| Credential | `ANTHROPIC_API_KEY` | `OPENAI_API_KEY` |
| Base-URL override | `ANTHROPIC_BASE_URL` | `OPENAI_BASE_URL` |

```bash
heroku config:set -a hermes-agent-wao-heroku \
  ANTHROPIC_API_KEY=<key> \
  HERMES_MODEL_PROVIDER=anthropic \
  HERMES_MODEL_DEFAULT=claude-sonnet-5
```

Valid model slugs come from `hermes_cli/models.py` (dots and dashes are
interchangeable): Anthropic — `claude-fable-5`, `claude-sonnet-5`,
`claude-opus-4-8`, `claude-opus-4-6`, `claude-haiku-4-5-20251001`;
OpenAI — `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.5`, `gpt-5.4-mini`, `gpt-4o-mini`.
A bare `gpt-5.6` is **not** a valid slug.

**Do not set `PORT`.** Heroku assigns it at dyno start; it cannot be set as a
config var.

### Optional

| Var | Effect |
|---|---|
| `HEROKU_WEB_CMD` | Overrides the web process command without rebuilding the image (see §6) |
| `API_SERVER_KEY` | **Enables** the gateway api_server; must be ≥16 chars (see §6) |
| `HERMES_GATEWAY_BOOTSTRAP_STATE=running` | Honored by upstream boot only; **no effect here** (no s6 reconciler) |
| `API_SERVER_HOST` / `API_SERVER_PORT` | Move the gateway api_server off its `127.0.0.1:8642` default |

---

## 5. Default exposed surface

The default web process is the **auth-gated dashboard bound to `$PORT`**,
mirroring upstream's own hosted topology: the dashboard is the single public
door, and the gateway `api_server` stays on loopback behind `API_SERVER_KEY`.

Exactly one process can receive routed traffic — Heroku routes inbound HTTP
only to the `web` process. Everything else stays localhost-only inside the dyno.

---

## 6. Switching to the gateway/API surface

`bootstrapper-wao` ultimately needs a programmatic control surface, not a
dashboard. The api_server exposes `GET /health` and is env-configurable, so it
can be promoted to the public port without an image rebuild.

**`API_SERVER_KEY` is the enable switch, not `API_SERVER_ENABLED`.**
`gateway/config.py` only enrols the api_server platform when `API_SERVER_KEY`
is present and **≥16 characters** (`_has_usable_api_server_key`, mirroring the
adapter's own startup guard). Setting `API_SERVER_ENABLED=true` on its own
does nothing useful — the code comment notes it would load a platform whose
adapter then refuses to start, leaving the reconnect watcher spinning.

Supply the key as a config var so callers know it. The entrypoint deliberately
does **not** write a generated key into `.env` when one is supplied, because
Hermes prefers `$HERMES_HOME/.env` over the process environment and a
generated key would otherwise shadow yours:

```bash
heroku config:set -a hermes-agent-wao-heroku \
  API_SERVER_KEY=<random-32-char-secret> \
  HEROKU_WEB_CMD='API_SERVER_HOST=0.0.0.0 API_SERVER_PORT=$PORT hermes gateway run --replace'
```

`$PORT` stays single-quoted so it is expanded at dyno start, not by your shell.

**This path is unvalidated** — whether the gateway starts cleanly under Heroku's
constraints is still an open question. Resolving it is part of the exit criteria
below, and the answer determines the `HermesRuntimeSpecification`'s
`required exposed service/API behavior` field.

---

## 7. Known constraints to test against

| Constraint | What to watch for |
|---|---|
| 60s web boot timeout (R10) | Hermes may not bind `$PORT` in time. If it fails, ask Heroku support to extend to 120/180s and **record that the recipe depends on it** |
| ~30s router request timeout | Any request that triggers real agent work will exceed it; the bootstrapper needs an async/polling pattern |
| Random non-root UID | Any `EACCES` means a path needs opening before the `VOLUME` line |
| Daily dyno cycling | All `/opt/data` state is lost; expected |
| Large image | Measure build time and cold-start time |

---

## 8. Exit criteria (spec §12A)

Record every result; these become the `HermesRuntimeSpecification`.

- [ ] Image builds on Heroku via `heroku.yml`
- [ ] Container starts under the random non-root UID with no `EACCES`
- [ ] Web process binds `$PORT` inside the boot window
- [ ] Process stays running (no crash loop); dyno cycling observed and timed
- [ ] Health can be inspected programmatically (`GET /health` reachable)
- [ ] The API/gateway surface the bootstrapper needs is reachable and
      authenticated (see §6)
- [ ] Long operations survive the router timeout via an async pattern
- [ ] A profile can be created, inspected, started, stopped, deleted
- [ ] Multiple profiles coexist in one runtime
- [ ] Full inventory of state lost on restart, classified as reconstructable
      config / durable state / secret / cache / temp
- [ ] Measured peak memory and the minimum viable dyno size
- [ ] Image build time and cold-start time
- [ ] The deployment mechanism automation will reproduce (spec §13) exercised
      end-to-end

**Exit criterion:** a known-good deployment recipe exists and can be
reproduced. Automated provisioning implements *this validated recipe* rather
than inventing a topology.

---

## 9. Useful commands

```bash
heroku logs --tail -a hermes-agent-wao-heroku
heroku ps -a hermes-agent-wao-heroku
heroku run bash -a hermes-agent-wao-heroku          # one-off dyno; entrypoint passes args through
heroku run hermes profile list -a hermes-agent-wao-heroku
heroku releases -a hermes-agent-wao-heroku
```

One-off dynos get a **fresh, empty filesystem** — they do not share the web
dyno's `/opt/data`. Inspect live runtime state through the web process, not
through `heroku run`.
