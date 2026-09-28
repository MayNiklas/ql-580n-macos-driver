#ifndef QL_STATUS_H
#define QL_STATUS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    int width;             /* Loaded media width in millimeters. */
    int length;            /* Zero for continuous media. */
    int type;              /* 0x0a continuous, 0x0b die-cut. */
    int printer_state;     /* 1 idle, 2 printing, 3 error. */
    uint16_t errors;       /* Low byte: error 1; high byte: error 2. */
    uint32_t pages;        /* Optional Printer MIB count, zero if unavailable. */
    char display[128];     /* Optional Printer MIB display text. */
} ql_status_t;

bool ql_status_decode(const unsigned char *data, size_t length, ql_status_t *status);
bool ql_status_read(ql_status_t *status);
const char *ql_status_reason(const ql_status_t *status);

#endif
