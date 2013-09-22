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

typedef SV* (*CUSTOM_DECODE)(SV*);

typedef struct redis_fast_s {
    redisAsyncContext* ac;
    char* hostname;
    int port;
    char* path;
    int reconnect;
    int every;
    int is_utf8;
} redis_fast_t, *Redis__Fast;

typedef struct redis_fast_sync_cb_s {
    SV* ret;
    char* error;
    CUSTOM_DECODE custom_decode;
} redis_fast_sync_cb_t;

typedef struct redis_fast_async_cb_s {
    SV* cb;
    CUSTOM_DECODE custom_decode;
} redis_fast_async_cb_t;

#define WAIT_FOR_READ  0x01
#define WAIT_FOR_WRITE 0x02
typedef struct redis_fast_event_s {
    int flags;
} redis_fast_event_t;


static void AddRead(void *privdata) {
    redis_fast_event_t *e = (redis_fast_event_t*)privdata;
    e->flags |= WAIT_FOR_READ;
}

static void DelRead(void *privdata) {
    redis_fast_event_t *e = (redis_fast_event_t*)privdata;
    e->flags &= ~WAIT_FOR_READ;
}

static void AddWrite(void *privdata) {
    redis_fast_event_t *e = (redis_fast_event_t*)privdata;
    e->flags |= WAIT_FOR_WRITE;
}

static void DelWrite(void *privdata) {
    redis_fast_event_t *e = (redis_fast_event_t*)privdata;
    e->flags &= ~WAIT_FOR_WRITE;
}

static void Cleanup(void *privdata) {
    free(privdata);
}

static int Attach(redisAsyncContext *ac) {
    redis_fast_event_t *e;

    /* Nothing should be attached when something is already attached */
    if (ac->ev.data != NULL)
        return REDIS_ERR;

    /* Create container for context and r/w events */
    e = (redis_fast_event_t*)malloc(sizeof(*e));
    e->flags = 0;

    /* Register functions to start/stop listening for events */
    ac->ev.addRead = AddRead;
    ac->ev.delRead = DelRead;
    ac->ev.addWrite = AddWrite;
    ac->ev.delWrite = DelWrite;
    ac->ev.cleanup = Cleanup;
    ac->ev.data = e;

    return REDIS_OK;
}

static void wait_for_event(Redis__Fast self) {
    redisContext *c;
    int fd;
    redis_fast_event_t *e;
    fd_set readfds, writefds, exceptfds;

    if(self==NULL) return;
    if(self->ac==NULL) return;

    c = &(self->ac->c);
    fd = c->fd;
    e = (redis_fast_event_t*)self->ac->ev.data;
    if(e==NULL) return;

    FD_ZERO(&readfds); if(e->flags & WAIT_FOR_READ) { FD_SET(fd, &readfds); }
    FD_ZERO(&writefds); if(e->flags & WAIT_FOR_WRITE) { FD_SET(fd, &writefds); }
    FD_ZERO(&exceptfds); FD_SET(fd, &exceptfds);
    select(fd + 1, &readfds, &writefds, &exceptfds, NULL);

    if(FD_ISSET(fd, &exceptfds)) {
        //fprintf(stderr, "error!!!!\n");
    }
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

    Attach(ac);
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


static void Redis__Fast_connect(Redis__Fast self) {
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

static void Redis__Fast_reconnect(Redis__Fast self) {
    if(!self->ac && self->reconnect) {
        Redis__Fast_connect(self);
    }
    if(!self->ac) {
        croak("Not connected to any server");
    }
}

static SV* Redis__Fast_decode_reply(Redis__Fast self, redisReply* reply) {
    SV* res = NULL;

    switch (reply->type) {
    case REDIS_REPLY_STRING:
    case REDIS_REPLY_ERROR:
    case REDIS_REPLY_STATUS:
        res = sv_2mortal(newSVpvn(reply->str, reply->len));
        if (self->is_utf8) {
            sv_utf8_decode(res);
        }
        break;

    case REDIS_REPLY_INTEGER:
        res = sv_2mortal(newSViv(reply->integer));
        break;
    case REDIS_REPLY_NIL:
        res = sv_2mortal(newSV(0));
        break;

    case REDIS_REPLY_ARRAY: {
        AV* av = (AV*)sv_2mortal((SV*)newAV());
        size_t i;
        res = newRV_inc((SV*)av);

        for (i = 0; i < reply->elements; i++) {
            av_push(av, SvREFCNT_inc(Redis__Fast_decode_reply(self, reply->element[i])));
        }
        break;
    }
    }

    return res;
}

static void Redis__Fast_sync_reply_cb(redisAsyncContext* c, void* reply, void* privdata) {
    Redis__Fast self = (Redis__Fast)c->data;
    redis_fast_sync_cb_t *cbt = (redis_fast_sync_cb_t*)privdata;
    if(reply) {
        cbt->ret = Redis__Fast_decode_reply(self, (redisReply*)reply);
        if(cbt->custom_decode) {
            cbt->ret = (cbt->custom_decode)(cbt->ret);
        }
    } else {
        cbt->error = c->errstr;
    }
}

static void Redis__Fast_async_reply_cb(redisAsyncContext* c, void* reply, void* privdata) {
    Redis__Fast self = (Redis__Fast)c->data;
    redis_fast_async_cb_t *cbt = (redis_fast_async_cb_t*)privdata;
    SV* sv_reply;
    SV* sv_undef;
    SV* sv_err;
    sv_undef = sv_2mortal(newSV(0));

    if (reply) {
        sv_reply = Redis__Fast_decode_reply(self, (redisReply*)reply);
        if(cbt->custom_decode) {
            sv_reply = (cbt->custom_decode)(sv_reply);
        }

        {
            dSP;

            ENTER;
            SAVETMPS;

            PUSHMARK(SP);
            if (((redisReply*)reply)->type == REDIS_REPLY_ERROR) {
                PUSHs(sv_undef);
                PUSHs(sv_reply);
            }
            else {
                PUSHs(sv_reply);
            }
            PUTBACK;

            call_sv(cbt->cb, G_DISCARD);

            FREETMPS;
            LEAVE;
        }
    }

    SvREFCNT_dec(cbt->cb);
    Safefree(cbt);
}

static SV* Redis__Fast_run_cmd(Redis__Fast self, int collect_errors, CUSTOM_DECODE custom_decode, SV* cb, int argc, const char** argv, size_t* argvlen) {
    if(cb) {
        redis_fast_async_cb_t *cbt;
        Newx(cbt, sizeof(redis_fast_async_cb_t), redis_fast_async_cb_t);
        cbt->cb = SvREFCNT_inc(cb);
        cbt->custom_decode = custom_decode;
        redisAsyncCommandArgv(
            self->ac, Redis__Fast_async_reply_cb, cbt,
            argc, argv, argvlen
            );
    } else {
        redis_fast_sync_cb_t cbt;
        int i, cnt = (self->reconnect == 0 ? 1 : 2);
        for(i = 0; i < cnt; i++) {
            cbt.ret = NULL;
            cbt.error = NULL;
            cbt.custom_decode = custom_decode;
            redisAsyncCommandArgv(
                self->ac, Redis__Fast_sync_reply_cb, &cbt,
                argc, argv, argvlen
                );
            _wait_all_responses(self);
            if(cbt.ret) {
                return cbt.ret;
            } else {
                Redis__Fast_reconnect(self);
            }
        }
        if(!cbt.ret) {
            croak(cbt.error);
        }
    }
    return NULL;
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


int
__set_utf8(Redis::Fast self, int val)
CODE:
{
    RETVAL = self->is_utf8 = val;
}


int
__get_utf8(Redis::Fast self, int val)
CODE:
{
    RETVAL = self->is_utf8;
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
    Redis__Fast_connect(self);
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
    SV* ret;
    SV* cb;
    char** argv;
    size_t* argvlen;
    STRLEN len;
    int argc, i;
CODE:
{
    Redis__Fast_reconnect(self);

    cb = ST(items - 1);
    if (SvROK(cb) && SvTYPE(SvRV(cb)) == SVt_PVCV) {
        argc = items - 2;
    } else {
        cb = NULL;
        argc = items - 1;
    }
    Newx(argv, sizeof(char*) * argc, char*);
    Newx(argvlen, sizeof(size_t) * argc, size_t);

    for (i = 0; i < argc; i++) {
        if(self->is_utf8) {
            argv[i] = SvPVutf8(ST(i + 1), len);
        } else {
            argv[i] = SvPV(ST(i + 1), len);
        }
        argvlen[i] = len;
    }

    ret = Redis__Fast_run_cmd(self, 0, NULL, cb, argc, (const char**)argv, argvlen);
    if(ret) {
        ST(0) = ret;
        XSRETURN(1);
    } else {
        XSRETURN(0);
    }

    Safefree(argv);
    Safefree(argvlen);
}


SV*
ping(Redis::Fast self)
PREINIT:
    redis_fast_sync_cb_t cbt;
CODE:
{
    if(self->ac) {
        cbt.ret = NULL;
        cbt.custom_decode = NULL;
        redisAsyncCommand(
            self->ac, Redis__Fast_sync_reply_cb, &cbt, "PING"
            );
        _wait_all_responses(self);
        ST(0) = cbt.ret;
        XSRETURN(1);
    } else {
        XSRETURN(0);
    }
}


SV*
quit(Redis::Fast self)
PREINIT:
    redis_fast_sync_cb_t cbt;
CODE:
{
    if(self->ac) {
        cbt.ret = NULL;
        cbt.custom_decode = NULL;
        redisAsyncCommand(
            self->ac, Redis__Fast_sync_reply_cb, &cbt, "QUIT"
            );
        redisAsyncDisconnect(self->ac);
        _wait_all_responses(self);
        ST(0) = cbt.ret;
        XSRETURN(1);
    } else {
        XSRETURN(0);
    }
}


