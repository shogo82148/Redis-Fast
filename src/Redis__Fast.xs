#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"
#include "hiredis.h"
#include "async.h"

#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <stdio.h>
#include <sys/select.h>

typedef struct redis_fast_s {
    redisAsyncContext* ac;
    char* hostname;
    int port;
    char* path;
    int reconnect;
    int every;
} redis_fast_t, *Redis__Fast;


static void wait_for_event(Redis__Fast self) {
    if(self==NULL) return;
    if(self->ac==NULL) return ;

    redisContext *c = &(self->ac->c);
    int fd = c->fd;
    fd_set readfds, writefds, exceptfds;

    fprintf(stderr, "select %d\n", fd);

    FD_ZERO(&readfds); FD_SET(fd, &readfds);
    FD_ZERO(&writefds); FD_SET(fd, &writefds);
    FD_ZERO(&exceptfds); FD_SET(fd, &exceptfds);
    select(fd + 1, &readfds, &writefds, &exceptfds, NULL);

    if(FD_ISSET(fd, &exceptfds)) {
        fprintf(stderr, "error!!\n");
    }
    if(self->ac && FD_ISSET(fd, &readfds)) {
        fprintf(stderr, "ready to read\n");
        redisAsyncHandleRead(self->ac);
    }
    if(self->ac && FD_ISSET(fd, &writefds)) {
        fprintf(stderr, "ready to write\n");
        redisAsyncHandleWrite(self->ac);
    }
}

static void Redis__Fast_connect_cb(redisAsyncContext* c, int status) {
    Redis__Fast self = (Redis__Fast)c->data;
    if(status != REDIS_OK) {
        // Connection Error!!
        // Redis context will close automatically
        self->ac = NULL;
        fprintf(stderr, "fail connect!!\n");
    } else {
        // TODO: send password
        // TODO: call on_connect callback
    }
}

static void Redis__Fast_disconnect_cb(redisAsyncContext* c, int status) {
    fprintf(stderr, "disconnecting\n");
    Redis__Fast self = (Redis__Fast)c->data;
    self->ac = NULL;
}

static redisAsyncContext* __build_sock(Redis__Fast self)
{
    redisAsyncContext *ac;

    if(self->path) {
        ac = redisAsyncConnectUnix(self->path);
    } else {
        fprintf(stderr, "Try to connect\n");
        ac = redisAsyncConnect(self->hostname, self->port);
    }

    if(!ac) {
        return NULL;
    }
    ac->data = (void*)self;
    self->ac = ac;

    redisAsyncSetConnectCallback(ac, (redisConnectCallback*)Redis__Fast_connect_cb);
    redisAsyncSetDisconnectCallback(ac, (redisDisconnectCallback*)Redis__Fast_disconnect_cb);

    // wait to connect...
    fprintf(stderr, "waiting...\n");
    wait_for_event(self);

    fprintf(stderr, "connected\n");
    return self->ac;
}


MODULE = Redis::Fast		PACKAGE = Redis::Fast

Redis::Fast
_new(char* cls);
CODE:
{
    fprintf(stderr, "new\n");
    PERL_UNUSED_VAR(cls);
    Newxz(RETVAL, sizeof(redis_fast_t), redis_fast_t);
    RETVAL->ac = NULL;
}
OUTPUT:
    RETVAL

int
__reconnect(Redis::Fast self, int val)
CODE:
{
    RETVAL = self->reconnect = val;
}


int
__every(Redis::Fast self, int val)
CODE:
{
    RETVAL = self->every = val;
}


void
DESTROY(Redis::Fast self);
CODE:
{
    fprintf(stderr, "DESTROY\n");
    if (self->ac) {
        redisAsyncFree(self->ac);
        self->ac = NULL;
    }

    if(self->hostname) {
        free(self->hostname);
        self->hostname = NULL;
    }

    if(self->path) {
        free(self->path);
        self->path = NULL;
    }

    Safefree(self);
}


void
__connection_info(Redis::Fast self, char* hostname, int port = 6379)
CODE:
{
    fprintf(stderr, "connection info %s:%d\n", hostname, port);
    if(self->hostname) {
        free(self->hostname);
        self->hostname = NULL;
    }

    if(self->path) {
        free(self->path);
        self->path = NULL;
    }

    if(hostname) {
        self->hostname = (char*)malloc(strlen(hostname) + 1);
        strcpy(self->hostname, hostname);
    }

    self->port = port;
}

void
__connection_info_unix(Redis::Fast self, char* path)
CODE:
{
    if(self->hostname) {
        free(self->hostname);
        self->hostname = NULL;
    }

    if(self->path) {
        free(self->path);
        self->path = NULL;
    }

    if(path) {
        self->path = (char*)malloc(strlen(path) + 1);
        strcpy(self->path, path);
    }
}


void
__connect(Redis::Fast self)
CODE:
{
    clock_t start;

    if (self->ac) {
        redisAsyncFree(self->ac);
        self->ac = NULL;
    }

    //$self->{queue} = [];

    if(self->reconnect == 0) {
        fprintf(stderr, "start build_sock\n");
        __build_sock(self);
        fprintf(stderr, "finish build_sock\n");
        if(!self->ac) {
            croak("connection timed out");
        }
        return ;
    }

    // Reconnect...
    start = clock();
    while (1) {
        if(__build_sock(self)) {
            // Connected!
            return;
        }
        if(clock() - start > self->reconnect * CLOCKS_PER_SEC) {
            croak("connection timed out");
            return;
        }
        usleep(self->every);
    }
}


int
__std_cmd(Redis::Fast self, ...)
CODE:
{
    RETVAL = 0;
}
OUTPUT:
    RETVAL


