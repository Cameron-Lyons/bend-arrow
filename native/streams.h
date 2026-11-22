#ifndef BEND_ARROW_STREAMS_H
#define BEND_ARROW_STREAMS_H

#include "arrow.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Move a live Arrow stream into a token suitable for Bend's Arrow.StreamId.
 * On success, input->release is NULL. On error, the caller still owns input.
 * These two ownership transfers are thread-safe. Errors are errno values. */
int bd_stream_put(struct ArrowArrayStream *input, uint32_t *out_id);

/* Move the stream out of a token, invalidating all copies of the token.
 * out points to uninitialized or released storage. Release a successful
 * result exactly once, even if no batches were read. */
int bd_stream_take(uint32_t id, struct ArrowArrayStream *out);

#ifdef __cplusplus
}
#endif
#endif
