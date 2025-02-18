/*
   nimt -- A minimal, dtach-like tool.

   (C) WTFPL License.
*/
#define _BSD_SOURCE
#define _DEFAULT_SOURCE
#define _GNU_SOURCE
#define _XOPEN_SOURCE 700

#include <errno.h>
#include <fcntl.h>
#include <pty.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

/**********************************************************************
 *                              CONSTANTS
 **********************************************************************/
static const char *SOCKET_PATH = "/tmp/nimt.sock";
static const int MAX_ATTEMPTS = 5;
static const unsigned int ATTACH_DETACH_KEY = 0x1D; // Ctrl-]
static const char *CGROUP_PATH = "/sys/fs/cgroup/nimt/cgroup.procs";
static const char *CGROUP_FOLDER = "/sys/fs/cgroup/nimt";

/**********************************************************************
 *                           SESSION STRUCT
 **********************************************************************/

typedef struct Session {
    int id;             // session ID
    pid_t child_pid;    // child running in the pty
    int master_fd;      // pty master FD
    struct Session *next;
} Session;

/**********************************************************************
 *                  GLOBALS FOR THE DAEMON
 **********************************************************************/

static Session *g_sessions = NULL;    // linked list of sessions
static int g_next_session_id = 1;     // simplistic ID generator
static int g_server_sock = -1;        // the daemon's listening socket
static int g_sigchld_pipe[2];         // Self-pipe for SIGCHLD handling

/**********************************************************************
 *                           UTIL FUNCTIONS
 **********************************************************************/

// Move the current process to a cgroup
void move_to_cgroup(const char *cgroup_path) {
    int fd = open(cgroup_path, O_WRONLY);
    if (fd < 0) {
        perror("open cgroup.procs");
        return;
    }
    char pid_str[32];
    snprintf(pid_str, sizeof(pid_str), "%d", getpid());
    if (write(fd, pid_str, strlen(pid_str)) < 0) {
        perror("write to cgroup.procs");
    }
    close(fd);
}

int mkdirp(const char *folder) {
    struct stat st;
    if (stat(folder, &st) == 0) {
        if (S_ISDIR(st.st_mode)) {
            return 0;
        } else {
            fprintf(stderr, "Error: %s exists but is not a directory.\n", folder);
            return -1;
        }
    } else {
        if (errno != ENOENT) {
            perror("stat");
            return -1;
        }
        if (mkdir(folder, 0755) != 0) {
            perror("mkdir");
            return -1;
        }
    }
    return 0;
}

// Print an error message and exit
static void perror_exit(const char *msg) {
    perror(msg);
    exit(EXIT_FAILURE);
}

// Safe write handling partial writes
static int write_all(int fd, const void *buf, size_t count) {
    size_t written = 0;
    const char *p = buf;
    while (written < count) {
        ssize_t n = write(fd, p + written, count - written);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        written += n;
    }
    return 0;
}

// Add a session to the global list
static Session *add_session(pid_t child_pid, int master_fd) {
    Session *s = (Session *)malloc(sizeof(Session));
    if (!s) perror_exit("malloc");
    s->id = g_next_session_id++;
    s->child_pid = child_pid;
    s->master_fd = master_fd;
    s->next = g_sessions;
    g_sessions = s;
    return s;
}

// Find a session by ID
static Session *find_session(int id) {
    Session *p = g_sessions;
    while (p) {
        if (p->id == id) return p;
        p = p->next;
    }
    return NULL;
}

// Remove a session from the list (and free it)
static void remove_session(Session *s) {
    Session **pp = &g_sessions;
    while (*pp) {
        if (*pp == s) {
            *pp = s->next;
            close(s->master_fd);
            free(s);
            return;
        }
        pp = &((*pp)->next);
    }
}

// Function to move the daemon process to the parent cgroup
static void move_self_to_parent_cgroup(void) {
    // The parent cgroup is typically the root: /sys/fs/cgroup/
    const char *parent_procs = "/sys/fs/cgroup/cgroup.procs";
    int fd = open(parent_procs, O_WRONLY);
    if (fd < 0) {
        perror("open parent cgroup.procs");
        return;
    }
    char pid_str[32];
    snprintf(pid_str, sizeof(pid_str), "%d", getpid());
    if (write(fd, pid_str, strlen(pid_str)) < 0) {
        perror("write to parent cgroup.procs");
    }
    close(fd);
}

static void cleanup_resources(void) {
    Session *p = g_sessions;
    while (p) {
        kill(p->child_pid, SIGKILL);
        close(p->master_fd);
        Session *temp = p;
        p = p->next;
        free(temp);
    }
    g_sessions = NULL;

    // Wait for all child processes to exit.
    while (1) {
        int status;
        pid_t pid = waitpid(-1, &status, WNOHANG);
        if (pid > 0) {
            continue;
        } else if (pid == 0) {
            usleep(100000);
            continue;
        } else {
            if (errno == ECHILD)
                break;
            else
                break;
        }
    }

    if (g_server_sock != -1) {
        close(g_server_sock);
        unlink(SOCKET_PATH);
        g_server_sock = -1;
    }

    close(g_sigchld_pipe[0]);
    close(g_sigchld_pipe[1]);

    move_self_to_parent_cgroup();

    if (rmdir(CGROUP_FOLDER) != 0) {
        perror("rmdir CGROUP_FOLDER");
    }
}


static void sigterm_handler(int signo) {
    (void)signo;  // Unused parameter.
    cleanup_resources();
    exit(0);
}

// Add signal handlers for SIGTERM and SIGINT
static void setup_signal_handlers(void) {
    struct sigaction sa_term;
    memset(&sa_term, 0, sizeof(sa_term));
    sa_term.sa_handler = sigterm_handler;
    sa_term.sa_flags = SA_RESTART;
    sigaction(SIGTERM, &sa_term, NULL);
    sigaction(SIGINT, &sa_term, NULL);
}

/**********************************************************************
 *                  HANDLING CHILD EXIT (SIGCHLD)
 **********************************************************************/
static void sigchld_handler(int signo) {
    (void)signo;
    // Notify main loop via self-pipe
    char c = 1;
    if (write(g_sigchld_pipe[1], &c, 1) < 0) {
        // Ignore errors
    }
}

static void handle_sigchld(void) {
    int status;
    pid_t pid;
    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        Session *p = g_sessions;
        while (p) {
            if (p->child_pid == pid) {
                remove_session(p);
                break;
            }
            p = p->next;
        }
    }
}

/**********************************************************************
 *                     DAEMON COMMAND HANDLERS
 **********************************************************************/

static void handle_spawn(int client_sock, char *cmdline) {
    char *command_str = cmdline;
    while (*command_str == ' ') command_str++;
    if (*command_str == '\0') command_str = "bash";

    int master_fd;
    pid_t child_pid;
    struct winsize ws = {24, 80, 0, 0};
    child_pid = forkpty(&master_fd, NULL, NULL, &ws);
    if (child_pid < 0) {
        dprintf(client_sock, "ERROR forkpty: %s\n", strerror(errno));
        return;
    }

    if (child_pid == 0) {
        char *shell = getenv("SHELL");
        if (!shell || !*shell) {
            shell = "/bin/sh";
        }
        signal(SIGHUP, SIG_IGN);
        setsid();
        execl(shell, "sh", "-c", command_str, (char *)NULL);
        _exit(127);
    }

    Session *s = add_session(child_pid, master_fd);
    dprintf(client_sock, "OK %d\n", s->id);
}

static void handle_list(int client_sock) {
    Session *p = g_sessions;
    while (p) {
        dprintf(client_sock, "SESSION %d pid=%d\n", p->id, p->child_pid);
        p = p->next;
    }
    dprintf(client_sock, "DONE\n");
}

static void handle_kill(int client_sock, int session_id) {
    Session *s = find_session(session_id);
    if (!s) {
        dprintf(client_sock, "ERROR no such session\n");
        return;
    }
    kill(s->child_pid, SIGKILL);
    dprintf(client_sock, "OK killing session %d\n", session_id);
}

static void handle_attach(int client_sock, int session_id) {
    Session *s = find_session(session_id);
    if (!s) {
        dprintf(client_sock, "ERROR no such session\n");
        return;
    }
    dprintf(client_sock, "OK ATTACH\n");

    struct winsize ws;
    if (ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0) {
        ioctl(s->master_fd, TIOCSWINSZ, &ws);
    }

    while (1) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(client_sock, &rfds);
        FD_SET(s->master_fd, &rfds);
        int maxfd = (client_sock > s->master_fd) ? client_sock : s->master_fd;

        int rv = select(maxfd + 1, &rfds, NULL, NULL, NULL);
        if (rv < 0) {
            if (errno == EINTR) continue;
            break;
        }

        if (FD_ISSET(client_sock, &rfds)) {
            char buf[4096];
            ssize_t n = read(client_sock, buf, sizeof(buf));
            if (n <= 0) break;

            for (int i = 0; i < n; i++) {
                if ((unsigned char)buf[i] == ATTACH_DETACH_KEY) {
                    if (i > 0) write_all(s->master_fd, buf, i);
                    goto detach;
                }
            }
            write_all(s->master_fd, buf, n);
        }

        if (FD_ISSET(s->master_fd, &rfds)) {
            char buf[4096];
            ssize_t n = read(s->master_fd, buf, sizeof(buf));
            if (n <= 0) break;
            write_all(client_sock, buf, n);
        }
    }
detach:
    return;
}

/**********************************************************************
 *                      DAEMON MAIN LOOP
 **********************************************************************/

static void daemon_loop(void) {
    umask(0177);
    if (pipe(g_sigchld_pipe) == -1) perror_exit("pipe");
    fcntl(g_sigchld_pipe[0], F_SETFL, O_NONBLOCK);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sigchld_handler;
    sa.sa_flags = SA_RESTART;
    sigaction(SIGCHLD, &sa, NULL);

    setup_signal_handlers();

    unlink(SOCKET_PATH);
    g_server_sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (g_server_sock < 0) perror_exit("socket");

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);

    if (bind(g_server_sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) perror_exit("bind");
    if (listen(g_server_sock, 5) < 0) perror_exit("listen");
    chmod(SOCKET_PATH, 0600);

    while (1) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(g_server_sock, &rfds);
        FD_SET(g_sigchld_pipe[0], &rfds);
        int maxfd = (g_server_sock > g_sigchld_pipe[0]) ? g_server_sock : g_sigchld_pipe[0];

        int rv = select(maxfd + 1, &rfds, NULL, NULL, NULL);
        if (rv < 0) {
            if (errno == EINTR) continue;
            perror("select");
            break;
        }

        if (FD_ISSET(g_sigchld_pipe[0], &rfds)) {
            char buf[16];
            while (read(g_sigchld_pipe[0], buf, sizeof(buf)) > 0);
            handle_sigchld();
        }

        if (FD_ISSET(g_server_sock, &rfds)) {
            int client_sock = accept(g_server_sock, NULL, NULL);
            if (client_sock < 0) {
                if (errno != EINTR) perror("accept");
                continue;
            }

            char line[4096];
            ssize_t len = read(client_sock, line, sizeof(line)-1);
            if (len <= 0) {
                close(client_sock);
                continue;
            }
            line[len] = 0;

            if (strncmp(line, "SPAWN ", 6) == 0) {
                handle_spawn(client_sock, line + 6);
            } else if (strncmp(line, "LIST", 4) == 0) {
                handle_list(client_sock);
            } else if (strncmp(line, "KILL ", 5) == 0) {
                handle_kill(client_sock, atoi(line + 5));
            } else if (strncmp(line, "ATTACH ", 7) == 0) {
                handle_attach(client_sock, atoi(line + 7));
            } else {
                dprintf(client_sock, "ERROR unknown command\n");
            }

            close(client_sock);
        }
    }
}

/**********************************************************************
 *                         CLIENT FUNCTIONS
 **********************************************************************/

static int connect_to_daemon(void) {
    int sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock < 0) return -1;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);

    if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(sock);
        return -1;
    }
    return sock;
}

static void start_daemon(void) {
    pid_t pid = fork();
    if (pid < 0) perror_exit("fork");
    if (pid == 0) {
        setsid();
        mkdirp(CGROUP_FOLDER);
        move_to_cgroup(CGROUP_PATH);

        daemon_loop();
        exit(0);
    }
    usleep(200000);
}

static int connect_with_retry(void) {
    int sock;
    for (int i = 0; i < MAX_ATTEMPTS; i++) {
        sock = connect_to_daemon();
        if (sock >= 0) return sock;
        if (i == 0) start_daemon();
        usleep(200000);
    }
    fprintf(stderr, "Error: Failed to connect to daemon\n");
    exit(1);
}

static void client_spawn(int argc, char **argv) {
    char buf[4096] = "SPAWN";
    for (int i = 2; i < argc; i++) {
        strncat(buf, " ", sizeof(buf) - strlen(buf) - 1);
        strncat(buf, argv[i], sizeof(buf) - strlen(buf) - 1);
    }

    int sock = connect_with_retry();
    write_all(sock, buf, strlen(buf));

    char line[256];
    ssize_t n = read(sock, line, sizeof(line)-1);
    if (n > 0) {
        line[n] = 0;
        printf("%s", line);
    }
    close(sock);
}

static void client_list(void) {
    int sock = connect_with_retry();
    write_all(sock, "LIST", 4);

    char line[4096];
    while (read(sock, line, sizeof(line)-1) > 0) {
        printf("%s", line);
    }
    close(sock);
}

static void client_kill(int id) {
    int sock = connect_with_retry();
    char buf[64];
    snprintf(buf, sizeof(buf), "KILL %d", id);
    write_all(sock, buf, strlen(buf));

    char line[256];
    ssize_t n = read(sock, line, sizeof(line)-1);
    if (n > 0) printf("%s", line);
    close(sock);
}

static void client_attach(int id) {
    int sock = connect_with_retry();
    char buf[64];
    snprintf(buf, sizeof(buf), "ATTACH %d", id);
    write_all(sock, buf, strlen(buf));

    char line[256];
    ssize_t n = read(sock, line, sizeof(line)-1);
    if (n <= 0 || strncmp(line, "OK ATTACH", 9) != 0) {
        if (n > 0) printf("%s", line);
        close(sock);
        return;
    }

    struct termios orig_term, raw_term;
    tcgetattr(STDIN_FILENO, &orig_term);
    raw_term = orig_term;
    cfmakeraw(&raw_term);
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw_term);

    while (1) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(STDIN_FILENO, &rfds);
        FD_SET(sock, &rfds);
        int maxfd = (sock > STDIN_FILENO) ? sock : STDIN_FILENO;

        int rv = select(maxfd + 1, &rfds, NULL, NULL, NULL);
        if (rv < 0) {
            if (errno == EINTR) continue;
            break;
        }

        if (FD_ISSET(STDIN_FILENO, &rfds)) {
            char buf2[4096];
            ssize_t nr = read(STDIN_FILENO, buf2, sizeof(buf2));
            if (nr <= 0) break;

            for (int i = 0; i < nr; i++) {
                if ((unsigned char)buf2[i] == ATTACH_DETACH_KEY) {
                    if (i > 0) write_all(sock, buf2, i);
                    goto detach;
                }
            }
            write_all(sock, buf2, nr);
        }

        if (FD_ISSET(sock, &rfds)) {
            char buf2[4096];
            ssize_t nr = read(sock, buf2, sizeof(buf2));
            if (nr <= 0) break;
            write_all(STDOUT_FILENO, buf2, nr);
        }
    }

detach:
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig_term);
    close(sock);
}

/**********************************************************************
 *                             MAIN
 **********************************************************************/

static void usage(const char *prog) {
    fprintf(stderr,
        "Usage: %s <command> [args...]\n"
        "Commands:\n"
        "  spawn [CMD...]   Spawn a new session\n"
        "  list             List sessions\n"
        "  attach <ID>      Attach to session\n"
        "  kill <ID>        Kill session\n",
        prog);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        usage(argv[0]);
        return 1;
    }
    if (strcmp(argv[1], "spawn") == 0) {
        client_spawn(argc, argv);
    } else if (strcmp(argv[1], "list") == 0) {
        client_list();
    } else if (strcmp(argv[1], "attach") == 0) {
        if (argc < 3) {
            usage(argv[0]);
            return 1;
        }
        client_attach(atoi(argv[2]));
    } else if (strcmp(argv[1], "kill") == 0) {
        if (argc < 3) {
            usage(argv[0]);
            return 1;
        }
        client_kill(atoi(argv[2]));
    } else {
        usage(argv[0]);
        return 1;
    }

    return 0;
}
