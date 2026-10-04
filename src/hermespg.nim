import std/[asyncdispatch, strformat]
import hermespg/proxy
import hermespg/config

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
  let serverConfig = parseConfig()

  setControlCHook(onControlC)
  raiseFileDescriptorLimit()

  waitFor startServer(serverConfig)

when isMainModule:
  main()
