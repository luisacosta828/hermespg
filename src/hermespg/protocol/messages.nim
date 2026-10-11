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

  AuthRequestKind* = enum
    AuthOk = 0                ## 0: Authentication successful
    AuthKerberosV5 = 1        ## 1: Kerberos V5 (obsolete)
    AuthCleartextPassword = 3 ## 3: Cleartext password
    AuthMD5Password = 5       ## 5: MD5 hashed password
    AuthSCMCredential = 6     ## 6: SCM credential
    AuthGSS = 7               ## 7: GSSAPI
    AuthGSSContinue = 8       ## 8: GSSAPI continue
    AuthSSPI = 9              ## 9: SSPI (Windows)
    AuthSASL = 10             ## 10: SASL negotiation (SCRAM-SHA-256)
    AuthSASLContinue = 11     ## 11: Server challenge with salt and iterations
    AuthSASLFinal = 12        ## 12: Server final signature verification

proc toAuthRequestKind*(code: int32): AuthRequestKind =
  case code
  of 0: AuthOk
  of 1: AuthKerberosV5
  of 3: AuthCleartextPassword
  of 5: AuthMD5Password
  of 6: AuthSCMCredential
  of 7: AuthGSS
  of 8: AuthGSSContinue
  of 9: AuthSSPI
  of 10: AuthSASL
  of 11: AuthSASLContinue
  of 12: AuthSASLFinal
  else:
    raise newException(ValueError, "Unknown PostgreSQL authentication code: " & $code)

type

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

proc buildAuthErrorPacket*(username: string): string =
  ## Generates standard PostgreSQL wire error packet for password authentication failure (SQLSTATE 28P01)
  let payload = "SFATAL\0VFATAL\0C28P01\0Mpassword authentication failed for user \"" & username & "\"\0\0"
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
