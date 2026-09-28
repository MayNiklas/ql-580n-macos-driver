/* Native CUPS raster filter for Brother QL-580N.
 * Protocol implemented from Brother's QL Series Raster Command Reference.
 * Copyright 2026. SPDX-License-Identifier: MIT
 */
#include <cups/cups.h>
#include <cups/ppd.h>
#include <cups/raster.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include "ql_status.h"

typedef struct { int mm, dots, right; } media_t;
static const media_t rolls[] = {
    {12,106,29}, {29,306,6}, {38,413,12},
    {50,554,12}, {54,590,0}, {62,696,12}
};
typedef struct { int w,h,dots,rows,right; } die_t;
static const die_t labels[] = {
    {17,54,165,566,0}, {17,87,165,956,0}, {23,23,236,202,42},
    {29,90,306,991,6}, {38,90,413,991,12}, {39,48,425,495,6},
    {52,29,578,271,0}, {62,29,696,271,12}, {62,100,696,1109,12}
};
static volatile sig_atomic_t canceled;
static void cancel_job(int sig) { (void)sig; canceled=1; }
static void fail(const char *message) { fprintf(stderr,"ERROR: %s\n",message); }
static void state_error(const char *reason, const char *message) {
    fprintf(stderr,"STATE: +%s-error\nERROR: %s\n",reason,message);
}
static bool check_status(ql_status_t *status) {
    if (!ql_status_read(status)) {
        state_error("com.brother.ql580n-status-unavailable",
            "Cannot read printer status. Check SNMP access and the network connection; no automatic retry.");
        return false;
    }
    const char *reason=ql_status_reason(status);
    if (reason) {
        fprintf(stderr,"STATE: +%s-error\nERROR: Printer reports %s (error bits 0x%04x). %s\n",
            reason,reason,status->errors,status->display);
        return false;
    }
    return true;
}
static double seconds(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
    return (double)t.tv_sec+(double)t.tv_nsec/1e9;
}
static void put(FILE *f, const unsigned char *b, size_t n) {
    if (fwrite(b,1,n,f)!=n) { fail("Cannot write raster job."); exit(1); }
}
#define COMMAND(f, ...) do { const unsigned char b[] = {__VA_ARGS__}; put(f,b,sizeof b); } while(0)

/* TIFF PackBits, including literal runs and repeated bytes. */
static size_t packbits(const unsigned char *src, size_t n, unsigned char *dst) {
    size_t i=0,o=0;
    while (i<n) {
        size_t run=1;
        while (i+run<n && src[i+run]==src[i] && run<128) run++;
        if (run>=3) { dst[o++]=(unsigned char)(257-run); dst[o++]=src[i]; i+=run; }
        else {
            size_t start=i;
            i+=run;
            while (i<n && i-start<128) {
                run=1;
                while (i+run<n && src[i+run]==src[i] && run<128) run++;
                if (run>=3) break;
                size_t room=128-(i-start);
                i+=run<room?run:room;
            }
            dst[o++]=(unsigned char)(i-start-1);
            memcpy(dst+o,src+start,i-start); o+=i-start;
        }
    }
    return o;
}

static const char *option(const char *name, int n, cups_option_t *opts, ppd_file_t *ppd) {
    const char *v=cupsGetOption(name,n,opts);
    if (v) return v;
    ppd_choice_t *choice=ppd?ppdFindMarkedChoice(ppd,name):NULL;
    return choice?choice->choice:NULL;
}

static bool black(const unsigned char *row, unsigned x, unsigned y,
                  const cups_page_header2_t *h, bool ordered) {
    unsigned gray;
    if (h->cupsBitsPerPixel==1) {
        gray=(row[x/8] & (0x80>>(x%8)))?255:0;
    } else if (h->cupsBitsPerPixel==8) gray=row[x];
    else {
        const unsigned char *p=row+3*x;
        gray=(77*p[0]+150*p[1]+29*p[2])>>8;
    }
    if (h->cupsColorSpace==CUPS_CSPACE_K) gray=255-gray;
    static const unsigned char bayer[4][4]={{0,8,2,10},{12,4,14,6},{3,11,1,9},{15,7,13,5}};
    unsigned threshold=ordered?8+16*bayer[y%4][x%4]:128;
    return gray<threshold;
}

int main(int argc, char **argv) {
    if (argc!=6 && argc!=7) { fail("Usage: rastertoql580n job user title copies options [raster-file]"); return 1; }
    signal(SIGTERM,cancel_job); signal(SIGINT,cancel_job); signal(SIGPIPE,SIG_IGN);
    int fd=argc==7?open(argv[6],O_RDONLY):STDIN_FILENO;
    if (fd<0) { fail("Cannot open input raster."); return 1; }
    cups_raster_t *r=cupsRasterOpen(fd,CUPS_RASTER_READ);
    if (!r) { fail("Cannot open CUPS raster stream."); return 1; }
    cups_option_t *opts=NULL;
    int n=cupsParseOptions(argv[5],0,&opts);
    const char *ppdpath=getenv("PPD");
    ppd_file_t *ppd=ppdpath?ppdOpenFile(ppdpath):NULL;
    if (ppd) { ppdMarkDefaults(ppd); cupsMarkOptions(ppd,n,opts); }
    const char *cut=option("AutoCut",n,opts,ppd);
    const char *half=option("QLHalftone",n,opts,ppd);
    const char *trim_option=option("QLTrim",n,opts,ppd);
    bool trim=trim_option && !strcmp(trim_option,"On");
    bool autocut=!cut || strcmp(cut,"Off");
    bool ordered=!half || strcmp(half,"Threshold");
    const char *selection=option("QLMedia",n,opts,ppd);
    const char *monitor=option("QLStatus",n,opts,ppd);
    bool automatic=selection && !strcmp(selection,"Auto");
    bool monitored=automatic || (monitor && !strcmp(monitor,"On"));
    ql_status_t loaded={0};
    if (monitored) {
        fprintf(stderr,"STATE: -media-empty-error,cover-open-error,media-jam-error,other-error,"
            "com.brother.ql580n-cutter-jam-error,com.brother.ql580n-status-unavailable-error,"
            "com.brother.ql580n-completion-unknown-error,media-needed-error\n");
        if (!check_status(&loaded)) return 1;
        fprintf(stderr,"INFO: Detected %d mm %s roll%s.\n",loaded.width,
            loaded.type==0x0b?"die-cut":"continuous",automatic?"; selecting loaded media":"");
    }
    char *end=NULL;
    long requested_copies=strtol(argv[4],&end,10);
    if (!end || *end || requested_copies<1 || requested_copies>999) { fail("Copies must be between 1 and 999."); return 1; }
    /* Validate and spool the complete job before sending any bytes to the device. */
    FILE *job=tmpfile();
    if (!job) { fail("Cannot create temporary raster spool."); return 1; }
    COMMAND(job,0x1b,'i','a',1);
    unsigned char zeros[200]={0}; put(job,zeros,sizeof zeros);
    COMMAND(job,0x1b,'@'); COMMAND(job,0x1b,'i','a',1);
    cups_page_header2_t h;
    unsigned pages=0;
    int result=1;
    while (!canceled && cupsRasterReadHeader2(r,&h)) {
        bool highres=h.HWResolution[0]==300 && h.HWResolution[1]==600;
        unsigned ydpi=highres?600:300;
        /* cupsManualCopies lets the macOS rasterizer expand job copies.
         * Only repeat copies explicitly left in the per-page raster header. */
        unsigned copies=h.NumCopies?h.NumCopies:1;
        if (copies>999) { fail("Raster copy count exceeds 999."); goto done; }
        double pw=h.cupsPageSize[0]>0?h.cupsPageSize[0]:h.PageSize[0];
        double ph=h.cupsPageSize[1]>0?h.cupsPageSize[1]:h.PageSize[1];
        double mmw=pw*25.4/72, mmh=ph*25.4/72;
        const char *name=h.cupsPageSizeName[0]?h.cupsPageSizeName:option("PageSize",n,opts,ppd);
        bool die=name && name[0]=='d' && strchr(name,'x');
        int width=0,length=0,dots=0,right=0,rows=0;
        if (die) {
            for (size_t i=0;i<sizeof labels/sizeof *labels;i++) {
                if (fabs(mmw-labels[i].w)<0.4 && fabs(mmh-labels[i].h)<0.4) {
                    width=labels[i].w; length=labels[i].h; dots=labels[i].dots;
                    rows=labels[i].rows*(int)(ydpi/300); right=labels[i].right; break;
                }
            }
        } else {
            for (size_t i=0;i<sizeof rolls/sizeof *rolls;i++) {
                if (fabs(mmw-rolls[i].mm)<0.4) {
                    width=rolls[i].mm; dots=rolls[i].dots; right=rolls[i].right; break;
                }
            }
            rows=(int)lround(ph*ydpi/72)-70*(int)(ydpi/300);
        }
        bool mono=(h.cupsColorSpace==CUPS_CSPACE_W || h.cupsColorSpace==CUPS_CSPACE_SW || h.cupsColorSpace==CUPS_CSPACE_K);
        bool rgb=(h.cupsColorSpace==CUPS_CSPACE_RGB || h.cupsColorSpace==CUPS_CSPACE_SRGB);
        if (!width || rows<1 || rows>11811*(int)(ydpi/300) || (!die && (mmh<19 || mmh>1000))) {
            fail("Unsupported label size. Select the loaded roll width and a supported label length."); goto done;
        }
        if (h.HWResolution[0]!=300 || (h.HWResolution[1]!=300 && h.HWResolution[1]!=600) || h.cupsColorOrder!=CUPS_ORDER_CHUNKED ||
            !((mono && ((h.cupsBitsPerPixel==8 && h.cupsBitsPerColor==8) || (h.cupsBitsPerPixel==1 && h.cupsBitsPerColor==1))) ||
              (rgb && h.cupsBitsPerPixel==24 && h.cupsBitsPerColor==8)) ||
            h.cupsWidth<1 || h.cupsWidth>800 || h.cupsHeight<1 || h.cupsHeight>24000 ||
            h.cupsBytesPerLine<(h.cupsWidth*h.cupsBitsPerPixel+7)/8 || h.cupsBytesPerLine>4096) {
            fail("Unsupported raster format. Driver requires 300 x 300 or 300 x 600 dpi gray or RGB raster."); goto done;
        }
        /* The macOS rasterizer may supply a full page or just the imageable area.
         * Center that raster inside the physical page, then crop to head geometry. */
        int xcrop=((int)h.cupsWidth-dots)/2;
        int ycrop=((int)h.cupsHeight-rows)/2;
        if (abs((int)h.cupsWidth-(int)lround(pw*300/72))>55 ||
            abs((int)h.cupsHeight-(int)lround(ph*ydpi/72))>80*(int)(ydpi/300)) {
            fail("Raster dimensions do not match the selected physical label."); goto done;
        }
        int source_dots=dots, source_rows=rows;
        if (monitored && !automatic &&
            (width!=loaded.width || (die?0x0b:0x0a)!=loaded.type || length!=loaded.length)) {
            state_error("media-needed","Selected paper size does not match the loaded roll. Select Automatic roll detection or load matching media.");
            goto done;
        }
        if (automatic) {
            width=0; length=loaded.length; die=loaded.type==0x0b;
            if (die) {
                for (size_t i=0;i<sizeof labels/sizeof *labels;i++) {
                    if (labels[i].w==loaded.width && labels[i].h==loaded.length) {
                        width=labels[i].w; dots=labels[i].dots; right=labels[i].right;
                        rows=labels[i].rows*(int)(ydpi/300); break;
                    }
                }
            } else if (loaded.type==0x0a && loaded.length==0) {
                for (size_t i=0;i<sizeof rolls/sizeof *rolls;i++) {
                    if (rolls[i].mm==loaded.width) {
                        width=rolls[i].mm; dots=rolls[i].dots; right=rolls[i].right; break;
                    }
                }
                rows=(int)lround(ph*ydpi/72)-70*(int)(ydpi/300);
            }
            if (!width || rows<1 || rows>11811*(int)(ydpi/300)) {
                state_error("media-needed","The detected roll is unsupported by this driver."); goto done;
            }
        }
        size_t data_size=(size_t)rows*90;
        unsigned char *data=calloc(1,data_size), *raster=malloc((size_t)h.cupsHeight*h.cupsBytesPerLine);
        if (!data || !raster) { free(data); free(raster); fail("Out of memory."); goto done; }
        for (unsigned y=0;y<h.cupsHeight;y++) {
            if (canceled || cupsRasterReadPixels(r,raster+(size_t)y*h.cupsBytesPerLine,h.cupsBytesPerLine)!=h.cupsBytesPerLine) {
                free(data); free(raster); fail("Canceled or truncated CUPS raster input."); goto done;
            }
        }
        /* Fit within detected media without stretching or enlarging the artwork.
         * Continuous media retains the requested label length. */
        double scale=fmin(1.0,fmin((double)dots/source_dots,(double)rows/source_rows));
        int draw_width=(int)lround(source_dots*scale), draw_height=(int)lround(source_rows*scale);
        int left=(dots-draw_width)/2, top=(rows-draw_height)/2;
        for (int y=0;y<draw_height && !canceled;y++) {
            int sy=ycrop+(int)floor(y/scale);
            if (sy<0 || sy>=(int)h.cupsHeight) continue;
            const unsigned char *line=raster+(size_t)sy*h.cupsBytesPerLine;
            for (int dx=0;dx<draw_width;dx++) {
                int x=left+dx, sx=xcrop+(int)floor(dx/scale);
                if (sx>=0 && sx<(int)h.cupsWidth && black(line,(unsigned)sx,(unsigned)sy,&h,ordered)) {
                    int bit=right+dots-1-x;
                    data[(size_t)(top+y)*90+bit/8]|=(unsigned char)(0x80>>(bit%8));
                }
            }
        }
        free(raster);
        if (trim && !die) {
            int first=-1,last=-1;
            for (int y=0;y<rows;y++) {
                for (int x=0;x<90;x++) {
                    if (data[(size_t)y*90+x]) {
                        if (first<0) first=y;
                        last=y; break;
                    }
                }
            }
            /* Preserve every printed row and the 35-dot feed margins. Keep
             * blank labels unchanged; never shorten below our 19 mm minimum
             * or enlarge an already shorter raster due to rounding. */
            if (first>=0) {
                int minimum=((int)ceil(19.0*300/25.4)-70)*(int)(ydpi/300);
                if (minimum>rows) minimum=rows;
                int kept=last-first+1;
                if (kept<minimum) kept=minimum;
                int start=first-(kept-(last-first+1))/2;
                if (start<0) start=0;
                if (start>rows-kept) start=rows-kept;
                if (kept<rows) {
                    memmove(data,data+(size_t)start*90,(size_t)kept*90);
                    fprintf(stderr,"INFO: Trimmed continuous label from %.1f to %.1f mm.\n",
                        (rows+70*(int)(ydpi/300))*25.4/ydpi,
                        (kept+70*(int)(ydpi/300))*25.4/ydpi);
                    rows=kept;
                }
            }
        }
        for (unsigned copy=0;copy<copies;copy++) {
            if (pages) COMMAND(job,0x0c);
            unsigned char info[]={0x1b,'i','z',(unsigned char)((die?0x8e:0x86)|(highres?0x40:0)),
                (unsigned char)(die?0x0b:0x0a),(unsigned char)width,(unsigned char)length,
                (unsigned char)rows,(unsigned char)(rows>>8),(unsigned char)(rows>>16),(unsigned char)(rows>>24),
                (unsigned char)(pages?1:0),0};
            put(job,info,sizeof info);
            COMMAND(job,0x1b,'i','M',autocut?0x40:0);
            COMMAND(job,0x1b,'i','A',1);
            COMMAND(job,0x1b,'i','K',(autocut?8:0)|(highres?0x40:0));
            COMMAND(job,0x1b,'i','d',die?0:35,0);
            COMMAND(job,'M',2);
            for (int y=0;y<rows;y++) {
                const unsigned char *row=data+(size_t)y*90;
                bool blank=true;
                for (int x=0;x<90;x++) if (row[x]) { blank=false; break; }
                if (blank) COMMAND(job,'Z');
                else {
                    unsigned char packed[182];
                    size_t bytes=packbits(row,90,packed);
                    COMMAND(job,'g',0,(unsigned char)bytes); put(job,packed,bytes);
                }
            }
            pages++;
        }
        free(data);
    }
    if (canceled) { fail("Job canceled."); goto done; }
    if (!pages) { fail("No raster pages in job."); goto done; }
    const char *raster_error=cupsRasterErrorString();
    if (raster_error && *raster_error) { fail(raster_error); goto done; }
    COMMAND(job,0x1a);
    if (fflush(job) || fseek(job,0,SEEK_SET)) { fail("Cannot rewind raster spool."); goto done; }
    ql_status_t before={0};
    if (monitored) {
        if (!check_status(&before)) goto done;
        if (before.width!=loaded.width || before.type!=loaded.type || before.length!=loaded.length) {
            state_error("media-needed","Roll changed while preparing the job. Resubmit using the currently loaded roll."); goto done;
        }
        if (before.printer_state!=1) {
            state_error("other","Printer is busy with another job. Wait until it is idle, then resubmit."); goto done;
        }
    }
    unsigned char buf[8192]; size_t bytes;
    while (!canceled && (bytes=fread(buf,1,sizeof buf,job))>0) {
        if (fwrite(buf,1,bytes,stdout)!=bytes) { fail("Printer backend closed the connection."); goto done; }
    }
    if (canceled || ferror(job) || fflush(stdout)) { fail("Job transfer failed or canceled."); goto done; }
    if (monitored) {
        unsigned timeout=120;
        const char *wait_option=cupsGetOption("QLWaitTimeout",n,opts);
        if (wait_option) {
            char *tail; long value=strtol(wait_option,&tail,10);
            if (!*tail && value>=1 && value<=3600) timeout=(unsigned)value;
        }
        fprintf(stderr,"INFO: Data sent; waiting for the printer to confirm %u label(s).\n",pages);
        double progress=seconds(); uint32_t last=before.pages;
        unsigned complete_samples=0;
        while (!canceled) {
            ql_status_t current;
            if (!check_status(&current)) goto done;
            uint32_t printed=current.pages-before.pages;
            if (printed>pages) {
                state_error("com.brother.ql580n-completion-unknown","Printer counter changed unexpectedly; another client may be printing. Check the labels before resubmitting."); goto done;
            }
            /* Observe a second idle status after the count advances so late
             * feed/cutter errors can surface before reporting success. */
            if (printed==pages && current.printer_state==1) {
                if (++complete_samples>=2) break;
            } else complete_samples=0;
            if (current.pages!=last) { progress=seconds(); last=current.pages; }
            if (seconds()-progress>=timeout) {
                state_error("com.brother.ql580n-completion-unknown","Printer did not confirm completion. Some labels may have printed; check before resubmitting."); goto done;
            }
            sleep(1);
        }
        if (canceled) { fail("Canceled while waiting for the printer. Some labels may already have printed."); goto done; }
        fprintf(stderr,"INFO: Printer confirmed %u label(s).\n",pages);
    } else fprintf(stderr,"INFO: Sent %u label(s); physical completion was not checked.\n",pages);
    fprintf(stderr,"PAGE: 1 %u\n",pages);
    result=0;
done:
    fclose(job); cupsRasterClose(r); if (argc==7) close(fd);
    if (ppd) ppdClose(ppd); cupsFreeOptions(n,opts);
    return result;
}
