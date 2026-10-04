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
  var clientReadFut: Future[PgMessage] = nil

  try:
    while not clientSock.isClosed and not shutdownRequested:
      # If no active read future from client, initiate one
      if clientReadFut == nil:
        clientReadFut = clientSock.readMessage()

      # Phase 1: Client is not holding a leased backend (Idle between queries/transactions)
      if leasedConn == nil:
        let clientMsg = await clientReadFut
        clientReadFut = nil

        if clientMsg.length == 0:
          # Normal client disconnection (EOF)
          break

        if clientMsg.kind == MsgTerminate:
          if verbose:
            echo fmt"[CLIENT #{clientId}] Session closed normally ('X')"
            flushFile(stdout)
          break

        # Acquire physical backend connection from pool
        let acq = await pool.acquire()
        case acq.status
        of AcquireOk:
          leasedConn = acq.conn
          if verbose:
            echo fmt"[POOL] Backend #{leasedConn.id} leased to Client #{clientId}"
            flushFile(stdout)
        of AcquireQueueFull:
          await clientSock.send(WireQueueFullError)
          clientSock.close()
          return
        of AcquireTimeout:
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

        # Forward initial command that triggered lease
        if clientMsg.kind == MsgParse:
          leasedConn.isDirty = true
        await leasedConn.socket.writeMessage(clientMsg)

      # Phase 2: Active turn with leased backend (supports Simple & Extended Query pipelining)
      var backendReadFut = leasedConn.socket.readMessage()

      while leasedConn != nil and not clientSock.isClosed and not leasedConn.socket.isClosed:
        if clientReadFut == nil:
          clientReadFut = clientSock.readMessage()

        var completedTurn = false

        # If client holds an active transaction block, monitor idle transaction timeout
        if leasedConn.lastStatus != Idle:
          let raceFut = clientReadFut or backendReadFut
          let onTime = await withTimeout(raceFut, pool.settings.idleTxTimeoutMs)
          if not onTime:
            echo fmt"[SECURITY] Client #{clientId} abandoned idle transaction (>{pool.settings.idleTxTimeoutMs}ms). Rescuing Backend #{leasedConn.id}..."
            flushFile(stdout)
            await clientSock.send(WireIdleTxTimeoutError)
            clientSock.close()
            discard await leasedConn.executeSimple("ROLLBACK;")
            await pool.release(leasedConn, dirty = true)
            leasedConn = nil
            return
        else:
          await (clientReadFut or backendReadFut)

        # 1. Forward incoming client messages to backend (pipelining)
        if clientReadFut.finished:
          let cMsg = clientReadFut.read()
          clientReadFut = nil

          if cMsg.length == 0 or cMsg.kind == MsgTerminate:
            # Client closed socket unexpectedly mid-turn
            clientSock.close()
            break

          if cMsg.kind == MsgParse:
            leasedConn.isDirty = true

          await leasedConn.socket.writeMessage(cMsg)

        # 2. Forward backend responses to client
        if backendReadFut.finished:
          let bMsg = backendReadFut.read()
          if bMsg.length == 0:
            # Backend died or closed unexpectedly
            leasedConn.isAlive = false
            clientSock.close()
            break

          await clientSock.writeMessage(bMsg)

          if bMsg.kind == MsgParameterStatus:
            # Runtime session parameter changed (e.g. SET timezone)
            leasedConn.isDirty = true

          if bMsg.kind == MsgReadyForQuery:
            let status = if bMsg.payload.len > 0: bMsg.payload[0] else: '?'
            leasedConn.lastStatus = toTransactionStatus(status)

            if status == 'I':
              # Query / transaction completed. Release backend back to pool
              await pool.release(leasedConn, dirty = false)
              leasedConn = nil
              completedTurn = true
            else:
              # InTransaction ('T') or FailedTransaction ('E').
              # Turn completed, but transaction remains open and pinned!
              completedTurn = true

          if completedTurn:
            break
          else:
            backendReadFut = leasedConn.socket.readMessage()

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
