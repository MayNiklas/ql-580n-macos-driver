/* Generate a deterministic CUPS raster stream for the filter tests. */
#include <cups/raster.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "--inspect") == 0) {
        int input = open(argv[2], O_RDONLY);
        if (input < 0) return 2;
        cups_raster_t *reader = cupsRasterOpen(input, CUPS_RASTER_READ);
        if (!reader) return 2;
        cups_page_header2_t header;
        while (cupsRasterReadHeader2(reader, &header)) {
            printf("%u %u %u %s %u %u\n", header.NumCopies, header.cupsWidth,
                   header.cupsHeight, header.cupsPageSizeName,
                   header.HWResolution[0], header.HWResolution[1]);
            unsigned char *pixels = malloc(header.cupsBytesPerLine);
            if (!pixels) return 2;
            for (unsigned y = 0; y < header.cupsHeight; y++)
                if (cupsRasterReadPixels(reader, pixels, header.cupsBytesPerLine) != header.cupsBytesPerLine)
                    return 2;
            free(pixels);
        }
        cupsRasterClose(reader);
        close(input);
        return 0;
    }
    if (argc != 11 && argc != 12 && argc != 13) {
        fprintf(stderr, "usage: raster_fixture OUT WIDTH HEIGHT PAGE_W_PT PAGE_H_PT NAME PAGES X Y gray8|cmyk32 [NUM_COPIES] [Y_DPI]\n");
        return 2;
    }
    const unsigned width = (unsigned)strtoul(argv[2], NULL, 10);
    const unsigned height = (unsigned)strtoul(argv[3], NULL, 10);
    const double page_width = strtod(argv[4], NULL);
    const double page_height = strtod(argv[5], NULL);
    const unsigned pages = (unsigned)strtoul(argv[7], NULL, 10);
    const unsigned num_copies = argc >= 12 ? (unsigned)strtoul(argv[11], NULL, 10) : 1;
    const unsigned ydpi = argc == 13 ? (unsigned)strtoul(argv[12], NULL, 10) : 300;
    const int mark_x = atoi(argv[8]);
    const int mark_y = atoi(argv[9]);
    const int cmyk = strcmp(argv[10], "cmyk32") == 0;
    if (!cmyk && strcmp(argv[10], "gray8") != 0) return 2;
    if (!width || !height || !pages || width > 800 || height > 24000 || (ydpi != 300 && ydpi != 600)) return 2;
    const unsigned bytes_per_pixel = cmyk ? 4 : 1;
    unsigned char *line = malloc((size_t)width * bytes_per_pixel);
    if (!line) return 2;
    int fd = open(argv[1], O_CREAT | O_TRUNC | O_WRONLY, 0600);
    if (fd < 0) { perror("open"); free(line); return 2; }
    cups_raster_t *raster = cupsRasterOpen(fd, CUPS_RASTER_WRITE);
    if (!raster) { free(line); close(fd); return 2; }

    for (unsigned page = 0; page < pages; page++) {
        cups_page_header2_t h;
        memset(&h, 0, sizeof h);
        h.HWResolution[0] = 300;
        h.HWResolution[1] = ydpi;
        h.cupsWidth = width;
        h.cupsHeight = height;
        h.cupsBitsPerColor = 8;
        h.cupsBitsPerPixel = 8 * bytes_per_pixel;
        h.cupsBytesPerLine = width * bytes_per_pixel;
        h.cupsColorSpace = cmyk ? CUPS_CSPACE_CMYK : CUPS_CSPACE_W;
        h.cupsColorOrder = CUPS_ORDER_CHUNKED;
        h.NumCopies = num_copies;
        h.cupsPageSize[0] = (float)page_width;
        h.cupsPageSize[1] = (float)page_height;
        h.PageSize[0] = (unsigned)page_width;
        h.PageSize[1] = (unsigned)page_height;
        snprintf(h.cupsPageSizeName, sizeof h.cupsPageSizeName, "%s", argv[6]);
        if (!cupsRasterWriteHeader2(raster, &h)) return 2;
        for (unsigned y = 0; y < height; y++) {
            memset(line, cmyk ? 0 : 255, (size_t)width * bytes_per_pixel);
            if (!cmyk && ((int)y == mark_y || (mark_y == -2 &&
                (y == 35*(ydpi/300) || y == height-35*(ydpi/300)-1)))) {
                if (mark_x == -2) {
                    for (unsigned x = 0; x < width; x++)
                        if ((x % 17) < 8) line[x] = 0;
                } else if (mark_x >= 0 && (unsigned)mark_x < width) {
                    line[mark_x] = 0;
                }
            }
            if (cupsRasterWritePixels(raster, line, h.cupsBytesPerLine) != h.cupsBytesPerLine) return 2;
        }
    }
    cupsRasterClose(raster);
    close(fd);
    free(line);
    return 0;
}
