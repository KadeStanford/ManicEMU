#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

extern int ManicStabilityCaptureForTest(unsigned);
static pthread_mutex_t mutex=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition=PTHREAD_COND_INITIALIZER;
static void *waiting(void *unused){
    pthread_mutex_lock(&mutex);
    pthread_cond_wait(&condition,&mutex);
    return NULL;
}
int main(void){
    pthread_t worker;
    if(pthread_create(&worker,NULL,waiting,NULL))return 1;
    usleep(50000);
    uint64_t identifier=0;
    if(pthread_threadid_np(worker,&identifier))return 2;
    char path[4096];
    snprintf(path,sizeof(path),"%s/waiting-thread-id.txt",getenv("MANIC_STABILITY_DIRECTORY"));
    FILE *file=fopen(path,"w");if(!file)return 3;
    fprintf(file,"%llu",(unsigned long long)identifier);fclose(file);
    // Real own-task sampling, including a known waiting thread; overwrite only
    // the new diagnostic ring to verify that its file count stays bounded.
    for(unsigned sequence=0;sequence<24;sequence++)
        if(ManicStabilityCaptureForTest(sequence))return 4;
    return 0;
}
