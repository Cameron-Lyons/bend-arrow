#ifndef BD_ARROW_H
#define BD_ARROW_H

#include <stdint.h>
#include "duckdb.h"

/* Apache Arrow C Data and C Stream interfaces, Apache License 2.0.
 * https://arrow.apache.org/docs/format/CDataInterface.html */
#ifndef ARROW_C_DATA_INTERFACE
#define ARROW_C_DATA_INTERFACE
#define ARROW_FLAG_DICTIONARY_ORDERED 1
#define ARROW_FLAG_NULLABLE 2
#define ARROW_FLAG_MAP_KEYS_SORTED 4

struct ArrowSchema {
    const char *format;
    const char *name;
    const char *metadata;
    int64_t flags;
    int64_t n_children;
    struct ArrowSchema **children;
    struct ArrowSchema *dictionary;
    void (*release)(struct ArrowSchema *);
    void *private_data;
};

struct ArrowArray {
    int64_t length;
    int64_t null_count;
    int64_t offset;
    int64_t n_buffers;
    int64_t n_children;
    const void **buffers;
    struct ArrowArray **children;
    struct ArrowArray *dictionary;
    void (*release)(struct ArrowArray *);
    void *private_data;
};
#endif

#ifndef ARROW_C_STREAM_INTERFACE
#define ARROW_C_STREAM_INTERFACE
struct ArrowArrayStream {
    int (*get_schema)(struct ArrowArrayStream *, struct ArrowSchema *out);
    int (*get_next)(struct ArrowArrayStream *, struct ArrowArray *out);
    const char *(*get_last_error)(struct ArrowArrayStream *);
    void (*release)(struct ArrowArrayStream *);
    void *private_data;
};
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Functions return 0 on success or an errno value on failure. If error is
 * supplied, free(*error) after a failure. A query materializes the SQL result
 * and converts each chunk on demand. Keep the connection open until releasing
 * its stream. Each returned schema and batch has its own release callback. */
int bd_arrow_query(duckdb_connection con, const char *sql,
                   struct ArrowArrayStream *out, char **error);

/* Attach a retained connection to a fresh bd_arrow_query stream. The stream
 * calls release_connection(id) after destroying its DuckDB resources. */
void bd_arrow_on_release(struct ArrowArrayStream *stream,
                         void (*release_connection)(uint32_t), uint32_t id);

/* Create a new temporary table from the remaining input batches. The caller
 * retains ownership of the stream. Input must follow the Arrow C Stream ABI
 * and describe a record batch (a struct of named fields). A LIST or LARGE_LIST
 * column with dictionary-encoded elements may return EINVAL if DuckDB would
 * read the wrong null bitmap window. Decode its dictionary before importing. */
int bd_arrow_import(duckdb_connection con, const char *table_name,
                    struct ArrowArrayStream *input, char **error);

#ifdef __cplusplus
}
#endif
#endif
