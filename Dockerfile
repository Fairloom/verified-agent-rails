# syntax=docker/dockerfile:1

# VAR dashboard (web/) — Next.js 15 app with server-side API routes.
#
# Built from the REPO ROOT context (not web/) because the web app depends on the
# @var/shared workspace via `transpilePackages` and resolves it from the root
# node_modules. The contracts/ and agent/ trees are NOT services and are not
# shipped — agent/package.json is copied only so the workspace install resolves.

# ---- build: install the full workspace, then compile the Next.js app ----
FROM node:20-bookworm AS build
WORKDIR /app

# Workspace manifests first so the `npm ci` layer caches on lockfile changes
# only — editing source below does not re-run the install.
COPY package.json package-lock.json ./
COPY shared/package.json shared/
COPY agent/package.json agent/
COPY web/package.json web/
RUN npm ci

# Only the sources the web build actually reads: the app itself plus the shared
# TS sources Next transpiles. (agent/ source and contracts/ are excluded.)
COPY shared/ shared/
COPY web/ web/

# NEXT_PUBLIC_* values are inlined into the client bundle at BUILD time, so they
# must be present here — runtime secrets are too late. These are public (not
# secret); pass real values via the [build.args] block in fly.toml.
#
# IMPORTANT: only NON-EMPTY values are exported into the build. An empty/omitted
# arg is left genuinely undefined (like local dev) so the app's own `?? default`
# fallbacks apply — REGISTER_RELAY_URL and AGENT_ADDRESS both default in code,
# and baking an empty string would defeat `??` (empty string is not nullish).
ARG NEXT_PUBLIC_DYNAMIC_ENVIRONMENT_ID
ARG NEXT_PUBLIC_WORLD_APP_ID
ARG NEXT_PUBLIC_WORLD_ACTION_ID
ARG NEXT_PUBLIC_AGENT_ADDRESS
ARG NEXT_PUBLIC_REGISTER_RELAY_URL
ENV NEXT_TELEMETRY_DISABLED=1
RUN for v in NEXT_PUBLIC_DYNAMIC_ENVIRONMENT_ID NEXT_PUBLIC_WORLD_APP_ID \
             NEXT_PUBLIC_WORLD_ACTION_ID NEXT_PUBLIC_AGENT_ADDRESS \
             NEXT_PUBLIC_REGISTER_RELAY_URL; do \
      eval "val=\${$v}"; \
      if [ -n "$val" ]; then export "$v=$val"; else unset "$v"; fi; \
    done; \
    npm run build -w @var/web

# ---- runtime: slim image running `next start` ----
FROM node:20-bookworm-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production \
    PORT=3000 \
    HOSTNAME=0.0.0.0 \
    NEXT_TELEMETRY_DISABLED=1

# We ship the full installed workspace rather than Next `standalone` output: the
# Dynamic MPC packages are declared serverExternalPackages and are require()d
# from node_modules at runtime, which standalone tracing does not reliably bundle.
# Copying shared/ and web/ to their original paths keeps the workspace symlinks in
# node_modules (@var/shared, @var/web) and any nested web/node_modules valid.
COPY --from=build /app/package.json /app/package-lock.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/shared ./shared
COPY --from=build /app/web ./web

EXPOSE 3000
CMD ["npm", "run", "start", "-w", "@var/web"]
