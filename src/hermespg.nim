import std/[asyncdispatch, strformat]
import hermespg/proxy
import hermespg/config

when defined(posix):
  import std/posix

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

proc main() =
  let serverConfig = parseConfig()

  setControlCHook(onControlC)
  raiseFileDescriptorLimit()

  waitFor startServer(serverConfig)

when isMainModule:
  main()
