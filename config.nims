# Global Nim project configuration
switch("path", "src")
switch("mm", "orc")
switch("threads", "on")
switch("panics", "on")

# Production binary sizing and optimization by default
if not defined(debug):
  switch("define", "danger")
  switch("opt", "speed")
  switch("passC", "-flto -ffunction-sections -fdata-sections -O3")
  switch("passL", "-flto -Wl,--gc-sections -s")

