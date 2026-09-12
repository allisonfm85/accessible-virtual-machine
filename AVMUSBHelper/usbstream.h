/* usbstream.h - one USB device streamed to QEMU via usbredirhost.
 *
 * This is probe3's proven attach / pump / release path, reshaped for the
 * root helper: a per-device stream instead of globals, one shared libusb
 * context and one event thread per process, and every outcome reported
 * through a callback that names the device, the step and the detail.
 *
 * The helper does four things: claim, stream, release, report. This file
 * is claim, stream and release. Report is the callback. Enumeration is
 * NOT here: AVM lists devices unprivileged and hands the helper a bus
 * address plus vendor:product to check it against.
 *
 * Threads:
 *   - avm_usb_runtime_start creates the libusb context and ONE event
 *     thread that serves every stream (libusb_handle_events).
 *   - avm_usb_stream_run is a blocking pump. The helper runs it on that
 *     device's own serial queue. It returns only when the stream ended
 *     (stop requested, socket closed, device lost or rejected, error)
 *     and the device has been released back to macOS.
 *   - The event callback can fire from the pump's thread OR from the
 *     libusb event thread (usbredirhost's flush path). Do not block in
 *     it; hand the event to your own queue.
 *
 * Strings passed to the callback are valid only for the duration of the
 * call. Copy them.
 */
#ifndef AVM_USBSTREAM_H
#define AVM_USBSTREAM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct avm_usb_stream avm_usb_stream;

typedef enum {
    /* A usbredir library log line. step is the level name, detail the line. */
    AVM_USB_EVENT_LOG = 0,
    /* Claimed and handed to the guest. detail: speed as reported to QEMU. */
    AVM_USB_EVENT_ATTACHED = 1,
    /* Unplugged while attached. The library already released it. */
    AVM_USB_EVENT_DEVICE_LOST = 2,
    /* The guest refused the device. */
    AVM_USB_EVENT_REJECTED = 3,
    /* QEMU closed the stream socket (VM stopped, device removed by QMP). */
    AVM_USB_EVENT_SOCKET_CLOSED = 4,
    /* Something failed after attach. step names it, detail explains. */
    AVM_USB_EVENT_ERROR = 5,
    /* The pump has finished and the device is back with macOS. Always the
     * last event for a stream. */
    AVM_USB_EVENT_RELEASED = 6
} avm_usb_event;

typedef void (*avm_usb_event_fn)(void *context,
                                 avm_usb_stream *stream,
                                 avm_usb_event event,
                                 const char *step,
                                 const char *detail);

/* Process-wide libusb context and event thread. Call once before the
 * first attach; call stop once after the last stream has been freed.
 * Both are idempotent. On failure returns nonzero and fills step/detail
 * (either may be NULL to skip). */
int avm_usb_runtime_start(char *step, size_t step_len,
                          char *detail, size_t detail_len);
void avm_usb_runtime_stop(void);

/* Open the device at bus/address, check it is vendor:product, connect to
 * the unix socket QEMU listens on, and hand the device to usbredirhost
 * (which claims every interface and sends the hello + device_connect).
 * Returns the stream, or NULL with step/detail filled. On NULL nothing
 * is left claimed. verbose nonzero selects usbredir debug logging.
 * The device is attached on return; run the pump next. */
avm_usb_stream *avm_usb_stream_attach(uint16_t vendor_id,
                                      uint16_t product_id,
                                      uint8_t bus_number,
                                      uint8_t device_address,
                                      const char *socket_path,
                                      int verbose,
                                      avm_usb_event_fn callback,
                                      void *context,
                                      char *step, size_t step_len,
                                      char *detail, size_t detail_len);

/* Blocking pump. Emits ATTACHED first, then whichever of DEVICE_LOST,
 * REJECTED, SOCKET_CLOSED or ERROR ended it (none if stop was requested),
 * releases the device, and emits RELEASED before returning. */
void avm_usb_stream_run(avm_usb_stream *stream);

/* Ask a running pump to finish. Safe from any thread. Returns at once;
 * the pump notices within one poll interval (250 ms). */
void avm_usb_stream_stop(avm_usb_stream *stream);

/* Free the stream. Only after run has returned (or if run was never
 * called; then this releases the device too). */
void avm_usb_stream_free(avm_usb_stream *stream);

/* The device's product string, or "(no product string)". Valid for the
 * life of the stream. */
const char *avm_usb_stream_name(const avm_usb_stream *stream);

#ifdef __cplusplus
}
#endif

#endif /* AVM_USBSTREAM_H */
