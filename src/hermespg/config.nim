## Módulo de configuración dinámica para HermesPG (CLI y Variables de Entorno)
import std/[parseopt, strutils, os, strformat, nativesockets]
import ./backend/pool
import ./proxy

const
  HermesVersion* = "0.1.0"
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
  echo fmt"HermesPG v{HermesVersion} - Connection Pooler & Proxy para PostgreSQL en Nim"

proc showHelp*() =
  echo fmt"""
⚡ HermesPG v{HermesVersion}
Connection Pooler & Proxy de alto rendimiento para PostgreSQL.

USO:
  hermespg [OPCIONES]

OPCIONES DEL PROXY (SERVIDOR):
  -b, --bind <host>             Dirección IP de escucha (default: 0.0.0.0, env: HERMES_BIND)
  -p, --port <puerto>           Puerto de escucha del proxy (default: 6432, env: HERMES_PORT o PORT)
  -V, --verbose                 Activa logs detallados de depuración (default: false, env: HERMES_VERBOSE)

OPCIONES DE POSTGRESQL (BACKEND):
  -H, --pg-host <host>          Host del servidor PostgreSQL (default: 127.0.0.1, env: PGHOST)
  -P, --pg-port <puerto>        Puerto de PostgreSQL (default: 5432, env: PGPORT)
  -U, --user <usuario>          Usuario de conexión (default: postgres, env: PGUSER)
  -W, --password <clave>        Contraseña de autenticación (default: "", env: PGPASSWORD)
  -d, --db, --database <db>     Base de datos a utilizar (default: postgres, env: PGDATABASE)

OPCIONES DEL POOL Y CONTROL DE SOBRECARGA:
  -c, --max-conns <num>         Máximo de conexiones físicas a Postgres (default: 10, env: HERMES_MAX_CONNS)
  -q, --max-queue <num>         Tamaño máximo de cola en sobrecarga (default: 2000, env: HERMES_MAX_QUEUE)
  -t, --timeout <ms>            Tiempo de espera máximo en cola en ms (default: 15000, env: HERMES_TIMEOUT_MS)
  -i, --idle-tx-timeout <ms>    Tiempo máx. transacción inactiva antes de ROLLBACK (default: 8000, env: HERMES_IDLE_TX_TIMEOUT_MS)
  -r, --reset-query <sql>       Consulta de limpieza de sesión (default: "DISCARD ALL;")
      --no-reset                Desactiva limpieza de sesión antes de prestar la conexión

INFORMACIÓN:
  -h, --help                    Muestra este mensaje de ayuda y termina
  -v, --version                 Muestra la versión de HermesPG y termina

EJEMPLOS:
  # Iniciar proxy local en el puerto 6432 hacia PostgreSQL local
  hermespg

  # Conectar a servidor remoto en AWS/Cloud con 25 conexiones físicas
  hermespg -H db.internal.net -P 5432 -U app_user -W secret123 -d production -c 25

  # Configurar vía variables de entorno estándar (12-Factor App)
  PGHOST=10.0.0.1 PGPASSWORD=secret HERMES_PORT=6432 hermespg
"""

proc parsePortValue(val, optName: string): Port =
  try:
    let p = parseInt(val)
    if p < 1 or p > 65535:
      quit(fmt"[ERROR CLI] Puerto fuera de rango [1..65535] en '{optName}': {val}", 1)
    return Port(p)
  except ValueError:
    quit(fmt"[ERROR CLI] Se esperaba un número de puerto entero en '{optName}': {val}", 1)

proc parsePositiveIntValue(val, optName: string): int =
  try:
    let n = parseInt(val)
    if n <= 0:
      quit(fmt"[ERROR CLI] El valor en '{optName}' debe ser un entero positivo mayor a 0: {val}", 1)
    return n
  except ValueError:
    quit(fmt"[ERROR CLI] Se esperaba un valor numérico entero en '{optName}': {val}", 1)

proc fetchVal(p: var OptParser, optName: string): string =
  if p.val.len > 0:
    return p.val
  p.next()
  if p.kind == cmdArgument and p.key.len > 0:
    return p.key
  else:
    quit(fmt"[ERROR CLI] Falta especificar el valor para '{optName}'", 1)

proc parseConfig*(cmdParams: seq[string] = commandLineParams()): ServerConfig =
  ## Construye ServerConfig resolviendo prioridades:
  ## 1. Argumentos CLI (máxima prioridad)
  ## 2. Variables de entorno (PGHOST, PGPORT, HERMES_*, etc.)
  ## 3. Valores por defecto (fallback)

  # Carga inicial desde variables de entorno o defaults
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

  # Parseo de opciones pasadas por línea de comandos
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
        quit(fmt"[ERROR CLI] Opción desconocida: '{p.key}'. Ejecuta 'hermespg --help' para ver la lista de opciones.", 1)
    of cmdArgument:
      quit(fmt"[ERROR CLI] Argumento inesperado: '{p.key}'. Ejecuta 'hermespg --help' para más información.", 1)

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
