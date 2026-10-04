## High-concurrency benchmark tool simulating 1,000+ concurrent clients on the pool
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

    # Wait for ReadyForQuery ('Z')
    while true:
      let msg = await sock.readMessage()
      if msg.length == 0 or msg.kind == MsgReadyForQuery: break

    # 3. Send simple query
    let queryMsg = PgMessage(kind: MsgQuery, length: 14, payload: "SELECT 42;\0")
    await sock.writeMessage(queryMsg)

    # Wait for response
    while true:
      let msg = await sock.readMessage()
      if msg.length == 0 or msg.kind == MsgReadyForQuery: break

    # 4. Terminate
    await sock.writeMessage(PgMessage(kind: MsgTerminate, length: 4, payload: ""))
    sock.close()
    return true
  except CatchableError as e:
    if id == 1:
      echo fmt"[DIAGNOSTIC] Client #1 error: {e.msg}"
      if "Connection refused" in e.msg or "111" in e.msg:
        echo "[DIAGNOSTIC] -> Ensure './hermespg' is running in another terminal before executing ./bench"
    if not sock.isClosed: sock.close()
    return false

proc main() {.async.} =
  let totalClients = if paramCount() >= 1: parseInt(paramStr(1)) else: 1000
  let host = "127.0.0.1"
  let port = Port(6432)

  echo fmt"[*] Starting mass load benchmark with {totalClients} concurrent clients..."
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
  echo fmt"[RESULT] Total clients: {totalClients}"
  echo fmt"[RESULT] Successful:    {successes}"
  echo fmt"[RESULT] Failed:        {failures}"
  echo fmt"[RESULT] Total time:    {elapsed:.3f} seconds"
  echo fmt"[RESULT] Throughput:    {tps:.1f} queries/second"
  echo "=========================================="

when isMainModule:
  waitFor main()
