/* usbstream.c - see usbstream.h.
 *
 * Lineage: probe3.c (sha256 51bc7c56..., ~/Developer/AVM-dist/probes),
 * the tool that first put the ATR2100x-USB into the guest and let JAWS
 * speak through its headphone jack. The attach sequence, the pump loop
 * and the release order below are probe3's, unchanged in substance.
 * What changed: globals became a per-stream struct, the device is found
 * by bus address (two identical microphones are two devices), and every
 * outcome is reported instead of printed. list / claimtest / predetach
 * and the Q5 wire sniffer did not come along; they were probe instruments.
 *
 * Threading notes are in the header. One more here: usbredirhost may call
 * flush_cb from the libusb event thread while the pump thread is inside
 * usbredirhost_read_guest_data. The library serializes its own state with
 * the lock callbacks we hand it, so both callers are safe. flush_cb only
 * writes when the stream still has a host and a live socket.
 */
#include "usbstream.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <libusb.h>
#include <usbredirhost.h>

/* ---- Process-wide runtime ------------------------------------------------ */

static libusb_context *g_ctx = NULL;
static pthread_t g_event_thread;
static volatile int g_event_run = 0;
static int g_started = 0;
static pthread_mutex_t g_runtime_lock = PTHREAD_MUTEX_INITIALIZER;

static void fill(char *buf, size_t len, const char *text)
{
    if (buf == NULL || len == 0)
        return;
    snprintf(buf, len, "%s", text != NULL ? text : "");
}

static void *event_thread_main(void *arg)
{
    (void)arg;
    while (g_event_run) {
        int r = libusb_handle_events(g_ctx);
        if (r != 0 && r != LIBUSB_ERROR_INTERRUPTED)
            break;
    }
    return NULL;
}

int avm_usb_runtime_start(char *step, size_t step_len,
                          char *detail, size_t detail_len)
{
    int rc = 0;
    pthread_mutex_lock(&g_runtime_lock);
    if (g_started) {
        pthread_mutex_unlock(&g_runtime_lock);
        return 0;
    }
    rc = libusb_init(&g_ctx);
    if (rc != 0) {
        fill(step, step_len, "libusb init");
        fill(detail, detail_len, libusb_strerror(rc));
        g_ctx = NULL;
        pthread_mutex_unlock(&g_runtime_lock);
        return 1;
    }
    g_event_run = 1;
    if (pthread_create(&g_event_thread, NULL, event_thread_main, NULL) != 0) {
        fill(step, step_len, "event thread");
        fill(detail, detail_len, "could not start the libusb event thread");
        g_event_run = 0;
        libusb_exit(g_ctx);
        g_ctx = NULL;
        pthread_mutex_unlock(&g_runtime_lock);
        return 1;
    }
    g_started = 1;
    pthread_mutex_unlock(&g_runtime_lock);
    return 0;
}

void avm_usb_runtime_stop(void)
{
    pthread_mutex_lock(&g_runtime_lock);
    if (g_started == 0) {
        pthread_mutex_unlock(&g_runtime_lock);
        return;
    }
    g_event_run = 0;
    libusb_interrupt_event_handler(g_ctx);
    pthread_join(g_event_thread, NULL);
    libusb_exit(g_ctx);
    g_ctx = NULL;
    g_started = 0;
    pthread_mutex_unlock(&g_runtime_lock);
}

/* ---- Stream -------------------------------------------------------------- */

struct avm_usb_stream {
    int fd;
    struct usbredirhost *host;
    char name[128];
    char speed[64];
    char socket_path[256];
    volatile int quit;
    volatile int socket_dead;
    avm_usb_event_fn callback;
    void *context;
};

static void emit(avm_usb_stream *s, avm_usb_event event,
                 const char *step, const char *detail)
{
    if (s->callback != NULL)
        s->callback(s->context, s, event, step, detail);
}

static const char *speed_name(int speed)
{
    switch (speed) {
    case LIBUSB_SPEED_LOW:   return "low 1.5 Mb/s";
    case LIBUSB_SPEED_FULL:  return "full 12 Mb/s";
    case LIBUSB_SPEED_HIGH:  return "high 480 Mb/s";
    case LIBUSB_SPEED_SUPER: return "super 5 Gb/s";
    default:                 return "unknown";
    }
}

/* usbredirhost callbacks. priv is the stream. */

static void log_cb(void *priv, int level, const char *msg)
{
    static const char *names[] = { "none", "error", "warning", "info", "debug", "data" };
    avm_usb_stream *s = (avm_usb_stream *)priv;
    const char *n = (level >= 0 && level <= 5) ? names[level] : "?";
    emit(s, AVM_USB_EVENT_LOG, n, msg);
}

static int read_cb(void *priv, uint8_t *data, int count)
{
    avm_usb_stream *s = (avm_usb_stream *)priv;
    ssize_t n = recv(s->fd, data, count, 0);
    if (n > 0)
        return (int)n;
    if (n == 0) {
        s->socket_dead = 1;
        return -1;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK)
        return 0;
    s->socket_dead = 1;
    return -1;
}

static int write_cb(void *priv, uint8_t *data, int count)
{
    avm_usb_stream *s = (avm_usb_stream *)priv;
    ssize_t n = send(s->fd, data, count, 0);
    if (n >= 0)
        return (int)n;
    if (errno == EAGAIN || errno == EWOULDBLOCK)
        return 0;
    s->socket_dead = 1;
    return -1;
}

static void flush_cb(void *priv)
{
    avm_usb_stream *s = (avm_usb_stream *)priv;
    if (s->host != NULL && s->socket_dead == 0)
        usbredirhost_write_guest_data(s->host);
}

static void *lock_alloc(void)
{
    pthread_mutex_t *m = malloc(sizeof(*m));
    if (m != NULL)
        pthread_mutex_init(m, NULL);
    return m;
}
static void lock_lock(void *l)   { pthread_mutex_lock((pthread_mutex_t *)l); }
static void lock_unlock(void *l) { pthread_mutex_unlock((pthread_mutex_t *)l); }
static void lock_free(void *l)   { pthread_mutex_destroy((pthread_mutex_t *)l); free(l); }

static void product_string(libusb_device_handle *h,
                           const struct libusb_device_descriptor *d,
                           char *buf, size_t len)
{
    buf[0] = 0;
    if (h != NULL && d->iProduct != 0) {
        int r = libusb_get_string_descriptor_ascii(h, d->iProduct,
                                                   (unsigned char *)buf, (int)len);
        if (r < 0)
            buf[0] = 0;
    }
    if (buf[0] == 0)
        snprintf(buf, len, "(no product string)");
}

/* Find the device at bus/address, verify vendor:product, open it.
 * On failure fills step/detail and returns NULL. */
static libusb_device_handle *open_at(uint16_t vid, uint16_t pid,
                                     uint8_t bus, uint8_t addr,
                                     char *name, size_t name_len,
                                     char *speed, size_t speed_len,
                                     char *step, size_t step_len,
                                     char *detail, size_t detail_len)
{
    libusb_device **devs = NULL;
    libusb_device_handle *h = NULL;
    ssize_t n, i;
    int found = 0;
    char text[256];

    n = libusb_get_device_list(g_ctx, &devs);
    if (n < 0) {
        fill(step, step_len, "list");
        fill(detail, detail_len, libusb_strerror((int)n));
        return NULL;
    }
    for (i = 0; i < n; i++) {
        struct libusb_device_descriptor d;
        int r;
        if (libusb_get_bus_number(devs[i]) != bus ||
            libusb_get_device_address(devs[i]) != addr)
            continue;
        found = 1;
        if (libusb_get_device_descriptor(devs[i], &d) != 0) {
            fill(step, step_len, "identify");
            fill(detail, detail_len, "could not read the device descriptor");
            break;
        }
        if (d.idVendor != vid || d.idProduct != pid) {
            snprintf(text, sizeof(text),
                     "bus %u address %u now holds %04x:%04x, expected %04x:%04x "
                     "(the device was replugged or another took its place)",
                     bus, addr, d.idVendor, d.idProduct, vid, pid);
            fill(step, step_len, "identify");
            fill(detail, detail_len, text);
            break;
        }
        r = libusb_open(devs[i], &h);
        if (r != 0) {
            snprintf(text, sizeof(text), "%s (%04x:%04x at bus %u address %u)",
                     libusb_strerror(r), vid, pid, bus, addr);
            fill(step, step_len, "open");
            fill(detail, detail_len, text);
            h = NULL;
            break;
        }
        product_string(h, &d, name, name_len);
        snprintf(speed, speed_len, "%s", speed_name(libusb_get_device_speed(devs[i])));
        break;
    }
    libusb_free_device_list(devs, 1);
    if (found == 0) {
        snprintf(text, sizeof(text), "no device at bus %u address %u (was it unplugged?)",
                 bus, addr);
        fill(step, step_len, "find");
        fill(detail, detail_len, text);
    }
    return h;
}

static int connect_unix(const char *path, char *step, size_t step_len,
                        char *detail, size_t detail_len)
{
    struct sockaddr_un sa;
    int fd, one = 1, fl;
    char text[512];

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        fill(step, step_len, "socket");
        fill(detail, detail_len, strerror(errno));
        return -1;
    }
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    memset(&sa, 0, sizeof(sa));
    sa.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(sa.sun_path)) {
        fill(step, step_len, "socket");
        fill(detail, detail_len, "stream socket path is too long for a unix socket");
        close(fd);
        return -1;
    }
    strncpy(sa.sun_path, path, sizeof(sa.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
        snprintf(text, sizeof(text), "%s: %s (is QEMU listening there?)",
                 path, strerror(errno));
        fill(step, step_len, "connect");
        fill(detail, detail_len, text);
        close(fd);
        return -1;
    }
    fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    return fd;
}

avm_usb_stream *avm_usb_stream_attach(uint16_t vendor_id,
                                      uint16_t product_id,
                                      uint8_t bus_number,
                                      uint8_t device_address,
                                      const char *socket_path,
                                      int verbose,
                                      avm_usb_event_fn callback,
                                      void *context,
                                      char *step, size_t step_len,
                                      char *detail, size_t detail_len)
{
    avm_usb_stream *s;
    libusb_device_handle *h;
    struct usbredirhost *host;
    char text[256];

    if (g_started == 0) {
        fill(step, step_len, "runtime");
        fill(detail, detail_len, "USB runtime not started");
        return NULL;
    }
    if (socket_path == NULL || socket_path[0] == 0) {
        fill(step, step_len, "socket");
        fill(detail, detail_len, "no stream socket path given");
        return NULL;
    }
    s = calloc(1, sizeof(*s));
    if (s == NULL) {
        fill(step, step_len, "allocate");
        fill(detail, detail_len, "out of memory");
        return NULL;
    }
    s->fd = -1;
    s->callback = callback;
    s->context = context;
    snprintf(s->socket_path, sizeof(s->socket_path), "%s", socket_path);

    h = open_at(vendor_id, product_id, bus_number, device_address,
                s->name, sizeof(s->name), s->speed, sizeof(s->speed),
                step, step_len, detail, detail_len);
    if (h == NULL) {
        free(s);
        return NULL;
    }

    s->fd = connect_unix(socket_path, step, step_len, detail, detail_len);
    if (s->fd < 0) {
        libusb_close(h);
        free(s);
        return NULL;
    }

    /* Takes ownership of h: claims every interface, sends hello + device
     * info to the guest, and closes h itself if it fails. */
    host = usbredirhost_open_full(g_ctx, h, log_cb, read_cb, write_cb, flush_cb,
                                  lock_alloc, lock_lock, lock_unlock, lock_free,
                                  s, "AVMUSBHelper",
                                  verbose ? usbredirparser_debug : usbredirparser_info,
                                  0);
    if (host == NULL) {
        snprintf(text, sizeof(text),
                 "usbredirhost could not claim %s (the library closed the device)",
                 s->name);
        fill(step, step_len, "claim");
        fill(detail, detail_len, text);
        close(s->fd);
        free(s);
        return NULL;
    }
    s->host = host;
    return s;
}

void avm_usb_stream_run(avm_usb_stream *s)
{
    avm_usb_event ending = AVM_USB_EVENT_RELEASED; /* means: none */
    const char *end_step = NULL;
    char end_detail[256];

    end_detail[0] = 0;
    if (s == NULL || s->host == NULL)
        return;

    emit(s, AVM_USB_EVENT_ATTACHED, "attach", s->speed);

    while (s->quit == 0 && s->socket_dead == 0) {
        struct pollfd p;
        int r;
        p.fd = s->fd;
        p.events = POLLIN;
        if (usbredirhost_has_data_to_write(s->host) > 0)
            p.events |= POLLOUT;
        p.revents = 0;
        r = poll(&p, 1, 250);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            ending = AVM_USB_EVENT_ERROR;
            end_step = "poll";
            snprintf(end_detail, sizeof(end_detail), "%s", strerror(errno));
            break;
        }
        if (p.revents & (POLLIN | POLLHUP | POLLERR)) {
            int rr = usbredirhost_read_guest_data(s->host);
            if (rr == usbredirhost_read_device_lost) {
                ending = AVM_USB_EVENT_DEVICE_LOST;
                end_step = "stream";
                snprintf(end_detail, sizeof(end_detail),
                         "%s was unplugged", s->name);
                break;
            }
            if (rr == usbredirhost_read_device_rejected) {
                ending = AVM_USB_EVENT_REJECTED;
                end_step = "stream";
                snprintf(end_detail, sizeof(end_detail),
                         "the guest rejected %s", s->name);
                break;
            }
            if (rr == usbredirhost_read_parse_error)
                emit(s, AVM_USB_EVENT_LOG, "warning", "parse error from guest, packet skipped");
        }
        if (s->socket_dead == 0 && usbredirhost_has_data_to_write(s->host) > 0)
            usbredirhost_write_guest_data(s->host);
    }

    if (ending == AVM_USB_EVENT_RELEASED && s->socket_dead) {
        ending = AVM_USB_EVENT_SOCKET_CLOSED;
        end_step = "stream";
        snprintf(end_detail, sizeof(end_detail),
                 "QEMU closed the stream socket for %s", s->name);
    }
    if (ending != AVM_USB_EVENT_RELEASED)
        emit(s, ending, end_step, end_detail);

    /* Release: same order as probe3. close() releases every interface,
     * reattaches the kernel drivers and closes the handle. */
    usbredirhost_close(s->host);
    s->host = NULL;
    close(s->fd);
    s->fd = -1;
    emit(s, AVM_USB_EVENT_RELEASED, "release", s->name);
}

void avm_usb_stream_stop(avm_usb_stream *s)
{
    if (s != NULL)
        s->quit = 1;
}

void avm_usb_stream_free(avm_usb_stream *s)
{
    if (s == NULL)
        return;
    if (s->host != NULL) {
        /* run was never called. Release without reporting a stream end. */
        usbredirhost_close(s->host);
        s->host = NULL;
        emit(s, AVM_USB_EVENT_RELEASED, "release", s->name);
    }
    if (s->fd >= 0) {
        close(s->fd);
        s->fd = -1;
    }
    free(s);
}

const char *avm_usb_stream_name(const avm_usb_stream *s)
{
    return s != NULL ? s->name : "";
}
