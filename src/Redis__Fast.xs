#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"
#include "hiredis.h"
#include "async.h"

// a compatible layer of <poll.h>, <sys/socket.h>, etc. from hiredis
#include "sockcompat.h"

#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <stdio.h>

#define MAX_ERROR_SIZE 256

#define WAIT_FOR_EVENT_OK 0
#define WAIT_FOR_EVENT_READ_TIMEOUT 1
#define WAIT_FOR_EVENT_WRITE_TIMEOUT 2
#define WAIT_FOR_EVENT_EXCEPTION 3

#define FLAG_INSIDE_TRANSACTION 0x01
#define FLAG_INSIDE_WATCH       0x02

#define DEBUG_MSG(fmt, ...) \
    if (self->debug) {                                                  \
        fprintf(stderr, "[%s:%d:%s]: ", __FILE__, __LINE__, __func__);  \
        fprintf(stderr, fmt, __VA_ARGS__);                              \
        fprintf(stderr, "\n");                                          \
    }

#define EQUALS_COMMAND(len, cmd, expected) ((len) == sizeof(expected) - 1 && memcmp(cmd, expected, sizeof(expected) - 1) == 0)

typedef struct redis_fast_s {
    redisAsyncContext* ac;
    char* hostname;
    int port;
    char* path;
    char* error;
    double reconnect;
    int every;
    int debug;
    double cnx_timeout;
    double read_timeout;
    double write_timeout;
    int current_database;
    int need_reconnect;
    int is_connected;
    SV* on_connect;
    SV* on_build_sock;
    SV* data;
    SV* reconnect_on_error;
    double next_reconnect_on_error_at;
    int proccess_sub_count;
    int is_subscriber;
    int expected_subs;
    pid_t pid;
    int flags;
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
    int on_flags;
    int off_flags;
} redis_fast_sync_cb_t;

typedef struct redis_fast_async_cb_s {
    SV* cb;
    int collect_errors;
    CUSTOM_DECODE custom_decode;
    int on_flags;
    int off_flags;
    const void* command_name;
    STRLEN command_length;
} redis_fast_async_cb_t;

typedef struct redis_fast_subscribe_cb_s {
    Redis__Fast self;
    SV* cb;
} redis_fast_subscribe_cb_t;


#define WAIT_FOR_READ  0x01
#define WAIT_FOR_WRITE 0x02
typedef struct redis_fast_event_s {
    int flags;
    Redis__Fast self;
} redis_fast_event_t;


static void AddRead(void *privdata) {
    redis_fast_event_t *e = (redis_fast_event_t*)privdata;
    Redis__Fast self = e->self;
    e->flags |= WAIT_FOR_READ;
    DEBUG_MSG("flags = %x", e->flags);
}

static void DelRead(void *privdata) {
    redis_fast_event_t *e = (redis_fast_event_t*)privdata;
    Redis__Fast self = e->self;
    e->flags &= ~WAIT_FOR_READ;
    DEBUG_MSG("flags = %x", e->flags);
}

static void AddWrite(void *privdata) {
    redis_fast_event_t *e = (redis_fast_event_t*)privdata;
    Redis__Fast self = e->self;
    e->flags |= WAIT_FOR_WRITE;
    DEBUG_MSG("flags = %x", e->flags);
}

static void DelWrite(void *privdata) {
    redis_fast_event_t *e = (redis_fast_event_t*)privdata;
    Redis__Fast self = e->self;
    e->flags &= ~WAIT_FOR_WRITE;
    DEBUG_MSG("flags = %x", e->flags);
}

static void Cleanup(void *privdata) {
    free(privdata);
}

static int Attach(redisAsyncContext *ac) {
    Redis__Fast self = (Redis__Fast)ac->data;
    redis_fast_event_t *e;

    /* Nothing should be attached when something is already attached */
    if (ac->ev.data != NULL)
        return REDIS_ERR;

    /* Create container for context and r/w events */
    e = (redis_fast_event_t*)malloc(sizeof(*e));
    e->flags = 0;
    e->self = self;

    /* Register functions to start/stop listening for events */
    ac->ev.addRead = AddRead;
    ac->ev.delRead = DelRead;
    ac->ev.addWrite = AddWrite;
    ac->ev.delWrite = DelWrite;
    ac->ev.cleanup = Cleanup;
    ac->ev.data = e;

    return REDIS_OK;
}

static int wait_for_event(Redis__Fast self, double read_timeout, double write_timeout) {
    redisContext *c;
    int fd;
    redis_fast_event_t *e;
    struct pollfd pollfd;
    int rc;
    double timeout = -1;
    int timeout_mode = WAIT_FOR_EVENT_WRITE_TIMEOUT;
    int ms;

    if(self==NULL) return WAIT_FOR_EVENT_EXCEPTION;
    if(self->ac==NULL) return WAIT_FOR_EVENT_EXCEPTION;

    c = &(self->ac->c);
    fd = c->fd;
    e = (redis_fast_event_t*)self->ac->ev.data;
    if(e==NULL) return 0;

    if((e->flags & (WAIT_FOR_READ|WAIT_FOR_WRITE)) == (WAIT_FOR_READ|WAIT_FOR_WRITE)) {
        DEBUG_MSG("set READ and WRITE, compare read_timeout = %f and write_timeout = %f",
                  read_timeout, write_timeout);
        if(read_timeout < 0 && write_timeout < 0) {
            timeout = -1;
            timeout_mode = WAIT_FOR_EVENT_WRITE_TIMEOUT;
        } else if(read_timeout < 0) {
            timeout = write_timeout;
            timeout_mode = WAIT_FOR_EVENT_WRITE_TIMEOUT;
        } else if(write_timeout < 0) {
            timeout = read_timeout;
            timeout_mode = WAIT_FOR_EVENT_READ_TIMEOUT;
        } else if(read_timeout < write_timeout) {
            timeout = read_timeout;
            timeout_mode = WAIT_FOR_EVENT_READ_TIMEOUT;
        } else {
            timeout = write_timeout;
            timeout_mode = WAIT_FOR_EVENT_WRITE_TIMEOUT;
        }
    } else if(e->flags & WAIT_FOR_READ) {
        DEBUG_MSG("set READ, read_timeout = %f", read_timeout);
        timeout = read_timeout;
        timeout_mode = WAIT_FOR_EVENT_READ_TIMEOUT;
    } else if(e->flags & WAIT_FOR_WRITE) {
        DEBUG_MSG("set WRITE, write_timeout = %f", write_timeout);
        timeout = write_timeout;
        timeout_mode = WAIT_FOR_EVENT_WRITE_TIMEOUT;
    }

  START_POLL:
    if (timeout < 0) {
        ms = -1;
    } else {
        ms = (int)(timeout * 1000 + 0.999);
    }
    DEBUG_MSG("select start, timeout is %f", timeout);
    pollfd.fd = fd;
    pollfd.events = 0;
    pollfd.revents = 0;
    if(e->flags & WAIT_FOR_READ) { pollfd.events |= POLLIN; }
    if(e->flags & WAIT_FOR_WRITE) { pollfd.events |= POLLOUT; }
    rc = poll(&pollfd, 1, ms);
    DEBUG_MSG("poll returns %d", rc);
    if(rc == 0) {
        DEBUG_MSG("%s", "timeout");
        return timeout_mode;
    }

    if(rc < 0) {
        DEBUG_MSG("exception: %s", strerror(errno));
        if( errno == EINTR ) {
            PERL_ASYNC_CHECK();
            DEBUG_MSG("%s", "recieved interrupt. retry wait_for_event");
            goto START_POLL;
        }
        return WAIT_FOR_EVENT_EXCEPTION;
    }
    if(self->ac && (pollfd.revents & POLLIN) != 0) {
        DEBUG_MSG("ready to %s", "read");
        redisAsyncHandleRead(self->ac);
    }
    if(self->ac && (pollfd.revents & (POLLOUT|POLLHUP)) != 0) {
        DEBUG_MSG("ready to %s", "write");
        redisAsyncHandleWrite(self->ac);
    }
    if((pollfd.revents & (POLLERR|POLLNVAL)) != 0) {
        DEBUG_MSG(
            "exception: %s%s",
            (pollfd.revents & POLLERR) ? "POLLERR " : "",
            (pollfd.revents & POLLNVAL) ? "POLLNVAL " : "");
        return WAIT_FOR_EVENT_EXCEPTION;
    }

    DEBUG_MSG("%s", "finish");
    return WAIT_FOR_EVENT_OK;
}

static void Redis__Fast_connect_cb(redisAsyncContext* c, int status) {
    Redis__Fast self = (Redis__Fast)c->data;
    DEBUG_MSG("connected status = %d", status);
    if(status != REDIS_OK) {
        // Connection Error!!
        // Redis context will close automatically
        self->ac = NULL;
    } else {
        self->is_connected = 1;
    }
}

static void Redis__Fast_disconnect_cb(redisAsyncContext* c, int status) {
    Redis__Fast self = (Redis__Fast)c->data;
    PERL_UNUSED_VAR(status);
    DEBUG_MSG("disconnected status = %d", status);
    self->ac = NULL;
}

static redisAsyncContext* __build_sock(Redis__Fast self)
{
    redisAsyncContext *ac;
    double timeout;
    int res;

    DEBUG_MSG("%s", "start");

    if(self->on_build_sock) {
        dSP;

        ENTER;
        SAVETMPS;

        PUSHMARK(SP);
        call_sv(self->on_build_sock, G_DISCARD | G_NOARGS);

        FREETMPS;
        LEAVE;
    }

    if(self->path) {
        ac = redisAsyncConnectUnix(self->path);
    } else {
        ac = redisAsyncConnect(self->hostname, self->port);
    }

    if(ac == NULL) {
        DEBUG_MSG("%s", "allocation error");
        return NULL;
    }
    if(ac->err) {
        DEBUG_MSG("connection error: %s", ac->errstr);
	redisAsyncFree(ac);
        return NULL;
    }
    ac->data = (void*)self;
    self->ac = ac;
    self->is_connected = 0;

    Attach(ac);
    redisAsyncSetConnectCallback(ac, (redisConnectCallback*)Redis__Fast_connect_cb);
    redisAsyncSetDisconnectCallback(ac, (redisDisconnectCallback*)Redis__Fast_disconnect_cb);

    // wait to connect...
    timeout = -1;
    if(self->cnx_timeout) {
        timeout = self->cnx_timeout;
    }
    while(!self->is_connected) {
        res = wait_for_event(self, timeout, timeout);
        if(self->ac == NULL) {
            // set is_connected flag to reconnect.
            // see https://github.com/shogo82148/Redis-Fast/issues/73
            self->is_connected = 1;

            return NULL;
        }
        if(res != WAIT_FOR_EVENT_OK) {
            DEBUG_MSG("error: %d", res);
            redisAsyncFree(self->ac);

            // set is_connected flag to reconnect.
            // see https://github.com/shogo82148/Redis-Fast/issues/73
            self->is_connected = 1;

            self->ac = NULL;
            return NULL;
        }
    }
    if(self->on_connect){
        dSP;
        PUSHMARK(SP);
        call_sv(self->on_connect, G_DISCARD | G_NOARGS);
    }

    DEBUG_MSG("%s", "finsih");
    return self->ac;
}


static int _wait_all_responses(Redis__Fast self) {
    DEBUG_MSG("%s", "start");
    while(self->ac && self->ac->replies.tail) {
        int res = wait_for_event(self, self->read_timeout, self->write_timeout);
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
    self->flags = 0;

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
        DEBUG_MSG("elasped time:%f, reconnect:%lf", elapsed_time, self->reconnect);
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
    if(self->is_connected && !self->ac && self->reconnect > 0) {
        DEBUG_MSG("%s", "connection not found. reconnect");
        Redis__Fast_connect(self);
    }
    if(!self->ac) {
        DEBUG_MSG("%s", "Not connected to any server");
    }
    DEBUG_MSG("%s", "finish");
}

static redis_fast_reply_t Redis__Fast_decode_reply(Redis__Fast self, redisReply* reply, int collect_errors) {
    redis_fast_reply_t res = {NULL, NULL};

    switch (reply->type) {
    case REDIS_REPLY_ERROR:
        res.error = sv_2mortal(newSVpvn(reply->str, reply->len));
        break;
    case REDIS_REPLY_STRING:
    case REDIS_REPLY_STATUS:
        res.result = sv_2mortal(newSVpvn(reply->str, reply->len));
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

static int Redis__Fast_call_reconnect_on_error(Redis__Fast self, redis_fast_reply_t ret, const void *command_name, STRLEN command_length) {
    int _need_reconnect = 0;
    struct timeval current;
    double current_sec;
    SV* sv_ret;
    SV* sv_err;
    SV* sv_cmd;
    int count;

    if (ret.error == NULL) {
        return _need_reconnect;
    }
    if (self->reconnect_on_error == NULL) {
        return _need_reconnect;
    }

    gettimeofday(&current, NULL);
    current_sec = current.tv_sec + 1E-6 * current.tv_usec;
    if( self->next_reconnect_on_error_at < 0 ||
            self->next_reconnect_on_error_at < current_sec) {
        dSP;
        ENTER;
        SAVETMPS;

        sv_ret = ret.result ? ret.result : sv_2mortal(newSV(0));
        sv_err = ret.error;
        sv_cmd = sv_2mortal(newSVpvn((const char*)command_name, command_length));

        PUSHMARK(SP);
        XPUSHs(sv_err);
        XPUSHs(sv_ret);
        XPUSHs(sv_cmd);
        PUTBACK;

        count = call_sv(self->reconnect_on_error, G_SCALAR);

        SPAGAIN;

        if (count != 1) {
            croak("[BUG] retval count should be 1\n");
        }
        _need_reconnect = POPi;

        PUTBACK;
        FREETMPS;
        LEAVE;
    }

    return _need_reconnect;
}

static void Redis__Fast_sync_reply_cb(redisAsyncContext* c, void* reply, void* privdata) {
    Redis__Fast self = (Redis__Fast)c->data;
    redis_fast_sync_cb_t *cbt = (redis_fast_sync_cb_t*)privdata;
    DEBUG_MSG("%p", (void*)privdata);
    if(reply) {
        self->flags = (self->flags | cbt->on_flags) & cbt->off_flags;
        if(cbt->custom_decode) {
            cbt->ret = (cbt->custom_decode)(self, (redisReply*)reply, cbt->collect_errors);
        } else {
            cbt->ret = Redis__Fast_decode_reply(self, (redisReply*)reply, cbt->collect_errors);
        }
    } else if(c->c.flags & REDIS_FREEING) {
        DEBUG_MSG("%s", "redis feeing");
        Safefree(cbt);
    } else {
        DEBUG_MSG("connect error: %s", c->errstr);
        self->need_reconnect = 1;
        cbt->ret.result = NULL;
        cbt->ret.error = sv_2mortal( newSVpvn(c->errstr, strlen(c->errstr)) );
    }
    DEBUG_MSG("%s", "finish");
}

static void Redis__Fast_async_reply_cb(redisAsyncContext* c, void* reply, void* privdata) {
    Redis__Fast self = (Redis__Fast)c->data;
    redis_fast_async_cb_t *cbt = (redis_fast_async_cb_t*)privdata;
    if (reply) {
        self->flags = (self->flags | cbt->on_flags) & cbt->off_flags;

        {
            redis_fast_reply_t result;
            SV* sv_undef;

            dSP;

            ENTER;
            SAVETMPS;

            if(cbt->custom_decode) {
                result = (cbt->custom_decode)(self, (redisReply*)reply, cbt->collect_errors);
            } else {
                result = Redis__Fast_decode_reply(self, (redisReply*)reply, cbt->collect_errors);
            }

            sv_undef = sv_2mortal(newSV(0));
            if(result.result == NULL) result.result = sv_undef;
            if(result.error == NULL) result.error = sv_undef;

            PUSHMARK(SP);
            XPUSHs(result.result);
            XPUSHs(result.error);
            PUTBACK;

            call_sv(cbt->cb, G_DISCARD);

            FREETMPS;
            LEAVE;
        }

        {
            if (0 < self->reconnect && !self->need_reconnect
                // Avoid useless cost when reconnect_on_error is not set.
                && self->reconnect_on_error != NULL) {
                redis_fast_reply_t result;
                if(cbt->custom_decode) {
                    result = (cbt->custom_decode)(
                        self, (redisReply*)reply, cbt->collect_errors
                    );
                } else {
                    result = Redis__Fast_decode_reply(
                        self, (redisReply*)reply, cbt->collect_errors
                    );
                }
                self->need_reconnect = Redis__Fast_call_reconnect_on_error(
                    self, result, cbt->command_name, cbt->command_length
                );
            }
        }
    }

    SvREFCNT_dec(cbt->cb);
    Safefree(cbt);
}

static void Redis__Fast_subscribe_cb(redisAsyncContext* c, void* reply, void* privdata) {
    int is_need_free = 0;
    Redis__Fast self = (Redis__Fast)c->data;
    redis_fast_subscribe_cb_t *cbt = (redis_fast_subscribe_cb_t*)privdata;
    redisReply* r = (redisReply*)reply;
    SV* sv_undef;

    DEBUG_MSG("%s", "start");
    if(!cbt) {
        DEBUG_MSG("%s", "cbt is empty finished");
        return ;
    }

    if (r) {
        char* stype = r->element[0]->str;
        int pvariant = (tolower(stype[0]) == 'p') ? 1 : 0;
        redis_fast_reply_t res;

        dSP;
        ENTER;
        SAVETMPS;

        res = Redis__Fast_decode_reply(self, r, 0);

        if (strcasecmp(stype+pvariant,"subscribe") == 0) {
            DEBUG_MSG("%s %s %lld", r->element[0]->str, r->element[1]->str, r->element[2]->integer);
            self->is_subscriber = r->element[2]->integer;
            self->expected_subs--;
        } else if (strcasecmp(stype+pvariant,"unsubscribe") == 0) {
            DEBUG_MSG("%s %s %lld", r->element[0]->str, r->element[1]->str, r->element[2]->integer);
            self->is_subscriber = r->element[2]->integer;
            is_need_free = 1;
            self->expected_subs--;
        } else {
            DEBUG_MSG("%s %s", r->element[0]->str, r->element[1]->str);
            self->proccess_sub_count++;
        }

        sv_undef = sv_2mortal(newSV(0));
        if(res.result == NULL) res.result = sv_undef;
        if(res.error == NULL) res.error = sv_undef;

        PUSHMARK(SP);
        XPUSHs(res.result);
        XPUSHs(res.error);
        PUTBACK;

        call_sv(cbt->cb, G_DISCARD);

        FREETMPS;
        LEAVE;
    } else {
        DEBUG_MSG("connect error: %s", c->errstr);
        is_need_free = 1;
    }

    if(is_need_free) {
        // destroy private data
        DEBUG_MSG("destroy %p", cbt);
        if(cbt->cb) {
            SvREFCNT_dec(cbt->cb);
            cbt->cb = NULL;
        }
        Safefree(cbt);
    }
    DEBUG_MSG("%s", "finish");
}

static void Redis__Fast_quit(Redis__Fast self) {
    redis_fast_sync_cb_t *cbt;

    if(!self->ac) {
        return;
    }

    Newx(cbt, sizeof(redis_fast_sync_cb_t), redis_fast_sync_cb_t);
    cbt->ret.result = NULL;
    cbt->ret.error = NULL;
    cbt->custom_decode = NULL;

    // initialize, or self->flags will be corrupted.
    cbt->on_flags = 0;
    cbt->off_flags = 0;

    redisAsyncCommand(
        self->ac, Redis__Fast_sync_reply_cb, cbt, "QUIT"
        );
    redisAsyncDisconnect(self->ac);
    if(_wait_all_responses(self) == WAIT_FOR_EVENT_OK) {
        DEBUG_MSG("%s", "wait_all_responses ok");
        if(cbt->ret.result || cbt->ret.error) Safefree(cbt);
    } else {
        DEBUG_MSG("%s", "wait_all_responses not ok");
        if(cbt->ret.result || cbt->ret.error) Safefree(cbt);
    }
    DEBUG_MSG("%s", "finish");
    self->ac = NULL;
}

static redis_fast_reply_t  Redis__Fast_run_cmd(Redis__Fast self, int collect_errors, CUSTOM_DECODE custom_decode, SV* cb, int argc, const char** argv, size_t* argvlen) {
    redis_fast_reply_t ret = {NULL, NULL};
    int on_flags = 0, off_flags = ~0;

    DEBUG_MSG("start %s", argv[0]);

    DEBUG_MSG("pid check: previous pid is %d, now %d", self->pid, getpid());
    if(self->pid != getpid()) {
        DEBUG_MSG("%s", "pid changed. create new connection..");
        Redis__Fast_connect(self);
    }

    if(EQUALS_COMMAND(argvlen[0], argv[0], "MULTI")) {
        on_flags = FLAG_INSIDE_TRANSACTION;
    } else if(EQUALS_COMMAND(argvlen[0], argv[0], "EXEC") ||
              EQUALS_COMMAND(argvlen[0], argv[0], "DISCARD")) {
        off_flags = ~(FLAG_INSIDE_TRANSACTION | FLAG_INSIDE_WATCH);
    } else if(EQUALS_COMMAND(argvlen[0], argv[0], "WATCH")) {
        on_flags = FLAG_INSIDE_WATCH;
    } else if(EQUALS_COMMAND(argvlen[0], argv[0], "UNWATCH")) {
        off_flags = ~FLAG_INSIDE_WATCH;
    }

    if(cb) {
        redis_fast_async_cb_t *cbt;
        Newx(cbt, sizeof(redis_fast_async_cb_t), redis_fast_async_cb_t);
        cbt->cb = SvREFCNT_inc(cb);
        cbt->custom_decode = custom_decode;
        cbt->collect_errors = collect_errors;
        cbt->on_flags = on_flags;
        cbt->off_flags = off_flags;
        cbt->command_name = argv[0];
        cbt->command_length = argvlen[0];
        redisAsyncCommandArgv(
            self->ac, Redis__Fast_async_reply_cb, cbt,
            argc, argv, argvlen
            );
        ret.result = sv_2mortal(newSViv(1));
    } else {
        redis_fast_sync_cb_t *cbt;
        int i, cnt = (self->reconnect == 0 ? 1 : 2);
        int res = WAIT_FOR_EVENT_OK;
        for(i = 0; i < cnt; i++) {
            Newx(cbt, sizeof(redis_fast_sync_cb_t), redis_fast_sync_cb_t);
            self->need_reconnect = 0;
            cbt->ret.result = NULL;
            cbt->ret.error = NULL;
            cbt->custom_decode = custom_decode;
            cbt->collect_errors = collect_errors;
            cbt->on_flags = on_flags;
            cbt->off_flags = off_flags;
            DEBUG_MSG("%s", "send command in sync mode");
            redisAsyncCommandArgv(
                self->ac, Redis__Fast_sync_reply_cb, cbt,
                argc, argv, argvlen
                );
            DEBUG_MSG("%s", "waiting response");
            res = _wait_all_responses(self);
            if(res == WAIT_FOR_EVENT_OK && self->need_reconnect == 0) {
                int _need_reconnect = 0;
                if (1 < cnt - i) {
                    _need_reconnect = Redis__Fast_call_reconnect_on_error(
                        self, cbt->ret, argv[0], argvlen[0]
                    );
                    // Should be quit before reconnect
                    if (_need_reconnect) {
                        Redis__Fast_quit(self);
                    }
                }
                if (!_need_reconnect) {
                    ret = cbt->ret;
                    if(cbt->ret.result || cbt->ret.error) Safefree(cbt);
                    DEBUG_MSG("finish %s", argv[0]);
                    return ret;
                }
            }

            if( res == WAIT_FOR_EVENT_READ_TIMEOUT ) break;

            if(self->flags & (FLAG_INSIDE_TRANSACTION | FLAG_INSIDE_WATCH)) {
                croak("reconnect disabled inside transaction or watch");
            }

            Redis__Fast_reconnect(self);
        }

        if( res == WAIT_FOR_EVENT_OK && (cbt->ret.result || cbt->ret.error) ) Safefree(cbt);
        // else destructor will release cbt

        if(res == WAIT_FOR_EVENT_READ_TIMEOUT || res == WAIT_FOR_EVENT_WRITE_TIMEOUT) {
            snprintf(self->error, MAX_ERROR_SIZE, "Error while reading from Redis server: %s", strerror(EAGAIN));
            errno = EAGAIN;
            croak("%s", self->error);
        }
        if(!self->ac) {
            croak("Not connected to any server");
        }
    }
    DEBUG_MSG("Finish %s", argv[0]);
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
                SV** ret;
                size_t keylen;
                keylen = sep - str;
                val = newSVpvn(sep + 1, linelen - keylen - 1);
                ret = hv_store(hv, str, keylen, val, 0);
                if (ret == NULL) {
                    SvREFCNT_dec(val);
                    croak("failed to hv_store");
                }
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
    DEBUG_MSG("%s", "start");
    self->error = (char*)malloc(MAX_ERROR_SIZE);
    self->reconnect_on_error = NULL;
    self->next_reconnect_on_error_at = -1;
    ST(0) = sv_newmortal();
    sv_setref_pv(ST(0), cls, (void*)self);
    DEBUG_MSG("return %p", ST(0));
    XSRETURN(1);
}
OUTPUT:
    RETVAL

double
__set_reconnect(Redis::Fast self, double val)
CODE:
{
    RETVAL = self->reconnect = val;
}
OUTPUT:
    RETVAL


double
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
__set_debug(Redis::Fast self, int val)
CODE:
{
    RETVAL = self->debug = val;
}
OUTPUT:
    RETVAL

double
__set_cnx_timeout(Redis::Fast self, double val)
CODE:
{
    RETVAL = self->cnx_timeout = val;
}
OUTPUT:
    RETVAL

double
__get_cnx_timeout(Redis::Fast self)
CODE:
{
    RETVAL = self->cnx_timeout;
}
OUTPUT:
    RETVAL


double
__set_read_timeout(Redis::Fast self, double val)
CODE:
{
    RETVAL = self->read_timeout = val;
}
OUTPUT:
    RETVAL

double
__get_read_timeout(Redis::Fast self)
CODE:
{
    RETVAL = self->read_timeout;
}
OUTPUT:
    RETVAL


double
__set_write_timeout(Redis::Fast self, double val)
CODE:
{
    RETVAL = self->write_timeout = val;
}
OUTPUT:
    RETVAL

double
__get_write_timeout(Redis::Fast self)
CODE:
{
    RETVAL = self->write_timeout;
}
OUTPUT:
    RETVAL


int
__set_current_database(Redis::Fast self, int val)
CODE:
{
    RETVAL = self->current_database = val;
}
OUTPUT:
    RETVAL


int
__get_current_database(Redis::Fast self)
CODE:
{
    RETVAL = self->current_database;
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
__set_on_build_sock(Redis::Fast self, SV* func)
CODE:
{
    self->on_build_sock = SvREFCNT_inc(func);
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
__set_reconnect_on_error(Redis::Fast self, SV* func)
CODE:
{
    self->reconnect_on_error = SvREFCNT_inc(func);
}

double
__set_next_reconnect_on_error_at(Redis::Fast self, double val)
CODE:
{
    struct timeval current;
    double current_sec;

    if ( -1 < val ) {
        gettimeofday(&current, NULL);
        current_sec = current.tv_sec + 1E-6 * current.tv_usec;
        val += current_sec;
    }

    RETVAL = self->next_reconnect_on_error_at = val;
}
OUTPUT:
    RETVAL

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
        DEBUG_MSG("%s", "free ac");
        redisAsyncFree(self->ac);
        self->ac = NULL;
    }

    if(self->hostname) {
        DEBUG_MSG("%s", "free hostname");
        free(self->hostname);
        self->hostname = NULL;
    }

    if(self->path) {
        DEBUG_MSG("%s", "free path");
        free(self->path);
        self->path = NULL;
    }

    if(self->error) {
        DEBUG_MSG("%s", "free error");
        free(self->error);
        self->error = NULL;
    }

    if(self->on_connect) {
        DEBUG_MSG("%s", "free on_connect");
        SvREFCNT_dec(self->on_connect);
        self->on_connect = NULL;
    }

    if(self->on_build_sock) {
        DEBUG_MSG("%s", "free on_build_sock");
        SvREFCNT_dec(self->on_build_sock);
        self->on_build_sock = NULL;
    }

    if(self->data) {
        DEBUG_MSG("%s", "free data");
        SvREFCNT_dec(self->data);
        self->data = NULL;
    }

    if(self->reconnect_on_error) {
        DEBUG_MSG("%s", "free reconnect_on_error");
        SvREFCNT_dec(self->reconnect_on_error);
        self->reconnect_on_error = NULL;
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
connect(Redis::Fast self)
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

    if (0 < self->reconnect && self->need_reconnect) {
        // Should be quit before reconnect
        Redis__Fast_quit(self);
        Redis__Fast_reconnect(self);
        self->need_reconnect = 0;
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

    if (0 < self->reconnect && self->need_reconnect) {
        // Should be quit before reconnect
        Redis__Fast_quit(self);
        Redis__Fast_reconnect(self);
        self->need_reconnect = 0;
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
    if(!self->ac) {
        croak("Not connected to any server");
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
        if(!sv_utf8_downgrade(ST(i + 1), 1)) {
            croak("command sent is not an octet sequence in the native encoding (Latin-1). Consider using debug mode to see the command itself.");
        }
        argv[i] = SvPV(ST(i + 1), len);
        argvlen[i] = len;
    }

    collect_errors = 0;
    if(cb && EQUALS_COMMAND(argvlen[0], argv[0], "EXEC"))
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
CODE:
{
    DEBUG_MSG("%s", "start QUIT");
    if(self->ac) {
        Redis__Fast_quit(self);
        ST(0) = sv_2mortal(newSViv(1));
        XSRETURN(1);
    } else {
        DEBUG_MSG("%s", "finish. there is no connection.");
        XSRETURN(0);
    }
}


void
__shutdown(Redis::Fast self)
CODE:
{
    DEBUG_MSG("%s", "start SHUTDOWN");
    if(self->ac) {
        redisAsyncCommand(
            self->ac, NULL, NULL, "SHUTDOWN"
            );
        redisAsyncDisconnect(self->ac);
        _wait_all_responses(self);
        self->is_connected = 0;
        self->ac = NULL;
        ST(0) = sv_2mortal(newSViv(1));
        XSRETURN(1);
    } else {
        DEBUG_MSG("%s", "redis server has alread shutdown");
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
        argv[i] = SvPV(ST(i), len);
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
        argv[i] = SvPV(ST(i), len);
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
    int cnt = (self->reconnect == 0 ? 1 : 2);

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
        argv[i] = SvPV(ST(i+1), len);
        argvlen[i] = len;
        DEBUG_MSG("argv[%d] = %s", i, argv[i]);
    }

    for(i = 0; i < cnt; i++) {
        pvariant = tolower(argv[0][0]) == 'p';
        if (strcasecmp(argv[0]+pvariant,"unsubscribe") != 0) {
            DEBUG_MSG("%s", "command is not unsubscribe");
            Newx(cbt, sizeof(redis_fast_subscribe_cb_t), redis_fast_subscribe_cb_t);
            cbt->self = self;
            cbt->cb = SvREFCNT_inc(cb);
        } else {
            DEBUG_MSG("%s", "command is unsubscribe");
            cbt = NULL;
        }
        redisAsyncCommandArgv(
            self->ac, cbt ? Redis__Fast_subscribe_cb : NULL, cbt,
            argc, (const char**)argv, argvlen
            );
        self->expected_subs = argc - 1;
        while(self->expected_subs > 0 && wait_for_event(self, self->read_timeout, self->write_timeout) == WAIT_FOR_EVENT_OK) ;
        if(self->expected_subs == 0) break;
        Redis__Fast_reconnect(self);
    }

    Safefree(argv);
    Safefree(argvlen);
    DEBUG_MSG("%s", "finish");
    XSRETURN(0);
}

void
wait_for_messages(Redis::Fast self, double timeout = -1)
CODE:
{
    int i, cnt = (self->reconnect == 0 ? 1 : 2);
    int res = WAIT_FOR_EVENT_OK;
    DEBUG_MSG("%s", "start");
    self->proccess_sub_count = 0;
    for(i = 0; i < cnt; i++) {
        while((res = wait_for_event(self, timeout, timeout)) == WAIT_FOR_EVENT_OK) ;
        if(res == WAIT_FOR_EVENT_READ_TIMEOUT || res == WAIT_FOR_EVENT_WRITE_TIMEOUT) break;
        Redis__Fast_reconnect(self);
    }
    if(res == WAIT_FOR_EVENT_EXCEPTION) {
        if(!self->ac) {
            DEBUG_MSG("%s", "Connection not found");
            croak("EOF from server");
        } else if(self->ac->c.err == REDIS_ERR_EOF) {
            DEBUG_MSG("hiredis returns error: %s", self->ac->c.errstr);
            croak("EOF from server");
        } else {
            DEBUG_MSG("hiredis returns error: %s", self->ac->c.errstr);
            snprintf(self->error, MAX_ERROR_SIZE, "[WAIT_FOR_MESSAGES] %s", self->ac->c.errstr);
            croak("%s", self->error);
        }
    }
    ST(0) = sv_2mortal(newSViv(self->proccess_sub_count));
    DEBUG_MSG("finish with %d", res);
    XSRETURN(1);
}

void
__wait_for_event(Redis::Fast self, double timeout = -1)
CODE:
{
    DEBUG_MSG("%s", "start");
    wait_for_event(self, timeout, timeout);
    DEBUG_MSG("%s", "finish");
    XSRETURN(0);
}
