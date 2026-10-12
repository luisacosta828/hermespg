## Module: hermespg/auth/catalog
## Multi-user authentication catalog and userlist file parser for Gateway mode.
## Compatible with PgBouncer userlist.txt format (SCRAM-SHA-256 and plaintext).

import std/[strutils, tables, os, strformat]
import ../crypto/scram

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

proc parseAuthLine*(line: string, user: var string, secret: var string): bool =
  ## Parses a single line from userlist.txt or auth file.
  ## Supports:
  ##   "user" "secret"
  ##   "user" "SCRAM-SHA-256$4096:..."
  ##   user:secret
  ##   user secret
  ## Returns true if a valid user/secret pair was extracted, false if comment or blank.
  let trimmed = line.strip()
  if trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';':
    return false

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
      raise newException(ValueError, "Unterminated quote for username in line: " & line)
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
    raise newException(ValueError, fmt"Invalid SQL identifier for username '{user}' in line: {line}. Usernames must be 1-63 chars and alphanumeric/underscore.")

  skipWhitespace()
  if i < n and (trimmed[i] == ':' or trimmed[i] == '='):
    inc i
    skipWhitespace()

  if i >= n:
    raise newException(ValueError, "Missing password/secret for user '" & user & "' in line: " & line)

  # Parse secret
  if trimmed[i] == '"':
    inc i
    let start = i
    while i < n and trimmed[i] != '"':
      inc i
    if i >= n:
      raise newException(ValueError, "Unterminated quote for password in line: " & line)
    secret = trimmed[start ..< i]
    inc i
  else:
    let start = i
    while i < n and trimmed[i] notin {' ', '\t', '\r', '\n'}:
      inc i
    secret = trimmed[start ..< i]

  return user.len > 0 and secret.len > 0

proc loadAuthString*(catalog: UserCatalog, content: string) =
  ## Loads user credentials from a multi-line string buffer.
  for line in content.splitLines():
    var user = ""
    var secret = ""
    if parseAuthLine(line, user, secret):
      if secret.startsWith("SCRAM-SHA-256$"):
        catalog.users[user] = parseScramSecret(secret)
      else:
        catalog.users[user] = generateVerifier(secret)

proc loadAuthFile*(path: string): UserCatalog =
  ## Reads an auth file from disk and parses all user definitions.
  if not fileExists(path):
    raise newException(IOError, fmt"Auth file does not exist: '{path}'")
  let content = readFile(path)
  result = newUserCatalog()
  result.loadAuthString(content)
