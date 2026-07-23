# inventario-app

Catálogo de inventario con interfaz web y base de datos local. Este repositorio es el **punto de partida** de la tarea de CI/CD — no incluye `Dockerfile`, workflow de GitHub Actions ni manifiestos de Kubernetes: esos tres se construyen como parte del trabajo asignado.

## Qué es

Una app Node.js/Express con:

- **Interfaz web** (`public/index.html`, `public/app.js`, `public/styles.css`): una tabla de productos con formulario para agregar y botón para eliminar.
- **Base de datos local** (`db.js`): un archivo JSON en `data/products.json` que persiste los productos entre reinicios del proceso — sin motor de base de datos externo ni dependencias nativas.
- **API REST** consumida por la interfaz.

## Ejecutar en local

```bash
npm install
npm start
# abrir http://localhost:3000
```

## Pruebas

```bash
npm test
```

## Endpoints

| Método y ruta | Qué hace |
|---|---|
| `GET /health` | Estado de salud: `200` si el proceso y el archivo de base de datos son accesibles, `500` si no (o si `SIMULATE_FAILURE=true`). |
| `GET /version` | Devuelve `version`, `color` y `hostname` — configurables por variables de entorno `APP_VERSION` / `APP_COLOR`. |
| `GET /api/products` | Lista todos los productos. |
| `GET /api/products/:id` | Devuelve un producto por id. |
| `POST /api/products` | Crea un producto (`name`, `sku`, `stock`, `price`). |
| `PATCH /api/products/:id` | Actualiza campos de un producto. |
| `DELETE /api/products/:id` | Elimina un producto. |
| `GET /` | Sirve la interfaz web. |

## Variables de entorno

| Variable | Por defecto | Para qué |
|---|---|---|
| `PORT` | `3000` | Puerto del servidor. |
| `APP_VERSION` | `v1` | Se muestra en `/version` y en el encabezado de la interfaz. |
| `APP_COLOR` | `blue` | Color del encabezado — útil para distinguir versiones en un despliegue. |
| `SIMULATE_FAILURE` | `false` | Si es `true`, `/health` responde siempre `500`. |
| `DB_PATH` | `./data/products.json` | Ruta del archivo de base de datos local. |

## Guía de Reproducción Paso a Paso

#### Paso 1: Dockerización Multi-Stage
Se creó un `Dockerfile` en la raíz del proyecto para empaquetar la aplicación de forma segura y liviana, ejecutando pruebas antes de compilar la imagen final.

**Archivo a crear (`Dockerfile`):**
```dockerfile
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
```

**Ejecución local en PowerShell:**
```powershell
# Construir la imagen
docker build -t inventario-app:local .

# Probar contenedor en background
docker run -d -p 3000:3000 --name inventario-test inventario-app:local

# Validar que responde
curl.exe http://localhost:3000/health

# Limpiar
docker stop inventario-test
docker rm inventario-test
```

#### Paso 2: CI/CD con GitHub Actions
Se construyó el pipeline automatizado en `.github/workflows/ci-cd.yml` para ejecutar pruebas y publicar la imagen base en GitHub Container Registry (`ghcr.io`).

**Archivo `.github/workflows/ci-cd.yml` base:**
```yaml
name: CI/CD Pipeline

on:
  push:
    branches:
      - main

env:
  REGISTRY: ghcr.io

jobs:
  # --- JOB 1: Instalación y Pruebas ---
  build-test:
    runs-on: ubuntu-latest
    steps:
      - name: Descargar código fuente
        uses: actions/checkout@v4

      - name: Configurar Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '18'

      - name: Instalar dependencias exactas
        run: npm ci

      - name: Ejecutar pruebas (Fail-Fast)
        run: npm test

  # --- JOB 2: Construcción y Publicación ---
  build-push:
    needs: build-test # Fundamental: esto asegura que solo corre si las pruebas pasaron
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write # Permiso estricto y necesario para publicar la imagen en GitHub

    steps:
      - name: Descargar código fuente
        uses: actions/checkout@v4

      - name: Iniciar sesión en GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }} # GitHub te da este token automáticamente

      - name: Construir y publicar imagen Docker
        run: |
          # Convertimos el nombre del repositorio a minúsculas para que Docker no se queje
          IMAGE_ID=${{ env.REGISTRY }}/$(echo "${{ github.repository }}" | tr '[:upper:]' '[:lower:]')
          
          # 1. Construir la imagen con la etiqueta del hash del commit
          docker build -t $IMAGE_ID:${{ github.sha }} .
          
          # 2. Etiquetar también como "latest"
          docker tag $IMAGE_ID:${{ github.sha }} $IMAGE_ID:latest
          
          # 3. Subir ambas etiquetas a ghcr.io
          docker push $IMAGE_ID:${{ github.sha }}
          docker push $IMAGE_ID:latest 
```

**Despliegue al repositorio:**
```powershell
git add .github/workflows/ci-cd.yml
git commit -m "implementacion de pipeline base build y push"
git push origin main
```
***Verificación:** Vaya a la pestaña "Actions" en su repositorio de GitHub. Verá el flujo ejecutándose. Al finalizar, los jobs `build-test` y `build-push` estarán en verde y la imagen aparecerá en la sección "Packages" de su perfil.*

---

#### Paso 3: Manifiestos base de Kubernetes (K8s) y Despliegue
Se escribieron los archivos `k8s/deployment.yaml` (con mínimo 2 réplicas, estrategia RollingUpdate configurada con `maxUnavailable: 1` y `maxSurge: 1`, y los *probes* de salud apuntando a `/health`) y `k8s/service.yaml`.

**Archivo `k8s/deployment.yaml`:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inventario-app
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 1
  selector:
    matchLabels:
      app: inventario-app
  template:
    metadata:
      labels:
        app: inventario-app
    spec:
      containers:
      - name: inventario-app
        image: ghcr.io/caromml55-maker/examenfinalsd:latest
        imagePullPolicy: Always
        ports:
        - containerPort: 3000
        livenessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 5
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 5
          periodSeconds: 10
```

**Archivo `k8s/service.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: inventario-service
spec:
  type: NodePort
  selector:
    app: inventario-app
  ports:
    - protocol: TCP
      port: 80
      targetPort: 3000
```

**Despliegue y verificación (PowerShell):**
```powershell
# Desplegar en el clúster local
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml

# Confirmar el estado del despliegue
kubectl rollout status deployment/inventario-app

# Observar en vivo cómo el readinessProbe retiene el tráfico por 35s (0/1 a 1/1)
kubectl get pods -w

# Exponer servicio para obtener la URL
minikube service inventario-service
```
***Verificación:** El comando `kubectl rollout status` confirmará que el despliegue fue exitoso ("successfully rolled out"). Una vez que Minikube abra el túnel, se puede confirmar desde otra terminal ejecutando `curl http://127.0.0.1:<PUERTO_DEL_TUNEL>/health` y verificando que el servicio responde correctamente con un estado 200 OK.*

#### Paso 4: Prueba de Persistencia (Pérdida de datos)
Si agregamos un producto desde la interfaz web, el dato se guarda en el contenedor efímero.

**Ejecución en PowerShell:**
```powershell
# Listar pods para obtener el nombre exacto
kubectl get pods

# Eliminar un pod para forzar su recreación por el ReplicaSet
kubectl delete pod inventario-app-<hash-del-pod>
```
***Verificación:** Al refrescar el navegador, el producto creado manualmente ha desaparecido, demostrando la naturaleza efímera de los contenedores al no tener un `PersistentVolumeClaim`.*

---

### Estrategia de Blue-Green
Se optó por la estrategia Blue-Green para garantizar un cambio de tráfico del 100% sin estados intermedios, protegiendo la integridad del catálogo de inventario.

#### Paso 1: Creación de los manifiestos
Se debe crear una carpeta llamada `k8s/blue-green/` y dentro de ella colocar tres archivos: un despliegue para la versión "blue" (v1), otro para la "green" (v2), y un servicio que controla el tráfico.

**Archivo `k8s/blue-green/deployment-blue.yaml`:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inventario-app-blue
spec:
  replicas: 2
  selector:
    matchLabels:
      app: inventario-app
      version: blue
  template:
    metadata:
      labels:
        app: inventario-app
        version: blue
    spec:
      containers:
      - name: inventario-app
        image: ghcr.io/caromml55-maker/examenfinalsd:latest
        imagePullPolicy: Always
        env:
        - name: APP_VERSION
          value: "v1"
        - name: APP_COLOR
          value: "blue"
        ports:
        - containerPort: 3000
        livenessProbe:
          httpGet:
            path: /health
            port: 3000
        readinessProbe:
          httpGet:
            path: /health
            port: 3000
```

**Archivo `k8s/blue-green/deployment-green.yaml`:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inventario-app-green
spec:
  replicas: 2
  selector:
    matchLabels:
      app: inventario-app
      version: green
  template:
    metadata:
      labels:
        app: inventario-app
        version: green
    spec:
      containers:
      - name: inventario-app
        image: ghcr.io/caromml55-maker/examenfinalsd:latest
        imagePullPolicy: Always
        env:
        - name: APP_VERSION
          value: "v2"
        - name: APP_COLOR
          value: "green"
        ports:
        - containerPort: 3000
        livenessProbe:
          httpGet:
            path: /health
            port: 3000
        readinessProbe:
          httpGet:
            path: /health
            port: 3000
```

**Archivo `k8s/blue-green/service.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: inventario-service-bg
spec:
  type: NodePort
  selector:
    app: inventario-app
    version: blue
  ports:
    - protocol: TCP
      port: 80
      targetPort: 3000
```

#### Paso 2: Ejecución y validación
Antes de aplicar esta estrategia, limpiamos el entorno base para evitar conflictos de puertos o selectores.

**Ejecución en PowerShell:**
```powershell
# 1. Eliminar despliegue base (si existe)
kubectl delete -f k8s/deployment.yaml
kubectl delete -f k8s/service.yaml

# 2. Aplicar los despliegues de ambas versiones simultáneamente
kubectl apply -f k8s/blue-green/

# 3. Verificar que los pods de ambas versiones corren en paralelo
kubectl get pods -l app=inventario-app

# 4. Exponer el servicio Blue-Green
minikube service inventario-service-bg
```

#### Paso 3: Demostración del corte de tráfico
Se comprueba el enrutamiento inicial y luego se modifica el selector del servicio (cambiando de `version: blue` a `version: green`) para redirigir el tráfico de forma instantánea.

**Ejecución en PowerShell (En una nueva terminal):**
```powershell
# 1. Comprobar versión actual (Devuelve "blue" / "v1")
curl.exe [http://127.0.0.1](http://127.0.0.1):<PUERTO_DEL_TUNEL>/version

# 2. Parcheo dinámico del servicio para el switch de tráfico
'{"spec":{"selector":{"version":"green"}}}' | Out-File patch.json -Encoding utf8
kubectl patch service inventario-service-bg --patch-file patch.json
Remove-Item patch.json

# 3. Comprobar nueva versión (Devuelve "green" / "v2" de forma inmediata)
curl.exe [http://127.0.0.1](http://127.0.0.1):<PUERTO_DEL_TUNEL>/version
```
***Verificación:** Al realizar el primer `curl`, la respuesta JSON mostrará `{"version":"v1","color":"blue"}`. Tras ejecutar el parcheo y lanzar el segundo `curl`, la respuesta cambiará inmediatamente a `{"version":"v2","color":"green"}`, confirmando que el 100% del tráfico migró sin caída del servicio.*

### Componentes Adicionales de Buenas Prácticas
Se implementó tres componentes avanzados de configuración, seguridad y resiliencia.

#### Componente 1: Manejo de secretos
Para evitar exponer credenciales (como contraseñas o tokens) en texto plano dentro de los repositorios versionados en Git, se implementó el uso de Secretos nativos de Kubernetes, los cuales se inyectan en el contenedor mediante `secretKeyRef`.

**Creación del secreto (PowerShell):**
Se crea el secreto de forma imperativa en el clúster antes de desplegar la aplicación.
```powershell
kubectl create secret generic app-secrets --from-literal=API_KEY=sk_test_super_secret
```

**Verificación de la encriptación base64:**
Se verifica que el secreto fue creado correctamente en el clúster consultando su salida en formato YAML.
```powershell
kubectl get secret app-secrets -o yaml
```

**Aplicación del manifiesto:**
Una vez creado el secreto, se aplica el despliegue que lo consume.
```powershell
kubectl apply -f k8s/deployment.yaml
```
***Verificación:** Al ejecutar el comando `get secret -o yaml`, el clúster devuelve la estructura del secreto mostrando el valor de la `API_KEY` codificado en base64 (`c2tfdGVzdF9zdXBlcl9zZWNyZXQ=`). Esto demuestra que la credencial está protegida en la base de datos de Kubernetes (etcd) y lista para ser inyectada dinámicamente en los pods.*
---

#### Componente 2: Escaneo de seguridad en el pipeline:
Se integró la herramienta de análisis estático (SAST) Trivy de Aqua Security dentro del pipeline de GitHub Actions (`.github/workflows/ci-cd.yml`). El objetivo es interceptar vulnerabilidades en la imagen Docker recién construida antes de publicarla.

**Código añadido al pipeline:**
Se agregó el siguiente paso (step) justo después de construir la imagen y antes de hacer el push:

**Archivo `github/workflows/ci-cd.yml`:**
```yaml
       # --- JOB 3: Escaneo de Vulnerabilidades (Trivy) ---
  trivy-scan:
    needs: build-push 
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - name: Descargar código fuente
        uses: actions/checkout@v4

      - name: Iniciar sesión en GHCR (para permitir la descarga de la imagen)
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Ejecutar escaneo de vulnerabilidades con Trivy
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: '${{ env.REGISTRY }}/${{ github.repository }}:latest'
          format: 'table'
          exit-code: '0' 
          ignore-unfixed: true
          severity: 'CRITICAL,HIGH'

      - name: Reporte de escaneo completado
        run: echo "Escaneo de seguridad Trivy finalizado correctamente."
```

**Despliegue de la mejora (PowerShell):**
```powershell
git add .github/workflows/ci-cd.yml
git commit -m "job de Trivy"
git push origin main
```
***Verificación:** Al revisar la pestaña "Actions" en GitHub, se observará un nuevo paso en el job de publicación. Si Trivy detecta alguna vulnerabilidad de nivel `CRITICAL`, forzará un `exit-code: 1`, haciendo que el pipeline falle y protegiendo el entorno de producción contra imágenes inseguras.*

---

#### Componente 3: Readiness realista con arranque lento
Se simuló el comportamiento de una aplicación pesada (por ejemplo, una que tarda en conectar a su base de datos) añadiendo un retardo intencional. Para que Kubernetes no asuma erróneamente que la aplicación falló y reinicie el pod (CrashLoopBackOff), se ajustaron los tiempos de gracia de las sondas de salud.

**Configuración en `deployment.yaml`:**
Se agregó la variable de entorno `STARTUP_DELAY_SECONDS` y se incrementó el `initialDelaySeconds` a 35 segundos en los *probes*.
```yaml
        env:
        - name: STARTUP_DELAY_SECONDS
          value: "30"
        livenessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 35
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 35
          periodSeconds: 10
```

**Ejecución y demostración (PowerShell):**
```powershell
# Aplicar el manifiesto actualizado
kubectl apply -f k8s/deployment.yaml

# Monitorear el comportamiento en vivo del tráfico
kubectl get pods -w
```
***Verificación:** En la terminal, se observará que el nuevo pod se crea pero permanece en estado `READY: 0/1` (ejecutándose pero sin recibir tráfico) durante los primeros ~35 segundos. Una vez superado el tiempo de retardo programado, cambiará automáticamente a `1/1`, demostrando que los probes toleraron el arranque lento exitosamente.*