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

#define MAX_ERROR_SIZE 256

typedef struct redis_fast_s {
    redisAsyncContext* ac;
    char* hostname;
    int port;
    char* path;
    char* error;
    int reconnect;
    int every;
    int is_utf8;
    int need_recoonect;
    SV* on_connect;
    SV* data;
} redis_fast_t, *Redis__Fast;

typedef struct redis_fast_reply_s {
    SV* result;
    SV* error;
} redis_fast_reply_t;

typedef redis_fast_reply_t (*CUSTOM_DECODE)(Redis__Fast self, redisReply* reply, int collect_errors);

typedef struct redis_fast_sync_cb_s {
    redis_fast_reply_t ret;
    int collect_errors;
    CUSTOM_DECODE custom_decode;
} redis_fast_sync_cb_t;

typedef struct redis_fast_async_cb_s {
    SV* cb;
    int collect_errors;
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
        if(self->on_connect){
            dSP;

            ENTER;
            SAVETMPS;

            PUSHMARK(SP);
            PUTBACK;

            call_sv(self->on_connect, G_DISCARD);

            FREETMPS;
            LEAVE;
        }
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
            if(self->path) {
                snprintf(self->error, MAX_ERROR_SIZE, "Could not connect to Redis server at %s", self->path);
            } else {
                snprintf(self->error, MAX_ERROR_SIZE, "Could not connect to Redis server at %s:%d", self->hostname, self->port);
            }
            croak(self->error);
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
            if(self->path) {
                snprintf(self->error, MAX_ERROR_SIZE, "Could not connect to Redis server at %s", self->path);
            } else {
                snprintf(self->error, MAX_ERROR_SIZE, "Could not connect to Redis server at %s:%d", self->hostname, self->port);
            }
            croak(self->error);
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

static redis_fast_reply_t Redis__Fast_decode_reply(Redis__Fast self, redisReply* reply, int collect_errors) {
    redis_fast_reply_t res = {NULL, NULL};

    switch (reply->type) {
    case REDIS_REPLY_ERROR:
        res.error = sv_2mortal(newSVpvn(reply->str, reply->len));
        if (self->is_utf8) {
            sv_utf8_decode(res.error);
        }
        break;
    case REDIS_REPLY_STRING:
    case REDIS_REPLY_STATUS:
        res.result = sv_2mortal(newSVpvn(reply->str, reply->len));
        if (self->is_utf8) {
            sv_utf8_decode(res.result);
        }
        break;

    case REDIS_REPLY_INTEGER:
        res.result = sv_2mortal(newSViv(reply->integer));
        break;
    case REDIS_REPLY_NIL:
        res.result = sv_2mortal(newSV(0));
        break;

    case REDIS_REPLY_ARRAY: {
        AV* av = (AV*)sv_2mortal((SV*)newAV());
        size_t i;
        res.result = newRV_inc((SV*)av);

        for (i = 0; i < reply->elements; i++) {
            redis_fast_reply_t elem = Redis__Fast_decode_reply(self, reply->element[i], collect_errors);
            if(collect_errors) {
                AV* elem_av = (AV*)sv_2mortal((SV*)newAV());
                if(elem.result) {
                    av_push(elem_av, SvREFCNT_inc(elem.result));
                } else {
                    av_push(elem_av, newSV(0));
                }
                if(elem.error) {
                    av_push(elem_av, SvREFCNT_inc(elem.error));
                } else {
                    av_push(elem_av, newSV(0));
                }
                av_push(av, newRV_inc((SV*)elem_av));
            } else {
                if(elem.result) {
                    av_push(av, SvREFCNT_inc(elem.result));
                } else {
                    av_push(av, newSV(0));
                }
                if(elem.error && !res.error) {
                    res.error = elem.error;
                }
            }
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
        if(cbt->custom_decode) {
            cbt->ret = (cbt->custom_decode)(self, (redisReply*)reply, cbt->collect_errors);
        } else {
            cbt->ret = Redis__Fast_decode_reply(self, (redisReply*)reply, cbt->collect_errors);
        }
    } else {
        self->need_recoonect = 1;
        cbt->ret.result = NULL;
        cbt->ret.error = sv_2mortal( newSVpvn(c->errstr, strlen(c->errstr)) );
    }
}

static void Redis__Fast_async_reply_cb(redisAsyncContext* c, void* reply, void* privdata) {
    Redis__Fast self = (Redis__Fast)c->data;
    redis_fast_async_cb_t *cbt = (redis_fast_async_cb_t*)privdata;
    redis_fast_reply_t result;
    SV* sv_undef;
    sv_undef = sv_2mortal(newSV(0));

    if (reply) {
        if(cbt->custom_decode) {
            result = (cbt->custom_decode)(self, (redisReply*)reply, cbt->collect_errors);
        } else {
            result = Redis__Fast_decode_reply(self, (redisReply*)reply, cbt->collect_errors);
        }

        if(result.result == NULL) result.result = sv_undef;
        if(result.error == NULL) result.error = sv_undef;

        {
            dSP;

            ENTER;
            SAVETMPS;

            PUSHMARK(SP);
            PUSHs(result.result);
            PUSHs(result.error);
            PUTBACK;

            call_sv(cbt->cb, G_DISCARD);

            FREETMPS;
            LEAVE;
        }
    }

    SvREFCNT_dec(cbt->cb);
    Safefree(cbt);
}

static redis_fast_reply_t  Redis__Fast_run_cmd(Redis__Fast self, int collect_errors, CUSTOM_DECODE custom_decode, SV* cb, int argc, const char** argv, size_t* argvlen) {
    redis_fast_reply_t ret = {NULL, NULL};
    if(cb) {
        redis_fast_async_cb_t *cbt;
        Newx(cbt, sizeof(redis_fast_async_cb_t), redis_fast_async_cb_t);
        cbt->cb = SvREFCNT_inc(cb);
        cbt->custom_decode = custom_decode;
        cbt->collect_errors = collect_errors;
        redisAsyncCommandArgv(
            self->ac, Redis__Fast_async_reply_cb, cbt,
            argc, argv, argvlen
            );
        ret.result = sv_2mortal(newSViv(1));
    } else {
        redis_fast_sync_cb_t cbt;
        int i, cnt = (self->reconnect == 0 ? 1 : 2);
        for(i = 0; i < cnt; i++) {
            self->need_recoonect = 0;
            cbt.ret.result = NULL;
            cbt.ret.error = NULL;
            cbt.custom_decode = custom_decode;
            cbt.collect_errors = collect_errors;
            redisAsyncCommandArgv(
                self->ac, Redis__Fast_sync_reply_cb, &cbt,
                argc, argv, argvlen
                );
            _wait_all_responses(self);
            if(!self->need_recoonect) return cbt.ret;
            Redis__Fast_reconnect(self);
        }
    }
    return ret;
}

static redis_fast_reply_t Redis__Fast_keys_custom_decode(Redis__Fast self, redisReply* reply, int collect_errors) {
    // TODO: Support redis <= 1.2.6
    return Redis__Fast_decode_reply(self, reply, collect_errors);
}

static redis_fast_reply_t Redis__Fast_info_custom_decode(Redis__Fast self, redisReply* reply, int collect_errors) {
    redis_fast_reply_t res = {NULL, NULL};
    if(reply->type == REDIS_REPLY_STRING ||
       reply->type == REDIS_REPLY_STATUS) {

        HV* hv = (HV*)sv_2mortal((SV*)newHV());
        char* str = reply->str;
        size_t len = reply->len;
        res.result = newRV_inc((SV*)hv);

        while(len != 0) {
            const char* line = (char*)memchr(str, '\r', len);
            const char* sep;
            size_t linelen;
            if(line == NULL) {
                linelen = len;
            } else {
                linelen = line - str;
            }
            sep = (char*)memchr(str, ':', linelen);
            if(str[0] != '#' && sep != NULL) {
                SV* val;
                size_t keylen;
                keylen = sep - str;
                val = newSVpvn(sep + 1, linelen - keylen - 1);
                if (self->is_utf8) {
                    sv_utf8_decode(val);
                }
                hv_store(hv, str, keylen, val, 0);
            }
            if(line == NULL) {
                break;
            } else {
                len -= linelen + 2;
                str += linelen + 2;
            }
        }
    } else {
        res = Redis__Fast_decode_reply(self, reply, collect_errors);
    }

    return res;
}

MODULE = Redis::Fast		PACKAGE = Redis::Fast

SV*
_new(char* cls);
PREINIT:
redis_fast_t* self;
CODE:
{
    Newxz(self, sizeof(redis_fast_t), redis_fast_t);
    self->error = (char*)malloc(MAX_ERROR_SIZE);
    ST(0) = sv_newmortal();
    sv_setref_pv(ST(0), cls, (void*)self);
    XSRETURN(1);
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


int
__sock(Redis::Fast self)
CODE:
{
    RETVAL = self->ac ? self->ac->c.fd : 0;
}

void
__set_on_connect(Redis::Fast self, SV* func)
CODE:
{
    self->on_connect = SvREFCNT_inc(func);
}

void
__set_data(Redis::Fast self, SV* data)
CODE:
{
    self->data = SvREFCNT_inc(data);
}

void
__get_data(Redis::Fast self)
CODE:
{
    ST(0) = self->data;
    XSRETURN(1);
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

    if(self->error) {
        free(self->error);
        self->error = NULL;
    }

    if(self->on_connect) {
        SvREFCNT_dec(self->on_connect);
        self->on_connect = NULL;
    }

    if(self->data) {
        SvREFCNT_dec(self->data);
        self->data = NULL;
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
    redis_fast_reply_t ret;
    SV* cb;
    char** argv;
    size_t* argvlen;
    STRLEN len;
    int argc, i, collect_errors;
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

    collect_errors = 0;
    if(cb && argvlen[0] == 4 && memcmp(argv[0], "EXEC", 4) == 0)
        collect_errors = 1;

    ret = Redis__Fast_run_cmd(self, collect_errors, NULL, cb, argc, (const char**)argv, argvlen);
    ST(0) = ret.result ? ret.result : sv_2mortal(newSV(0));
    ST(1) = ret.error ? ret.error : sv_2mortal(newSV(0));
    XSRETURN(2);

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
        cbt.ret.result = NULL;
        cbt.ret.error = NULL;
        cbt.custom_decode = NULL;
        redisAsyncCommand(
            self->ac, Redis__Fast_sync_reply_cb, &cbt, "PING"
            );
        _wait_all_responses(self);
        ST(0) = cbt.ret.result;
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
        cbt.ret.result = NULL;
        cbt.ret.error = NULL;
        cbt.custom_decode = NULL;
        redisAsyncCommand(
            self->ac, Redis__Fast_sync_reply_cb, &cbt, "QUIT"
            );
        redisAsyncDisconnect(self->ac);
        _wait_all_responses(self);
        ST(0) = cbt.ret.result;
        XSRETURN(1);
    } else {
        XSRETURN(0);
    }
}


SV*
shutdown(Redis::Fast self)
CODE:
{
    if(self->ac) {
        redisAsyncCommand(
            self->ac, NULL, NULL, "SHUTDOWN"
            );
        redisAsyncDisconnect(self->ac);
        _wait_all_responses(self);
        ST(0) = sv_2mortal(newSViv(1));
        XSRETURN(1);
    } else {
        XSRETURN(0);
    }
}


SV*
__keys(Redis::Fast self, ...)
PREINIT:
    redis_fast_reply_t ret;
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
        argc = items - 1;
    } else {
        cb = NULL;
        argc = items;
    }
    Newx(argv, sizeof(char*) * argc, char*);
    Newx(argvlen, sizeof(size_t) * argc, size_t);

    argv[0] = "KEYS";
    argvlen[0] = 4;
    for (i = 1; i < argc; i++) {
        if(self->is_utf8) {
            argv[i] = SvPVutf8(ST(i), len);
        } else {
            argv[i] = SvPV(ST(i), len);
        }
        argvlen[i] = len;
    }

    ret = Redis__Fast_run_cmd(self, 0, Redis__Fast_keys_custom_decode, cb, argc, (const char**)argv, argvlen);
    ST(0) = ret.result ? ret.result : sv_2mortal(newSV(0));
    ST(1) = ret.error ? ret.error : sv_2mortal(newSV(0));
    XSRETURN(2);

    Safefree(argv);
    Safefree(argvlen);
}


SV*
info(Redis::Fast self, ...)
PREINIT:
    redis_fast_reply_t ret;
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
        argc = items - 1;
    } else {
        cb = NULL;
        argc = items;
    }
    Newx(argv, sizeof(char*) * argc, char*);
    Newx(argvlen, sizeof(size_t) * argc, size_t);

    argv[0] = "INFO";
    argvlen[0] = 4;
    for (i = 1; i < argc; i++) {
        if(self->is_utf8) {
            argv[i] = SvPVutf8(ST(i), len);
        } else {
            argv[i] = SvPV(ST(i), len);
        }
        argvlen[i] = len;
    }

    ret = Redis__Fast_run_cmd(self, 0, Redis__Fast_info_custom_decode, cb, argc, (const char**)argv, argvlen);
    ST(0) = ret.result ? ret.result : sv_2mortal(newSV(0));
    XSRETURN(1);

    Safefree(argv);
    Safefree(argvlen);
}
