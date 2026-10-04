import std/[asyncnet, asyncdispatch, strutils, strformat, tables]
import ./protocol/[messages, codec]
import ./backend/[connection, pool]

type
  ServerConfig* = object
    listenPort*: Port
    poolSettings*: PoolSettings
    verbose*: bool

var
  shutdownRequested* = false
  shutdownFuture*: Future[void]

  # Handshake pre-ensamblado en un solo buffer binario para despacho en microsegundos
  prebuiltHandshake*: string

proc assemblePrebuiltHandshake(params: Table[string, string]): string =
  ## Combina AuthenticationOk, todos los ParameterStatus, BackendKeyData y ReadyForQuery
  ## en un solo paquete binario continuo de red.
  var buf = ""

  # 1. AuthenticationOk ('R', len = 8, type = 0)
  buf.add(encode(PgMessage(kind: MsgAuth, length: 8, payload: writeInt32BE(0))))

  # 2. Replicar todos los ParameterStatus de Postgres
  for key, val in params:
    let payload = key & "\0" & val & "\0"
    buf.add(encode(PgMessage(
      kind: MsgParameterStatus,
      length: int32(4 + payload.len),
      payload: payload
    )))

  # 3. BackendKeyData simulado (PID 1234, Secret 5678)
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
  # 1. Handshake inicial del cliente
  var initMsg = await clientSock.readStartupOrSsl()
  if initMsg.length == 0:
    clientSock.close()
    return

  # Si el cliente solicita SSL, respondemos 'N' inmediatamente
  if initMsg.length == 8 and initMsg.payload.len >= 4:
    let code = readInt32BE(initMsg.payload, 0)
    if code == SslRequestCode:
      await clientSock.send("N")
      initMsg = await clientSock.readStartupOrSsl()
      if initMsg.length == 0:
        clientSock.close()
        return

  # Despacho instantáneo: entregamos todo el handshake en 1 sola llamada de red
  await clientSock.send(prebuiltHandshake)

  if verbose:
    let startup = parseStartupMessage(initMsg.payload)
    let user = startup.parameters.getOrDefault("user", "postgres")
    let app = startup.parameters.getOrDefault("application_name", "cliente")
    echo fmt"[CLIENT #{clientId}] Conectado y autenticado (<0.2ms). Usuario: '{user}', App: '{app}'"
    flushFile(stdout)

  var leasedConn: BackendConn = nil

  try:
    while not clientSock.isClosed and not shutdownRequested:
      var clientMsg: PgMessage

      # Si el cliente tiene una transacción abierta retenida, vigilamos el timeout de inactividad
      if leasedConn != nil and leasedConn.lastStatus != Idle:
        let readFut = clientSock.readMessage()
        let onTime = await withTimeout(readFut, pool.settings.idleTxTimeoutMs)
        if not onTime:
          # Inactividad transaccional excedida: matar al cliente y rescatar el backend
          echo fmt"[SECURITY] Cliente #{clientId} abandonó una transacción inactiva (>{pool.settings.idleTxTimeoutMs}ms). Rescatando Backend #{leasedConn.id}..."
          flushFile(stdout)
          await clientSock.send(WireIdleTxTimeoutError)
          clientSock.close()
          discard await leasedConn.executeSimple("ROLLBACK;")
          await pool.release(leasedConn, dirty = true)
          leasedConn = nil
          break
        clientMsg = readFut.read()
      else:
        # Espera normal de consulta
        clientMsg = await clientSock.readMessage()

      if clientMsg.length == 0:
        break

      if clientMsg.kind == MsgTerminate:
        if verbose:
          echo fmt"[CLIENT #{clientId}] Cierre de sesión normal ('X')"
          flushFile(stdout)
        break

      # El cliente requiere un backend para ejecutar su consulta
      if leasedConn == nil:
        let acq = await pool.acquire()
        case acq.status
        of AcquireOk:
          leasedConn = acq.conn
          if verbose:
            echo fmt"[POOL] Backend #{leasedConn.id} asignado a Cliente #{clientId}"
            flushFile(stdout)
        of AcquireQueueFull:
          # Fail-Fast: Rechazo inmediato sin esperas ni excepciones
          await clientSock.send(WireQueueFullError)
          clientSock.close()
          return
        of AcquireTimeout:
          # Timeout ordenado con paquete oficial de PostgreSQL
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

      # Reenviar mensaje del cliente al backend
      await leasedConn.socket.writeMessage(clientMsg)

      # Transmitir respuestas del backend al cliente hasta recibir ReadyForQuery ('Z')
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
            # Estado Idle: Consulta finalizada limpiamente. Liberar backend sin forzar DISCARD ALL
            await pool.release(leasedConn, dirty = false)
            leasedConn = nil
          break

  except CatchableError as e:
    if verbose and not clientSock.isClosed:
      echo fmt"[CLIENT #{clientId}] Error en sesión: {e.msg}"
      flushFile(stdout)
  finally:
    # Garantía de liberación si el cliente muere
    if leasedConn != nil:
      await pool.release(leasedConn, dirty = true)
      leasedConn = nil

    if not clientSock.isClosed:
      clientSock.close()

proc startServer*(config: ServerConfig) {.async.} =
  shutdownFuture = newFuture[void]("server.shutdown")

  echo "[*] Inicializando Pool de Conexiones de Alta Concurrencia..."
  let pool = newConnectionPool(config.poolSettings)

  # Precalentar 1 conexión física para verificar Postgres y construir el buffer de handshake
  try:
    let warmAcq = await pool.acquire()
    if warmAcq.status != AcquireOk:
      echo fmt"[FATAL] No se pudo precalentar el pool: {warmAcq.errorMsg}"
      return
    let warmConn = warmAcq.conn
    prebuiltHandshake = assemblePrebuiltHandshake(warmConn.parameters)
    await pool.release(warmConn, dirty = false)
    echo fmt"[OK] Conexión establecida con PostgreSQL ({config.poolSettings.pgHost}:{config.poolSettings.pgPort.int})"
    echo fmt"[*] Handshake binario pre-ensamblado en memoria: {prebuiltHandshake.len} bytes"
  except CatchableError as e:
    echo fmt"[FATAL] Error conectando a PostgreSQL: {e.msg}"
    return

  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(config.listenPort)
  server.listen()

  echo fmt"[*] Proxy escuchando en 0.0.0.0:{config.listenPort.int}"
  echo fmt"[*] Backends físicos: {config.poolSettings.maxConnections} conexiones"
  echo fmt"[*] Cola acotada (Fail-Fast): {config.poolSettings.maxQueueSize} clientes máx en espera"
  echo fmt"[*] Timeout de adquisición: {config.poolSettings.acquireTimeoutMs}ms"
  echo fmt"[*] Protección Transacción Inactiva: {config.poolSettings.idleTxTimeoutMs}ms"
  echo "[*] Presiona Ctrl+C para Graceful Shutdown"
  flushFile(stdout)

  var clientIdCounter = 0

  let acceptLoop = (proc() {.async.} =
    while not shutdownRequested:
      var clientSock: AsyncSocket
      try:
        clientSock = await server.accept()
      except CatchableError as e:
        if shutdownRequested: break
        # Si se saturan los descriptores temporalmente (EMFILE), pausamos brevemente
        # para que las conexiones activas liberen sockets en vez de terminar el servidor
        await sleepAsync(50)
        continue

      inc clientIdCounter
      asyncCheck handleClientSession(clientSock, clientIdCounter, pool, config.verbose)
  )()

  await (acceptLoop or shutdownFuture)

  echo "\n[SHUTDOWN] Cerrando socket listener..."
  server.close()

  echo "[SHUTDOWN] Apagando pool de conexiones..."
  await pool.shutdown(graceTimeoutMs = 5000)

  echo "[SHUTDOWN] Servidor apagado limpiamente."
  flushFile(stdout)
