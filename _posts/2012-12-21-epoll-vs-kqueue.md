---
layout: post
section: blog
title: "Scalable Event Multiplexing: epoll vs. kqueue"
---

# {{page.title}}

I like Linux much more than BSD in general, but I do want the kqueue functionality of BSD in Linux.

## What is event multiplexing?

Suppose that you have a simple web server, and there are currently two open connections (sockets). When the server receives a HTTP request from either connection, it should transmit a HTTP response to the client. But you have no idea which of the two clients will send a message first, and when. The blocking behavior of BSD Socket API means that if you invoke recv() on one connection, you will not be able to respond to a request on the other connection. This is where you need I/O multiplexing.

One straightforward way for I/O multiplexing is to have one process/thread for each connection, so that blocking in one connection does not affect others. In this way, you effectively delegate all the hairy scheduling/multiplexing issues to the OS kernel. This multi-threaded architecture comes with (arguably) high cost. Maintaining a large number of threads is not trivial for the kernel. Having a separate stack for each connection increases memory footprint, and thus degrading CPU cache locality.

How can we achieve I/O multiplexing without thread-per-connection? You can simply do busy-wait polling for each connection with non-blocking socket operations, but this is too wasteful. What we need to know is which socket becomes ready. So the OS kernel provides a separate channel between your application and the kernel, and this channel notifies when some of your sockets become ready. This is how select()/poll() works, based on _the readiness model_.

## Recap: select()

select() and poll() are very similar in the way they work. Let me quickly review how select() looks like first.

    select(int nfds, fd_set *r, fd_set *w, fd_set *e, struct timeval *timeout)
    
With select(), your application needs to provide three _interest sets_, r, w, and e. Each set is represented as a bitmap of your file descriptor. For example, if you are interested in reading from file descriptor 6, the sixth bit of r is set to 1. The call is blocked, until one or more file descriptors in the interest sets become ready, so you can perform operations on those file descriptors without blocking. Upon return, the kernel overwrites the bitmaps to specify which file descriptors are ready.

In terms of scalability, we can find four issues.

1. Those bitmaps are fixed in size (FD_SETSIZE, usually 1,024). There are some ways to work around this limitation, though.

1. Since the bitmaps are overwritten by the kernel, user applications should refill the interest sets for every call.

1. The user application and the kernel should scan the entire bitmaps for every call, to figure out what file descriptors belong to the interest sets and the result sets. This is especially inefficient for the result sets, since they are likely to be very sparse (i.e., only a few of file descriptors are ready at a given time).

1. The kernel should iterate over the entire interest sets to find out which file descriptors are ready, again for every call. If none of them is ready, the kernel iterates again to register an internal event handler for each socket.

## Recap: poll()

poll() is designed to address some of those issues.

    poll(struct pollfd *fds, int nfds, int timeout)
    
    struct pollfd {
        int fd;
        short events;
        short revents;
    }

poll() does not rely on bitmap, but array of file descriptors (thus the issue #1 solved). By having separate fields for interest (events) and result (revents), the issue #2 is also solved if the user application properly maintains and re-uses the array). The issue #3 could have been fixed if poll separated the array, not the field. The last issue is inherent and unavoidable, as both select() and poll() are stateless; the kernel does not internally maintain the interest sets.

## Why does scalability matter?

If your network server needs to maintain a relatively small number of connections (say, a few 100s) and the connection rate is slow (again, 100s of connections per second), select() or poll() would be good enough. Maybe you do not need to even bother with event-driven programming; just stick with the multi-process/threaded architecture. If performance is not your number one concern, ease of programming and flexibility are king. Apache web server is a prime example.

However, if your server application is network-intensive (e.g., 1000s of concurrent connections and/or a high connection rate), you should get really serious about performance. This situation is often called [the c10k problem](http://www.kegel.com/c10k.html). With select() or poll(), your network server will hardly perform any useful things but wasting precious CPU cycles under such high load.

Suppose that there are 10,000 concurrent connections. Typically, only a small number of file descriptors among them, say 10, are ready to read. The rest 9,990 file descriptors are copied and scanned for no reason, for every select()/poll() call.

As mentioned earlier, this problem comes from the fact that those select()/poll() interfaces are stateless. [The paper](http://static.usenix.org/event/usenix99/full_papers/banga/banga.pdf) by Banga et al, published at USENIX ATC 1999, suggested a new idea: _stateful_ interest sets. Instead of providing the entire interest set for every system call, the kernel internally maintains the interest set. Upon a decalre_interest() call, the kernel incrementally updates the interest set. The user application dispatches new events from the kernel via get_next_event().

Inspired by the research result, Linux and FreeBSD came up with their own implementations, epoll and kqueue, respectively. This means lack of portability, as applications based on epoll cannot be run on FreeBSD. One sad thing is that kqueue is _technically_ superior to epoll, so there is really no good reason to justify the existence of epoll.

## epoll in Linux

The epoll interface consists of three system calls:

    int epoll_create(int size);
    int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event);
    int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout);
    
epoll_ctl() and epoll_wait() essentially corresponds to the declare_interest() and get_next_event() above, respectively. epoll_create() creates a context as a file descriptor, while the paper mentioned above implicitly assumed per-process context.

Internally, the epoll implementation in the Linux kernel is not very different from the select()/poll() implementations. The only difference is whether it is stateful or not. This is because the design goal of them is exactly the same (event multiplexing for sockets/pipes). Refer to fs/select.c (for select and poll) and fs/eventpoll.c (for epoll) in the Linux source tree for more information.

You can also find some initial thoughts of Linus Torvalds on the early version of epoll [here](http://lkml.indiana.edu/hypermail/linux/kernel/0010.3/0003.html).

## kqueue in FreeBSD

Like epoll, kqueue also supports multiple contexts (interest sets) for each process. kqueue() performs the same thing as epoll_create(). However, the kevent() call integrates the role of epoll_ctl() (adjusting the interest set) and epoll_wait() (retrieving the events) with kevent().

    int kqueue(void);
    int kevent(int kq, const struct kevent *changelist, int nchanges, 
               struct kevent *eventlist, int nevents, const struct timespec *timeout);

Actually kqueue is a bit more complicated than epoll, from the view of ease of programming. This is because kqueue is designed in a more abstracted way, to achieve generality. Let us take a look at how struct kevent looks like.


    struct kevent {
         uintptr_t       ident;          /* identifier for this event */
         int16_t         filter;         /* filter for event */
         uint16_t        flags;          /* general flags */
         uint32_t        fflags;         /* filter-specific flags */
         intptr_t        data;           /* filter-specific data */
         void            *udata;         /* opaque user data identifier */
     };

While the details of those fields are beyond the scope of this article, you may have noticed that there is no explicit file descriptor field. This is because kqueue is not designed as a mere replacement of select()/poll() for socket event multiplexing, but as a general mechanism for various types of operating system events.

The filter field specifies the type of kernel event. If it is either EVFILT_READ or EVFILT_WRITE, kqueue works similar to epoll. In this case, the ident field represents a file descriptor. The ident field may represent other types of identifiers, such as process ID and signal number, depending on the filter type. The details can be found in the [man page](http://www.freebsd.org/cgi/man.cgi?query=kqueue&sektion=2) or the [paper](http://people.freebsd.org/~jlemon/papers/kqueue.pdf).

## Comparison of epoll and kqueue

### Performance

In terms of performance, the epoll design has a weakness; it does not support multiple updates on the interest set in a single system call. When you have 100 file descriptors to update their status in the interest set, you have to make 100 epoll_ctl() calls. The performance degradation from the excessive system calls is significant, as explained in [a paper](http://www.linuxsymposium.org/archives/OLS/Reprints-2004/LinuxSymposium2004_All.pdf#page=217). I would guess this is a legacy of the original work of Banga et al, as the  declare_interest() also supports only one update for each call. In contrast, you can specify multiple interest updates in a single kevent() call.

### Non-file support

Another issue, which is more important in my opinion, is the limited scope of epoll. As it was designed to improve the performance of select()/epoll(), but for nothing more, epoll only works with file descriptors. What is wrong with this?

It is often quoted that "In Unix, everything is a file". It is mostly true, but not always. For example, timers are not files. Signals are not files. Semaphores are not files. Processes are not files. (In Linux,) Network devices are not files. There are many things that are not files in UNIX-like operating systems. You cannot use select()/poll()/epoll for event multiplexing of those "things". Typical network servers manage various types of resources, in addition to sockets. You would probably want monitor them with a single, unified interface, but you cannot. To work around this problem, Linux supports many supplementary system calls, such as signalfd(), eventfd(), and timerfd_create(), which transforms non-file resources to file descriptors, so that you can multiplex them with epoll(). But this does not look quite elegant... do you really want a dedicated system call for every type of resource?

In kqueue, the versatile struct kevent structure supports various non-file events. For example, your application can get a notification when a child process exits (with filter = EVFILT_PROC, ident = pid, and fflags = NOTE_EXIT). Even if some resources or event types are not supported by the current kernel version, those are extended in a future kernel version, without any change in the API.

### disk file support

The last issue is that epoll does not even support all kinds of file descriptors; select()/poll()/epoll do not work with regular (disk) files. This is because epoll has a strong assumption of _the readiness model_; you monitor the readiness of sockets, so that subsequent IO calls on the sockets do not block. However, disk files do not fit this model, since simply they are always ready. 

Disk I/O blocks when the data is not cached in memory, not because the client did not send a message. For disk files, _the completion notification model_ fits. In this model, you simply issue I/O operations on the disk files, and get notified when they are done. kqueue supports this approach with the EVFILT_AIO filter type, in conjunction with POSIX AIO functions, such as aio_read(). In Linux, you should simply pray that disk access would not block with high cache hit rate (surprisingly common in many network servers), or have separate threads so that disk I/O blocking does not affect network socket processing (e.g., the [FLASH](http://www.cs.princeton.edu/~vivek/pubs/flash_usenix_99/flash.pdf) architecture).

In our previous paper, [MegaPipe](http://www.eecs.berkeley.edu/~sangjin/static/pub/osdi2012_megapipe.pdf), we proposed a new programming interface, which is entirely based on the completion notification model, for both disk and non-disk files.
