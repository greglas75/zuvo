# EXPECT: K4-no-multistage
FROM node:20.11.1@sha256:aa11bb22cc33dd44ee55ff6677889900aabbccddeeff00112233445566778899
RUN apt-get update && apt-get install -y build-essential curl
COPY . .
RUN npm install && npm run build
USER node
CMD ["node","dist/server.js"]
