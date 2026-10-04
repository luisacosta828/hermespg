import std/[unittest, envvars, nativesockets]
import hermespg/config
import hermespg/proxy
import hermespg/backend/pool

suite "HermesPG Dynamic Configuration & CLI":
  test "Default configuration":
    let cfg = parseConfig(@[])
    check cfg.listenAddress == "0.0.0.0"
    check cfg.listenPort == Port(6432)
    check cfg.verbose == false
    check cfg.poolSettings.pgHost == "127.0.0.1"
    check cfg.poolSettings.pgPort == Port(5432)
    check cfg.poolSettings.user == "postgres"
    check cfg.poolSettings.database == "postgres"
    check cfg.poolSettings.maxConnections == 10
    check cfg.poolSettings.maxQueueSize == 2000
    check cfg.poolSettings.acquireTimeoutMs == 15000
    check cfg.poolSettings.idleTxTimeoutMs == 8000
    check cfg.poolSettings.resetBeforeFirstQuery == true

  test "CLI flags override defaults":
    let args = @[
      "-b", "127.0.0.1",
      "-p", "6543",
      "-H", "postgres.internal",
      "-P", "5433",
      "-U", "custom_user",
      "-W", "my_pass",
      "-d", "custom_db",
      "-c", "25",
      "-q", "500",
      "-t", "5000",
      "-i", "3000",
      "-r", "DISCARD TEMP;",
      "--no-reset",
      "-V"
    ]
    let cfg = parseConfig(args)
    check cfg.listenAddress == "127.0.0.1"
    check cfg.listenPort == Port(6543)
    check cfg.verbose == true
    check cfg.poolSettings.pgHost == "postgres.internal"
    check cfg.poolSettings.pgPort == Port(5433)
    check cfg.poolSettings.user == "custom_user"
    check cfg.poolSettings.password == "my_pass"
    check cfg.poolSettings.database == "custom_db"
    check cfg.poolSettings.maxConnections == 25
    check cfg.poolSettings.maxQueueSize == 500
    check cfg.poolSettings.acquireTimeoutMs == 5000
    check cfg.poolSettings.idleTxTimeoutMs == 3000
    check cfg.poolSettings.resetQuery == "DISCARD TEMP;"
    check cfg.poolSettings.resetBeforeFirstQuery == false

  test "Environment variables fallback":
    putEnv("PGHOST", "envhost.net")
    putEnv("PGPORT", "5439")
    putEnv("PGUSER", "envuser")
    putEnv("PGPASSWORD", "envsecret")
    putEnv("PGDATABASE", "envdb")
    putEnv("HERMES_PORT", "9999")
    putEnv("HERMES_MAX_CONNS", "40")
    putEnv("HERMES_VERBOSE", "true")

    let cfg = parseConfig(@[])
    check cfg.listenPort == Port(9999)
    check cfg.verbose == true
    check cfg.poolSettings.pgHost == "envhost.net"
    check cfg.poolSettings.pgPort == Port(5439)
    check cfg.poolSettings.user == "envuser"
    check cfg.poolSettings.password == "envsecret"
    check cfg.poolSettings.database == "envdb"
    check cfg.poolSettings.maxConnections == 40

    # Cleanup env vars
    delEnv("PGHOST")
    delEnv("PGPORT")
    delEnv("PGUSER")
    delEnv("PGPASSWORD")
    delEnv("PGDATABASE")
    delEnv("HERMES_PORT")
    delEnv("HERMES_MAX_CONNS")
    delEnv("HERMES_VERBOSE")

  test "CLI flags take precedence over environment variables":
    putEnv("PGHOST", "envhost.net")
    let cfg = parseConfig(@["-H", "cli-wins.net"])
    check cfg.poolSettings.pgHost == "cli-wins.net"
    delEnv("PGHOST")
