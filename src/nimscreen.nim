{.passL: "-lutil".}
import posix, os, strutils, terminal

# Define TWinSize struct for handling terminal window size changes
type
  TWinSize {.importc: "struct winsize", header: "<sys/ioctl.h>".} = object
    ws_row: cuint
    ws_col: cuint
    ws_xpixel: cuint
    ws_ypixel: cuint

proc forkpty(master: ptr cint, name: cstring, termp: pointer, winp: pointer): cint
  {.importc, header: "<pty.h>".}

const
  TIOCGWINSZ* = 0x5413  # Request window size
  TIOCSWINSZ* = 0x5414  # Set window size
  SIGWINCH* = 28  # Signal number for window size change (POSIX standard)

# Handle terminal window resizing (SIGWINCH)
proc resizeHandler(masterFd: cint) {.noconv.} =
  var ws: TWinSize
  discard ioctl(STDOUT_FILENO, TIOCGWINSZ, addr ws)
  discard ioctl(masterFd, TIOCSWINSZ, addr ws)

# Handle child process termination (SIGCHLD)
proc sigchldHandler {.noconv.} =
  var status: cint
  while waitpid(-1, status, WNOHANG) > 0:
    echo "Child process exited with status: ", status
    quit(0)

# Setup signal handlers for proper process management
proc setupSignals(masterFd: cint) =
  var act: SigAction
  act.saHandler = cast[proc (signal: cint) {.noconv.}](sigchldHandler)
  discard sigaction(SIGCHLD, act, nil)

  act.saHandler = cast[proc (signal: cint) {.noconv.}](resizeHandler)
  discard sigaction(SIGWINCH, act, nil)

# Main I/O loop for interacting with the PTY
proc ioLoop(masterFd: cint) =
  var readfds: TFdSet
  var buf: array[1024, char]

  while true:
    FD_ZERO(readfds)
    FD_SET(masterFd, readfds)
    FD_SET(STDIN_FILENO, readfds)
    let nfds = max(masterFd, STDIN_FILENO) + 1

    let ready = select(nfds, addr readfds, nil, nil, nil)
    if ready < 0:
      echo "select error: ", strerror(errno)
      break

    if FD_ISSET(masterFd, readfds) != 0:
      let count = read(masterFd, addr buf[0], 1024)
      if count <= 0: break  # pty closed or error
      discard posix.write(STDOUT_FILENO, addr buf, count)

    if FD_ISSET(STDIN_FILENO, readfds) != 0:
      let count = read(STDIN_FILENO, addr buf, sizeof(buf))
      if count <= 0: break  # stdin closed or error
      discard posix.write(masterFd, addr buf, count)

# Main process logic
proc main() =
  var masterFd: cint
  let pid = forkpty(addr masterFd, nil, nil, nil)

  if pid < 0:
    echo "forkpty failed: ", strerror(errno)
    quit(1)
  elif pid == 0:
    var shell = os.getenv("SHELL")
    if shell.len == 0:
      shell = "/bin/sh"

    var args = allocCStringArray([shell])
    discard execvp(shell.cstring, args)

    echo "execvp failed: ", strerror(errno)
    quit(127)
  else:
    echo "Spawned shell with pty master fd: ", masterFd
    setupSignals(masterFd)
    ioLoop(masterFd)

    var status: cint
    discard waitpid(pid, status, 0)
    echo "Child exited with status ", status

if isMainModule:
  main()
