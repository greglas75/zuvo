# Vendored, de-secreted sample (real-shape; secret values scrubbed to ***).
FROM node:20-alpine
WORKDIR /usr/src/app
ENV NODE_ENV=production
ENV SESSION_SECRET=***
COPY . .
RUN npm install --production
EXPOSE 3000
CMD ["npm","start"]
