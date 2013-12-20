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
#include <sys/socket.h>

#define MAX_ERROR_SIZE 256

#define WAIT_FOR_EVENT_OK 0
#define WAIT_FOR_EVENT_TIMEDOUT 1
#define WAIT_FOR_EVENT_EXCEPTION 2

//#define DEBUG
#if defined(DEBUG)
#define DEBUG_MSG(fmt, ...) \
    do {                                                                \
        fprintf(stderr, "[%s:%d:%s]: ", __FILE__, __LINE__, __func__);    \
        fprintf(stderr, fmt, __VA_ARGS__);                              \
        fprintf(stderr, "\n");                                          \
    } while(0)
#else
#define DEBUG_MSG(fmt, ...)
#endif

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
    int proccess_sub_count;
    int is_subscriber;
    int expected_subs;
    pid_t pid;
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

typedef struct redis_fast_subscribe_cb_s {
    SV* cb;
} redis_fast_subscribe_cb_t;


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

static int wait_for_event(Redis__Fast self, double timeout) {
    redisContext *c;
    int fd;
    redis_fast_event_t *e;
    fd_set readfds, writefds, exceptfds;
    struct timeval t;
    int rc;

    if(self==NULL) return WAIT_FOR_EVENT_EXCEPTION;
    if(self->ac==NULL) return WAIT_FOR_EVENT_EXCEPTION;

    c = &(self->ac->c);
    fd = c->fd;
    e = (redis_fast_event_t*)self->ac->ev.data;
    if(e==NULL) return 0;

    t.tv_sec = (int)timeout;
    t.tv_usec = (timeout - (int)timeout) * 1000000;

    DEBUG_MSG("select start, timeout is %f", timeout);
    FD_ZERO(&readfds); if(e->flags & WAIT_FOR_READ) { FD_SET(fd, &readfds); }
    FD_ZERO(&writefds); if(e->flags & WAIT_FOR_WRITE) { FD_SET(fd, &writefds); }
    FD_ZERO(&exceptfds); FD_SET(fd, &exceptfds);
    rc = select(fd + 1, &readfds, &writefds, &exceptfds, timeout < 0 ? NULL : &t);
    if(rc<=0) {
        DEBUG_MSG("%s", "timeout");
        return WAIT_FOR_EVENT_TIMEDOUT;
    }

    if(FD_ISSET(fd, &exceptfds)) {
        DEBUG_MSG("%s", "exception!!");
        return WAIT_FOR_EVENT_EXCEPTION;
    }
    if(self->ac && FD_ISSET(fd, &readfds)) {
        DEBUG_MSG("ready to %s", "read");
        redisAsyncHandleRead(self->ac);
    }
    if(self->ac && FD_ISSET(fd, &writefds)) {
        DEBUG_MSG("ready to %s", "write");
        redisAsyncHandleWrite(self->ac);
    }

    DEBUG_MSG("%s", "finish");
    return WAIT_FOR_EVENT_OK;
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
    PERL_UNUSED_VAR(status);
    self->ac = NULL;
}

static redisAsyncContext* __build_sock(Redis__Fast self)
{
    redisAsyncContext *ac;
    DEBUG_MSG("%s", "start");

    if(self->path) {
        ac = redisAsyncConnectUnix(self->path);
    } else {
        ac = redisAsyncConnect(self->hostname, self->port);
    }

    if(!ac) {
        DEBUG_MSG("%s", "fail to allocate");
        return NULL;
    }
    ac->data = (void*)self;
    self->ac = ac;

    Attach(ac);
    redisAsyncSetConnectCallback(ac, (redisConnectCallback*)Redis__Fast_connect_cb);
    redisAsyncSetDisconnectCallback(ac, (redisDisconnectCallback*)Redis__Fast_disconnect_cb);

    // wait to connect...
    int res = wait_for_event(self, self->reconnect ? self->reconnect : -1);
    if(res != WAIT_FOR_EVENT_OK) {
        DEBUG_MSG("error: %d", res);
        redisAsyncFree(self->ac);
        self->ac = NULL;
        return NULL;
    }

    DEBUG_MSG("%s", "finsih");
    return self->ac;
}


static int _wait_all_responses(Redis__Fast self) {
    DEBUG_MSG("%s", "start");
    while(self->ac && self->ac->replies.tail) {
        int res = wait_for_event(self, -1);
        if (res != WAIT_FOR_EVENT_OK) {
            DEBUG_MSG("error: %d", res);
            return res;
        }
    }
    DEBUG_MSG("%s", "finish");
    return WAIT_FOR_EVENT_OK;
}


static void Redis__Fast_connect(Redis__Fast self) {
    struct timeval start, end;

    DEBUG_MSG("%s", "start");

    if (self->ac) {
        redisAsyncFree(self->ac);
        self->ac = NULL;
    }

    //$self->{queue} = [];
    self->pid = getpid();

    if(self->reconnect == 0) {
        __build_sock(self);
        if(!self->ac) {
            if(self->path) {
                snprintf(self->error, MAX_ERROR_SIZE, "Could not connect to Redis server at %s", self->path);
            } else {
                snprintf(self->error, MAX_ERROR_SIZE, "Could not connect to Redis server at %s:%d", self->hostname, self->port);
            }
            croak("%s", self->error);
        }
        return ;
    }

    // Reconnect...
    gettimeofday(&start, NULL);
    while (1) {
        double elapsed_time;
        if(__build_sock(self)) {
            // Connected!
            DEBUG_MSG("%s", "finish");
            return;
        }
        gettimeofday(&end, NULL);
        elapsed_time = (end.tv_sec-start.tv_sec) + 1E-6 * (end.tv_usec-start.tv_usec);
        DEBUG_MSG("elasped time:%f, reconnect:%d", elapsed_time, self->reconnect);
        if( elapsed_time > self->reconnect) {
            if(self->path) {
                snprintf(self->error, MAX_ERROR_SIZE, "Could not connect to Redis server at %s", self->path);
            } else {
                snprintf(self->error, MAX_ERROR_SIZE, "Could not connect to Redis server at %s:%d", self->hostname, self->port);
            }
            DEBUG_MSG("%s", "timed out");
            croak("%s", self->error);
            return;
        }
        DEBUG_MSG("%s", "failed to connect. wait...");
        usleep(self->every);
    }
    DEBUG_MSG("%s", "finish");
}

static void Redis__Fast_reconnect(Redis__Fast self) {
    DEBUG_MSG("%s", "start");
    if(!self->ac && self->reconnect) {
        DEBUG_MSG("%s", "connection not found. reconnect");
        Redis__Fast_connect(self);
    }
    if(!self->ac) {
        croak("Not connected to any server");
    }
    DEBUG_MSG("%s", "finish");
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
        AV* av = newAV();
        size_t i;
        res.result = sv_2mortal(newRV_noinc((SV*)av));

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
    DEBUG_MSG("%p", (void*)privdata);
    if(reply) {
        if(cbt->custom_decode) {
            cbt->ret = (cbt->custom_decode)(self, (redisReply*)reply, cbt->collect_errors);
        } else {
            cbt->ret = Redis__Fast_decode_reply(self, (redisReply*)reply, cbt->collect_errors);
        }
    } else {
        DEBUG_MSG("connect error: %s", c->errstr);
        self->need_recoonect = 1;
        cbt->ret.result = NULL;
        cbt->ret.error = sv_2mortal( newSVpvn(c->errstr, strlen(c->errstr)) );
    }
    DEBUG_MSG("%s", "finish");
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

static void Redis__Fast_subscribe_cb(redisAsyncContext* c, void* reply, void* privdata) {
    Redis__Fast self = (Redis__Fast)c->data;
    redis_fast_subscribe_cb_t *cbt = (redis_fast_subscribe_cb_t*)privdata;
    redisReply* r = (redisReply*)reply;
    SV* sv_undef;
    sv_undef = sv_2mortal(newSV(0));

    DEBUG_MSG("%s", "start");

    if (r) {
        char* stype = r->element[0]->str;
        int pvariant = (tolower(stype[0]) == 'p') ? 1 : 0;
        redis_fast_reply_t res = Redis__Fast_decode_reply(self, r, 0);

        if (strcasecmp(stype+pvariant,"subscribe") == 0) {
            DEBUG_MSG("%s %s %lld", r->element[0]->str, r->element[1]->str, r->element[2]->integer);
            self->is_subscriber = r->element[2]->integer;
            self->expected_subs--;
        } else if (strcasecmp(stype+pvariant,"unsubscribe") == 0) {
            DEBUG_MSG("%s %s %lld", r->element[0]->str, r->element[1]->str, r->element[2]->integer);
            self->is_subscriber = r->element[2]->integer;
        } else {
            DEBUG_MSG("%s %s", r->element[0]->str, r->element[1]->str);
            self->proccess_sub_count++;
        }

        if(res.result == NULL) res.result = sv_undef;
        if(res.error == NULL) res.error = sv_undef;

        {
            dSP;

            ENTER;
            SAVETMPS;

            PUSHMARK(SP);
            PUSHs(res.result);
            PUSHs(res.error);
            PUTBACK;

            call_sv(cbt->cb, G_DISCARD);

            FREETMPS;
            LEAVE;
        }
    } else {
        // destroy private data
        DEBUG_MSG("connect error: %s", c->errstr);
        DEBUG_MSG("destroy %p", cbt);
        SvREFCNT_dec(cbt->cb);
        Safefree(cbt);
    }
    DEBUG_MSG("%s", "finish");
}


static redis_fast_reply_t  Redis__Fast_run_cmd(Redis__Fast self, int collect_errors, CUSTOM_DECODE custom_decode, SV* cb, int argc, const char** argv, size_t* argvlen) {
    redis_fast_reply_t ret = {NULL, NULL};

    DEBUG_MSG("start %s", argv[0]);

    if(self->pid != getpid()) {
        Redis__Fast_connect(self);
    }

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
            int res;
            self->need_recoonect = 0;
            cbt.ret.result = NULL;
            cbt.ret.error = NULL;
            cbt.custom_decode = custom_decode;
            cbt.collect_errors = collect_errors;
            redisAsyncCommandArgv(
                self->ac, Redis__Fast_sync_reply_cb, &cbt,
                argc, argv, argvlen
                );
            res = _wait_all_responses(self);
            if(res == WAIT_FOR_EVENT_OK && !self->need_recoonect) {
                DEBUG_MSG("finish %s", argv[0]);
                return cbt.ret;
            }
            Redis__Fast_reconnect(self);
        }
    }
    DEBUG_MSG("finish %s", argv[0]);
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
OUTPUT:
    RETVAL


int
__get_reconnect(Redis::Fast self)
CODE:
{
    RETVAL = self->reconnect;
}
OUTPUT:
    RETVAL


int
__set_every(Redis::Fast self, int val)
CODE:
{
    RETVAL = self->every = val;
}
OUTPUT:
    RETVAL


int
__get_every(Redis::Fast self)
CODE:
{
    RETVAL = self->every;
}
OUTPUT:
    RETVAL


int
__set_utf8(Redis::Fast self, int val)
CODE:
{
    RETVAL = self->is_utf8 = val;
}
OUTPUT:
    RETVAL


int
__get_utf8(Redis::Fast self)
CODE:
{
    RETVAL = self->is_utf8;
}
OUTPUT:
    RETVAL


int
__sock(Redis::Fast self)
CODE:
{
    RETVAL = self->ac ? self->ac->c.fd : 0;
}
OUTPUT:
    RETVAL


int
__get_port(Redis::Fast self)
CODE:
{
    struct sockaddr_in addr;
    socklen_t len;
    len = sizeof( addr );
    getsockname( self->ac->c.fd, ( struct sockaddr *)&addr, &len );
    RETVAL = addr.sin_port;
}
OUTPUT:
    RETVAL


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
is_subscriber(Redis::Fast self)
CODE:
{
    ST(0) = sv_2mortal(newSViv(self->is_subscriber));
    XSRETURN(1);
}


void
DESTROY(Redis::Fast self);
CODE:
{
    DEBUG_MSG("%s", "start");
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
    DEBUG_MSG("%s", "finish");
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
    int res = _wait_all_responses(self);
    if(res != WAIT_FOR_EVENT_OK) {
        croak("Error while reading from Redis server");
    }
}


void
wait_one_response(Redis::Fast self)
CODE:
{
    int res = _wait_all_responses(self);
    if(res != WAIT_FOR_EVENT_OK) {
        croak("Error while reading from Redis server");
    }
}


void
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

    Safefree(argv);
    Safefree(argvlen);

    ST(0) = ret.result ? ret.result : sv_2mortal(newSV(0));
    ST(1) = ret.error ? ret.error : sv_2mortal(newSV(0));
    XSRETURN(2);
}


void
__quit(Redis::Fast self)
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
        if(_wait_all_responses(self) == WAIT_FOR_EVENT_OK) {
            ST(0) = cbt.ret.result;
            XSRETURN(1);
        } else {
            XSRETURN(0);
        }
    } else {
        XSRETURN(0);
    }
}


void
__shutdown(Redis::Fast self)
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


void
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
    Safefree(argv);
    Safefree(argvlen);

    ST(0) = ret.result ? ret.result : sv_2mortal(newSV(0));
    ST(1) = ret.error ? ret.error : sv_2mortal(newSV(0));
    XSRETURN(2);
}


void
__info(Redis::Fast self, ...)
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
    Safefree(argv);
    Safefree(argvlen);

    ST(0) = ret.result ? ret.result : sv_2mortal(newSV(0));
    ST(1) = ret.error ? ret.error : sv_2mortal(newSV(0));
    XSRETURN(2);
}


void
__send_subscription_cmd(Redis::Fast self, ...)
PREINIT:
    SV* cb;
    char** argv;
    size_t* argvlen;
    STRLEN len;
    int argc, i;
    redis_fast_subscribe_cb_t* cbt;
    int pvariant;
CODE:
{
    DEBUG_MSG("%s", "start");

    Redis__Fast_reconnect(self);
    if(!self->is_subscriber) {
        _wait_all_responses(self);
    }
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
            argv[i] = SvPVutf8(ST(i+1), len);
        } else {
            argv[i] = SvPV(ST(i+1), len);
        }
        argvlen[i] = len;
        DEBUG_MSG("argv[%d] = %s", i, argv[i]);
    }

    pvariant = (tolower(argv[0][0]) == 'p') ? 1 : 0;
    if (strcasecmp(argv[0]+pvariant,"unsubscribe") != 0) {
        Newx(cbt, sizeof(redis_fast_subscribe_cb_t), redis_fast_subscribe_cb_t);
        cbt->cb = SvREFCNT_inc(cb);
    } else {
        cbt = NULL;
    }
    redisAsyncCommandArgv(
        self->ac, cbt ? Redis__Fast_subscribe_cb : NULL, cbt,
        argc, (const char**)argv, argvlen
        );
    self->expected_subs = argc - 1;
    while(self->expected_subs > 0 && wait_for_event(self, 1) == WAIT_FOR_EVENT_OK) ;

    Safefree(argv);
    Safefree(argvlen);
    DEBUG_MSG("%s", "finish");
    XSRETURN(0);
}

void
wait_for_messages(Redis::Fast self, double timeout = -1)
CODE:
{
    DEBUG_MSG("%s", "start");
    self->proccess_sub_count = 0;
    while(wait_for_event(self, timeout) == WAIT_FOR_EVENT_OK) ;
    ST(0) = sv_2mortal(newSViv(self->proccess_sub_count));
    DEBUG_MSG("%s", "finish");
    XSRETURN(1);
}
