FROM node:20.11.1-slim@sha256:aa11bb22cc33dd44ee55ff6677889900aabbccddeeff00112233445566778899 AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci && npm cache clean --force
COPY . .
RUN npm run build

FROM gcr.io/distroless/nodejs20-debian12:nonroot@sha256:bb22cc33dd44ee55ff6677889900aabbccddeeff001122334455667788990011
WORKDIR /app
COPY --from=builder /app/dist /app
USER nonroot
CMD ["server.js"]
