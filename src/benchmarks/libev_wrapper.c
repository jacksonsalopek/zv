#include "libev_wrapper.h"
#include <ev.h>
#include <stdlib.h>

libev_loop* libev_loop_new(void) {
    /* Match zv's backend set: epoll/kqueue/poll. Do not enable io_uring/linuxaio. */
    return (libev_loop*)ev_loop_new(EVBACKEND_EPOLL | EVBACKEND_KQUEUE | EVBACKEND_POLL);
}

void libev_loop_destroy(libev_loop* loop) {
    ev_loop_destroy((struct ev_loop*)loop);
}

void libev_loop_run(libev_loop* loop, int flags) {
    ev_run((struct ev_loop*)loop, flags);
}

void libev_loop_break(libev_loop* loop, int how) {
    ev_break((struct ev_loop*)loop, how);
}

uint64_t libev_loop_iteration(libev_loop* loop) {
    return ev_iteration((struct ev_loop*)loop);
}

double libev_loop_now(libev_loop* loop) {
    return ev_now((struct ev_loop*)loop);
}

size_t libev_io_sizeof(void) {
    return sizeof(struct ev_io);
}

libev_io* libev_io_alloc_array(size_t n) {
    return (libev_io*)calloc(n, sizeof(struct ev_io));
}

void libev_io_free_array(libev_io* base) {
    free(base);
}

libev_io* libev_io_nth(libev_io* base, size_t i) {
    return (libev_io*)((struct ev_io*)base + i);
}

void libev_io_init(libev_io* watcher, void (*callback)(libev_loop*, libev_io*, int), int fd, int events) {
    ev_io_init((struct ev_io*)watcher, (void(*)(struct ev_loop*, struct ev_io*, int))callback, fd, events);
}

void libev_io_start(libev_loop* loop, libev_io* watcher) {
    ev_io_start((struct ev_loop*)loop, (struct ev_io*)watcher);
}

void libev_io_stop(libev_loop* loop, libev_io* watcher) {
    ev_io_stop((struct ev_loop*)loop, (struct ev_io*)watcher);
}

void libev_io_modify(libev_io* watcher, int events) {
    ev_io_modify((struct ev_io*)watcher, events);
}

void libev_io_set(libev_io* watcher, int fd, int events) {
    ev_io_set((struct ev_io*)watcher, fd, events);
}

size_t libev_timer_sizeof(void) {
    return sizeof(struct ev_timer);
}

libev_timer* libev_timer_alloc_array(size_t n) {
    return (libev_timer*)calloc(n, sizeof(struct ev_timer));
}

void libev_timer_free_array(libev_timer* base) {
    free(base);
}

libev_timer* libev_timer_nth(libev_timer* base, size_t i) {
    return (libev_timer*)((struct ev_timer*)base + i);
}

void libev_timer_init(libev_timer* watcher, void (*callback)(libev_loop*, libev_timer*, int), double after, double repeat) {
    ev_timer_init((struct ev_timer*)watcher, (void(*)(struct ev_loop*, struct ev_timer*, int))callback, after, repeat);
}

void libev_timer_start(libev_loop* loop, libev_timer* watcher) {
    ev_timer_start((struct ev_loop*)loop, (struct ev_timer*)watcher);
}

void libev_timer_stop(libev_loop* loop, libev_timer* watcher) {
    ev_timer_stop((struct ev_loop*)loop, (struct ev_timer*)watcher);
}

void libev_timer_again(libev_loop* loop, libev_timer* watcher) {
    ev_timer_again((struct ev_loop*)loop, (struct ev_timer*)watcher);
}

libev_signal* libev_signal_new(void) {
    return (libev_signal*)malloc(sizeof(struct ev_signal));
}

void libev_signal_init(libev_signal* watcher, void (*callback)(libev_loop*, libev_signal*, int), int signum) {
    ev_signal_init((struct ev_signal*)watcher, (void(*)(struct ev_loop*, struct ev_signal*, int))callback, signum);
}

void libev_signal_start(libev_loop* loop, libev_signal* watcher) {
    ev_signal_start((struct ev_loop*)loop, (struct ev_signal*)watcher);
}

void libev_signal_stop(libev_loop* loop, libev_signal* watcher) {
    ev_signal_stop((struct ev_loop*)loop, (struct ev_signal*)watcher);
}

void libev_signal_destroy(libev_signal* watcher) {
    free(watcher);
}
