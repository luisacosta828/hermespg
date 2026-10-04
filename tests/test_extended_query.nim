import std/[unittest, asyncdispatch, asyncnet, nativesockets, strutils]
import hermespg/protocol/[messages, codec]
import hermespg/backend/[connection, pool]
import hermespg/proxy

suite "Extended Query Protocol and Transaction Pinning":
  test "Proxy supports Extended Query pipelining and transaction state pinning":
    let poolSettings = PoolSettings(
      pgHost: "127.0.0.1",
      pgPort: Port(5432),
      user: "postgres",
      password: "",
      database: "postgres",
      maxConnections: 2,
      maxQueueSize: 50,
      acquireTimeoutMs: 5000,
      idleTxTimeoutMs: 5000,
      resetQuery: "DISCARD ALL;",
      resetBeforeFirstQuery: true
    )

    let testPort = Port(6433)
    let srvConfig = ServerConfig(
      listenAddress: "127.0.0.1",
      listenPort: testPort,
      poolSettings: poolSettings,
      verbose: false
    )

    waitFor (proc() {.async.} =
      # 1. Start test server on port 6433
      let srvFut = startServer(srvConfig)
      await sleepAsync(150) # Allow server listener to bind

      let client = newAsyncSocket(buffered = false)
      await client.connect("127.0.0.1", testPort)

      # 2. Handshake: SSLRequest
      await client.send("\0\0\0\x08\x04\xd2\x16\x2f")
      let sslResp = await client.readExact(1)
      check sslResp == "N"

      # 3. Handshake: StartupMessage
      let startupPayload = writeInt32BE(ProtocolVersion30) & "user\0postgres\0database\0postgres\0\0"
      let startupMsg = PgMessage(kind: '\0', length: int32(4 + startupPayload.len), payload: startupPayload)
      await client.writeMessage(startupMsg)

      # Drain handshake packets until ReadyForQuery ('Z')
      while true:
        let msg = await client.readMessage()
        if msg.kind == MsgReadyForQuery:
          check msg.payload == "I"
          break

      # 4. TEST PIPELINED EXTENDED QUERY: Parse + Bind + Describe + Execute + Sync
      # Query: SELECT $1::int + 10; with parameter 32 -> Expected result: 42
      let sql = "SELECT $1::int + 10;\0"
      
      # Parse message: unnamed statement (""), sql, 1 param type (int4 oid = 23)
      let parsePayload = "\0" & sql & writeInt16BE(1) & writeInt32BE(23)
      let parseMsg = PgMessage(kind: MsgParse, length: int32(4 + parsePayload.len), payload: parsePayload)

      # Bind message: unnamed portal (""), unnamed statement (""), 1 format code (0=text),
      # 1 param (len=2, val="32"), 0 result format codes
      let bindPayload = "\0\0" & writeInt16BE(1) & writeInt16BE(0) & writeInt16BE(1) & writeInt32BE(2) & "32" & writeInt16BE(0)
      let bindMsg = PgMessage(kind: MsgBind, length: int32(4 + bindPayload.len), payload: bindPayload)

      # Describe message: 'P' (portal) + unnamed portal ("")
      let descPayload = "P\0"
      let descMsg = PgMessage(kind: MsgDescribe, length: int32(4 + descPayload.len), payload: descPayload)

      # Execute message: unnamed portal ("") + max rows 0 (all)
      let execPayload = "\0" & writeInt32BE(0)
      let execMsg = PgMessage(kind: MsgExecute, length: int32(4 + execPayload.len), payload: execPayload)

      # Sync message: length 4, no payload
      let syncMsg = PgMessage(kind: MsgSync, length: 4, payload: "")

      # Send the entire batch in a pipeline!
      await client.writeMessage(parseMsg)
      await client.writeMessage(bindMsg)
      await client.writeMessage(descMsg)
      await client.writeMessage(execMsg)
      await client.writeMessage(syncMsg)

      # Read pipelined responses from server
      var gotParseComplete = false
      var gotBindComplete = false
      var gotRowDesc = false
      var gotDataRow = false
      var dataRowValue = ""
      var gotCmdComplete = false
      var gotReady = false

      while true:
        let resp = await client.readMessage()
        case resp.kind
        of MsgParseComplete:
          gotParseComplete = true
        of MsgBindComplete:
          gotBindComplete = true
        of MsgRowDescription:
          gotRowDesc = true
        of MsgDataRow:
          gotDataRow = true
          # DataRow payload: int16 colCount (1), int32 colLen (2), bytes ("42")
          if resp.payload.len >= 6:
            let colLen = readInt32BE(resp.payload, 2)
            if colLen > 0 and resp.payload.len >= 6 + colLen:
              dataRowValue = resp.payload[6 ..< 6 + colLen]
        of MsgCommandComplete:
          gotCmdComplete = true
        of MsgReadyForQuery:
          gotReady = true
          check resp.payload == "I" # Idle, unpinned
          break
        else:
          discard

      check gotParseComplete
      check gotBindComplete
      check gotRowDesc
      check gotDataRow
      check dataRowValue == "42"
      check gotCmdComplete
      check gotReady

      # Helper for simple query message formatting
      proc makeQueryMsg(sql: string): PgMessage =
        PgMessage(kind: MsgQuery, length: int32(4 + sql.len + 1), payload: sql & "\0")

      # 5. TEST TRANSACTION PINNING: BEGIN -> Query -> COMMIT
      # Step A: BEGIN
      await client.writeMessage(makeQueryMsg("BEGIN;"))
      while true:
        let resp = await client.readMessage()
        if resp.kind == MsgReadyForQuery:
          check resp.payload == "T" # InTransaction! Pinned to backend!
          break

      # Step B: Execute query inside transaction
      await client.writeMessage(makeQueryMsg("SELECT 100;"))
      while true:
        let resp = await client.readMessage()
        if resp.kind == MsgReadyForQuery:
          check resp.payload == "T" # Still in transaction! Still pinned!
          break

      # Step C: COMMIT
      await client.writeMessage(makeQueryMsg("COMMIT;"))
      while true:
        let resp = await client.readMessage()
        if resp.kind == MsgReadyForQuery:
          check resp.payload == "I" # Back to Idle! Unpinned and released to pool!
          break

      # 6. Terminate client cleanly
      await client.writeMessage(PgMessage(kind: MsgTerminate, length: 4, payload: ""))
      client.close()

      # 7. Stop server
      shutdownRequested = true
      if shutdownFuture != nil and not shutdownFuture.finished:
        shutdownFuture.complete()
      await srvFut
    )()
