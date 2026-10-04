## Autonomous PostgreSQL backend connection managed by the Pool
import std/[asyncnet, asyncdispatch, tables, strutils, strformat, md5]
import ../protocol/[messages, codec]

type
  BackendConn* = ref object
    socket*: AsyncSocket
    id*: int
    inTransaction*: bool
    lastStatus*: TransactionStatus
    backendPid*: int32
    secretKey*: int32
    parameters*: Table[string, string]
    isAlive*: bool
    isDirty*: bool  ## Indicates whether the connection was used and requires session cleanup

proc newBackendConn*(id: int): BackendConn =
  BackendConn(
    socket: nil,
    id: id,
    inTransaction: false,
    lastStatus: Idle,
    backendPid: 0,
    secretKey: 0,
    parameters: initTable[string, string](),
    isAlive: false,
    isDirty: false
  )

proc toTransactionStatus*(c: char): TransactionStatus =
  case c
  of 'I': Idle
  of 'T': InTransaction
  of 'E': FailedTransaction
  else: Idle

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
  while true:
    let msg = await conn.socket.readMessage()
    if msg.length == 0:
      conn.socket.close()
      raise newException(IOError, fmt"[Backend #{connId}] Connection closed by server during handshake")

    case msg.kind
    of MsgAuth:
      let authType = if msg.payload.len >= 4: readInt32BE(msg.payload, 0) else: -1
      case authType
      of 0:
        # AuthenticationOk
        discard
      of 3:
        # Cleartext password
        let passPayload = password & "\0"
        let passMsg = PgMessage(
          kind: MsgPassword,
          length: int32(4 + passPayload.len),
          payload: passPayload
        )
        await conn.socket.writeMessage(passMsg)
      of 5:
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
      else:
        raise newException(ValueError, fmt"Unsupported authentication mechanism: {authType}")
    of MsgParameterStatus:
      # Store session parameters
      let nullPos = msg.payload.find('\0')
      if nullPos != -1:
        let key = msg.payload[0 ..< nullPos]
        let val = msg.payload[nullPos + 1 .. ^2]
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
