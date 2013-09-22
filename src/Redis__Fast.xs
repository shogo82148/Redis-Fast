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

    FD_ZERO(&readfds); FD_SET(fd, &readfds);
    FD_ZERO(&writefds); FD_SET(fd, &writefds);
    FD_ZERO(&exceptfds); FD_SET(fd, &exceptfds);
    select(fd + 1, &readfds, &writefds, &exceptfds, NULL);

    if(self->ac && FD_ISSET(fd, &readfds)) {
        //fprintf(stderr, "ready to read\n");
        redisAsyncHandleRead(self->ac);
    }
    if(self->ac && FD_ISSET(fd, &writefds)) {
        //fprintf(stderr, "ready to write\n");
        redisAsyncHandleWrite(self->ac);
    }
}

static void Redis__Fast_connect_cb(redisAsyncContext* c, int status) {
    Redis__Fast self = (Redis__Fast)c->data;
    if(status != REDIS_OK) {
        // Connection Error!!
        // Redis context will close automatically
        self->ac = NULL;
    } else {
        // TODO: send password
        // TODO: call on_connect callback
    }
}

static void Redis__Fast_disconnect_cb(redisAsyncContext* c, int status) {
    Redis__Fast self = (Redis__Fast)c->data;
    self->ac = NULL;
}

static redisAsyncContext* __build_sock(Redis__Fast self)
{
    redisAsyncContext *ac;

    if(self->path) {
        ac = redisAsyncConnectUnix(self->path);
    } else {
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
    wait_for_event(self);

    return self->ac;
}


static void _wait_all_responses(Redis__Fast self) {
    while(self->ac && self->ac->replies.tail) {
        wait_for_event(self);
    }
}


static SV* Redis__Fast_decode_reply(redisReply* reply) {
    SV* res = NULL;

    switch (reply->type) {
    case REDIS_REPLY_STRING:
    case REDIS_REPLY_ERROR:
    case REDIS_REPLY_STATUS:
        res = sv_2mortal(newSVpvn(reply->str, reply->len));
        break;

    case REDIS_REPLY_INTEGER:
        res = sv_2mortal(newSViv(reply->integer));
        break;
    case REDIS_REPLY_NIL:
        res = sv_2mortal(newSV(0));
        break;

    case REDIS_REPLY_ARRAY: {
        AV* av = (AV*)sv_2mortal((SV*)newAV());
        res = newRV_inc((SV*)av);

        size_t i;
        for (i = 0; i < reply->elements; i++) {
            av_push(av, Redis__Fast_decode_reply(reply->element[i]));
        }
        break;
    }
    }

    return res;
}

static void Redis__Fast_sync_reply_cb(redisAsyncContext* c, void* reply, void* privdata) {
    SV** sv_reply = (SV**)privdata;
    *sv_reply = Redis__Fast_decode_reply((redisReply*)reply);
}

static void Redis__Fast_reply_cb(redisAsyncContext* c, void* reply, void* privdata) {
    SV* sv_reply;
    sv_reply = Redis__Fast_decode_reply((redisReply*)reply);
}


MODULE = Redis::Fast		PACKAGE = Redis::Fast

Redis::Fast
_new(char* cls);
CODE:
{
    PERL_UNUSED_VAR(cls);
    Newxz(RETVAL, sizeof(redis_fast_t), redis_fast_t);
    RETVAL->ac = NULL;
}
OUTPUT:
    RETVAL

int
__set_reconnect(Redis::Fast self, int val)
CODE:
{
    RETVAL = self->reconnect = val;
}


int
__get_reconnect(Redis::Fast self)
CODE:
{
    RETVAL = self->reconnect;
}


int
__set_every(Redis::Fast self, int val)
CODE:
{
    RETVAL = self->every = val;
}


int
__get_every(Redis::Fast self, int val)
CODE:
{
    RETVAL = self->every;
}


void
DESTROY(Redis::Fast self);
CODE:
{
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
        __build_sock(self);
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

void
wait_all_responses(Redis::Fast self)
CODE:
{
    _wait_all_responses(self);
}


void
wait_one_response(Redis::Fast self)
CODE:
{
    _wait_all_responses(self);
}


SV*
__std_cmd(Redis::Fast self, ...)
PREINIT:
    char** argv;
    size_t* argvlen;
    STRLEN len;
    int argc, i;
CODE:
{
    argc = items - 1;
    Newx(argv, sizeof(char*) * argc, char*);
    Newx(argvlen, sizeof(size_t) * argc, size_t);

    for (i = 0; i < argc; i++) {
        argv[i] = SvPV(ST(i + 1), len);
        argvlen[i] = len;
    }

    {
        SV* ret;
        redisAsyncCommandArgv(
            self->ac, Redis__Fast_sync_reply_cb, &ret,
            argc, (const char**)argv, argvlen
            );
        Safefree(argv);
        Safefree(argvlen);
        _wait_all_responses(self);
        ST(0) = ret;
        XSRETURN(1);
    }
}


SV*
ping(Redis::Fast self)
PREINIT:
    SV* ret;
CODE:
{
    redisAsyncCommand(
        self->ac, Redis__Fast_sync_reply_cb, &ret, "PING"
        );
    _wait_all_responses(self);
    ST(0) = ret;
    XSRETURN(1);
}


