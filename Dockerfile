# --- Etapa 1: Construcción y Pruebas (builder) ---
FROM node:18-alpine AS builder
WORKDIR /app

COPY package*.json ./
RUN npm ci
COPY . .
RUN npm test

# --- Etapa 2: Imagen Final de Producción ---
FROM node:18-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev

COPY --from=builder /app/server.js ./
COPY --from=builder /app/db.js ./
COPY --from=builder /app/public ./public
RUN mkdir data

EXPOSE 3000

CMD ["npm", "start"]