# EXPECT: none
# Multi-stage: builder + distroless nonroot runtime, digest-pinned, no baked secrets
FROM node:20.11.1-slim@sha256:2f0b0c0d1e2f3a4b5c6d7e8f90112233445566778899aabbccddeeff00112233 AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY . .

FROM gcr.io/distroless/nodejs20-debian12:nonroot@sha256:aa11bb22cc33dd44ee55ff6677889900aabbccddeeff00112233445566778899
WORKDIR /app
COPY --from=builder /app /app
USER nonroot
CMD ["server.js"]
