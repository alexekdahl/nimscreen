## nimscreen.nim
## A minimal Unix-only "screen"-like terminal multiplexer written in Nim.
##
## This program launches a shell in a detached pseudo-terminal (PTY) session.
## You can attach to this session via a Unix domain socket and later detach by
## pressing Ctrl-A then d.
##
## Usage:
##   Start a new session: ./nimscreen new
##   Attach to a session: ./nimscreen attach

import os, posix, strutils, times

const
  SESSION_SOCKET* = "/tmp/nimscreen.sock"
  DETACH_SEQ*      = "\x01d"  # Ctrl-A then d

## ─── C-BINDINGS FOR forkpty AND cfmakeraw ───────────────────────────────

{.passC: "forkpty".}
proc forkpty(master: ptr cint, name: cstring, term: ptr termios, winp: ptr winsize): cint
  {.cdecl, importc: "forkpty", header: "<pty.h>".}

proc cfmakeraw(t: ptr termios) {.cdecl, importc: "cfmakeraw", header: "<termios.h>".}

## ─── UTILITY: UNIX DOMAIN SOCKET ADDRESS ───────────────────────────────

type
  sockaddr_un* = object
    sun_family: sa_family_t
    sun_path: array[108, char]

proc initSockAddr*(path: string): sockaddr_un =
  ## Initializes a Unix domain socket address with the given path.
  var addr: sockaddr_un
  addr.sun_family = AF_UNIX
  for i in 0 ..< path.len:
    addr.sun_path[i] = path[i].ord
  addr.sun_path[path.len] = 0
  addr

## ─── TERMINAL RAW-MODE HELPERS ───────────────────────────────────────────

proc enableRawMode(fd: cint): termios =
  ## Puts the file descriptor (e.g. STDIN_FILENO) into raw mode.
  ## Returns the original terminal settings.
  var term: termios
  if tcgetattr(fd, term) != 0:
    raise newException(OSError, "tcgetattr failed")
  let orig = term
  cfmakeraw(addr term)
  if tcsetattr(fd, TCSANOW, term) != 0:
    raise newException(OSError, "tcsetattr failed")
  orig

proc disableRawMode(fd: cint, orig: termios) =
  ## Restores the terminal settings from orig.
  discard tcsetattr(fd, TCSANOW, orig)

## ─── HELPER: DATA FORWARDING ──────────────────────────────────────────────

proc forwardData(srcFd, dstFd: cint) =
  ## Forwards data from srcFd to dstFd until an error occurs or EOF is reached.
  var buf: array[1024, char]
  while true:
    let n = read(srcFd, buf, sizeof(buf))
    if n <= 0:
      break
    if write(dstFd, buf, n) <= 0:
      break

## ─── SERVER MODE: NEW SESSION ─────────────────────────────────────────────

proc runServer*() =
  ## Creates a new session. This starts a shell in a pseudo-terminal
  ## and listens on a Unix domain socket for client connections.
  if fileExists(SESSION_SOCKET):
    try:
      removeFile(SESSION_SOCKET)
    except OSError:
      discard

  let listenfd = socket(AF_UNIX, SOCK_STREAM, 0)
  if listenfd < 0:
    raise newException(OSError, "socket error")

  var uaddr = initSockAddr(SESSION_SOCKET)
  if bind(listenfd, cast[pointer(sockaddr)](addr uaddr), sizeof(uaddr)) != 0:
    raise newException(OSError, "bind error")
  if listen(listenfd, 5) != 0:
    raise newException(OSError, "listen error")
  echo "Session socket created at ", SESSION_SOCKET

  var master: cint
  let pid = forkpty(addr master, nil, nil, nil)
  if pid < 0:
    raise newException(OSError, "forkpty error")
  elif pid == 0:
    ## Child process: execute the shell.
    var sh = getEnv("SHELL")
    if sh.len == 0:
      sh = "/bin/sh"
    var args = @[sh, nil]
    execvp(sh, addr args[0])
    raise newException(OSError, "execvp failed")
  else:
    echo "Shell started with PID ", pid
    echo "Waiting for client connections..."
    var buf: array[1024, char]
    while true:
      let clientfd = accept(listenfd, nil, nil)
      if clientfd < 0:
        continue
      echo "Client attached."
      ## Client connection loop: forward data between PTY master and client.
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
          if write(clientfd, buf, n) <= 0: break
        if FD_ISSET(clientfd, rfds):
          let n = read(clientfd, buf, sizeof(buf))
          if n <= 0: break
          if write(master, buf, n) <= 0: break
      echo "Client detached."
      close(clientfd)
    close(listenfd)
    try:
      removeFile(SESSION_SOCKET)
    except OSError:
      discard

## ─── CLIENT MODE: ATTACH TO SESSION ─────────────────────────────────────-

proc attachSession*() =
  ## Attaches to an existing PTY session via the Unix domain socket.
  ## Puts STDIN in raw mode so that keystrokes are transmitted directly.
  let sockfd = socket(AF_UNIX, SOCK_STREAM, 0)
  if sockfd < 0:
    raise newException(OSError, "socket error")
  let uaddr = initSockAddr(SESSION_SOCKET)
  if connect(sockfd, cast[pointer(sockaddr)](addr uaddr), sizeof(uaddr)) != 0:
    raise newException(OSError, "connect error")
  echo "Attached to session. (Press Ctrl-A then d to detach.)"
  let origTerm = enableRawMode(STDIN_FILENO)
  defer:
    disableRawMode(STDIN_FILENO, origTerm)
    close(sockfd)
    echo "\nDetached from session."

  var buf: array[1024, char]
  while true:
    var rfds: fd_set
    FD_ZERO(rfds)
    FD_SET(STDIN_FILENO, rfds)
    FD_SET(sockfd, rfds)
    let nfds = max(STDIN_FILENO, sockfd) + 1
    let ret = select(nfds, rfds, nil, nil, nil)
    if ret <= 0:
      break
    if FD_ISSET(STDIN_FILENO, rfds):
      let n = read(STDIN_FILENO, buf, sizeof(buf))
      if n <= 0:
        break
      ## Check for the detach sequence (Ctrl-A then d).
      if n >= 2 and buf[0] == '\x01' and buf[1] == 'd':
        break
      if write(sockfd, buf, n) <= 0:
        break
    if FD_ISSET(sockfd, rfds):
      let n = read(sockfd, buf, sizeof(buf))
      if n <= 0:
        break
      if write(STDOUT_FILENO, buf, n) <= 0:
        break

## ─── MAIN: MODE SELECTION AND ERROR HANDLING ─────────────────────────────

when isMainModule:
  try:
    if paramCount() < 1:
      echo "Usage: nimscreen new|attach"
      quit(1)
    let mode = paramStr(1)
    case mode
    of "new":
      runServer()
    of "attach":
      attachSession()
    else:
      echo "Unknown mode. Use 'new' or 'attach'."
  except OSError as e:
    echo "Error: ", e.msg
    quit(1)
