/* Portable microbenchmarks. NOT macOS switching / interactivity measurements. */
#define _POSIX_C_SOURCE 200809L
#include "rheo_core.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static volatile uint64_t sink;
static uint64_t ns(void) {
    struct timespec ts; if (clock_gettime(CLOCK_MONOTONIC,&ts)) abort();
    return (uint64_t)ts.tv_sec*1000000000u+(uint64_t)ts.tv_nsec;
}
static int cmp(const void *a,const void *b) {
    double x=*(const double *)a,y=*(const double *)b; return (x>y)-(x<y);
}
static void run(const char *name,int kind,FILE *raw) {
    enum { SAMPLES=31, N=200000 };
    double samples[SAMPLES]; uint64_t checksum=0;
    sn_policy p={true,true,false,0};
    for (int sample=-1;sample<SAMPLES;++sample) {
        sn_gesture g={0}; uint8_t bytes[96];
        sn_payload_input payload={.timestamp=100,.phase=SN_ENDED,.progress=1e-4,.velocity_x=2000};
        uint64_t start=ns();
        for (int i=0;i<N;++i) {
            if (kind==0) {
                sn_input e={SN_OTHER,SN_NONE,false,0,0,(uint64_t)i+1};
                checksum+=sn_gesture_step(&g,&e,&p).flags;
            } else if (kind==1) {
                sn_input e={SN_HORIZONTAL,SN_BEGAN,false,0,0,(uint64_t)i*3+1};
                checksum+=sn_gesture_step(&g,&e,&p).flags;
                e.phase=SN_CHANGED; e.progress=0.1; ++e.now_ns;
                checksum+=sn_gesture_step(&g,&e,&p).flags;
                checksum+=sn_gesture_feedback(&g,SN_POSTED,false,false).flags;
                e.phase=SN_ENDED; ++e.now_ns;
                checksum+=sn_gesture_step(&g,&e,&p).flags;
            } else {
                payload.timestamp=(uint64_t)i;
                checksum+=sn_payload_encode(&payload,bytes,sizeof(bytes));
                checksum+=bytes[0]+bytes[84];
            }
        }
        double elapsed=(double)(ns()-start)/N;
        if (sample>=0) samples[sample]=elapsed;
    }
    if (raw) for (int i=0;i<SAMPLES;++i)
        fprintf(raw,"%s,%d,%.6f,%d\n",name,i,samples[i],N);
    sink=checksum; qsort(samples,SAMPLES,sizeof(double),cmp);
    printf("%s,%.3f,%.3f,%.3f,%d,%d\n",name,samples[0],samples[SAMPLES/2],samples[29],N,SAMPLES);
}
int main(int argc,char **argv) {
    if (argc>2) { fputs("Usage: core-bench [raw-samples.csv]\n",stderr); return 2; }
    FILE *raw=argc==2 ? fopen(argv[1],"w") : NULL;
    if (argc==2 && !raw) { perror(argv[1]); return 1; }
    if (raw) fputs("operation,batch,mean_ns_per_operation,operations\n",raw);
    puts("operation,min_ns_per_operation,median_ns_per_operation,p95_batch_mean_ns,operations_per_batch,batches");
    run("unrelated_event",0,raw); run("gesture_began_changed_feedback_ended",1,raw); run("iohid_96_byte_encode",2,raw);
    if (raw && fclose(raw)) { perror("writing raw samples"); return 1; }
    return sink==0;
}
