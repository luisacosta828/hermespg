## Definiciones de tipos y constantes del protocolo Frontend/Backend v3.0 de PostgreSQL
import std/tables

const
  # Códigos especiales de mensajes iniciales (no llevan byte de tipo)
  SslRequestCode* = 80877103'i32    # 1234.5679 en decimal (0x04D2162F)
  CancelRequestCode* = 80877102'i32 # 1234.5678 en decimal (0x04D2162E)
  ProtocolVersion30* = 196608'i32   # (3 shl 16) or 0

  # Mensajes Backend -> Frontend
  MsgParseComplete* = '1'
  MsgBindComplete* = '2'
  MsgCloseComplete* = '3'
  MsgCommandComplete* = 'C'
  MsgDataRow* = 'D'
  MsgErrorResponse* = 'E'
  MsgBackendKeyData* = 'K'
  MsgNoticeResponse* = 'N'
  MsgAuth* = 'R'
  MsgParameterStatus* = 'S'
  MsgRowDescription* = 'T'
  MsgReadyForQuery* = 'Z'

  # Mensajes Frontend -> Backend
  MsgBind* = 'B'
  MsgClose* = 'C'
  MsgDescribe* = 'D'
  MsgExecute* = 'E'
  MsgFlush* = 'H'
  MsgParse* = 'P'
  MsgQuery* = 'Q'
  MsgSync* = 'S'
  MsgTerminate* = 'X'
  MsgPassword* = 'p'

type
  TransactionStatus* = enum
    FailedTransaction = 'E'
    Idle = 'I'
    InTransaction = 'T'

  PgMessage* = object
    kind*: char       ## Identificador de 1 byte ('Q', 'Z', 'R', etc.) o '\0' para Startup
    length*: int32    ## Longitud total declarada (incluye los 4 bytes de longitud)
    payload*: string  ## Datos del mensaje (excluye el tipo y los 4 bytes de longitud)

  StartupMessage* = object
    protocolVersion*: int32
    parameters*: Table[string, string]

# Utilidad en tiempo de compilación para pre-ensamblar paquetes de error en formato binario PG
proc buildStaticErrorPacket(sqlState, message: string): string {.compileTime.} =
  let payload = "SFATAL\0VFATAL\0C" & sqlState & "\0M" & message & "\0\0"
  let totalLen = int32(4 + payload.len)
  var beLen = newString(4)
  beLen[0] = chr((totalLen shr 24) and 0xFF)
  beLen[1] = chr((totalLen shr 16) and 0xFF)
  beLen[2] = chr((totalLen shr 8) and 0xFF)
  beLen[3] = chr(totalLen and 0xFF)
  result = "E" & beLen & payload

const
  # Paquete pre-compilado: Timeout en cola de espera (SQLSTATE 53300: too_many_connections)
  WireTimeoutError* = buildStaticErrorPacket(
    "53300",
    "connection pool: timeout waiting for available backend connection"
  )

  # Paquete pre-compilado: Cola saturada (Rechazo inmediato / Fail-Fast)
  WireQueueFullError* = buildStaticErrorPacket(
    "53300",
    "connection pool: request rejected immediately, queue is full"
  )

  # Paquete pre-compilado: Transacción abandonada (SQLSTATE 25P03: idle_in_transaction_session_timeout)
  WireIdleTxTimeoutError* = buildStaticErrorPacket(
    "25P03",
    "connection pool: transaction closed due to idle timeout"
  )

  # Paquete pre-compilado: Pool en apagado
  WirePoolShuttingDownError* = buildStaticErrorPacket(
    "57P01",
    "connection pool: server is shutting down"
  )
