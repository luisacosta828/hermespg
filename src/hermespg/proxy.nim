import std/[asyncnet, asyncdispatch, strutils, strformat, tables]
import ./protocol/[messages, codec]
import ./backend/[connection, pool]

type
  ServerConfig* = object
    listenAddress*: string
    listenPort*: Port
    poolSettings*: PoolSettings
    verbose*: bool

var
  shutdownRequested* = false
  shutdownFuture*: Future[void]

  # Pre-assembled handshake in a single binary buffer for microsecond dispatch
  prebuiltHandshake*: string

proc assemblePrebuiltHandshake(params: Table[string, string]): string =
  ## Combines AuthenticationOk, all ParameterStatus, BackendKeyData, and ReadyForQuery
  ## into a single contiguous binary network packet.
  var buf = ""

  # 1. AuthenticationOk ('R', len = 8, type = 0)
  buf.add(encode(PgMessage(kind: MsgAuth, length: 8, payload: writeInt32BE(0))))

  # 2. Replicate all Postgres ParameterStatus key-values
  for key, val in params:
    let payload = key & "\0" & val & "\0"
    buf.add(encode(PgMessage(
      kind: MsgParameterStatus,
      length: int32(4 + payload.len),
      payload: payload
    )))

  # 3. Simulated BackendKeyData (PID 1234, Secret 5678)
  let keyPayload = writeInt32BE(1234) & writeInt32BE(5678)
  buf.add(encode(PgMessage(
    kind: MsgBackendKeyData,
    length: int32(4 + keyPayload.len),
    payload: keyPayload
  )))

  # 4. ReadyForQuery ('Z', len = 5, status 'I')
  buf.add(encode(PgMessage(kind: MsgReadyForQuery, length: 5, payload: "I")))
  return buf

proc handleClientSession(clientSock: AsyncSocket, clientId: int, pool: ConnectionPool, verbose: bool): Future[void] {.async.} =
  # 1. Initial client handshake
  var initMsg = await clientSock.readStartupOrSsl()
  if initMsg.length == 0:
    clientSock.close()
    return

  # If client requests SSL, reply 'N' immediately
  if initMsg.length == 8 and initMsg.payload.len >= 4:
    let code = readInt32BE(initMsg.payload, 0)
    if code == SslRequestCode:
      await clientSock.send("N")
      initMsg = await clientSock.readStartupOrSsl()
      if initMsg.length == 0:
        clientSock.close()
        return

  # Instant dispatch: send pre-assembled handshake in a single network syscall
  await clientSock.send(prebuiltHandshake)

  if verbose:
    let startup = parseStartupMessage(initMsg.payload)
    let user = startup.parameters.getOrDefault("user", "postgres")
    let app = startup.parameters.getOrDefault("application_name", "client")
    echo fmt"[CLIENT #{clientId}] Connected and authenticated (<0.2ms). User: '{user}', App: '{app}'"
    flushFile(stdout)

  var leasedConn: BackendConn = nil

  try:
    while not clientSock.isClosed and not shutdownRequested:
      var clientMsg: PgMessage

      # If client holds an active open transaction, monitor idle timeout
      if leasedConn != nil and leasedConn.lastStatus != Idle:
        let readFut = clientSock.readMessage()
        let onTime = await withTimeout(readFut, pool.settings.idleTxTimeoutMs)
        if not onTime:
          # Transaction inactivity timeout exceeded: terminate client and rescue backend
          echo fmt"[SECURITY] Client #{clientId} abandoned idle transaction (>{pool.settings.idleTxTimeoutMs}ms). Rescuing Backend #{leasedConn.id}..."
          flushFile(stdout)
          await clientSock.send(WireIdleTxTimeoutError)
          clientSock.close()
          discard await leasedConn.executeSimple("ROLLBACK;")
          await pool.release(leasedConn, dirty = true)
          leasedConn = nil
          break
        clientMsg = readFut.read()
      else:
        # Standard query wait
        clientMsg = await clientSock.readMessage()

      if clientMsg.length == 0:
        break

      if clientMsg.kind == MsgTerminate:
        if verbose:
          echo fmt"[CLIENT #{clientId}] Session closed normally ('X')"
          flushFile(stdout)
        break

      # Client requires a backend connection to execute query
      if leasedConn == nil:
        let acq = await pool.acquire()
        case acq.status
        of AcquireOk:
          leasedConn = acq.conn
          if verbose:
            echo fmt"[POOL] Backend #{leasedConn.id} leased to Client #{clientId}"
            flushFile(stdout)
        of AcquireQueueFull:
          # Fail-Fast: immediate rejection without queuing or overhead
          await clientSock.send(WireQueueFullError)
          clientSock.close()
          return
        of AcquireTimeout:
          # Timed out waiting for available backend connection
          await clientSock.send(WireTimeoutError)
          clientSock.close()
          return
        of AcquireShuttingDown:
          await clientSock.send(WirePoolShuttingDownError)
          clientSock.close()
          return
        of AcquireFailed:
          await clientSock.send(WireQueueFullError)
          clientSock.close()
          return

      # Forward client message to backend
      await leasedConn.socket.writeMessage(clientMsg)

      # Forward backend responses to client until ReadyForQuery ('Z')
      while true:
        let srvMsg = await leasedConn.socket.readMessage()
        if srvMsg.length == 0:
          leasedConn.isAlive = false
          break

        await clientSock.writeMessage(srvMsg)

        if srvMsg.kind == MsgReadyForQuery:
          let status = if srvMsg.payload.len > 0: srvMsg.payload[0] else: '?'
          leasedConn.lastStatus = toTransactionStatus(status)

          if status == 'I':
            # Idle state: Query finished cleanly. Release backend without forcing DISCARD ALL
            await pool.release(leasedConn, dirty = false)
            leasedConn = nil
          break

  except CatchableError as e:
    if verbose and not clientSock.isClosed:
      echo fmt"[CLIENT #{clientId}] Session error: {e.msg}"
      flushFile(stdout)
  finally:
    # Guarantee release if client disconnects unexpectedly
    if leasedConn != nil:
      await pool.release(leasedConn, dirty = true)
      leasedConn = nil

    if not clientSock.isClosed:
      clientSock.close()

proc startServer*(config: ServerConfig) {.async.} =
  shutdownFuture = newFuture[void]("server.shutdown")

  echo "[*] Initializing high-concurrency connection pool..."
  let pool = newConnectionPool(config.poolSettings)

  # Pre-warm 1 physical connection to verify Postgres and construct handshake buffer
  try:
    let warmAcq = await pool.acquire()
    if warmAcq.status != AcquireOk:
      echo fmt"[FATAL] Could not pre-warm connection pool: {warmAcq.errorMsg}"
      return
    let warmConn = warmAcq.conn
    prebuiltHandshake = assemblePrebuiltHandshake(warmConn.parameters)
    await pool.release(warmConn, dirty = false)
    echo fmt"[OK] Connection established with PostgreSQL ({config.poolSettings.pgHost}:{config.poolSettings.pgPort.int})"
    echo fmt"[*] Pre-assembled binary handshake cached in memory: {prebuiltHandshake.len} bytes"
  except CatchableError as e:
    echo fmt"[FATAL] Error connecting to PostgreSQL: {e.msg}"
    return

  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  if config.listenAddress.len > 0 and config.listenAddress != "0.0.0.0":
    server.bindAddr(config.listenPort, config.listenAddress)
  else:
    server.bindAddr(config.listenPort)
  server.listen()

  let bindDisplay = if config.listenAddress.len > 0: config.listenAddress else: "0.0.0.0"
  echo fmt"[*] Proxy listening on {bindDisplay}:{config.listenPort.int}"
  echo fmt"[*] Physical backends: {config.poolSettings.maxConnections} connections"
  echo fmt"[*] Bounded queue (Fail-Fast): {config.poolSettings.maxQueueSize} max pending clients"
  echo fmt"[*] Acquire timeout: {config.poolSettings.acquireTimeoutMs}ms"
  echo fmt"[*] Idle transaction watchdog timeout: {config.poolSettings.idleTxTimeoutMs}ms"
  echo "[*] Press Ctrl+C for graceful shutdown"
  flushFile(stdout)

  var clientIdCounter = 0

  let acceptLoop = (proc() {.async.} =
    while not shutdownRequested:
      var clientSock: AsyncSocket
      try:
        clientSock = await server.accept()
      except CatchableError:
        if shutdownRequested: break
        # Pause briefly on temporary file descriptor exhaustion (EMFILE)
        await sleepAsync(50)
        continue

      inc clientIdCounter
      asyncCheck handleClientSession(clientSock, clientIdCounter, pool, config.verbose)
  )()

  await (acceptLoop or shutdownFuture)

  echo "\n[SHUTDOWN] Closing server listener socket..."
  server.close()

  echo "[SHUTDOWN] Shutting down connection pool..."
  await pool.shutdown(graceTimeoutMs = 5000)

  echo "[SHUTDOWN] Server stopped gracefully."
  flushFile(stdout)
