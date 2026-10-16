import std/[asyncdispatch, strformat]
import hermespg/proxy
import hermespg/config
import hermespg/metrics
import hermespg/backend/connection
import hermespg/auth/catalog

when defined(posix):
  import std/posix

type
  MetricsThreadArgs = object
    port: Port
    bindAddr: string

var metricsThread: Thread[MetricsThreadArgs]

proc metricsWorker(args: MetricsThreadArgs) {.thread.} =
  {.cast(gcsafe).}:
    waitFor startMetricsServer(args.port, args.bindAddr)

proc raiseFileDescriptorLimit() =
  ## Automatically raises open file/socket descriptor limit on Linux (RLIMIT_NOFILE)
  ## from 1,024 to the system allowed maximum (up to 65,536)
  when defined(posix):
    var limit: RLimit
    if getrlimit(RLIMIT_NOFILE, limit) == 0:
      let desired = min(limit.rlim_max, type(limit.rlim_max)(65536))
      if limit.rlim_cur < desired:
        limit.rlim_cur = desired
        if setrlimit(RLIMIT_NOFILE, limit) == 0:
          echo fmt"[*] System file descriptor limit raised to: {desired} descriptors"
        else:
          echo "[WARN] Could not raise system file descriptor limit"

proc onControlC() {.noconv.} =
  echo "\n[INFO] Termination signal received (Ctrl+C). Initiating graceful shutdown..."
  shutdownRequested = true
  if shutdownFuture != nil and not shutdownFuture.finished:
    shutdownFuture.complete()

proc workerThread(cfg: ServerConfig) {.thread.} =
  {.cast(gcsafe).}:
    waitFor startServer(cfg)

proc main() =
  let serverConfig = parseConfig()

  if serverConfig.genAuthFile.len > 0:
    let ps = serverConfig.poolSettings
    echo fmt"[*] Connecting to PostgreSQL ({ps.pgHost}:{ps.pgPort.int}) to export SCRAM-SHA-256 verifiers from pg_shadow..."
    try:
      let conn = waitFor connectBackend(ps.pgHost, ps.pgPort, ps.user, ps.password, ps.database, 1)
      let users = waitFor fetchPgShadowUsers(conn)
      waitFor conn.terminate()
      writeSecureAuthFile(serverConfig.genAuthFile, users)
      echo fmt"[OK] Exported {users.len} SCRAM-SHA-256 user verifier(s) to '{serverConfig.genAuthFile}' (mode 0600)"
      quit(0)
    except CatchableError as e:
      quit(fmt"[FATAL] Failed to generate auth file from pg_shadow: {e.msg}", 1)

  setControlCHook(onControlC)
  raiseFileDescriptorLimit()

  if serverConfig.metricsEnabled:
    initMetrics(
      serverConfig.poolSettings.maxConnections,
      serverConfig.poolSettings.maxQueueSize,
      serverConfig.workers
    )
    let mArgs = MetricsThreadArgs(port: serverConfig.metricsPort, bindAddr: serverConfig.metricsBind)
    createThread(metricsThread, metricsWorker, mArgs)

  if serverConfig.workers <= 1:
    waitFor startServer(serverConfig)
  else:
    echo fmt"[*] Spawning {serverConfig.workers} native worker threads with SO_REUSEPORT..."
    var threads = newSeq[Thread[ServerConfig]](serverConfig.workers)

    var workerCfg = serverConfig
    let connsPerWorker = max(1, serverConfig.poolSettings.maxConnections div serverConfig.workers)
    workerCfg.poolSettings.maxConnections = connsPerWorker

    for i in 0 ..< serverConfig.workers:
      createThread(threads[i], workerThread, workerCfg)

    for i in 0 ..< serverConfig.workers:
      joinThread(threads[i])

when isMainModule:
  main()
