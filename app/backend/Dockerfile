FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY *.js ./
USER node
ENV PORT=8080
EXPOSE 8080
# The worker component overrides this with: node worker.js
CMD ["node", "api.js"]
