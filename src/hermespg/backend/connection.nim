import std/[asyncnet, asyncdispatch, tables, strutils, strformat, nativesockets, posix]
import checksums/md5
import ../protocol/[messages, codec]
import ../crypto/scram

type
  BackendConn* = ref object
    # Hot cache line fields accessed during query leasing/dispatch (within first 64 bytes)
    socket*: AsyncSocket
    id*: int
    isAlive*: bool
    isDirty*: bool
    inTransaction*: bool
    lastStatus*: TransactionStatus
    backendPid*: int32
    secretKey*: int32
    # Cold fields accessed rarely outside handshake
    parameters*: Table[string, string]

proc newBackendConn*(id: int): BackendConn =
  BackendConn(
    socket: nil,
    id: id,
    isAlive: false,
    isDirty: false,
    inTransaction: false,
    lastStatus: Idle,
    backendPid: 0,
    secretKey: 0,
    parameters: initTable[string, string]()
  )

proc toTransactionStatus*(c: char): TransactionStatus {.inline.} =
  case c
  of 'I': Idle
  of 'T': InTransaction
  of 'E': FailedTransaction
  else: Idle

proc optimizeSocket*(socket: AsyncSocket) {.inline.} =
  ## Enables TCP_NODELAY (disables Nagle algorithm) and SO_KEEPALIVE for microsecond network latency
  try:
    let fd = socket.getFd()
    var optOne: cint = 1
    discard setsockopt(fd, posix.IPPROTO_TCP, posix.TCP_NODELAY, addr optOne, SockLen(sizeof(optOne)))
    discard setsockopt(fd, posix.SOL_SOCKET, posix.SO_KEEPALIVE, addr optOne, SockLen(sizeof(optOne)))
  except CatchableError:
    discard

proc executeSimple*(conn: BackendConn, sql: string): Future[bool] {.async.} =
  ## Executes a simple query synchronously on backend (useful for DISCARD ALL, ping, etc.)
  if not conn.isAlive or conn.socket.isClosed:
    return false

  let queryMsg = PgMessage(
    kind: MsgQuery,
    length: int32(4 + sql.len + 1),
    payload: sql & "\0"
  )

  await conn.socket.writeMessage(queryMsg)

  var success = true
  while true:
    let msg = await conn.socket.readMessage()
    if msg.length == 0:
      conn.isAlive = false
      return false

    case msg.kind
    of MsgErrorResponse:
      success = false
    of MsgReadyForQuery:
      if msg.payload.len > 0:
        conn.lastStatus = toTransactionStatus(msg.payload[0])
      break
    else:
      discard

  return success

proc connectBackend*(host: string, port: Port, user, password, database: string, connId: int): Future[BackendConn] {.async.} =
  ## Establishes TCP connection and completes authentication handshake with PostgreSQL
  let conn = newBackendConn(connId)
  conn.socket = newAsyncSocket(buffered = false)

  await conn.socket.connect(host, port)
  optimizeSocket(conn.socket)

  # Build StartupMessage
  var payload = writeInt32BE(ProtocolVersion30)
  payload.add("user\0" & user & "\0")
  payload.add("database\0" & database & "\0")
  payload.add("client_encoding\0UTF8\0")
  payload.add("application_name\0hermespg\0")
  payload.add("\0") # Final null terminator

  let startupMsg = PgMessage(
    kind: '\0',
    length: int32(4 + payload.len),
    payload: payload
  )

  await conn.socket.writeMessage(startupMsg)

  # Authentication loop
  var scramState = newScramClient(user, password)

  while true:
    let msg = await conn.socket.readMessage()
    if msg.length == 0:
      conn.socket.close()
      raise newException(IOError, fmt"[Backend #{connId}] Connection closed by server during handshake")

    case msg.kind
    of MsgAuth:
      let rawCode = if msg.payload.len >= 4: readInt32BE(msg.payload, 0) else: -1
      let authKind = toAuthRequestKind(rawCode)
      case authKind
      of AuthOk:
        # Authentication successful
        discard
      of AuthCleartextPassword:
        # Cleartext password
        let passPayload = password & "\0"
        let passMsg = PgMessage(
          kind: MsgPassword,
          length: int32(4 + passPayload.len),
          payload: passPayload
        )
        await conn.socket.writeMessage(passMsg)
      of AuthMD5Password:
        # MD5 password: 4-byte salt in msg.payload[4..7]
        if msg.payload.len < 8:
          raise newException(ValueError, "Insufficient payload for MD5 authentication")
        let salt = msg.payload[4 .. 7]
        let inner = getMD5(password & user)
        let outer = "md5" & getMD5(inner & salt) & "\0"
        let passMsg = PgMessage(
          kind: MsgPassword,
          length: int32(4 + outer.len),
          payload: outer
        )
        await conn.socket.writeMessage(passMsg)
      of AuthSASL:
        # Server requests SASL authentication negotiation (SCRAM-SHA-256)
        let mechList = if msg.payload.len > 4: msg.payload[4 .. ^1] else: ""
        if not mechList.contains("SCRAM-SHA-256"):
          raise newException(ValueError, "PostgreSQL does not offer SCRAM-SHA-256: " & mechList)

        let clientFirst = scramState.buildClientFirstMessage()
        var saslResp = "SCRAM-SHA-256\0"
        saslResp.add(writeInt32BE(int32(clientFirst.len)))
        saslResp.add(clientFirst)

        let passMsg = PgMessage(
          kind: MsgPassword,
          length: int32(4 + saslResp.len),
          payload: saslResp
        )
        await conn.socket.writeMessage(passMsg)
      of AuthSASLContinue:
        # Server challenge with salt and iterations
        if msg.payload.len <= 4:
          raise newException(ValueError, "Insufficient payload for AuthenticationSASLContinue")
        let serverFirst = msg.payload[4 .. ^1]
        let clientFinal = scramState.processServerFirstAndBuildFinal(serverFirst)

        let passMsg = PgMessage(
          kind: MsgPassword,
          length: int32(4 + clientFinal.len),
          payload: clientFinal
        )
        await conn.socket.writeMessage(passMsg)
      of AuthSASLFinal:
        # Server final message with ServerSignature for mutual authentication
        if msg.payload.len <= 4:
          raise newException(ValueError, "Insufficient payload for AuthenticationSASLFinal")
        let serverFinal = msg.payload[4 .. ^1]
        if not scramState.verifyServerFinalMessage(serverFinal):
          raise newException(ValueError, "SCRAM-SHA-256 server signature verification failed")
      else:
        raise newException(ValueError, fmt"Unsupported authentication mechanism: {authKind}")
    of MsgParameterStatus:
      # Store session parameters (key\0val\0)
      let nullPos = msg.payload.find('\0')
      if nullPos != -1 and nullPos + 1 < msg.payload.len:
        let key = msg.payload[0 ..< nullPos]
        let rest = msg.payload[nullPos + 1 .. ^1]
        let secondNull = rest.find('\0')
        let val = if secondNull != -1: rest[0 ..< secondNull] else: rest
        conn.parameters[key] = val
    of MsgBackendKeyData:
      if msg.payload.len >= 8:
        conn.backendPid = readInt32BE(msg.payload, 0)
        conn.secretKey = readInt32BE(msg.payload, 4)
    of MsgErrorResponse:
      conn.socket.close()
      raise newException(IOError, fmt"[Backend #{connId}] PostgreSQL authentication failed")
    of MsgReadyForQuery:
      if msg.payload.len > 0:
        conn.lastStatus = toTransactionStatus(msg.payload[0])
      conn.isAlive = true
      break
    else:
      discard

  return conn

proc terminate*(conn: BackendConn): Future[void] {.async.} =
  ## Closes the connection by sending the Terminate ('X') packet
  if conn != nil and conn.socket != nil and not conn.socket.isClosed:
    try:
      let termMsg = PgMessage(kind: MsgTerminate, length: 4, payload: "")
      await conn.socket.writeMessage(termMsg)
    except CatchableError:
      discard
    finally:
      conn.socket.close()
      conn.isAlive = false
