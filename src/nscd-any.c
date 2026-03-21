#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

/*
 * nscd-any: A minimal nscd responder for musl libc.
 *
 * musl's getpwnam() falls back to querying /var/run/nscd/socket when a
 * user isn't found in /etc/passwd. This daemon responds to every
 * GETPWBYNAME query with a valid passwd entry, mapping any username to
 * a single system user. This allows OpenSSH to accept connections for
 * usernames that don't exist in /etc/passwd.
 *
 * Protocol: musl nscd binary protocol (not the glibc nscd protocol).
 * See musl source: src/passwd/nscd.h, src/passwd/nscd_query.c
 */

#define SOCKET_PATH "/var/run/nscd/socket"

/* musl nscd request types */
#define GETPWBYNAME 0
#define GETPWBYUID  1
#define GETGRBYNAME 2
#define GETGRBYUID  3
#define GETINITGR   4

/* Fallback user — must exist in /etc/passwd for uid/gid */
#define FALLBACK_UID   1000
#define FALLBACK_GID   1000
#define FALLBACK_HOME  "/home/whoah-testimage-user"
#define FALLBACK_SHELL "/bin/sh"
#define FALLBACK_GECOS ""
#define FALLBACK_PASSWD "x"

struct nscd_request {
    uint32_t version;
    uint32_t type;
    uint32_t keylen;
};

static void send_not_found(int fd)
{
    int32_t resp[9] = {0};
    resp[0] = 2;  /* version */
    resp[1] = 0;  /* not found */
    write(fd, resp, sizeof(resp));
}

static void send_passwd(int fd, const char *name)
{
    size_t name_len = strlen(name) + 1;
    size_t passwd_len = strlen(FALLBACK_PASSWD) + 1;
    size_t gecos_len = strlen(FALLBACK_GECOS) + 1;
    size_t dir_len = strlen(FALLBACK_HOME) + 1;
    size_t shell_len = strlen(FALLBACK_SHELL) + 1;

    int32_t resp[9];
    resp[0] = 2;                    /* version */
    resp[1] = 1;                    /* found */
    resp[2] = (int32_t)name_len;    /* pw_name len */
    resp[3] = (int32_t)passwd_len;  /* pw_passwd len */
    resp[4] = FALLBACK_UID;         /* pw_uid */
    resp[5] = FALLBACK_GID;         /* pw_gid */
    resp[6] = (int32_t)gecos_len;   /* pw_gecos len */
    resp[7] = (int32_t)dir_len;     /* pw_dir len */
    resp[8] = (int32_t)shell_len;   /* pw_shell len */

    /* Send header */
    if (write(fd, resp, sizeof(resp)) < 0)
        return;

    /* Send strings: name, passwd, gecos, dir, shell */
    write(fd, name, name_len);
    write(fd, FALLBACK_PASSWD, passwd_len);
    write(fd, FALLBACK_GECOS, gecos_len);
    write(fd, FALLBACK_HOME, dir_len);
    write(fd, FALLBACK_SHELL, shell_len);
}

static int read_full(int fd, void *buf, size_t len)
{
    size_t pos = 0;
    while (pos < len) {
        ssize_t n = read(fd, (char *)buf + pos, len - pos);
        if (n <= 0)
            return -1;
        pos += n;
    }
    return 0;
}

int main(void)
{
    signal(SIGPIPE, SIG_IGN);

    /* Clean up stale socket */
    unlink(SOCKET_PATH);
    mkdir("/var/run/nscd", 0755);

    int srv = socket(AF_UNIX, SOCK_STREAM, 0);
    if (srv < 0) {
        perror("socket");
        return 1;
    }

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);

    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return 1;
    }

    chmod(SOCKET_PATH, 0666);

    if (listen(srv, 8) < 0) {
        perror("listen");
        return 1;
    }

    for (;;) {
        int fd = accept(srv, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR)
                continue;
            perror("accept");
            continue;
        }

        struct nscd_request req;
        if (read_full(fd, &req, sizeof(req)) < 0)
            goto next;

        if (req.version != 2 || req.keylen == 0 || req.keylen > 256)
            goto next;

        char name[257];
        if (read_full(fd, name, req.keylen) < 0)
            goto next;
        name[req.keylen - 1] = '\0';

        if (req.type == GETPWBYNAME) {
            send_passwd(fd, name);
        } else {
            send_not_found(fd);
        }

    next:
        close(fd);
    }

    return 0;
}
