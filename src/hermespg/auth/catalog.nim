## Module: hermespg/auth/catalog
## Multi-user authentication catalog and userlist file parser for Gateway mode.
## Compatible with PgBouncer userlist.txt format (SCRAM-SHA-256 and plaintext).

import std/[strutils, tables, os, strformat, asyncdispatch]
when defined(posix):
  import std/posix
import ../crypto/scram
import ../backend/connection

type
  UserCatalog* = ref object
    users*: Table[string, ScramVerifier]

proc newUserCatalog*(): UserCatalog =
  UserCatalog(users: initTable[string, ScramVerifier]())

proc len*(catalog: UserCatalog): int =
  catalog.users.len

proc hasUser*(catalog: UserCatalog, username: string): bool =
  catalog.users.hasKey(username)

proc getVerifier*(catalog: UserCatalog, username: string, verifier: var ScramVerifier): bool =
  if catalog.users.hasKey(username):
    verifier = catalog.users[username]
    return true
  return false

proc addUser*(catalog: UserCatalog, username: string, verifier: ScramVerifier) =
  catalog.users[username] = verifier

proc addUserPlain*(catalog: UserCatalog, username, password: string) =
  catalog.users[username] = generateVerifier(password)

proc secureZeroString*(s: var string) {.inline.} =
  ## Overwrites string memory in place with zeroes before releasing it.
  if s.len > 0:
    zeroMem(addr s[0], s.len)
    s.setLen(0)

proc checkFilePermissions*(path: string): bool =
  ## Returns true if the file has strict owner-only permissions (no group/other access: mode & 0o077 == 0).
  when defined(posix):
    var st: Stat
    if stat(cstring(path), st) == 0:
      return (int(st.st_mode) and 0o077) == 0
    return false
  else:
    return true

proc quoteIdentifier*(ident: string): string =
  ## Quotes a PostgreSQL identifier safely according to SQL standard:
  ## Encloses in double quotes and escapes internal double quotes by doubling them ("" -> """").
  ## Rejects identifiers with null bytes.
  if '\0' in ident:
    raise newException(ValueError, "Identifier contains null bytes")
  if ident.len == 0:
    raise newException(ValueError, "Identifier cannot be empty")
  var res = "\""
  for c in ident:
    if c == '"':
      res.add("\"\"")
    else:
      res.add(c)
  res.add("\"")
  return res

proc isValidIdentifier*(ident: string): bool =
  ## Validates that an identifier contains only safe alphanumeric/underscore characters
  ## and is between 1 and 63 bytes (PostgreSQL standard NAMEDATALEN - 1)
  if ident.len == 0 or ident.len > 63:
    return false
  if ident[0] notin {'a'..'z', 'A'..'Z', '_'}:
    return false
  for c in ident:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      return false
  return true

proc parseAuthLine*(line: string, user: var string, secret: var string, lineNum: int = 0): bool =
  ## Parses a single line from userlist.txt or auth file.
  ## Supports:
  ##   "user" "secret"
  ##   "user" "SCRAM-SHA-256$4096:..."
  ##   user:secret
  ##   user secret
  ## Returns true if a valid user/secret pair was extracted, false if comment or blank.
  ## Security policy: Never include raw line contents or secrets in exception messages.
  let trimmed = line.strip()
  if trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';':
    return false

  let loc = if lineNum > 0: fmt" at line #{lineNum}" else: ""
  var i = 0
  let n = trimmed.len

  template skipWhitespace() =
    while i < n and (trimmed[i] == ' ' or trimmed[i] == '\t'):
      inc i

  skipWhitespace()
  if i >= n: return false

  # Parse username
  if trimmed[i] == '"':
    inc i
    let start = i
    while i < n and trimmed[i] != '"':
      inc i
    if i >= n:
      raise newException(ValueError, fmt"Unterminated quote for username{loc}")
    user = trimmed[start ..< i]
    inc i
  else:
    let start = i
    while i < n and trimmed[i] notin {' ', '\t', ':', '='}:
      inc i
    user = trimmed[start ..< i]

  if user.len == 0:
    return false

  if not isValidIdentifier(user):
    raise newException(ValueError, fmt"Invalid SQL identifier for username '{user}'{loc}. Usernames must be 1-63 chars and alphanumeric/underscore.")

  skipWhitespace()
  if i < n and (trimmed[i] == ':' or trimmed[i] == '='):
    inc i
    skipWhitespace()

  if i >= n:
    raise newException(ValueError, fmt"Missing password/secret for user '{user}'{loc}")

  # Parse secret
  if trimmed[i] == '"':
    inc i
    let start = i
    while i < n and trimmed[i] != '"':
      inc i
    if i >= n:
      raise newException(ValueError, fmt"Unterminated quote for password of user '{user}'{loc}")
    secret = trimmed[start ..< i]
    inc i
  else:
    let start = i
    while i < n and trimmed[i] notin {' ', '\t', '\r', '\n'}:
      inc i
    secret = trimmed[start ..< i]

  return user.len > 0 and secret.len > 0

proc loadAuthString*(catalog: UserCatalog, content: string, sourceLabel: string = "") =
  ## Loads user credentials from a multi-line string buffer and zeroes temporary secret buffers.
  var lineNum = 0
  var plaintextCount = 0
  for line in content.splitLines():
    inc lineNum
    var user = ""
    var secret = ""
    try:
      if parseAuthLine(line, user, secret, lineNum):
        if secret.startsWith("SCRAM-SHA-256$"):
          catalog.users[user] = parseScramSecret(secret)
        else:
          inc plaintextCount
          catalog.users[user] = generateVerifier(secret)
    finally:
      secureZeroString(secret)

  if plaintextCount > 0 and sourceLabel.len > 0:
    echo fmt"[SECURITY WARNING] Auth file '{sourceLabel}' contains {plaintextCount} plaintext password(s). Use 'hermespg --gen-auth-file' to export SCRAM-SHA-256 verifiers from pg_shadow."

proc loadAuthFile*(path: string): UserCatalog =
  ## Reads an auth file from disk, verifies POSIX permissions, parses all user definitions,
  ## and scrubs the raw file content from RAM immediately after parsing.
  if not fileExists(path):
    raise newException(IOError, fmt"Auth file does not exist: '{path}'")
  if not checkFilePermissions(path):
    echo fmt"[SECURITY WARNING] Auth file '{path}' has overly permissive file mode. Recommend running: chmod 600 {path}"

  var content = readFile(path)
  result = newUserCatalog()
  try:
    result.loadAuthString(content, path)
  finally:
    secureZeroString(content)

proc writeSecureAuthFile*(path: string, users: seq[(string, string)]) =
  ## Writes (username, scram_secret) pairs to disk in userlist.txt format and enforces POSIX 0600 permissions.
  var buf = "# Generated by HermesPG (--gen-auth-file) from PostgreSQL pg_shadow\n"
  buf.add("# Format: \"username\" \"SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey>\"\n")
  for (user, secret) in users:
    if isValidIdentifier(user) and secret.startsWith("SCRAM-SHA-256$"):
      buf.add("\"" & user & "\" \"" & secret & "\"\n")

  try:
    writeFile(path, buf)
    when defined(posix):
      discard chmod(cstring(path), Mode(0o600))
  finally:
    secureZeroString(buf)

proc fetchPgShadowUsers*(conn: BackendConn): Future[seq[(string, string)]] {.async.} =
  ## Queries pg_shadow for all roles with SCRAM-SHA-256 verifiers.
  const query = "SELECT usename::text, passwd::text FROM pg_shadow WHERE passwd LIKE 'SCRAM-SHA-256$%' ORDER BY usename;"
  let rows = await conn.queryRows(query)
  var exported: seq[(string, string)] = @[]
  for row in rows:
    if row.len >= 2:
      let username = row[0]
      let passwd = row[1]
      if isValidIdentifier(username) and passwd.startsWith("SCRAM-SHA-256$"):
        exported.add((username, passwd))
  return exported

proc syncCatalogFromPgShadow*(conn: BackendConn): Future[UserCatalog] {.async.} =
  ## Builds an in-memory UserCatalog directly from PostgreSQL pg_shadow SCRAM-SHA-256 verifiers.
  let pairs = await fetchPgShadowUsers(conn)
  let catalog = newUserCatalog()
  for i in 0 ..< pairs.len:
    let user = pairs[i][0]
    var secret = pairs[i][1]
    try:
      catalog.addUser(user, parseScramSecret(secret))
    finally:
      secureZeroString(secret)
  return catalog
