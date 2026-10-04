import std/[unittest, tables]
import hermespg/protocol/[messages, codec]

suite "PostgreSQL Protocol Codec":
  test "Integer Big-Endian serialization and deserialization":
    let original: int32 = 80877103 # SSLRequest code
    let bytes = writeInt32BE(original)
    check bytes.len == 4
    let parsed = readInt32BE(bytes, 0)
    check parsed == original

  test "Encode and parse standard Query message":
    let sql = "SELECT 1;\0"
    let totalLen = int32(4 + sql.len)
    let msg = PgMessage(
      kind: 'Q',
      length: totalLen,
      payload: sql
    )
    let wire = encode(msg)
    
    check wire.len == 1 + totalLen
    check wire[0] == 'Q'
    check readInt32BE(wire, 1) == totalLen
    check wire[5 .. ^1] == sql

  test "Parse StartupMessage parameters":
    # Construimos un payload de StartupMessage manual:
    # 4 bytes de versión (196608 = 3.0) + "user\0postgres\0database\0postgres\0\0"
    var payload = writeInt32BE(ProtocolVersion30)
    payload.add("user\0postgres\0database\0my_database\0\0")

    let startup = parseStartupMessage(payload)
    check startup.protocolVersion == ProtocolVersion30
    check startup.parameters["user"] == "postgres"
    check startup.parameters["database"] == "my_database"

  test "Detect SSLRequest from payload":
    let payload = writeInt32BE(SslRequestCode)
    let code = readInt32BE(payload, 0)
    check code == SslRequestCode
