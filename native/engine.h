#ifndef BEND_ARROW_ENGINE_H
#define BEND_ARROW_ENGINE_H

#include <duckdb.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Each open starts a new session. File sessions share a database instance,
 * and anonymous memory sessions are private. Free error messages with
 * duckdb_free. Nonzero status values are errno codes. */
int bd_open(const char *path, uint32_t *out, char **error);
int bd_close(uint32_t id);

/* Borrow without retaining only when the caller controls the token's
 * lifetime and can exclude close. A closed or unknown token returns NULL.
 * Tokens are never reused. */
duckdb_connection bd_connection(uint32_t id);
/* Atomically borrow and return the connection. Pair a successful acquire
 * with bd_connection_release, even if the public token closes meanwhile. */
int bd_connection_acquire(uint32_t id, duckdb_connection *out);
void bd_connection_release(uint32_t id);

#ifdef __cplusplus
}
#endif
#endif
