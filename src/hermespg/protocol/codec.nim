## Binary serialization and deserialization module for PostgreSQL v3.0 protocol
import std/[asyncnet, asyncdispatch, endians, tables, os]
when defined(posix):
  import std/posix
import ./messages

proc readInt32BE*(data: openArray[char], offset = 0): int32 {.inline.} =
  ## Reads a 32-bit signed big-endian integer from a buffer
  if offset < 0 or offset + 4 > data.len:
    raise newException(ValueError, "Buffer underflow reading int32")
  bigEndian32(addr result, unsafeAddr data[offset])

proc writeInt32BE*(val: int32): string {.inline.} =
  ## Serializes a 32-bit signed integer to big-endian bytes (4 bytes)
  result = newString(4)
  var v = val
  bigEndian32(addr result[0], addr v)

proc readInt16BE*(data: openArray[char], offset = 0): int16 {.inline.} =
  ## Reads a 16-bit signed big-endian integer from a buffer
  if offset < 0 or offset + 2 > data.len:
    raise newException(ValueError, "Buffer underflow reading int16")
  bigEndian16(addr result, unsafeAddr data[offset])

proc writeInt16BE*(val: int16): string {.inline.} =
  ## Serializes a 16-bit signed integer to big-endian bytes (2 bytes)
  result = newString(2)
  var v = val
  bigEndian16(addr result[0], addr v)

proc readExact*(socket: AsyncSocket, size: int): Future[string] {.async.} =
  ## Reads exactly `size` bytes from an asynchronous socket.
  ## Uses recvInto directly into destination string buffer to eliminate intermediate chunk allocations.
  if size == 0:
    return ""
  result = newString(size)
  var totalRead = 0
  while totalRead < size:
    let bytesRead = await socket.recvInto(addr result[totalRead], size - totalRead)
    if bytesRead == 0:
      if totalRead == 0:
        return "" # Clean connection close
      raise newException(IOError, "Connection closed prematurely while reading packet")
    totalRead.inc(bytesRead)

proc readMessage*(socket: AsyncSocket): Future[PgMessage] {.async.} =
  ## Reads a standard PostgreSQL message (1-byte type + 4-byte length + payload).
  ## Reads full 5-byte header in a single read call, eliminating 1 syscall per packet.
  let header = await socket.readExact(5)
  if header.len == 0:
    return PgMessage(kind: '\0', length: 0, payload: "")
  if header.len < 5:
    raise newException(IOError, "Unexpected EOF reading packet header")

  let kind = header[0]
  let totalLen = readInt32BE(header, 1)
  if totalLen < 4:
    raise newException(ValueError, "Invalid packet length: " & $totalLen)

  let payloadLen = totalLen - 4
  let payload = if payloadLen > 0: await socket.readExact(payloadLen) else: ""

  return PgMessage(
    kind: kind,
    length: totalLen,
    payload: payload
  )

proc readRawMessage*(socket: AsyncSocket): Future[string] {.async.} =
  ## Reads a full raw wire packet (1B Kind + 4B Length + Payload) in a single contiguous buffer.
  ## Eliminates unpacking to PgMessage and subsequent re-encoding in the proxy passthrough path.
  let header = await socket.readExact(5)
  if header.len == 0:
    return ""
  if header.len < 5:
    raise newException(IOError, "Unexpected EOF reading packet header")

  let totalLen = readInt32BE(header, 1)
  if totalLen < 4:
    raise newException(ValueError, "Invalid packet length: " & $totalLen)

  let payloadLen = totalLen - 4
  result = newString(1 + totalLen)
  copyMem(addr result[0], unsafeAddr header[0], 5)

  if payloadLen > 0:
    var totalRead = 0
    while totalRead < payloadLen:
      let bytesRead = await socket.recvInto(addr result[5 + totalRead], payloadLen - totalRead)
      if bytesRead == 0:
        raise newException(IOError, "Connection closed prematurely while reading packet payload")
      totalRead.inc(bytesRead)

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

type
  PacketBuffer* = ref object
    data*: string
    rpos*: int
    wpos*: int

proc newPacketBuffer*(capacity = 65536): PacketBuffer =
  PacketBuffer(data: newString(capacity), rpos: 0, wpos: 0)

proc fastRecvDirect*(socket: AsyncSocket, buf: pointer, size: int): int {.inline.} =
  ## Attempts non-blocking socket recv directly from kernel buffer.
  ## Returns number of bytes read (>= 0), or -1 if data is not immediately available.
  when defined(posix):
    let fd = socket.getFd()
    let res = posix.recv(fd, buf, size, 0)
    if res >= 0:
      return res
    let err = osLastError()
    if err.int32 == EAGAIN or err.int32 == EWOULDBLOCK or err.int32 == EINTR:
      return -1
    raise newOSError(err)
  else:
    return -1

proc fastRecvPeek*(socket: AsyncSocket, buf: pointer, size: int): int {.inline.} =
  ## Peeks up to `size` bytes from kernel socket receive buffer without consuming them.
  ## Returns number of bytes peeked, or -1 on EAGAIN/EWOULDBLOCK.
  when defined(posix):
    let fd = socket.getFd()
    let res = posix.recv(fd, buf, size, posix.MSG_PEEK)
    if res >= 0:
      return res
    let err = osLastError()
    if err.int32 == EAGAIN or err.int32 == EWOULDBLOCK or err.int32 == EINTR:
      return -1
    raise newOSError(err)
  else:
    return -1

proc fastSendDirect*(socket: AsyncSocket, buf: pointer, size: int): bool {.inline.} =
  ## Attempts non-blocking socket send directly into kernel socket send buffer.
  ## Returns true on instant complete transmission, avoiding async dispatch.
  when defined(posix):
    let fd = socket.getFd()
    let res = posix.send(fd, buf, size, MSG_NOSIGNAL)
    return res == size
  else:
    return false

proc readExactInto*(socket: AsyncSocket, p: pointer, size: int): Future[bool] {.async.} =
  ## Reads exactly `size` bytes into destination pointer `p`.
  ## First speculatively performs a direct kernel recv syscall (0 allocations, 0 epoll latency).
  ## If partial, uses async socket recvInto until buffer is full.
  var done = 0
  let fast = fastRecvDirect(socket, p, size)
  if fast > 0:
    done = fast
    if done == size:
      return true
  elif fast == 0:
    return false # Clean EOF

  while done < size:
    let target = cast[pointer](cast[uint](p) + uint(done))
    let n = await socket.recvInto(target, size - done)
    if n == 0:
      if done == 0: return false
      raise newException(IOError, "Unexpected EOF reading packet bytes")
    done.inc(n)
  return true

proc readMessageInto*(socket: AsyncSocket, buf: PacketBuffer): Future[int] {.async.} =
  ## Reads complete PostgreSQL frame into `buf`:
  ## 1. Preserves and compacts unconsumed pipelined messages (0 syscalls for queued packets).
  ## 2. Ingests incoming frames in a single direct kernel recv (0 MSG_PEEK overhead, 1 syscall).
  ## 3. Dynamically handles packet frames larger than initial capacity.
  ## 4. Safely falls back to async recvInto only on partial network arrival.
  ## Returns total packet size, or 0 on clean EOF.
  if buf.rpos > 0:
    let unconsumed = buf.wpos - buf.rpos
    if unconsumed > 0:
      copyMem(addr buf.data[0], addr buf.data[buf.rpos], unconsumed)
      buf.wpos = unconsumed
    else:
      buf.wpos = 0
    buf.rpos = 0

  if buf.wpos >= 5:
    let totalLen = readInt32BE(buf.data, 1)
    if totalLen < 4 or totalLen > 100_000_000:
      raise newException(ValueError, "Invalid packet length: " & $totalLen)
    let msgSize = 1 + int(totalLen)
    if buf.wpos >= msgSize:
      buf.rpos = msgSize
      return msgSize
    if msgSize > buf.data.len:
      buf.data.setLen(msgSize)

  when defined(posix):
    let availSpace = buf.data.len - buf.wpos
    if availSpace > 0:
      let n = fastRecvDirect(socket, addr buf.data[buf.wpos], availSpace)
      if n > 0:
        buf.wpos.inc(n)
        if buf.wpos >= 5:
          let totalLen = readInt32BE(buf.data, 1)
          if totalLen < 4 or totalLen > 100_000_000:
            raise newException(ValueError, "Invalid packet length: " & $totalLen)
          let msgSize = 1 + int(totalLen)
          if buf.wpos >= msgSize:
            buf.rpos = msgSize
            return msgSize
          if msgSize > buf.data.len:
            buf.data.setLen(msgSize)
      elif n == 0:
        if buf.wpos == 0:
          return 0
        raise newException(IOError, "Unexpected EOF reading packet")

  while true:
    if buf.wpos >= 5:
      let totalLen = readInt32BE(buf.data, 1)
      if totalLen < 4 or totalLen > 100_000_000:
        raise newException(ValueError, "Invalid packet length: " & $totalLen)
      let msgSize = 1 + int(totalLen)
      if buf.wpos >= msgSize:
        buf.rpos = msgSize
        return msgSize
      if msgSize > buf.data.len:
        buf.data.setLen(msgSize)

    var availSpace = buf.data.len - buf.wpos
    if availSpace <= 0:
      buf.data.setLen(max(buf.data.len * 2, buf.wpos + 4096))
      availSpace = buf.data.len - buf.wpos
    let n = await socket.recvInto(addr buf.data[buf.wpos], availSpace)
    if n == 0:
      if buf.wpos == 0:
        return 0
      raise newException(IOError, "Unexpected EOF reading packet")
    buf.wpos.inc(n)

proc readStartupOrSslInto*(socket: AsyncSocket, buf: PacketBuffer): Future[tuple[length: int, protoCode: int32]] {.async.} =
  ## Reads client StartupMessage or SSLRequest into `buf`.
  if buf.rpos > 0:
    let unconsumed = buf.wpos - buf.rpos
    if unconsumed > 0:
      copyMem(addr buf.data[0], addr buf.data[buf.rpos], unconsumed)
      buf.wpos = unconsumed
    else:
      buf.wpos = 0
    buf.rpos = 0

  if buf.wpos >= 4:
    let totalLen = readInt32BE(buf.data, 0)
    if totalLen >= 8 and totalLen <= 100_000:
      let msgSize = int(totalLen)
      if buf.wpos >= msgSize:
        let protoCode = readInt32BE(buf.data, 4)
        buf.rpos = msgSize
        return (msgSize, protoCode)
      if msgSize > buf.data.len:
        buf.data.setLen(msgSize)

  when defined(posix):
    let availSpace = buf.data.len - buf.wpos
    if availSpace > 0:
      let n = fastRecvDirect(socket, addr buf.data[buf.wpos], availSpace)
      if n > 0:
        buf.wpos.inc(n)
        if buf.wpos >= 4:
          let totalLen = readInt32BE(buf.data, 0)
          if totalLen >= 8 and totalLen <= 100_000:
            let msgSize = int(totalLen)
            if buf.wpos >= msgSize:
              let protoCode = readInt32BE(buf.data, 4)
              buf.rpos = msgSize
              return (msgSize, protoCode)
            if msgSize > buf.data.len:
              buf.data.setLen(msgSize)
      elif n == 0:
        if buf.wpos == 0:
          return (0, 0'i32)
        raise newException(IOError, "Unexpected EOF reading startup message")

  while true:
    if buf.wpos >= 4:
      let totalLen = readInt32BE(buf.data, 0)
      if totalLen < 8 or totalLen > 100_000:
        raise newException(ValueError, "Invalid startup length: " & $totalLen)
      let msgSize = int(totalLen)
      if buf.wpos >= msgSize:
        let protoCode = readInt32BE(buf.data, 4)
        buf.rpos = msgSize
        return (msgSize, protoCode)
      if msgSize > buf.data.len:
        buf.data.setLen(msgSize)

    var availSpace = buf.data.len - buf.wpos
    if availSpace <= 0:
      buf.data.setLen(max(buf.data.len * 2, buf.wpos + 4096))
      availSpace = buf.data.len - buf.wpos
    let n = await socket.recvInto(addr buf.data[buf.wpos], availSpace)
    if n == 0:
      if buf.wpos == 0:
        return (0, 0'i32)
      raise newException(IOError, "Unexpected EOF reading startup message")
    buf.wpos.inc(n)

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

proc encode*(msg: PgMessage): string {.inline.} =
  ## Serializes a PgMessage to wire bytes ready for transmission.
  ## Preallocates exact buffer size to eliminate intermediate string concatenations.
  if msg.kind == '\0':
    # Message without type byte (e.g. forwarded StartupMessage)
    result = newString(4 + msg.payload.len)
    var lenBE = msg.length
    bigEndian32(addr result[0], addr lenBE)
    if msg.payload.len > 0:
      copyMem(addr result[4], unsafeAddr msg.payload[0], msg.payload.len)
  else:
    result = newString(5 + msg.payload.len)
    result[0] = msg.kind
    var lenBE = msg.length
    bigEndian32(addr result[1], addr lenBE)
    if msg.payload.len > 0:
      copyMem(addr result[5], unsafeAddr msg.payload[0], msg.payload.len)

proc writeMessage*(socket: AsyncSocket, msg: PgMessage): Future[void] {.async.} =
  ## Sends a PgMessage across an asynchronous socket
  let wireBytes = encode(msg)
  await socket.send(wireBytes)
