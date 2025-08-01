# ---- Etapa Base ----
# Usamos una imagen oficial de Node.js con Alpine Linux para un tamaño reducido.
# Fijamos la versión para compilaciones reproducibles.
FROM node:22-alpine AS base

# Establecemos el directorio de trabajo dentro del contenedor.
WORKDIR /usr/src/app

# Por defecto, Corepack (que gestiona pnpm) está disponible en las imágenes de Node.
# Lo habilitamos para poder usar pnpm sin instalarlo globalmente.
RUN corepack enable

# ---- Etapa de Dependencias ----
# Esta etapa se enfoca únicamente en instalar las dependencias de producción.
# Se beneficia enormemente del cache de Docker.
FROM base AS deps

# Copiamos solo los archivos de manifiesto. La caché de esta capa
# solo se invalidará si pnpm-lock.yaml o package.json cambian.
COPY pnpm-lock.yaml package.json./

# Usamos un cache mount de BuildKit para persistir el store de pnpm entre compilaciones.
# Esto acelera drásticamente las instalaciones posteriores.
# pnpm fetch descarga los paquetes al store sin instalarlos en node_modules.
RUN --mount=type=cache,id=pnpm,target=/root/.local/share/pnpm/store \
    pnpm fetch --prod --frozen-lockfile

# pnpm install ahora usará los paquetes del store cacheado para crear node_modules.
RUN --mount=type=cache,id=pnpm,target=/root/.local/share/pnpm/store \
    pnpm install --prod --frozen-lockfile

# ---- Etapa de Compilación ----
# Esta etapa instala TODAS las dependencias (incluidas las de desarrollo) y compila la aplicación.
FROM base AS build

# Copiamos los archivos de manifiesto nuevamente.
COPY pnpm-lock.yaml package.json./

# Usamos el mismo cache mount para acelerar la instalación de TODAS las dependencias.
RUN --mount=type=cache,id=pnpm,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile

# Ahora copiamos el resto del código fuente.
COPY. .

# Ejecutamos el script de compilación definido en package.json.
RUN pnpm run build

# ---- Etapa de Producción ----
# Esta es la imagen final, optimizada para ser pequeña y segura.
FROM base AS production

# Establecemos variables de entorno para producción.
# NODE_ENV=production es crucial para el rendimiento de Node.js y NestJS.
ENV NODE_ENV=production

# Creamos un usuario y grupo 'node' sin privilegios. La imagen base ya lo incluye,
# pero es bueno ser explícito. Aquí nos aseguramos de que el directorio de la app exista.
# El usuario 'node' ya existe en la imagen base 'node:alpine'.
# Creamos el directorio y asignamos la propiedad al usuario 'node'.
RUN mkdir -p /usr/src/app/dist && chown -R node:node /usr/src/app

# Cambiamos al usuario sin privilegios. Todas las instrucciones siguientes se ejecutarán como 'node'.
USER node

# Copiamos el directorio de trabajo al nuevo contenedor
WORKDIR /usr/src/app

# Copiamos las dependencias de producción desde la etapa 'deps'.
# Usamos --chown para asegurarnos de que el usuario 'node' sea el propietario.
COPY --from=deps --chown=node:node /usr/src/app/node_modules ./node_modules

# Copiamos el código compilado desde la etapa 'build'.
COPY --from=build --chown=node:node /usr/src/app/dist ./dist

# Copiamos otros archivos necesarios para la ejecución.
COPY --chown=node:node package.json ecosystem.config.js./

# Exponemos el puerto que la aplicación usará. Es buena práctica usar ARG para hacerlo configurable.
ARG PORT=8000
EXPOSE $PORT

# El comando para iniciaasr la aplicación.
# pm2-runtime es el reemplazo recomendado de 'node' para contenedores,
# ya que maneja correctamente las señales del sistema (SIGINT, SIGTERM).
CMD ["pm2-runtime", "start", "ecosystem.config.js"]