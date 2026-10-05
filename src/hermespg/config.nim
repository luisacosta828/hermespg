## Dynamic configuration module for HermesPG (CLI and Environment Variables)
import std/[parseopt, strutils, os, strformat, nativesockets]
import ./backend/pool
import ./proxy

const
  HermesVersion* = "0.1.1"
  DefaultListenAddress* = "0.0.0.0"
  DefaultListenPort* = Port(6432)
  DefaultPgHost* = "127.0.0.1"
  DefaultPgPort* = Port(5432)
  DefaultPgUser* = "postgres"
  DefaultPgPassword* = ""
  DefaultPgDatabase* = "postgres"
  DefaultMaxConnections* = 10
  DefaultMaxQueueSize* = 2000
  DefaultAcquireTimeoutMs* = 15000
  DefaultIdleTxTimeoutMs* = 8000
  DefaultResetQuery* = "DISCARD ALL;"
  DefaultResetBeforeFirstQuery* = true
  DefaultVerbose* = false

proc showVersion*() =
  echo fmt"HermesPG v{HermesVersion} - High-Performance PostgreSQL Connection Pooler & Proxy in Nim"

proc showHelp*() =
  echo fmt"""
⚡ HermesPG v{HermesVersion}
High-performance, lightweight PostgreSQL connection pooler and proxy in Nim.

USAGE:
  hermespg [OPTIONS]

PROXY SERVER OPTIONS:
  -b, --bind <host>             Listen IP address (default: 0.0.0.0, env: HERMES_BIND)
  -p, --port <port>             Listen port for frontend clients (default: 6432, env: HERMES_PORT or PORT)
  -V, --verbose                 Enable detailed debug logging (default: false, env: HERMES_VERBOSE)

POSTGRESQL BACKEND OPTIONS:
  -H, --pg-host <host>          PostgreSQL server host (default: 127.0.0.1, env: PGHOST)
  -P, --pg-port <port>          PostgreSQL server port (default: 5432, env: PGPORT)
  -U, --user <user>             PostgreSQL connection user (default: postgres, env: PGUSER)
  -W, --password <password>     PostgreSQL connection password (default: "", env: PGPASSWORD)
  -d, --db, --database <db>     PostgreSQL database name (default: postgres, env: PGDATABASE)

CONNECTION POOL & LOAD SHEDDING OPTIONS:
  -c, --max-conns <num>         Maximum physical connections to PostgreSQL (default: 10, env: HERMES_MAX_CONNS)
  -q, --max-queue <num>         Maximum waiting clients queue size (default: 2000, env: HERMES_MAX_QUEUE)
  -t, --timeout <ms>            Maximum queue acquisition wait time in ms (default: 15000, env: HERMES_TIMEOUT_MS)
  -i, --idle-tx-timeout <ms>    Maximum idle transaction time before auto-ROLLBACK in ms (default: 8000, env: HERMES_IDLE_TX_TIMEOUT_MS)
  -r, --reset-query <sql>       Session cleanup query (default: "DISCARD ALL;")
      --no-reset                Disable automatic session cleanup before leasing connection

GENERAL OPTIONS:
  -h, --help                    Show this help message and exit
  -v, --version                 Show HermesPG version and exit

EXAMPLES:
  # Start proxy on default port 6432 pointing to local PostgreSQL
  hermespg

  # Connect to remote PostgreSQL server on AWS/Cloud with 25 pooled connections
  hermespg -H db.internal.net -P 5432 -U app_user -W secret123 -d production -c 25

  # Configure using standard 12-factor environment variables
  PGHOST=10.0.0.1 PGPASSWORD=secret HERMES_PORT=6432 hermespg
"""

proc parsePortValue(val, optName: string): Port =
  try:
    let p = parseInt(val)
    if p < 1 or p > 65535:
      quit(fmt"[CLI ERROR] Port number out of range [1..65535] for '{optName}': {val}", 1)
    return Port(p)
  except ValueError:
    quit(fmt"[CLI ERROR] Expected an integer port number for '{optName}': {val}", 1)

proc parsePositiveIntValue(val, optName: string): int =
  try:
    let n = parseInt(val)
    if n <= 0:
      quit(fmt"[CLI ERROR] Value for '{optName}' must be a positive integer greater than 0: {val}", 1)
    return n
  except ValueError:
    quit(fmt"[CLI ERROR] Expected a numeric integer value for '{optName}': {val}", 1)

proc fetchVal(p: var OptParser, optName: string): string =
  if p.val.len > 0:
    return p.val
  p.next()
  if p.kind == cmdArgument and p.key.len > 0:
    return p.key
  else:
    quit(fmt"[CLI ERROR] Missing value for option '{optName}'", 1)

proc parseConfig*(cmdParams: seq[string] = commandLineParams()): ServerConfig =
  ## Builds ServerConfig resolving precedence:
  ## 1. CLI arguments (highest priority)
  ## 2. Environment variables (PGHOST, PGPORT, HERMES_*, etc.)
  ## 3. Safe defaults (fallback)

  # Load from environment variables or defaults
  var listenAddress = getEnv("HERMES_BIND", DefaultListenAddress)
  var listenPort = parsePortValue(getEnv("HERMES_PORT", getEnv("PORT", $DefaultListenPort.int)), "HERMES_PORT")
  var verbose = getEnv("HERMES_VERBOSE", "false").toLowerAscii in ["1", "true", "yes", "on"]

  var pgHost = getEnv("PGHOST", DefaultPgHost)
  var pgPort = parsePortValue(getEnv("PGPORT", $DefaultPgPort.int), "PGPORT")
  var pgUser = getEnv("PGUSER", DefaultPgUser)
  var pgPassword = getEnv("PGPASSWORD", DefaultPgPassword)
  var pgDatabase = getEnv("PGDATABASE", DefaultPgDatabase)

  var maxConns = parsePositiveIntValue(getEnv("HERMES_MAX_CONNS", $DefaultMaxConnections), "HERMES_MAX_CONNS")
  var maxQueue = parsePositiveIntValue(getEnv("HERMES_MAX_QUEUE", $DefaultMaxQueueSize), "HERMES_MAX_QUEUE")
  var timeoutMs = parsePositiveIntValue(getEnv("HERMES_TIMEOUT_MS", $DefaultAcquireTimeoutMs), "HERMES_TIMEOUT_MS")
  var idleTxTimeoutMs = parsePositiveIntValue(getEnv("HERMES_IDLE_TX_TIMEOUT_MS", $DefaultIdleTxTimeoutMs), "HERMES_IDLE_TX_TIMEOUT_MS")
  var resetQuery = getEnv("HERMES_RESET_QUERY", DefaultResetQuery)
  var resetBeforeFirstQuery = DefaultResetBeforeFirstQuery

  # Parse command-line options
  var p = initOptParser(cmdParams)
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "h", "help":
        showHelp()
        quit(0)
      of "v", "version":
        showVersion()
        quit(0)
      of "b", "bind":
        listenAddress = p.fetchVal("--bind")
      of "p", "port":
        listenPort = parsePortValue(p.fetchVal("--port"), "--port")
      of "H", "pg-host":
        pgHost = p.fetchVal("--pg-host")
      of "P", "pg-port":
        pgPort = parsePortValue(p.fetchVal("--pg-port"), "--pg-port")
      of "U", "user":
        pgUser = p.fetchVal("--user")
      of "W", "password":
        pgPassword = p.fetchVal("--password")
      of "d", "db", "database":
        pgDatabase = p.fetchVal("--database")
      of "c", "max-conns", "max-connections":
        maxConns = parsePositiveIntValue(p.fetchVal("--max-conns"), "--max-conns")
      of "q", "max-queue":
        maxQueue = parsePositiveIntValue(p.fetchVal("--max-queue"), "--max-queue")
      of "t", "timeout":
        timeoutMs = parsePositiveIntValue(p.fetchVal("--timeout"), "--timeout")
      of "i", "idle-tx-timeout":
        idleTxTimeoutMs = parsePositiveIntValue(p.fetchVal("--idle-tx-timeout"), "--idle-tx-timeout")
      of "r", "reset-query":
        resetQuery = p.fetchVal("--reset-query")
      of "no-reset":
        resetBeforeFirstQuery = false
      of "V", "verbose":
        verbose = true
      else:
        quit(fmt"[CLI ERROR] Unknown option: '{p.key}'. Run 'hermespg --help' to see all available options.", 1)
    of cmdArgument:
      quit(fmt"[CLI ERROR] Unexpected argument: '{p.key}'. Run 'hermespg --help' for usage information.", 1)

  let poolSettings = PoolSettings(
    pgHost: pgHost,
    pgPort: pgPort,
    user: pgUser,
    password: pgPassword,
    database: pgDatabase,
    maxConnections: maxConns,
    maxQueueSize: maxQueue,
    acquireTimeoutMs: timeoutMs,
    idleTxTimeoutMs: idleTxTimeoutMs,
    resetQuery: resetQuery,
    resetBeforeFirstQuery: resetBeforeFirstQuery
  )

  return ServerConfig(
    listenAddress: listenAddress,
    listenPort: listenPort,
    poolSettings: poolSettings,
    verbose: verbose
  )
