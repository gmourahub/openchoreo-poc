FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev
COPY . .
ENV PORT=8080
EXPOSE 8080
# Numeric UID: the platform runs pods with runAsNonRoot and Kubernetes only
# accepts that with a numeric user (1000 is "node" in this image).
USER 1000
CMD ["node", "server.js"]
