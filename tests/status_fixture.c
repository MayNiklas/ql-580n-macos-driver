/* Mock a CUPS network backend's SNMP side channel for filter integration tests. */
#include <cups/sidechannel.h>
#include <stdio.h>
#include <string.h>

static const char *status_oid = ".1.3.6.1.4.1.2435.3.3.9.1.6.1.0";
static const char *count_oid = ".1.3.6.1.2.1.43.10.2.1.4.1.1";
static const char *display_oid = ".1.3.6.1.2.1.43.16.5.1.2.1.1";

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    const char *mode = argv[1];
    int count_queries = 0;
    int status_queries = 0;
    for (;;) {
        cups_sc_command_t command;
        cups_sc_status_t status;
        char query[256];
        int length = sizeof query;
        if (cupsSideChannelRead(&command, &status, query, &length, 5.0)) break;
        if (command != CUPS_SC_CMD_SNMP_GET || length < 1 ||
            !memchr(query, 0, (size_t)length)) return 3;
        char reply[256];
        int reply_length = 0;
        cups_sc_status_t reply_status = CUPS_SC_STATUS_OK;
        if (strcmp(query, status_oid) == 0) {
            ++status_queries;
            if (strcmp(mode, "unavailable") == 0) reply_status = CUPS_SC_STATUS_NO_RESPONSE;
            else {
                unsigned char bytes[32] = {0x80, 0x20, 'B', '4', '3', '0'};
                bytes[10] = 62;
                bytes[11] = 0x0a;
                if (strcmp(mode, "diecut") == 0) {
                    bytes[11] = 0x0b;
                    bytes[17] = 100;
                } else if (strcmp(mode, "narrow") == 0) bytes[10] = 29;
                else if (strcmp(mode, "roll-change") == 0 && status_queries >= 2) bytes[10] = 29;
                else if (strcmp(mode, "empty") == 0) bytes[8] = 1;
                else if (strcmp(mode, "cover") == 0) bytes[9] = 0x10;
                else if (strcmp(mode, "jam") == 0 ||
                         (strcmp(mode, "post-jam") == 0 && status_queries >= 3)) bytes[8] = 4;
                else if (strcmp(mode, "bad-packet") == 0) bytes[0] = 0;
                for (int i = 0; i < 32; ++i)
                    snprintf(reply + i * 2, sizeof reply - (size_t)i * 2, "%02X", bytes[i]);
                reply_length = 64;
            }
        } else if (strcmp(query, count_oid) == 0) {
            ++count_queries;
            const char *number = count_queries >= 3 && strcmp(mode, "stalled") != 0 ? "101" : "100";
            if (strcmp(mode, "four-digits") == 0)
                number = count_queries >= 3 ? "1001" : "1000";
            else if (strcmp(mode, "excess") == 0 && count_queries >= 3) number = "103";
            else if (strcmp(mode, "bad-count") == 0) number = "12x";
            else if (strcmp(mode, "overflow-count") == 0) number = "4294967296";
            memcpy(reply, number, strlen(number));
            reply_length = (int)strlen(number);
        } else if (strcmp(query, display_oid) == 0) {
            const char *display = "Ready";
            memcpy(reply, display, strlen(display));
            reply_length = (int)strlen(display);
        } else reply_status = CUPS_SC_STATUS_NOT_IMPLEMENTED;

        char wire[512];
        int oid_length = (int)strlen(query) + 1;
        memcpy(wire, query, (size_t)oid_length);
        if (reply_length) memcpy(wire + oid_length, reply, (size_t)reply_length);
        if (cupsSideChannelWrite(CUPS_SC_CMD_SNMP_GET, reply_status, wire,
                                 oid_length + reply_length, 5.0)) return 4;
    }
    return 0;
}
