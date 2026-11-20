/* streamfd.c - see streamfd.h.
 *
 * No libusb here, so the unit tests can build and run it on any Mac.
 */
#include "streamfd.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>

static void fill(char *buf, size_t len, const char *text)
{
    if (buf == NULL || len == 0)
        return;
    snprintf(buf, len, "%s", text != NULL ? text : "");
}

int avm_usb_prepare_stream_fd(int fd, char *step, size_t step_len,
                              char *detail, size_t detail_len)
{
    struct stat st;
    struct sockaddr_storage peer;
    socklen_t peer_len = sizeof(peer);
    int type = 0, one = 1, fl;
    socklen_t type_len = sizeof(type);
    char text[256];

    if (fd < 0) {
        fill(step, step_len, "socket");
        fill(detail, detail_len, "no stream socket was received");
        return -1;
    }
    if (fstat(fd, &st) != 0 || !S_ISSOCK(st.st_mode)) {
        fill(step, step_len, "socket");
        fill(detail, detail_len, "the stream handed to the helper is not a socket");
        return -1;
    }
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &type_len) != 0 || type != SOCK_STREAM) {
        fill(step, step_len, "socket");
        fill(detail, detail_len, "the stream handed to the helper is not a stream socket");
        return -1;
    }
    memset(&peer, 0, sizeof(peer));
    if (getpeername(fd, (struct sockaddr *)&peer, &peer_len) != 0) {
        snprintf(text, sizeof(text), "the stream socket is not connected (%s)", strerror(errno));
        fill(step, step_len, "socket");
        fill(detail, detail_len, text);
        return -1;
    }
    if (peer.ss_family != AF_UNIX) {
        fill(step, step_len, "socket");
        fill(detail, detail_len, "the stream socket is not a unix socket");
        return -1;
    }
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    fl = fcntl(fd, F_GETFL, 0);
    if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) != 0) {
        snprintf(text, sizeof(text), "could not make the stream socket non-blocking (%s)", strerror(errno));
        fill(step, step_len, "socket");
        fill(detail, detail_len, text);
        return -1;
    }
    return 0;
}
