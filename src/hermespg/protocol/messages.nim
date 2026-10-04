## Type definitions and constants for PostgreSQL Frontend/Backend protocol v3.0
import std/tables

const
  # Special initial message codes (do not carry a 1-byte type prefix)
  SslRequestCode* = 80877103'i32    # 1234.5679 decimal (0x04D2162F)
  CancelRequestCode* = 80877102'i32 # 1234.5678 decimal (0x04D2162E)
  ProtocolVersion30* = 196608'i32   # (3 shl 16) or 0

  # Backend -> Frontend messages
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

  # Frontend -> Backend messages
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
    kind*: char       ## 1-byte identifier ('Q', 'Z', 'R', etc.) or '\0' for Startup
    length*: int32    ## Declared total length (includes the 4 bytes of length)
    payload*: string  ## Message payload data (excludes type byte and 4 length bytes)

  StartupMessage* = object
    protocolVersion*: int32
    parameters*: Table[string, string]

# Compile-time utility to pre-assemble binary PostgreSQL error packets
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
  # Pre-compiled packet: Queue acquisition timeout (SQLSTATE 53300: too_many_connections)
  WireTimeoutError* = buildStaticErrorPacket(
    "53300",
    "connection pool: timeout waiting for available backend connection"
  )

  # Pre-compiled packet: Saturated queue (Immediate Fail-Fast rejection)
  WireQueueFullError* = buildStaticErrorPacket(
    "53300",
    "connection pool: request rejected immediately, queue is full"
  )

  # Pre-compiled packet: Abandoned idle transaction (SQLSTATE 25P03: idle_in_transaction_session_timeout)
  WireIdleTxTimeoutError* = buildStaticErrorPacket(
    "25P03",
    "connection pool: transaction closed due to idle timeout"
  )

  # Pre-compiled packet: Server shutting down (SQLSTATE 57P01: admin_shutdown)
  WirePoolShuttingDownError* = buildStaticErrorPacket(
    "57P01",
    "connection pool: server is shutting down"
  )
