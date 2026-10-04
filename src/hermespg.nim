import std/[asyncdispatch, strformat]
import hermespg/proxy
import hermespg/backend/pool

when defined(posix):
  import std/posix

proc raiseFileDescriptorLimit() =
  ## Eleva automáticamente el límite de sockets abiertos en Linux (RLIMIT_NOFILE)
  ## de 1,024 al límite permitido por el sistema (hasta 65,536)
  when defined(posix):
    var limit: RLimit
    if getrlimit(RLIMIT_NOFILE, limit) == 0:
      let desired = min(limit.rlim_max, type(limit.rlim_max)(65536))
      if limit.rlim_cur < desired:
        limit.rlim_cur = desired
        if setrlimit(RLIMIT_NOFILE, limit) == 0:
          echo fmt"[*] Límite de sockets del sistema elevado a: {desired} descriptores"
        else:
          echo "[WARN] No se pudo elevar el límite de descriptores"

proc onControlC() {.noconv.} =
  echo "\n[INFO] Señal de terminación recibida (Ctrl+C). Iniciando apagado seguro..."
  shutdownRequested = true
  if shutdownFuture != nil and not shutdownFuture.finished:
    shutdownFuture.complete()

proc main() =
  setControlCHook(onControlC)
  raiseFileDescriptorLimit()

  let poolSettings = PoolSettings(
    pgHost: "127.0.0.1",
    pgPort: Port(5432),
    user: "postgres",
    password: "",
    database: "postgres",
    maxConnections: 10,           # 10 conexiones físicas hacia Postgres
    maxQueueSize: 2000,           # Soporta hasta 2,000 clientes en cola de espera
    acquireTimeoutMs: 15000,      # 15s de espera máxima en cola para cargas masivas
    idleTxTimeoutMs: 8000,        # 8s de inactividad máxima en transacciones
    resetQuery: "DISCARD ALL;",   # Limpieza de sesión
    resetBeforeFirstQuery: true   # Limpiar antes de entregar al cliente
  )

  let serverConfig = ServerConfig(
    listenPort: Port(6432),
    poolSettings: poolSettings,
    verbose: false                # En cargas de 1,000 clientes, el logging a terminal satura el kernel
  )

  waitFor startServer(serverConfig)

when isMainModule:
  main()
