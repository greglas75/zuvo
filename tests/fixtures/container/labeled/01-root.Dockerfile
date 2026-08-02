# EXPECT: K2-root-user
FROM node:20.11.1@sha256:aa11bb22cc33dd44ee55ff6677889900aabbccddeeff00112233445566778899
WORKDIR /app
COPY --chown=node:node . .
CMD ["node","server.js"]
