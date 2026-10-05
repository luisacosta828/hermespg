## Binary serialization and deserialization module for PostgreSQL v3.0 protocol
import std/[asyncnet, asyncdispatch, endians, tables]
import ./messages

proc readInt32BE*(data: string, offset = 0): int32 =
  ## Reads a 32-bit signed big-endian integer from a string buffer
  if offset < 0 or offset + 4 > data.len:
    raise newException(ValueError, "Buffer underflow reading int32")
  bigEndian32(addr result, unsafeAddr data[offset])

proc writeInt32BE*(val: int32): string =
  ## Serializes a 32-bit signed integer to big-endian bytes (4 bytes)
  result = newString(4)
  var v = val
  bigEndian32(addr result[0], addr v)

proc readInt16BE*(data: string, offset = 0): int16 =
  ## Reads a 16-bit signed big-endian integer from a string buffer
  if offset < 0 or offset + 2 > data.len:
    raise newException(ValueError, "Buffer underflow reading int16")
  bigEndian16(addr result, unsafeAddr data[offset])

proc writeInt16BE*(val: int16): string =
  ## Serializes a 16-bit signed integer to big-endian bytes (2 bytes)
  result = newString(2)
  var v = val
  bigEndian16(addr result[0], addr v)

proc readExact*(socket: AsyncSocket, size: int): Future[string] {.async.} =
  ## Reads exactly `size` bytes from an asynchronous socket.
  ## Returns "" if the socket closes cleanly before reading any bytes.
  ## Raises IOError if the socket closes prematurely after partial read.
  if size == 0:
    return ""
  result = newString(size)
  var totalRead = 0
  while totalRead < size:
    let chunk = await socket.recv(size - totalRead)
    if chunk.len == 0:
      if totalRead == 0:
        return "" # Clean connection close
      raise newException(IOError, "Connection closed prematurely while reading packet")
    copyMem(addr result[totalRead], unsafeAddr chunk[0], chunk.len)
    totalRead.inc(chunk.len)

proc readMessage*(socket: AsyncSocket): Future[PgMessage] {.async.} =
  ## Reads a standard PostgreSQL message (1-byte type + 4-byte length + payload)
  let typeByte = await socket.readExact(1)
  if typeByte.len == 0:
    # EOF detected
    return PgMessage(kind: '\0', length: 0, payload: "")

  let lenBytes = await socket.readExact(4)
  if lenBytes.len < 4:
    raise newException(IOError, "Unexpected EOF reading packet length")

  let totalLen = readInt32BE(lenBytes, 0)
  if totalLen < 4:
    raise newException(ValueError, "Invalid packet length: " & $totalLen)

  let payloadLen = totalLen - 4
  var payload = ""
  if payloadLen > 0:
    payload = await socket.readExact(payloadLen)
    if payload.len < payloadLen:
      raise newException(IOError, "Unexpected EOF reading packet payload")

  return PgMessage(
    kind: typeByte[0],
    length: totalLen,
    payload: payload
  )

proc readStartupOrSsl*(socket: AsyncSocket): Future[PgMessage] {.async.} =
  ## Reads the initial message from a PostgreSQL client (StartupMessage or SSLRequest).
  ## These messages start directly with 4 bytes of length without a type prefix.
  let lenBytes = await socket.readExact(4)
  if lenBytes.len == 0:
    return PgMessage(kind: '\0', length: 0, payload: "")
  if lenBytes.len < 4:
    raise newException(IOError, "Unexpected EOF reading startup header")

  let totalLen = readInt32BE(lenBytes, 0)
  if totalLen < 4:
    raise newException(ValueError, "Invalid startup packet length: " & $totalLen)

  let payloadLen = totalLen - 4
  var payload = ""
  if payloadLen > 0:
    payload = await socket.readExact(payloadLen)

  return PgMessage(
    kind: '\0',
    length: totalLen,
    payload: payload
  )

proc parseStartupMessage*(payload: string): StartupMessage =
  ## Decodes the payload of a StartupMessage extracting protocol version and key-value pairs
  if payload.len < 4:
    raise newException(ValueError, "Insufficient payload for StartupMessage")

  result.protocolVersion = readInt32BE(payload, 0)
  result.parameters = initTable[string, string]()

  var i = 4
  while i < payload.len:
    if payload[i] == '\0':
      # Final null byte terminator of packet
      break

    # Read key up to '\0'
    let keyStart = i
    while i < payload.len and payload[i] != '\0':
      inc i
    if i >= payload.len: break
    let key = payload[keyStart ..< i]
    inc i # skip '\0'

    # Read val up to '\0'
    let valStart = i
    while i < payload.len and payload[i] != '\0':
      inc i
    if i >= payload.len: break
    let val = payload[valStart ..< i]
    inc i # skip '\0'

    result.parameters[key] = val

proc encode*(msg: PgMessage): string =
  ## Serializes a PgMessage to wire bytes ready for transmission
  if msg.kind == '\0':
    # Message without type byte (e.g. forwarded StartupMessage)
    result = writeInt32BE(msg.length) & msg.payload
  else:
    result = $msg.kind & writeInt32BE(msg.length) & msg.payload

proc writeMessage*(socket: AsyncSocket, msg: PgMessage): Future[void] {.async.} =
  ## Sends a PgMessage across an asynchronous socket
  let wireBytes = encode(msg)
  await socket.send(wireBytes)
