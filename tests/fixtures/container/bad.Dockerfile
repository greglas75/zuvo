# EXPECT: K1-latest-tag K2-root-user K3-secret-in-env K3-no-dockerignore
FROM node:latest
WORKDIR /app
ENV API_KEY=sk-live-51H8xExampleSecretValue0000
COPY . .
RUN npm install
CMD ["node", "server.js"]
