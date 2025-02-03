# nimscreen.nim
#
# A very minimal Unix-only “screen”-like multiplexer.
# It creates a Unix-domain socket at SESSION_SOCKET.
# In “new” mode it spawns a shell (using forkpty) and then listens for
# a client connection. In “attach” mode it connects to that socket,
# sets the terminal in raw mode, and shuttles data between STDIN/STDOUT and
# the PTY.
#
# Note: This is a minimal proof-of-concept and lacks many features and
# robustness aspects of a full multiplexer like GNU screen.

import os, posix, strutils, times

const
  SESSION_SOCKET* = "/tmp/nimscreen.sock"
  DETACH_SEQ* = "\x01d"  # Ctrl-A followed by d

## ─── C-BINDINGS FOR forkpty AND cfmakeraw ────────────────────────────────

# forkpty(3) creates a new pseudo-terminal and forks.
{.passC: "forkpty".}
proc forkpty(master: ptr cint, name: cstring, term: ptr termios, winp: ptr winsize): cint
  {.cdecl, importc: "forkpty", header: "<pty.h>".}

# cfmakeraw(3) sets the termios structure into “raw mode”
proc cfmakeraw(t: ptr termios) {.cdecl, importc: "cfmakeraw", header: "<termios.h>".}

## ─── UTILITY: UNIX DOMAIN SOCKET ADDRESS ────────────────────────────────

type
  sockaddr_un* = object
    sun_family: sa_family_t
    sun_path: array[108, char]

# Helper: initialize a sockaddr_un from a path string.
proc initSockAddr*(path: string): sockaddr_un =
  var addr: sockaddr_un
  addr.sun_family = AF_UNIX
  ## copy the path into sun_path (make sure it is NUL-terminated)
  for i in 0 ..< path.len:
    addr.sun_path[i] = path[i].ord
  addr.sun_path[path.len] = 0
  addr

## ─── TERMINAL RAW-MODE HELPERS ─────────────────────────────────────────────

proc enableRawMode(fd: cint): termios =
  ## Get current settings, set raw mode, and return the original settings.
  var term: termios
  if tcgetattr(fd, term) != 0:
    quit("tcgetattr failed")
  let orig = term
  cfmakeraw(addr term)
  if tcsetattr(fd, TCSANOW, term) != 0:
    quit("tcsetattr failed")
  return orig

proc disableRawMode(fd: cint, orig: termios) =
  tcsetattr(fd, TCSANOW, orig)

## ─── SERVER MODE: CREATE A NEW SESSION ─────────────────────────────────────

proc runServer*() =
  ## Remove any previous socket file.
  if fileExists(SESSION_SOCKET):
    removeFile(SESSION_SOCKET)

  let listenfd = socket(AF_UNIX, SOCK_STREAM, 0)
  if listenfd < 0:
    quit("socket error")
  var uaddr = initSockAddr(SESSION_SOCKET)
  if bind(listenfd, cast[pointer(sockaddr)](addr uaddr), sizeof(uaddr)) != 0:
    quit("bind error")
  if listen(listenfd, 5) != 0:
    quit("listen error")
  echo "Session socket created at ", SESSION_SOCKET

  ## Fork a pseudo-terminal and spawn a shell.
  var master: cint
  let pid = forkpty(addr master, nil, nil, nil)
  if pid < 0:
    quit("forkpty error")
  elif pid == 0:
    ## Child: exec the shell.
    var sh = getEnv("SHELL")
    if sh.len == 0:
      sh = "/bin/sh"
    # Note: execvp expects a NULL-terminated array.
    var args = @[sh, nil]
    execvp(sh, addr args[0])
    quit("execvp failed")
  else:
    echo "Shell started with PID ", pid
    echo "Waiting for client connections..."
    var buf: array[1024, char]
    ## Main server loop: accept one client at a time and forward I/O.
    while true:
      let clientfd = accept(listenfd, nil, nil)
      if clientfd < 0:
        continue
      echo "Client attached."
      ## Forward data between PTY master and client socket.
      while true:
        var rfds: fd_set
        FD_ZERO(rfds)
        FD_SET(master, rfds)
        FD_SET(clientfd, rfds)
        let nfds = max(master, clientfd) + 1
        let ret = select(nfds, rfds, nil, nil, nil)
        if ret <= 0:
          break
        if FD_ISSET(master, rfds):
          let n = read(master, buf, sizeof(buf))
          if n <= 0: break
          _ = write(clientfd, buf, n)
        if FD_ISSET(clientfd, rfds):
          let n = read(clientfd, buf, sizeof(buf))
          if n <= 0: break
          _ = write(master, buf, n)
      echo "Client detached."
      close(clientfd)
    close(listenfd)
    ## (If the server ever exits, remove the socket file.)
    removeFile(SESSION_SOCKET)

## ─── CLIENT MODE: ATTACH TO AN EXISTING SESSION ───────────────────────────

proc attachSession*() =
  let sockfd = socket(AF_UNIX, SOCK_STREAM, 0)
  if sockfd < 0:
    quit("socket error")
  let uaddr = initSockAddr(SESSION_SOCKET)
  if connect(sockfd, cast[pointer(sockaddr)](addr uaddr), sizeof(uaddr)) != 0:
    quit("connect error")
  echo "Attached to session. (Press Ctrl-A then d to detach.)"
  let origTerm = enableRawMode(STDIN_FILENO)
  var buf: array[1024, char]
  while true:
    var rfds: fd_set
    FD_ZERO(rfds)
    FD_SET(STDIN_FILENO, rfds)
    FD_SET(sockfd, rfds)
    let nfds = max(STDIN_FILENO, sockfd) + 1
    let ret = select(nfds, rfds, nil, nil, nil)
    if ret <= 0: break
    if FD_ISSET(STDIN_FILENO, rfds):
      let n = read(STDIN_FILENO, buf, sizeof(buf))
      if n <= 0: break
      ## Check for detach sequence: if the first two characters match DETACH_SEQ.
      if n >= 2 and buf[0] == '\x01' and buf[1] == 'd':
        break
      _ = write(sockfd, buf, n)
    if FD_ISSET(sockfd, rfds):
      let n = read(sockfd, buf, sizeof(buf))
      if n <= 0: break
      _ = write(STDOUT_FILENO, buf, n)
  disableRawMode(STDIN_FILENO, origTerm)
  close(sockfd)
  echo "\nDetached from session."

## ─── MAIN: PICK MODE BASED ON ARGUMENTS ───────────────────────────────────

when isMainModule:
  if paramCount() < 1:
    echo "Usage: nimscreen new|attach"
    quit(1)
  let mode = paramStr(1)
  if mode == "new":
    runServer()
  elif mode == "attach":
    attachSession()
  else:
    echo "Unknown mode. Use 'new' or 'attach'."
