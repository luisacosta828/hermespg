# Package
version       = "0.1.3"
author        = "luisacosta828"
description   = "HermesPG - A lightweight, ultra-fast PostgreSQL connection pooler and proxy in Nim"
license       = "MIT"
srcDir        = "src"
bin           = @["hermespg"]

# Dependencies
requires "nim >= 2.0.0"
requires "checksums >= 0.1.0"

task test, "Run the test suite":
  exec "testament pattern 'tests/test_*.nim'"
