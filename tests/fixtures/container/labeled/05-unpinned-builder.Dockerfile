# EXPECT: K1-unpinned-builder
FROM node:latest AS builder
WORKDIR /app
COPY . .
RUN npm ci && npm run build
FROM gcr.io/distroless/nodejs20-debian12:nonroot@sha256:aa11bb22cc33dd44ee55ff6677889900aabbccddeeff00112233445566778899
COPY --from=builder /app/dist /app
USER nonroot
CMD ["/app/server.js"]
