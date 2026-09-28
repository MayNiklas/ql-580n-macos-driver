/* Read the QL-580N's status through the active CUPS backend's SNMP side channel.
 * Copyright 2026. SPDX-License-Identifier: MIT
 */
#include "ql_status.h"

#include <cups/sidechannel.h>
#include <ctype.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

#define QL_STATUS_OID ".1.3.6.1.4.1.2435.3.3.9.1.6.1.0"
#define QL_PAGE_COUNT_OID ".1.3.6.1.2.1.43.10.2.1.4.1.1"
#define QL_DISPLAY_OID ".1.3.6.1.2.1.43.16.5.1.2.1.1"

bool ql_status_decode(const unsigned char *data, size_t length, ql_status_t *status) {
    unsigned char decoded[32];
    if (length == 64 && data) {
        for (size_t i = 0; i < 32; ++i) {
            int high = isxdigit(data[2 * i]) ?
                (isdigit(data[2 * i]) ? data[2 * i] - '0' :
                 (toupper(data[2 * i]) - 'A' + 10)) : -1;
            int low = isxdigit(data[2 * i + 1]) ?
                (isdigit(data[2 * i + 1]) ? data[2 * i + 1] - '0' :
                 (toupper(data[2 * i + 1]) - 'A' + 10)) : -1;
            if (high < 0 || low < 0) return false;
            decoded[i] = (unsigned char)((high << 4) | low);
        }
        data = decoded;
        length = sizeof(decoded);
    }
    if (!data || !status || length != 32 || data[0] != 0x80 ||
        data[1] != 0x20 || data[2] != 'B' || data[3] != '4' ||
        data[4] != '3' || data[5] != '0') return false;
    memset(status, 0, sizeof(*status));
    status->errors = (uint16_t)data[8] | ((uint16_t)data[9] << 8);
    status->width = data[10];
    status->type = data[11];
    status->length = data[17];
    status->printer_state = data[18] == 2 ? 3 : (data[19] == 1 ? 2 : 1);
    return true;
}

static bool read_count(const char *data, int length, uint32_t *count) {
    /* CUPS encodes SNMP Counter32 as a decimal string. */
    if (!data || !count || length < 1 || length > 10) return false;
    uint32_t value = 0;
    for (int i = 0; i < length; ++i) {
        if (!isdigit((unsigned char)data[i])) return false;
        unsigned digit = (unsigned)(data[i] - '0');
        if (value > (UINT32_MAX - digit) / 10) return false;
        value = value * 10 + digit;
    }
    *count = value;
    return true;
}

bool ql_status_read(ql_status_t *status) {
    if (!status) return false;
    char data[256];
    int length = sizeof(data);
    cups_sc_status_t result = cupsSideChannelSNMPGet(QL_STATUS_OID, data, &length, 1.0);
    if (result != CUPS_SC_STATUS_OK || length < 0 ||
        !ql_status_decode((const unsigned char *)data, (size_t)length, status)) return false;

    length = sizeof(data);
    if (cupsSideChannelSNMPGet(QL_PAGE_COUNT_OID, data, &length, 1.0) != CUPS_SC_STATUS_OK ||
        !read_count(data, length, &status->pages)) return false;

    length = sizeof(data);
    if (cupsSideChannelSNMPGet(QL_DISPLAY_OID, data, &length, 0.5) == CUPS_SC_STATUS_OK &&
        length > 0 && length <= (int)sizeof(data)) {
        size_t n = (size_t)length < sizeof(status->display) - 1 ?
                   (size_t)length : sizeof(status->display) - 1;
        memcpy(status->display, data, n);
        while (n && (status->display[n - 1] == ' ' || status->display[n - 1] == '\0')) --n;
        status->display[n] = '\0';
    }
    return true;
}

const char *ql_status_reason(const ql_status_t *status) {
    if (!status) return NULL;
    if (status->errors & 0x0004) return "com.brother.ql580n-cutter-jam";
    if (status->errors & 0x1000) return "cover-open";
    if ((status->errors & 0x0003) || status->type == 0) return "media-empty";
    if (status->errors & 0x4000) return "media-jam";
    if (status->errors || status->printer_state == 3) return "other";
    return NULL;
}
