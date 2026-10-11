# 📊 HermesPG Monitoring Stack (Prometheus + Grafana)

Este directorio contiene la pila de observabilidad completa para HermesPG, preconfigurada para recopilar métricas nativas en formato **OpenMetrics** cada 2 segundos y visualizarlas en un dashboard de Grafana con cero configuración manual.

---

## 🚀 Inicio Rápido

### 1. Iniciar HermesPG con el Exportador de Métricas Activo
HermesPG expone el endpoint `/metrics` en el puerto `9127` por defecto:

```bash
./hermespg -U scram_user -W 'HermesSecr3t!2026' -p 6432 -c 10
```

Puedes verificar el payload de métricas directamente:
```bash
curl -s http://localhost:9127/metrics
```

### 2. Levantar la Pila de Monitoreo
Desde este directorio (`deploy/monitoring`):

```bash
docker compose up -d
# o alternativamente con podman:
# podman-compose up -d
```

### 3. Acceder a las Interfaces Web
- **Grafana Dashboard**: [http://localhost:3000](http://localhost:3000)
  - *Acceso directo*: Anonymous Viewer habilitado (no requiere login).
  - *Admin Login*: Usuario `admin`, Contraseña `admin`.
  - *Dashboard precargado*: **HermesPG - Production Monitoring & Observability** (en la carpeta `HermesPG`).
- **Prometheus UI**: [http://localhost:9090](http://localhost:9090)
  - Target: [http://localhost:9090/targets](http://localhost:9090/targets) (verifica el estado UP de HermesPG).

---

## 📈 Paneles del Dashboard

El dashboard precargado (`hermespg_overview.json`) incluye visualización en tiempo real para:

1. **⚡ Overview & Health**:
   - TPS (Transacciones por segundo en tiempo real: `rate(hermespg_transactions_total[15s])`).
   - QPS (Consultas por segundo: `rate(hermespg_queries_total[15s])`).
   - Conexiones Físicas Arrendadas vs Capacidad Máxima del Pool.
   - Clientes Conectados activos en el frontend.
   - Profundidad de la cola de espera (`Queue Depth`).
   - Uptime acumulado del servidor proxy.

2. **📈 Traffic & Throughput**:
   - Rendimiento de consultas y transacciones por segundo.
   - Ratio de adquisición Fast-Path (LIFO cache hit en RAM) vs Slow-Path (espera en cola asíncrona).

3. **🏊 Connection Pool Saturation & Queuing**:
   - Distribución de conexiones activas (arrendadas) vs inactivas (idle disponibles).
   - Clientes esperando en cola y tasa de peticiones descartadas por saturación (**Load Shedding** con SQLSTATE `53300`).

4. **🛡️ SCRAM-SHA-256 Authentication & Security**:
   - Tasa de intentos de autenticación exitosos vs rechazados.
   - Desglose de fallos de seguridad por contraseña incorrecta (`invalid_password`) o usuario no autorizado (`invalid_user`) con SQLSTATE `28P01`.

5. **🧹 Watchdog & Session Hygiene**:
   - Transacciones huérfanas abortadas automáticamente por el watchdog (`ROLLBACK`).
   - Conexiones recicladas y desinfectadas con `DISCARD ALL` tras estados modificados.

---

## 🛑 Detener la Pila
Para detener los contenedores:
```bash
docker compose down
```
