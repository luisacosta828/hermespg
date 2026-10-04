## Módulo de codificación y decodificación binaria para el protocolo PostgreSQL v3.0
import std/[asyncnet, asyncdispatch, endians, tables]
import ./messages

proc readInt32BE*(data: string, offset = 0): int32 =
  ## Lee un entero de 32 bits con signo en orden Big-Endian desde un string
  assert offset + 4 <= data.len, "Buffer insuficiente para leer int32"
  bigEndian32(addr result, unsafeAddr data[offset])

proc writeInt32BE*(val: int32): string =
  ## Serializa un entero de 32 bits con signo a Big-Endian (4 bytes)
  result = newString(4)
  var v = val
  bigEndian32(addr result[0], addr v)

proc readInt16BE*(data: string, offset = 0): int16 =
  ## Lee un entero de 16 bits con signo en orden Big-Endian desde un string
  assert offset + 2 <= data.len, "Buffer insuficiente para leer int16"
  bigEndian16(addr result, unsafeAddr data[offset])

proc writeInt16BE*(val: int16): string =
  ## Serializa un entero de 16 bits con signo a Big-Endian (2 bytes)
  result = newString(2)
  var v = val
  bigEndian16(addr result[0], addr v)

proc readExact*(socket: AsyncSocket, size: int): Future[string] {.async.} =
  ## Lee exactamente `size` bytes de un socket asíncrono.
  ## Si la conexión se cierra antes de leer cualquier byte, retorna "".
  ## Si la conexión se cierra tras leer parcialmente, lanza IOError.
  if size == 0:
    return ""
  result = newString(size)
  var totalRead = 0
  while totalRead < size:
    let chunk = await socket.recv(size - totalRead)
    if chunk.len == 0:
      if totalRead == 0:
        return "" # Conexión cerrada limpiamente
      raise newException(IOError, "Conexión cerrada prematuramente durante la lectura de paquete")
    copyMem(addr result[totalRead], unsafeAddr chunk[0], chunk.len)
    totalRead.inc(chunk.len)

proc readMessage*(socket: AsyncSocket): Future[PgMessage] {.async.} =
  ## Lee un mensaje estándar de PostgreSQL (1 byte tipo + 4 bytes longitud + payload)
  let typeByte = await socket.readExact(1)
  if typeByte.len == 0:
    # EOF detectado
    return PgMessage(kind: '\0', length: 0, payload: "")

  let lenBytes = await socket.readExact(4)
  if lenBytes.len < 4:
    raise newException(IOError, "EOF inesperado leyendo longitud de paquete")

  let totalLen = readInt32BE(lenBytes, 0)
  if totalLen < 4:
    raise newException(ValueError, "Longitud de paquete inválida: " & $totalLen)

  let payloadLen = totalLen - 4
  var payload = ""
  if payloadLen > 0:
    payload = await socket.readExact(payloadLen)
    if payload.len < payloadLen:
      raise newException(IOError, "EOF inesperado leyendo payload de paquete")

  return PgMessage(
    kind: typeByte[0],
    length: totalLen,
    payload: payload
  )

proc readStartupOrSsl*(socket: AsyncSocket): Future[PgMessage] {.async.} =
  ## Lee el primer mensaje de un cliente PostgreSQL (StartupMessage o SSLRequest).
  ## Estos mensajes NO tienen el byte de tipo inicial, inician directamente con 4 bytes de longitud.
  let lenBytes = await socket.readExact(4)
  if lenBytes.len == 0:
    return PgMessage(kind: '\0', length: 0, payload: "")
  if lenBytes.len < 4:
    raise newException(IOError, "EOF inesperado leyendo cabecera inicial")

  let totalLen = readInt32BE(lenBytes, 0)
  if totalLen < 4:
    raise newException(ValueError, "Longitud inicial inválida: " & $totalLen)

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
  ## Decodifica el payload de un StartupMessage extrayendo la versión y pares clave-valor
  if payload.len < 4:
    raise newException(ValueError, "Payload insuficiente para StartupMessage")

  result.protocolVersion = readInt32BE(payload, 0)
  result.parameters = initTable[string, string]()

  var i = 4
  while i < payload.len:
    if payload[i] == '\0':
      # Byte nulo final terminador del paquete
      break

    # Leemos la clave hasta el '\0'
    let keyStart = i
    while i < payload.len and payload[i] != '\0':
      inc i
    if i >= payload.len: break
    let key = payload[keyStart ..< i]
    inc i # saltamos el '\0' de la clave

    # Leemos el valor hasta el '\0'
    let valStart = i
    while i < payload.len and payload[i] != '\0':
      inc i
    if i >= payload.len: break
    let val = payload[valStart ..< i]
    inc i # saltamos el '\0' del valor

    result.parameters[key] = val

proc encode*(msg: PgMessage): string =
  ## Serializa un PgMessage a bytes listos para transmitirse por el cable
  if msg.kind == '\0':
    # Mensaje sin byte de tipo (ej. StartupMessage reenviado)
    result = writeInt32BE(msg.length) & msg.payload
  else:
    result = $msg.kind & writeInt32BE(msg.length) & msg.payload

proc writeMessage*(socket: AsyncSocket, msg: PgMessage): Future[void] {.async.} =
  ## Envía un PgMessage a través de un socket asíncrono
  let wireBytes = encode(msg)
  await socket.send(wireBytes)
