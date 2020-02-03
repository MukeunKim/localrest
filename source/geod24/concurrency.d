/**
 * This is a low-level messaging API upon which more structured or restrictive
 * APIs may be built.  The general idea is that every messageable entity is
 * represented by a common handle type called a Tid, which allows messages to
 * be sent to logical threads that are executing in both the current process
 * and in external processes using the same interface.  This is an important
 * aspect of scalability because it allows the components of a program to be
 * spread across available resources with few to no changes to the actual
 * implementation.
 *
 * A logical thread is an execution context that has its own stack and which
 * runs asynchronously to other logical threads.  These may be preemptively
 * scheduled kernel threads, fibers (cooperative user-space threads), or some
 * other concept with similar behavior.
 *
 * The type of concurrency used when logical threads are created is determined
 * by the Scheduler selected at initialization time.  The default behavior is
 * currently to create a new kernel thread per call to spawn, but other
 * schedulers are available that multiplex fibers across the main thread or
 * use some combination of the two approaches.
 *
 * Note:
 * Copied (almost verbatim) from Phobos at commit 3bfccf4f1 (2019-11-27)
 * Changes are this notice, and the module rename, from `std.concurrency`
 * to `geod24.concurrency`.
 *
 * Copyright: Copyright Sean Kelly 2009 - 2014.
 * License:   <a href="http://www.boost.org/LICENSE_1_0.txt">Boost License 1.0</a>.
 * Authors:   Sean Kelly, Alex Rønne Petersen, Martin Nowak
 * Source:    $(PHOBOSSRC std/concurrency.d)
 */
/*          Copyright Sean Kelly 2009 - 2014.
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module geod24.concurrency;

public import std.variant;

import core.atomic;
import core.sync.condition;
import core.sync.mutex;
import core.thread;
import std.container;
import std.range.primitives;
import std.range.interfaces : InputRange;
import std.traits;


/**
 * Thrown on calls to `receive` if the thread that spawned the receiving
 * thread has terminated and no more messages exist.
 */
class OwnerTerminated : Exception
{
    ///
    this(string msg = "Owner terminated") @safe pure nothrow @nogc
    {
        super(msg);
    }
}


/**
 * Encapsulates all implementation-level data needed for scheduling.
 *
 * When defining a Scheduler, an instance of this struct must be associated
 * with each logical thread.  It contains all implementation-level information
 * needed by the internal API.
 */
struct ThreadInfo
{
    /// Storage of information required for scheduling, message passing, etc.
    public Object[string] objects;

    /**
     * Gets a thread-local instance of ThreadInfo.
     *
     * Gets a thread-local instance of ThreadInfo, which should be used as the
     * default instance when info is requested for a thread not created by the
     * Scheduler.
     */
    static @property ref thisInfo() nothrow
    {
        static ThreadInfo val;
        return val;
    }

    /**
     * Cleans up this ThreadInfo.
     *
     * This must be called when a scheduled thread terminates.  It tears down
     * the messaging system for the thread and notifies interested parties of
     * the thread's termination.
     */
    void cleanup()
    {
    }
}


/***************************************************************************

    Getter of FiberScheduler assigned to a called thread.

***************************************************************************/

public @property FiberScheduler thisScheduler () nothrow
{
    auto p = ("scheduler" in thisInfo.objects);
    if (p !is null)
        return cast(FiberScheduler)*p;
    else
        return null;
}


/***************************************************************************

    Setter of FiberScheduler assigned to a called thread.

***************************************************************************/

public @property void thisScheduler (FiberScheduler value) nothrow
{
    thisInfo.objects["scheduler"] = value;
}



/***************************************************************************

    Thread with ThreadInfo,
    It can have objects for Fiber Scheduling and Message Passing.

***************************************************************************/

public class InfoThread : Thread
{
    public ThreadInfo info;

    /***************************************************************************

        Initializes a thread object which is associated with a static

        Params:
            fn = The thread function.
            sz = The stack size for this thread.

    ***************************************************************************/

    this (void function() fn, size_t sz = 0) @safe pure nothrow @nogc
    {
        super(fn, sz);
    }


    /***************************************************************************

        Initializes a thread object which is associated with a dynamic

        Params:
            dg = The thread function.
            sz = The stack size for this thread.

    ***************************************************************************/

    this (void delegate() dg, size_t sz = 0) @safe pure nothrow @nogc
    {
        super(dg, sz);
    }
}


/**
 * An example Scheduler using kernel threads.
 *
 * This is an example Scheduler that mirrors the default scheduling behavior
 * of creating one kernel thread per call to spawn.  It is fully functional
 * and may be instantiated and used, but is not a necessary part of the
 * default functioning of this module.
 */
class ThreadScheduler
{
    /**
     * This simply runs op directly, since no real scheduling is needed by
     * this approach.
     */
    void start(void delegate() op)
    {
        op();
    }

    /**
     * Creates a new kernel thread and assigns it to run the supplied op.
     */
    void spawn(void delegate() op)
    {
        auto t = new InfoThread({
            thisScheduler = new FiberScheduler();
            op();
        });
        t.start();
    }

    /**
     * Creates a new Condition variable.  No custom behavior is needed here.
     */
    Condition newCondition(Mutex m) nothrow
    {
        return new Condition(m);
    }
}

public @property ref ThreadInfo thisInfo() nothrow
{
    if (auto t = cast(InfoThread)Thread.getThis())
        return t.info;
    else
        return ThreadInfo.thisInfo;
}

/**
 * An example Scheduler using Fibers.
 *
 * This is an example scheduler that creates a new Fiber per call to spawn
 * and multiplexes the execution of all fibers within the main thread.
 */
class FiberScheduler
{
    private Mutex fibers_lock;

    /// Ctor
    public this () @safe
    {
        this.fibers_lock = new Mutex;
    }

    /**
     * This creates a new Fiber for the supplied op and then starts the
     * dispatcher.
     */
    void start(void delegate() op)
    {
        create(op);
        dispatch();
    }

    /**
     * This created a new Fiber for the supplied op and adds it to the
     * dispatch list.
     */
    void spawn(void delegate() op) nothrow
    {
        create(op);
        FiberScheduler.yield();
    }

    /**
     * If the caller is a scheduled Fiber, this yields execution to another
     * scheduled Fiber.
     */
    static void yield() nothrow
    {
        // NOTE: It's possible that we should test whether the calling Fiber
        //       is an InfoFiber before yielding, but I think it's reasonable
        //       that any fiber should yield here.
        if (Fiber.getThis())
            Fiber.yield();
    }


    /**
     * Returns a Condition analog that yields when wait or notify is called.
     *
     * Bug:
     * For the default implementation, `notifyAll`will behave like `notify`.
     *
     * Params:
     *   m = A `Mutex` to use for locking if the condition needs to be waited on
     *       or notified from multiple `Thread`s.
     *       If `null`, no `Mutex` will be used and it is assumed that the
     *       `Condition` is only waited on/notified from one `Thread`.
     */
    Condition newCondition(Mutex m = null) nothrow
    {
        if (m is null)
            return new FiberCondition(this.fibers_lock);
        else
            return new FiberCondition(m);
    }

protected:
    /**
     * Creates a new Fiber which calls the given delegate.
     *
     * Params:
     *   op = The delegate the fiber should call
     */
    void create(void delegate() op) nothrow
    {
        void wrap()
        {
            op();
        }

        this.fibers_lock.lock_nothrow();
        scope (exit) this.fibers_lock.unlock_nothrow();
        m_fibers ~= new InfoFiber(&wrap);
    }

    /**
     * Fiber which embeds a ThreadInfo
     */
    static class InfoFiber : Fiber
    {

        this(void delegate() op, size_t sz = 16 * 1024 * 1024) nothrow
        {
            super(op, sz);
        }
    }

    protected class FiberCondition : Condition
    {
        /// When notify() is called, this value is true.
        private bool _notified;

        this (Mutex m = null) nothrow
        {
            super(m);
            notified = false;
        }

        override void wait() nothrow
        {
            scope (exit) notified = false;

            while (!notified)
                FiberScheduler.yield();
        }

        override bool wait(Duration period) nothrow
        {
            import core.time : MonoTime;

            scope (exit) notified = false;

            for (auto limit = MonoTime.currTime + period;
                 !notified && !period.isNegative;
                 period = limit - MonoTime.currTime)
            {
                FiberScheduler.yield();
            }
            return notified;
        }

        override void notify() nothrow
        {
            notified = true;
            FiberScheduler.yield();
        }

        override void notifyAll() nothrow
        {
            notified = true;
            FiberScheduler.yield();
        }


        /***********************************************************************

            Getter of `notified`
            Synchronization is used to access _notified.

        ***********************************************************************/

        private @property bool notified () nothrow
        {
            if (this.mutex_nothrow !is null)
            {
                this.mutex_nothrow.lock_nothrow();
                scope (exit) this.mutex_nothrow.unlock_nothrow();
                return this._notified;
            }
            else
            {
                return this._notified;
            }
        }


        /***********************************************************************

            Setter of `notified`
            Synchronization is used to access _notified.

        ***********************************************************************/

        private @property void notified (bool value) nothrow
        {
            if (this.mutex_nothrow !is null)
            {
                this.mutex_nothrow.lock_nothrow();
                scope (exit) this.mutex_nothrow.unlock_nothrow();
                this._notified = value;
            }
            else
            {
                this._notified = value;
            }
        }
    }

private:
    void dispatch()
    {
        import std.algorithm.mutation : remove;

        while (true)
        {
            synchronized (this.fibers_lock)
            {
                if (m_fibers.length == 0)
                    break;

                auto t = m_fibers[m_pos].call(Fiber.Rethrow.no);
                if (t !is null)
                {
                    if (cast(OwnerTerminated) t)
                        break;
                    else
                        throw t;
                }

                if (m_fibers[m_pos].state == Fiber.State.TERM)
                {
                    if (m_pos >= (m_fibers = remove(m_fibers, m_pos)).length)
                        m_pos = 0;
                }
                else if (m_pos++ >= m_fibers.length - 1)
                {
                    m_pos = 0;
                }
            }
        }
    }

private:
    Fiber[] m_fibers;
    size_t m_pos;
}


/*******************************************************************************

    This channel has queues that senders and receivers can wait for.
    With these queues, a single thread alone can exchange data with each other.

    Technically, a channel is a data transmission pipe where data can be passed
    into or read from.
    Hence one fiber(thread) can send data into a channel, while other fiber(thread)
    can read that data from the same channel

    It is the Scheduler that allows the channel to connect the fiber organically.
    This allows for the segmentation of small units of logic during a program
    using fiber in a multi-threaded environment.

*******************************************************************************/

public class Channel (T)
{
    /// closed
    private bool closed;

    /// lock for queue and status
    private Mutex mutex;

    /// size of queue
    private size_t qsize;

    /// queue of data
    private DList!T queue;

    /// collection of send waiters
    private DList!(ChannelContext!T) sendq;

    /// collection of recv waiters
    private DList!(ChannelContext!T) recvq;

    /// Ctor
    public this (size_t qsize = 0)
    {
        this.closed = false;
        this.mutex = new Mutex;
        this.qsize = qsize;
    }


    /***************************************************************************

        Send data `msg`.
        First, check the receiving waiter that is in the `recvq`.
        If there are no targets there, add data to the `queue`.
        If queue is full then stored waiter(fiber) to the `sendq`.

        Params:
            msg = value to send

        Return:
            true if the sending is succescontextul, otherwise false

    ***************************************************************************/

    public bool send (T msg)
    {
        this.mutex.lock();

        if (this.closed)
        {
            this.mutex.unlock();
            return false;
        }

        if (this.recvq[].walkLength > 0)
        {
            ChannelContext!T context = this.recvq.front;
            this.recvq.removeFront();
            *(context.msg_ptr) = msg;
            this.mutex.unlock();
            context.notify();
            return true;
        }

        if (this.queue[].walkLength < this.qsize)
        {
            this.queue.insertBack(msg);
            this.mutex.unlock();
            return true;
        }

        scope scheduler = thisScheduler;
        if (Fiber.getThis() && scheduler)
        {
            ChannelContext!T new_context;
            new_context.msg_ptr = null;
            new_context.msg = msg;
            new_context.mutex = null;
            new_context.condition = scheduler.newCondition();
            this.sendq.insertBack(new_context);
            this.mutex.unlock();
            new_context.wait();
            return true;
        }
        else
        {
            ChannelContext!T new_context;
            new_context.msg_ptr = null;
            new_context.msg = msg;
            new_context.mutex = new Mutex();
            new_context.condition = new Condition(new_context.mutex);
            this.sendq.insertBack(new_context);
            this.mutex.unlock();
            new_context.wait();
            return true;
        }
    }


    /***************************************************************************

        Return the received message.

        Return:
            msg = value to receive

    ***************************************************************************/

    public bool receive (T* msg)
    {
        this.mutex.lock();

        if (this.closed)
        {
            (*msg) = T.init;
            this.mutex.unlock();
            return false;
        }

        if (this.sendq[].walkLength > 0)
        {
            ChannelContext!T context = this.sendq.front;
            this.sendq.removeFront();
            *(msg) = context.msg;
            this.mutex.unlock();
            context.notify();
            return true;
        }

        if (this.queue[].walkLength > 0)
        {
            *(msg) = this.queue.front;
            this.queue.removeFront();
            this.mutex.unlock();
            return true;
        }

        scope scheduler = thisScheduler;
        if (Fiber.getThis() && scheduler)
        {
            ChannelContext!T new_context;
            new_context.msg_ptr = msg;
            new_context.mutex = null;
            new_context.condition = scheduler.newCondition();
            this.recvq.insertBack(new_context);
            this.mutex.unlock();
            new_context.wait();
            return true;
        }
        else
        {
            ChannelContext!T new_context;
            new_context.msg_ptr = msg;
            new_context.mutex = new Mutex();
            new_context.condition = new Condition(new_context.mutex);
            this.recvq.insertBack(new_context);
            this.mutex.unlock();
            new_context.wait();
            return true;
        }
    }


    /***************************************************************************

        Return the received message.

        Return:
            msg = value to receive

    ***************************************************************************/

    public bool tryReceive (T *msg)
    {
        this.mutex.lock();

        if (this.closed)
        {
            this.mutex.unlock();
            return false;
        }

        if (this.sendq[].walkLength > 0)
        {
            ChannelContext!T context = this.sendq.front;
            this.sendq.removeFront();
            *(msg) = context.msg;
            this.mutex.unlock();
            context.notify();
            return true;
        }

        if (this.queue[].walkLength > 0)
        {
            *(msg) = this.queue.front;
            this.queue.removeFront();
            this.mutex.unlock();
            return true;
        }

        this.mutex.unlock();
        return false;
    }


    /***************************************************************************

        Return closing status

        Return:
            true if channel is closed, otherwise false

    ***************************************************************************/

    public @property bool isClosed () @safe @nogc pure
    {
        synchronized (this.mutex)
        {
            return this.closed;
        }
    }


    /***************************************************************************

        Close Channel

    ***************************************************************************/

    public void close ()
    {
        ChannelContext!T context;

        this.mutex.lock();
        scope (exit) this.mutex.unlock();

        this.closed = true;

        while (true)
        {
            if (this.recvq[].walkLength == 0)
                break;

            context = this.recvq.front;
            this.recvq.removeFront();
            context.notify();
        }

        this.queue.clear();

        while (true)
        {
            if (this.sendq[].walkLength == 0)
                break;

            context = this.sendq.front;
            this.sendq.removeFront();
            context.notify();
        }
    }
}


/***************************************************************************

    A structure to be stored in a queue.
    It has information to use in standby.

***************************************************************************/

private struct ChannelContext (T)
{
    /// This is a message. Used in put
    public T  msg;

    /// This is a message point. Used in get
    public T* msg_ptr;

    //  Waiting Condition
    public Condition condition;

    /// lock for thread waiting
    public Mutex mutex;
}

private void wait (T) (ChannelContext!T context)
{
    if (context.condition is null)
        return;

    if (context.mutex is null)
        context.condition.wait();
    else
    {
        synchronized(context.mutex)
        {
            context.condition.wait();
        }
    }
}

private void notify (T) (ChannelContext!T context)
{
    if (context.condition is null)
        return;

    if (context.mutex is null)
        context.condition.notify();
    else
    {
        synchronized(context.mutex)
        {
            context.condition.notify();
        }
    }
}


/// Fiber1 -> [ channel2 ] -> Fiber2 -> [ channel1 ] -> Fiber1
unittest
{
    auto channel1 = new Channel!int;
    auto channel2 = new Channel!int;
    auto thread_scheduler = new ThreadScheduler();
    int result = 0;

    Mutex mutex = new Mutex;
    Condition condition = new Condition(mutex);

    // Thread1
    thread_scheduler.spawn({
        scope scheduler = thisScheduler;
        scheduler.start({
            //  Fiber1
            scheduler.spawn({
                channel2.send(2);
                channel1.receive(&result);
                synchronized (mutex)
                {
                    condition.notify;
                }
            });
            //  Fiber2
            scheduler.spawn({
                int msg;
                channel2.receive(&msg);
                channel1.send(msg*msg);
            });
        });
    });

    synchronized (mutex)
    {
        condition.wait(1000.msecs);
    }

    assert(result == 4);
}


/// Fiber1 in Thread1 -> [ channel2 ] -> Fiber2 in Thread2 -> [ channel1 ] -> Fiber1 in Thread1
unittest
{
    auto channel1 = new Channel!int;
    auto channel2 = new Channel!int;
    auto thread_scheduler = new ThreadScheduler();
    int result;

    Mutex mutex = new Mutex;
    Condition condition = new Condition(mutex);

    // Thread1
    thread_scheduler.spawn({
        // Fiber1
        thisScheduler.start({
            channel2.send(2);
            channel1.receive(&result);
            synchronized (mutex)
            {
                condition.notify;
            }
        });
    });

    // Thread2
    thread_scheduler.spawn({
        // Fiber2
        thisScheduler.start({
            int msg;
            channel2.receive(&msg);
            channel1.send(msg*msg);
        });
    });

    synchronized (mutex)
    {
        condition.wait(1000.msecs);
    }
    assert(result == 4);
}


/// Thread1 -> [ channel2 ] -> Thread2 -> [ channel1 ] -> Thread1
unittest
{
    auto channel1 = new Channel!int;
    auto channel2 = new Channel!int;
    auto thread_scheduler = new ThreadScheduler();
    int result;

    Mutex mutex = new Mutex;
    Condition condition = new Condition(mutex);

    // Thread1
    thread_scheduler.spawn({
        channel2.send(2);
        channel1.receive(&result);
        synchronized (mutex)
        {
            condition.notify;
        }
    });

    // Thread2
    thread_scheduler.spawn({
        int msg;
        channel2.receive(&msg);
        channel1.send(msg*msg);
    });

    synchronized (mutex)
    {
        condition.wait(3000.msecs);
    }

    assert(result == 4);
}


/// Thread1 -> [ channel2 ] -> Fiber1 in Thread 2 -> [ channel1 ] -> Thread1
unittest
{
    auto channel1 = new Channel!int;
    auto channel2 = new Channel!int;
    auto thread_scheduler = new ThreadScheduler();
    int result;

    Mutex mutex = new Mutex;
    Condition condition = new Condition(mutex);

    // Thread1
    thread_scheduler.spawn({
        channel2.send(2);
        channel1.receive(&result);
        synchronized (mutex)
        {
            condition.notify;
        }
    });

    // Thread2
    thread_scheduler.spawn({
        // Fiber1
        thisScheduler.start({
            int msg;
            channel2.receive(&msg);
            channel1.send(msg*msg);
        });
    });

    synchronized (mutex)
    {
        condition.wait(1000.msecs);
    }
    assert(result == 4);
}


// If the queue size is 0, it will block when it is sent and received on the same thread.
unittest
{
    auto channel_qs0 = new Channel!int(0);
    auto channel_qs1 = new Channel!int(1);
    auto thread_scheduler = new ThreadScheduler();
    int result = 0;

    Mutex mutex = new Mutex;
    Condition condition = new Condition(mutex);

    // Thread1 - It'll be tangled.
    thread_scheduler.spawn({
        channel_qs0.send(2);
        channel_qs0.receive(&result);
        synchronized (mutex)
        {
            condition.notify;
        }
    });

    synchronized (mutex)
    {
        condition.wait(1000.msecs);
    }
    assert(result == 0);

    // Thread2 - Unravel a tangle
    thread_scheduler.spawn({
        channel_qs0.receive(&result);
        channel_qs0.send(2);
    });

    synchronized (mutex)
    {
        condition.wait(1000.msecs);
    }
    assert(result == 2);

    result = 0;
    // Thread3 - It'll not be tangled, because queue size is 1
    thread_scheduler.spawn({
        channel_qs1.send(2);
        channel_qs1.receive(&result);
        synchronized (mutex)
        {
            condition.notify;
        }
    });

    synchronized (mutex)
    {
        condition.wait(1000.msecs);
    }
    assert(result == 2);
}


// If the queue size is 0, it will block when it is sent and received on the same fiber.
unittest
{
    auto channel_qs0 = new Channel!int(0);
    auto channel_qs1 = new Channel!int(1);
    auto thread_scheduler = new ThreadScheduler();
    int result = 0;

    // Thread1
    thread_scheduler.spawn({

        scope scheduler = thisScheduler;
        scope cond = scheduler.newCondition();

        scheduler.start({
            //  Fiber1 - It'll be tangled.
            scheduler.spawn({
                channel_qs0.send(2);
                channel_qs0.receive(&result);
                cond.notify();
            });

            assert(!cond.wait(1000.msecs));
            assert(result == 0);

            //  Fiber2 - Unravel a tangle
            scheduler.spawn({
                channel_qs0.receive(&result);
                channel_qs0.send(2);
            });

            cond.wait(1000.msecs);
            assert(result == 2);

            //  Fiber3 - It'll not be tangled, because queue size is 1
            scheduler.spawn({
                channel_qs1.send(2);
                channel_qs1.receive(&result);
                cond.notify();
            });

            cond.wait(1000.msecs);
            assert(result == 2);
        });
    });
}
