## Herramienta de benchmark asíncrono para probar 1,000+ conexiones concurrentes en el pool
import std/[asyncdispatch, asyncnet, times, strformat, strutils, os]
import hermespg/protocol/[messages, codec]

when defined(posix):
  import std/posix
  var limit: RLimit
  if getrlimit(RLIMIT_NOFILE, limit) == 0:
    limit.rlim_cur = min(limit.rlim_max, type(limit.rlim_max)(65536))
    discard setrlimit(RLIMIT_NOFILE, limit)

proc simulateClient(id: int, host: string, port: Port): Future[bool] {.async.} =
  let sock = newAsyncSocket(buffered = false)
  try:
    await sock.connect(host, port)

    # 1. SSLRequest
    await sock.send("\0\0\0\x08\x04\xd2\x16\x2f")
    discard await sock.readExact(1)

    # 2. StartupMessage
    let startupPayload = writeInt32BE(ProtocolVersion30) & "user\0postgres\0database\0postgres\0\0"
    let startupMsg = PgMessage(kind: '\0', length: int32(4 + startupPayload.len), payload: startupPayload)
    await sock.writeMessage(startupMsg)

    # Esperar ReadyForQuery ('Z')
    while true:
      let msg = await sock.readMessage()
      if msg.length == 0 or msg.kind == MsgReadyForQuery: break

    # 3. Enviar consulta
    let queryMsg = PgMessage(kind: MsgQuery, length: 14, payload: "SELECT 42;\0")
    await sock.writeMessage(queryMsg)

    # Esperar respuesta
    while true:
      let msg = await sock.readMessage()
      if msg.length == 0 or msg.kind == MsgReadyForQuery: break

    # 4. Terminate
    await sock.writeMessage(PgMessage(kind: MsgTerminate, length: 4, payload: ""))
    sock.close()
    return true
  except CatchableError as e:
    if id == 1:
      echo fmt"[DIAGNÓSTICO] Error en Cliente #1: {e.msg}"
      if "Connection refused" in e.msg or "111" in e.msg:
        echo "[DIAGNÓSTICO] -> Asegúrate de tener './hermespg' corriendo en otra terminal antes de ejecutar ./bench"
    if not sock.isClosed: sock.close()
    return false

proc main() {.async.} =
  let totalClients = if paramCount() >= 1: parseInt(paramStr(1)) else: 1000
  let host = "127.0.0.1"
  let port = Port(6432)

  echo fmt"[*] Iniciando prueba de carga masiva con {totalClients} clientes concurrentes..."
  let startTime = cpuTime()

  var futures: seq[Future[bool]] = @[]
  for i in 1 .. totalClients:
    futures.add(simulateClient(i, host, port))

  var successes = 0
  var failures = 0

  for fut in futures:
    let ok = await fut
    if ok: inc successes else: inc failures

  let elapsed = cpuTime() - startTime
  let tps = float(successes) / max(elapsed, 0.001)

  echo "=========================================="
  echo fmt"[RESULTADO] Total clientes: {totalClients}"
  echo fmt"[RESULTADO] Exitosos:        {successes}"
  echo fmt"[RESULTADO] Fallidos:        {failures}"
  echo fmt"[RESULTADO] Tiempo total:    {elapsed:.3f} segundos"
  echo fmt"[RESULTADO] Throughput:      {tps:.1f} consultas/segundo"
  echo "=========================================="

when isMainModule:
  waitFor main()
