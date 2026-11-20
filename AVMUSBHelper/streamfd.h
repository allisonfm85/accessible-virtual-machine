/* streamfd.h - checks the stream socket AVM hands the root USB helper.
 *
 * Contract 0.3.0-fd: AVM connects to QEMU's usbredir socket as the user
 * and sends the connected socket over XPC. The helper never connects by
 * path. Before streaming a device over the socket, the helper makes sure
 * it is what AVM says: a connected unix stream socket. Then it sets the
 * options the pump relies on (SO_NOSIGPIPE, O_NONBLOCK).
 *
 * Kept apart from usbstream.c, which needs libusb, so the unit tests can
 * build this file on its own.
 */
#ifndef AVM_STREAMFD_H
#define AVM_STREAMFD_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Returns 0 when fd is a connected unix stream socket and is now set up
 * for the pump. Otherwise returns -1 with step/detail filled (either may
 * be NULL to skip). Never closes fd. */
int avm_usb_prepare_stream_fd(int fd, char *step, size_t step_len,
                              char *detail, size_t detail_len);

#ifdef __cplusplus
}
#endif

#endif /* AVM_STREAMFD_H */
