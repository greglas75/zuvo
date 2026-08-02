# EXPECT: K1-mutable-version-tag
FROM node:20.11.1-slim
USER node
COPY --chown=node:node . /app
CMD ["node","/app/server.js"]
