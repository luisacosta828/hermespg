import std/[asyncnet, asyncdispatch, strutils, strformat, tables, posix, nativesockets]
import ./protocol/[messages, codec]
import ./backend/[connection, pool]
import ./crypto/scram

type
  ServerConfig* = object
    listenAddress*: string
    listenPort*: Port
    poolSettings*: PoolSettings
    verbose*: bool
    workers*: int

var
  shutdownRequested* {.threadvar.}: bool
  shutdownFuture* {.threadvar.}: Future[void]
  prebuiltHandshake* {.threadvar.}: string
  scramVerifier* {.threadvar.}: ScramVerifier
  requireAuth* {.threadvar.}: bool
  expectedUser* {.threadvar.}: string

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

const
  WireReadyIdle* = "\x5a\x00\x00\x00\x05I" # ReadyForQuery ('Z', 5, 'I')

let
  WireSaslOffer* = "R\x00\x00\x00\x17\x00\x00\x00\x0aSCRAM-SHA-256\x00\x00"



proc forwardBackendTurn*(leasedConn: BackendConn, clientSock: AsyncSocket, backendBuf: PacketBuffer): Future[bool] {.async.} =
  ## Streams backend response chunks directly to client socket with speculative direct syscalls.
  ## Inspects PostgreSQL v3 framing to detect MsgReadyForQuery ('Z') and determine transaction state.
  var turnCompleted = false
  var neededPayload = 0
  var partialHeaderLen = 0
  var partialHeader: array[5, char]

  while not turnCompleted:
    # 1. Speculatively read available bytes directly from backend socket
    var n = fastRecvDirect(leasedConn.socket, addr backendBuf.data[0], backendBuf.data.len)
    if n < 0:
      n = await leasedConn.socket.recvInto(addr backendBuf.data[0], backendBuf.data.len)
      if n == 0:
        leasedConn.isAlive = false
        return false
    elif n == 0:
      leasedConn.isAlive = false
      return false

    # 2. Speculatively transmit entire chunk directly to client socket in a single syscall
    if not fastSendDirect(clientSock, addr backendBuf.data[0], n):
      await clientSock.send(addr backendBuf.data[0], n)

    # 3. Parse framing within this chunk to detect ReadyForQuery
    var offset = 0
    while offset < n:
      if neededPayload > 0:
        let take = min(neededPayload, n - offset)
        neededPayload.dec(take)
        offset.inc(take)
        continue

      if partialHeaderLen > 0:
        let take = min(5 - partialHeaderLen, n - offset)
        copyMem(addr partialHeader[partialHeaderLen], addr backendBuf.data[offset], take)
        partialHeaderLen.inc(take)
        offset.inc(take)
        if partialHeaderLen == 5:
          let kind = partialHeader[0]
          let totalLen = readInt32BE(partialHeader, 1)
          let payloadLen = int(totalLen) - 4
          partialHeaderLen = 0

          if kind == MsgParameterStatus:
            leasedConn.isDirty = true
          elif kind == MsgReadyForQuery:
            let status = if offset < n: backendBuf.data[offset] else: 'I'
            leasedConn.lastStatus = toTransactionStatus(status)
            turnCompleted = true
            break
          neededPayload = payloadLen
        continue

      if offset + 5 <= n:
        let kind = backendBuf.data[offset]
        let totalLen = readInt32BE(backendBuf.data, offset + 1)
        let msgTotal = 1 + int(totalLen)

        if kind == MsgParameterStatus:
          leasedConn.isDirty = true
        elif kind == MsgReadyForQuery:
          let status = if offset + 5 < n: backendBuf.data[offset + 5] else: 'I'
          leasedConn.lastStatus = toTransactionStatus(status)
          turnCompleted = true
          break

        if offset + msgTotal <= n:
          offset.inc(msgTotal)
        else:
          neededPayload = (offset + msgTotal) - n
          offset = n
      else:
        let rem = n - offset
        copyMem(addr partialHeader[0], addr backendBuf.data[offset], rem)
        partialHeaderLen = rem
        offset = n

  return true

proc handleClientSession(clientSock: AsyncSocket, clientId: int, pool: ConnectionPool, verbose: bool): Future[void] {.async.} =
  optimizeSocket(clientSock)

  let clientBuf = newPacketBuffer(65536)
  let backendBuf = newPacketBuffer(65536)

  # 1. Initial client handshake
  let init = await clientSock.readStartupOrSslInto(clientBuf)
  if init.length == 0:
    clientSock.close()
    return

  # If client requests SSL, reply 'N' immediately
  var realInit = init
  if init.protoCode == SslRequestCode:
    if not fastSendDirect(clientSock, cstring("N"), 1):
      await clientSock.send("N")
    realInit = await clientSock.readStartupOrSslInto(clientBuf)
    if realInit.length == 0:
      clientSock.close()
      return

  if requireAuth:
    # Authenticate client via SCRAM-SHA-256
    let startup = parseStartupMessage(clientBuf.data[4 ..< realInit.length])
    let clientUser = startup.parameters.getOrDefault("user", "")
    if expectedUser.len > 0 and clientUser != expectedUser:
      let errPkt = buildAuthErrorPacket(clientUser)
      await clientSock.send(errPkt)
      clientSock.close()
      return

    # Step 1: Send AuthenticationSASL offer (SCRAM-SHA-256)
    if not fastSendDirect(clientSock, unsafeAddr WireSaslOffer[0], WireSaslOffer.len):
      await clientSock.send(WireSaslOffer)

    # Step 2: Read SASLInitialResponse from client
    let saslInitLen = await clientSock.readMessageInto(clientBuf)
    if saslInitLen == 0 or clientBuf.data[0] != MsgPassword:
      let errPkt = buildAuthErrorPacket(clientUser)
      await clientSock.send(errPkt)
      clientSock.close()
      return

    let mechEnd = clientBuf.data.find('\0', 5)
    if mechEnd == -1 or clientBuf.data[5 ..< mechEnd] != "SCRAM-SHA-256":
      let errPkt = buildAuthErrorPacket(clientUser)
      await clientSock.send(errPkt)
      clientSock.close()
      return

    let saslDataLen = int(readInt32BE(clientBuf.data, mechEnd + 1))
    let dataStart = mechEnd + 5
    if dataStart + saslDataLen > saslInitLen:
      let errPkt = buildAuthErrorPacket(clientUser)
      await clientSock.send(errPkt)
      clientSock.close()
      return
    let clientFirst = clientBuf.data[dataStart ..< dataStart + saslDataLen]

    var serverSession = newScramServerSession(scramVerifier)
    let serverFirst = serverSession.processClientFirstAndBuildChallenge(clientFirst)

    # Step 3: Send AuthenticationSASLContinue (11)
    let continuePayload = writeInt32BE(11) & serverFirst
    let continueMsg = PgMessage(
      kind: MsgAuth,
      length: int32(4 + continuePayload.len),
      payload: continuePayload
    )
    let contBytes = encode(continueMsg)
    if not fastSendDirect(clientSock, addr contBytes[0], contBytes.len):
      await clientSock.send(contBytes)

    # Step 4: Read SASLResponse from client
    let saslRespLen = await clientSock.readMessageInto(clientBuf)
    if saslRespLen == 0 or clientBuf.data[0] != MsgPassword:
      let errPkt = buildAuthErrorPacket(clientUser)
      await clientSock.send(errPkt)
      clientSock.close()
      return

    let clientFinal = clientBuf.data[5 ..< saslRespLen]
    let (valid, serverSigB64) = serverSession.verifyClientFinal(clientFinal)
    if not valid:
      let errPkt = buildAuthErrorPacket(clientUser)
      await clientSock.send(errPkt)
      clientSock.close()
      return

    # Step 5: Send AuthenticationSASLFinal (12) + prebuiltHandshake (AuthenticationOk, ParameterStatus, ReadyForQuery)
    let finalPayload = writeInt32BE(12) & "v=" & serverSigB64
    let finalMsg = PgMessage(
      kind: MsgAuth,
      length: int32(4 + finalPayload.len),
      payload: finalPayload
    )
    let finalBytes = encode(finalMsg) & prebuiltHandshake
    if not fastSendDirect(clientSock, addr finalBytes[0], finalBytes.len):
      await clientSock.send(finalBytes)
  else:
    # Instant dispatch: send pre-assembled handshake in a single network syscall
    if not fastSendDirect(clientSock, addr prebuiltHandshake[0], prebuiltHandshake.len):
      await clientSock.send(addr prebuiltHandshake[0], prebuiltHandshake.len)


  if verbose:
    echo fmt"[CLIENT #{clientId}] Connected and authenticated (<0.2ms)"
    flushFile(stdout)

  var leasedConn: BackendConn = nil

  try:
    while not clientSock.isClosed and not shutdownRequested:
      # Read client query packet
      let cMsgLen = await clientSock.readMessageInto(clientBuf)
      if cMsgLen == 0:
        break # Client disconnected

      let msgKind = clientBuf.data[0]
      if msgKind == MsgTerminate:
        break

      if leasedConn == nil:
        if not pool.tryAcquireFast(leasedConn):
          let acq = await pool.acquire()
          case acq.status
          of AcquireOk:
            leasedConn = acq.conn
          of AcquireQueueFull:
            await clientSock.send(WireQueueFullError)
            await clientSock.send(WireReadyIdle)
            continue
          of AcquireTimeout:
            await clientSock.send(WireTimeoutError)
            clientSock.close()
            return
          of AcquireShuttingDown, AcquireFailed:
            await clientSock.send(WireQueueFullError)
            clientSock.close()
            return

      # If Parse with named statement, mark connection dirty
      if msgKind == MsgParse and cMsgLen > 5 and clientBuf.data[5] != '\0':
        leasedConn.isDirty = true

      # Forward first packet to backend
      if not fastSendDirect(leasedConn.socket, addr clientBuf.data[0], cMsgLen):
        await leasedConn.socket.send(addr clientBuf.data[0], cMsgLen)

      # If Extended Query (Parse, Bind, Describe, Execute), forward pipeline until Sync ('S')
      if msgKind in {MsgParse, MsgBind, MsgDescribe, MsgExecute, MsgFlush}:
        var currentKind = msgKind
        while currentKind != MsgSync:
          let nextLen = await clientSock.readMessageInto(clientBuf)
          if nextLen == 0:
            break
          currentKind = clientBuf.data[0]
          if currentKind == MsgParse and nextLen > 5 and clientBuf.data[5] != '\0':
            leasedConn.isDirty = true
          if not fastSendDirect(leasedConn.socket, addr clientBuf.data[0], nextLen):
            await leasedConn.socket.send(addr clientBuf.data[0], nextLen)

      # Phase 2: Consume responses from leased backend until ReadyForQuery ('Z')
      let ok = await forwardBackendTurn(leasedConn, clientSock, backendBuf)
      if not ok:
        clientSock.close()
        break

      if leasedConn.lastStatus == Idle:
        # Session back to Idle ('I'): release backend back to pool immediately!
        if not leasedConn.isDirty:
          pool.releaseFast(leasedConn)
        else:
          await pool.release(leasedConn, dirty = false)
        leasedConn = nil

  except CatchableError as e:
    if verbose and not clientSock.isClosed:
      echo fmt"[CLIENT #{clientId}] Session error: {e.msg}"
  finally:
    if leasedConn != nil:
      if leasedConn.lastStatus != Idle:
        discard await leasedConn.executeSimple("ROLLBACK;")
      await pool.release(leasedConn, dirty = true)
      leasedConn = nil

    if not clientSock.isClosed:
      clientSock.close()

proc startServer*(config: ServerConfig) {.async.} =
  shutdownFuture = newFuture[void]("server.shutdown")

  echo "[*] Initializing high-concurrency connection pool..."
  let pool = newConnectionPool(config.poolSettings)

  # Pre-warm all physical connections to verify Postgres and construct handshake buffer
  try:
    await pool.prewarm()
    if pool.idleConns.len == 0:
      echo "[FATAL] No connections established with PostgreSQL"
      return
    let warmConn = pool.idleConns[0]
    prebuiltHandshake = assemblePrebuiltHandshake(warmConn.parameters)
    echo fmt"[OK] Connection established with PostgreSQL ({config.poolSettings.pgHost}:{config.poolSettings.pgPort.int})"
    echo fmt"[*] Pre-warmed {pool.idleConns.len} physical backend connections"
    echo fmt"[*] Pre-assembled binary handshake cached in memory: {prebuiltHandshake.len} bytes"

    if config.poolSettings.password.len > 0:
      requireAuth = true
      expectedUser = config.poolSettings.user
      scramVerifier = generateVerifier(config.poolSettings.password)
      echo fmt"[*] SCRAM-SHA-256 Frontend authentication active for user '{expectedUser}'"
    else:
      requireAuth = false
  except CatchableError as e:
    echo fmt"[FATAL] Error connecting to PostgreSQL: {e.msg}"
    return

  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  when defined(posix):
    var reusePortVal: cint = 1
    discard setsockopt(server.getFd(), posix.SOL_SOCKET, posix.SO_REUSEPORT, addr reusePortVal, SockLen(sizeof(reusePortVal)))
  if config.listenAddress.len > 0 and config.listenAddress != "0.0.0.0":
    server.bindAddr(config.listenPort, config.listenAddress)
  else:
    server.bindAddr(config.listenPort)
  server.listen(4096)

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
