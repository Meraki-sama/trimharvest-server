# ---- Multi-stage build (12-factor, Railway-friendly) ----
# Base image Node 20-alpine. Railway inject DATABASE_URL otomatis dari
# Postgres add-on; tidak perlu file credential apa pun di container.
# NOTE: Railway build context = root repo, jadi semua COPY merujuk ke
# folder server/ (sesuai letak kode di repo ini).
FROM node:20-alpine AS build
WORKDIR /app
COPY server/package*.json ./
RUN npm ci --omit=dev
COPY server/ ./

# Runtime image: jauh lebih kecil & tidak mengandung devDeps/build tools.
FROM node:20-alpine AS runtime
ENV NODE_ENV=production
WORKDIR /app

# Jalankan sebagai non-root user (standar keamanan container).
RUN addgroup -S trimharvest && adduser -S trimharvest -G trimharvest

COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app ./

USER trimharvest

EXPOSE 8080
# Healthcheck untuk orchestrator (Railway membaca /health).
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:8080/health || exit 1

# Port di-inject Railway via env PORT; default 8080.
ENV PORT=8080
CMD ["node", "src/index.js"]
