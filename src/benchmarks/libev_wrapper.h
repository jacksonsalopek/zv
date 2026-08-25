#ifndef LIBEV_WRAPPER_H
#define LIBEV_WRAPPER_H

#include <stdint.h>
#include <stddef.h>

typedef struct libev_loop libev_loop;
typedef struct libev_io libev_io;
typedef struct libev_timer libev_timer;
typedef struct libev_signal libev_signal;

libev_loop* libev_loop_new(void);
void libev_loop_destroy(libev_loop* loop);
void libev_loop_run(libev_loop* loop, int flags);
void libev_loop_break(libev_loop* loop, int how);
uint64_t libev_loop_iteration(libev_loop* loop);
double libev_loop_now(libev_loop* loop);

size_t libev_io_sizeof(void);
libev_io* libev_io_alloc_array(size_t n);
void libev_io_free_array(libev_io* base);
libev_io* libev_io_nth(libev_io* base, size_t i);
void libev_io_init(libev_io* watcher, void (*callback)(libev_loop*, libev_io*, int), int fd, int events);
void libev_io_start(libev_loop* loop, libev_io* watcher);
void libev_io_stop(libev_loop* loop, libev_io* watcher);
void libev_io_modify(libev_io* watcher, int events);
void libev_io_set(libev_io* watcher, int fd, int events);

size_t libev_timer_sizeof(void);
libev_timer* libev_timer_alloc_array(size_t n);
void libev_timer_free_array(libev_timer* base);
libev_timer* libev_timer_nth(libev_timer* base, size_t i);
void libev_timer_init(libev_timer* watcher, void (*callback)(libev_loop*, libev_timer*, int), double after, double repeat);
void libev_timer_start(libev_loop* loop, libev_timer* watcher);
void libev_timer_stop(libev_loop* loop, libev_timer* watcher);
void libev_timer_again(libev_loop* loop, libev_timer* watcher);

libev_signal* libev_signal_new(void);
void libev_signal_init(libev_signal* watcher, void (*callback)(libev_loop*, libev_signal*, int), int signum);
void libev_signal_start(libev_loop* loop, libev_signal* watcher);
void libev_signal_stop(libev_loop* loop, libev_signal* watcher);
void libev_signal_destroy(libev_signal* watcher);

#define LIBEV_READ  0x01
#define LIBEV_WRITE 0x02

#define LIBEV_RUN_DEFAULT  0
#define LIBEV_RUN_NOWAIT   1
#define LIBEV_RUN_ONCE     2

#define LIBEV_BREAK_ONE    1
#define LIBEV_BREAK_ALL    2

#endif
