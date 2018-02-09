---
title: "探索 golang 一致性原语"
date: 2018-01-21T22:04:41+08:00
lastmod: 2018-05-05T21:49:00+08:00
draft: false
tags: ["golang","一致性"]
categories: ["cs"]
---

## 缘由

前段时间，一位业内人士问我：你用了几年的 golang，对哪一块有什么比较深的感受么？

这话提醒了我，用了挺久的 golang，虽和身边的朋友有不少交流，却没什么整理和分享。刚好前段时间了解了点 golang 的锁之类的一致性原语，在这里就做下记录。

要问为什么要了解一致性原语？主要是因为，在高并发场景下，**锁往往会成为并发能力的瓶颈**。为了避免这个问题，我们往往会选择对服务进行水平扩容，然而多数情况下，这并不能实质性地解决问题，只是将问题往后抛，最后的最后，落在数据库身上。

## 一致性的意义

### 编译器

写过 C/C++ 的朋友应该知道，编译的时候有一大堆优化参数可以调节。golang 也是一样，自带了一大堆优化，不过默认已经调节得挺好了。而这些个优化中，就包括：在逻辑正确的情况下调整代码的前后顺序。

这一点，在单线程的时候没毛病，但多线程或者说并行执行的情况下，就会导致问题。这时，我们需要使用一致性原语，来保证编译器在这里不会进行这些 “看似正确” 的优化。 常见的一致性原语包括锁、原子操作等，在一些语言里还有专门用于临时禁用这些优化的关键字 `volatile`。

### CPU

#### 单核

学 golang 的朋友都知道，什么是并发、什么是并行。还有人会表达一种观点：“单核就是并发，多核就是并行”，这其实有点片面了。

我们知道，指令是在 CPU 中的流水线上执行的，而流水线有多级，各级可以同时执行不同的指令，也就是说我们的代码在单核 CPU 上也是在并行执行，只不过这是指令级并行。同时，CPU 厂商，为了减少等待从缓存读取数据的时间，也是不遗余力，做了很多优化，比如说：**分支预测**和**乱序执行**。前段时间刷屏的 [Spectre](https://zh.wikipedia.org/wiki/%E5%B9%BD%E7%81%B5_(%E5%AE%89%E5%85%A8%E6%BC%8F%E6%B4%9E)) 和 [Meltdown](https://en.wikipedia.org/wiki/Meltdown_(security_vulnerability)) 漏洞，同样与分支预测以及乱序执行有着直接的因果关系。

当然，前面提到的这些，在单核 (single-processor) 运行的时候，都不会造成一致性问题，厂商已经在 CPU 层面替我们处理好了这些。

#### 多核

单核的一致性问题，CPU 帮我们解决了，那多核 (multiple-processor) 呢？

这里我们需要了解，CPU 的**每个核心都有独立的 L1、L2 缓存（cache）**，为了提高性能，多数情况下 CPU 读数据是读的缓存，而不是 [主存 (RAM)](https://zh.wikipedia.org/wiki/%E9%9A%8F%E6%9C%BA%E5%AD%98%E5%8F%96%E5%AD%98%E5%82%A8%E5%99%A8)。Intel 为了解决这些缓存间的同步问题，在 cache 上实现了 [MESIF 协议](https://en.wikipedia.org/wiki/MESIF_protocol)，来保证缓存的同步，即：在一处修改缓存后，其它缓存的状态会跟着改变。

但 MESIF 只解决了缓存的**空间一致性**问题，并没有解决**时间一致性**问题。之前提到的**分支预测**和**乱序执行**在多核的情况下，会导致代码出错。例如：

```go
var data, flag, out int
// run in two processors
    +                +
data = 1             |
flag = 1        for {
    |               if r1 := flag; r1 == 1 {
    |                   r2 := data
    |                   out = r2
    |                   break
    |               }
    |           }
    v                v

// * r1、r2 在这里可以理解为 CPU 的寄存器，需要先从缓存载入才能进行计算，
// 其它变量也有载入寄存器的过程，这里没有突出描述。
// * 虽然看起来这段执行顺序没有问题，但 out 的值却很有可能为 0。
// 因为 CPU 很有可能对我们的指令进行重排序，将 flag 的赋值提到了 data 的前面，
// 亦或者，将 data 的缓存载入，提到了最前面执行。
```

我们来简单看一下，Intel 是怎么描述 CPU 在多核的场景下，缓存的行为：

> In a multiple-processor system, the following ordering principles apply:
>
> - Individual processors use the same ordering principles as in a single-processor system.
> - Writes by a single processor are observed in the same order by all processors.
> - Writes from an individual processor are NOT ordered with respect to the writes from other processors.
> - Memory ordering obeys causality (memory ordering respects transitive visibility).
> - Any two stores are seen in a consistent order by processors other than those performing the stores
> - Locked instructions have a total order.

这里描述得很明显，写与写之间没有顺序保证。这会直接导致我们在“读->计算->写” 这个场景的执行过程中，可能有新的写发生，导致覆写，影响最后输出的结果的正确性。

### Happens Before 语义

既然并行场景下会出问题，那我们就必须有解决这个问题的方法，也就是我们今天的主角：一致性原语。

一致性原语在支持并行的语言里都有支持，golang 也不例外。golang 官方已经提供给我们不少资料来描述这个问题，首先就是 github 上的 [LearnConcurrency](https://github.com/golang/go/wiki/LearnConcurrency)，里面详细介绍了一致性原语的设计、使用中的细节。其中最推荐看的是这篇  [The Go Memory Model](https://golang.org/ref/mem)，不仅列举了不少一致性原语的正确打开方式，更是引入了[Happens Before](https://golang.org/ref/mem#tmp_2) 这一重要概念。

[Happens Before](https://en.wikipedia.org/wiki/Happened-before) 语义是一致性原语能够实现一致性的重要保障，在许多其它语言的相关设计中，同样占有着重要的地位，[C++](http://zh.cppreference.com/w/cpp/atomic/memory_order)、[Java](https://docs.oracle.com/javase/tutorial/essential/concurrency/memconsist.html) 中就同样有详细介绍他们的文档。Happens Before 描述的核心问题是代码（指令）执行的时序问题，简单的理解就是：在执行了带有 Happens Before 语义的指令时，这个指令之前的代码影响面必须在执行该指令之后的代码之前已存在。这样的描述看起来有点抽象，我们不妨来看一下 Intel 对的 `LFENCE` 指令的描述，虽然 golang 并没有使用 `LFENCE` 来实现 Happens Before，但它的行为和 Happens Before 倒是可以完整对得上。

> The LFENCE instruction establishes a memory fence for loads. It guarantees ordering between two loads and prevents speculative loads from passing the load fence (that is, no speculative loads are allowed until all loads specified before the load fence have been carried out).

## 常用一致性原语

让我们再回头来看下这篇 [The Go Memory Model](https://golang.org/ref/mem)，里面讲到， golang 中有数个地方实现了 Happens Before 语义，分别是 [init 函数](https://golang.org/ref/mem#tmp_4)、[goruntine 的创建](https://golang.org/ref/mem#tmp_5)、[goruntine 的销毁](https://golang.org/ref/mem#tmp_6)、[**channel 通讯**](https://golang.org/ref/mem#tmp_7)、[**锁**](https://golang.org/ref/mem#tmp_8)、[**sync 包的 once**](https://golang.org/ref/mem#tmp_9)。注意，这里没有提到 [atomic](https://golang.org/pkg/sync/atomic/) 里的操作，这点后面我们还会提到。

### channel

channel 通讯的概念和语法实在没什么好说的，作为 golang 的亮点特性，已经有太多的教程对此做了详细的介绍。内部实现主要是**使用锁来保证一致性**，但这把锁并不是标准库里的锁，而是在 runtime 中自己实现的一把更加简单、高效的锁。既然依托于锁来保证一致性，那我们在这里就没什么必要去做详细的解读了。

channel 的实现中还有一个等待队列的处理，同样是精彩而漂亮，可惜不是我们今天的主角，但不妨我们来简单看一下 channel 的定义：

```Go
type hchan struct {
...
	buf      unsafe.Pointer // points to an array of dataqsiz elements
...
	recvq    waitq  // list of recv waiters
	sendq    waitq  // list of send waiters

	// lock protects all fields in hchan, as well as several
	// fields in sudogs blocked on this channel.
	//
	// Do not change another G's status while holding this lock
	// (in particular, do not ready a G), as this can deadlock
	// with stack shrinking.
	lock mutex
}
```

### 锁

锁是我们熟悉到不能再熟悉的一致性手段，channel 和 [once](https://golang.org/pkg/sync/#Once) 的实现也都是内部自带一把锁来保障一致性，golang 1.9 新推出的 [sync-map](https://golang.org/doc/go1.9#sync-map) 也是自带了一把锁。

#### 互斥锁

根据前面看到的情况，我们知道：互斥锁是实现 Happens Before 语义的重要一环。这样，我们就必须了解一下互斥锁的内部实现：

```Go
// A Mutex must not be copied after first use.
type Mutex struct {
    // 记录锁的状态
	state int32
    // semaphore，描绘获取锁的进度，
    // 和 runtime 做交互，实现加入、退出一个用 treap 实现的高效等待（调度）队列
	sema  uint32 
}
```

简单得有点出乎意料，只用两个变量就实现了锁的功能。那么，它又是如何实现 Happens Before 语义的？为此，我们需要查看 `Mutex.Lock()` 方法的实现：

```Go
func (m *Mutex) Lock() {
	// Fast path: grab unlocked mutex.
	if atomic.CompareAndSwapInt32(&m.state, 0, mutexLocked) {
		if race.Enabled {
			race.Acquire(unsafe.Pointer(m))
		}
		return
	}
	... // 包括 spin lock 以及进入等待（调度）队列的逻辑
}
```

还是一如继往的“简洁”，简洁到让人怀疑是不是找错了代码，然而**必然运行**的代码只有这一处。难道说，带有 Happens Before 语义的互斥锁是用一个在“[官方介绍](https://golang.org/ref/mem)”中不带  Happens Before 语义的 atomic 实现的？

如果仅仅这样，我们就认为是 `atomic.CompareAndSwapInt32` 实现了 Happens Before 语义，相信不仅是我，各位也不会信服。我们来看看这个 cas 操作的具体实现吧，不过 cas 等一众 atomic 操作都是用汇编来实现的，看起来会比较费劲：

```Asm
TEXT ·CompareAndSwapInt32(SB),NOSPLIT,$0-17
	JMP	·CompareAndSwapUint32(SB)

TEXT ·CompareAndSwapUint32(SB),NOSPLIT,$0-17
	MOVQ	addr+0(FP), BP
	MOVL	old+8(FP), AX
	MOVL	new+12(FP), CX
	LOCK
	CMPXCHGL	CX, 0(BP)
	SETEQ	swapped+16(FP)
	RET
```

这下看起来倒是有点像了，里面看到了 `LOCK` 这个看起来挺靠谱的**指令前缀**。让我们看一看 `LOCK` 的具体意义，在 [英特尔开发人员手册](https://www.intel.cn/content/www/cn/zh/architecture-and-technology/64-ia-32-architectures-software-developer-manual-325462.html) 中，我们到了如下的解释：

> The I/O instructions, locking instructions, the LOCK prefix, and serializing instructions force stronger orderingon the processor.

> ----

> Memory mapped devices and other I/O devices on the bus are often sensitive to the order of writes to their I/Obuffers. I/O instructions can be used to (the IN and OUT instructions) impose strong write ordering on suchaccesses as follows. Prior to executing an I/O instruction, the processor waits for all previous instructions in theprogram to complete and for all buffered writes to drain to memory. Only instruction fetch and page tables walkscan pass I/O instructions. Execution of subsequent instructions do not begin until the processor determines thatthe I/O instruction has been completed.

从描述中，我们了解到：`LOCK` 指令前缀提供了强一致性的内(缓)存读写保证，可以保证 `LOCK` 之后的指令在带 `LOCK` 前缀的指令执行之后才会执行。同时，我们在手册中还了解到，现代的 CPU 中的 `LOCK` 操作并不是简单锁 CPU 和主存之间的通讯总线， Intel 在 cache 层实现了这个 `LOCK` 操作，因此我们也无需为 `LOCK` 的执行效率担忧。

如果对这个结论持怀疑态度的话，我们不妨来自己试试实现一个 mutex，看是否能保证 Happens Before 语义。当然，在笔者的简单测试中，这个 mutex 除了占用稍高，一致性并没有什么问题。

```go
const locked = 1
var mu int32

func lock(mu *int32) {
	for {
		if atomic.CompareAndSwapInt32(mu, 0, locked) {
			return
		}
		// std sync package spin and put thread into wait queue here
		runtime.Gosched()
	}
}

func unlock(mu *int32) {
	atomic.AddInt32(mu, -locked)
}
```

#### 读写锁

golang 的读写锁是使用一个互斥锁加数个控制变量实现的，其中读锁独立使用原子操作进行实现。当然，相比简单的原子操作，还多加了一系列调用了 runtime 的函数，用以实现等待队列。而写锁，则是在互斥锁外边又包了一层逻辑来记录当前锁的状态。经过前面互斥锁的解读，相信这里不需要做过多解释也就基本理解了。

在使用的过程中，我们需要注意下：当有至少一处写锁在等待读锁时，新来的读锁会等待这个写锁先执行，而不是直接使用已有的写锁，这个逻辑主要是为了避免写锁饿死。因此，如下的代码会造成**死锁**：

```go
package main

import (
	"sync"
	"time"
)

func main() {
	mu := sync.RWMutex{}
	mu.RLock()
	defer mu.RUnlock() // do not unlock in defer

	go func(mu *sync.RWMutex) {
		mu.Lock()
		defer mu.Unlock()
	}(&mu)
	time.Sleep(time.Second) // a rough way to ensure new goroutine running

	mu.RLock() // deadlock
	defer mu.RUnlock()
}
```

### 原子操作

原子操作可以说是一致性原语中最简单、高效的一种了，能够保证我们的操作一定是完整的，执行过程中不会被打断，也不会有其它的操作在我们的执行过程中加塞进来。因为简单，很多人都认为自己已经完全掌握它了，那么我们来看点不一样的。

前面我们提到，Cas 操作使用 `LOCK` 前缀来保证动作的原子性，那么所有的 atomic 操作都是这么实现的吗？为此，我们需要完整翻一遍 atomic 的汇编实现，看看各个实现各个操作的关键指令是什么：

- Swap    : `XCHGQ`
- Cas     : `LOCK` 搭配 `CMPXCHGQ`
- Add     : `LOCK` 搭配 `XADDQ`
- Load    : `MOVQ`
- Store   : `XCHGQ`
- Pointer : 以上操作搭配 runtime 的 GC 调度

让我们在打开 Intel 手册，看看这些指令都是怎么运行的：

> - The LOCK prefix is automatically assumed for XCHG instruction.

> ----

> The Intel486 processor (and newer processors since) guarantees that the following basic memory operations willalways be carried out atomically:
>
> - Reading or writing a byte
>
> - Reading or writing a word aligned on a 16-bit boundary
>
> - Reading or writing a doubleword aligned on a 32-bit boundary
>
>   The Pentium processor (and newer processors since) guarantees that the following additional memory operationswill always be carried out atomically:
>
>
> - Reading or writing a quadword aligned on a 64-bit boundary
>
> - 16-bit accesses to uncached memory locations that fit within a 32-bit data bus
>
>   The P6 family processors (and newer processors since) guarantee that the following additional memory operationwill always be carried out atomically:
>
> - Unaligned 16-, 32-, and 64-bit accesses to cached memory that fit within a cache line

这下，我们知道了，所有 `Store` 内存的操作，实际上都带了 `LOCK` 前缀，也就是说都有 Happens Before 的语义。而 golang 在分配内存的时候，是实现了内存对齐的，所以单纯地 `Load` 内存的操作，也可以保证操作原子性，但不保证 Happens Before 的语义。这也刚好解释了为何在  [The Go Memory Model](https://golang.org/ref/mem) 只字不提 atomic 和 Happens Before 的关系。

### 其它

#### WaitGroup

WaitGroup 也算是我们在写异步代码时一个常用的操作了，它的三个操作`Add`、`Done`、`Wait` 也是用 atomic 实现的，并且三个操作都带有 Happens Before 的语义。

#### lock in runtime

runtime 为了避免包的循环导入，在内部实现了一致性原语，并且封装了两套 `mutex` 。`futex` 版用于 linux 平台，`sema` 版用于 MacOS 和 Windows。这两套的主要区别是 futex 使用了 linux 的系统调用，sleep 操作使用 kernel 提供的服务，而不是 runtime 自己封装的 sleep。

#### Happen Before 语义继承图

```
                +----------+ +-----------+   +---------+
                | sync.Map | | sync.Once |   | channel |
                ++---------+++---------+-+   +----+----+
                 |          |          |          |
                 |          |          |          |
+------------+   | +-----------------+ |          |
|            |   | |       +v--------+ |          |
|  WaitGroup +---+ | RwLock|  Mutex  | |   +------v-------+
+------------+   | +-------+---------+ |   | runtime lock |
                 |                     |   +------+-------+
                 |                     |          |
                 |                     |          |
                 |                     |          |
         +------+v---------------------v   +------v-------+
         | LOAD | other atomic action  |   |runtime atomic|
         +------+--------------+-------+   +------+-------+
                               |                  |
                               |                  |
                  +------------v------------------v+
                  |           LOCK prefix          |
                  +--------------------------------+

```



## 现有原语的不足

写这个章节，说起来还挺虚的，经历了那么多商业公司论证的一致性原语设计，很难说有什么问题，这里更多可以理解为吐槽吧。

### POSIX semaphores

POSIX 信号量是进程间保证一致性的一个手段，当然也可以用于线程间通信。实际上，进程内通讯的话，channel  比 semaphores 更加高效、易用。

需要进行进程间通讯的话，可以直接使用一些第三方封装好的包。如果愿意的话，也可以自己来封装一套系统调用，用以实现 POSIX 信号量。不出意外的话，过段时间我也会写一篇介绍如何封装系统调用的文章。

### TryLock

TryLock 在一些依耐锁比较严重的项目中会用到，主要是用来为锁提供一个类似 channel 的 select 的功能。在能上锁的时候上锁，锁被别人占用的时候，就去做其它事情。

网上也可以找到一些第三方实现，比如说 [tmutex](https://godoc.org/github.com/google/netstack/tmutex)。不过第三方的封装不是很全，并且终归没有标准库用起来方便。

### RCU

[RCU](https://en.wikipedia.org/wiki/Read-copy-update) 是 Read-copy-update 的缩写，主要用来提供将一个读锁升级为写锁的能力，这个相比上面两个更加具有实用场景。在**读多写少并发高**的地方，我们会优先考虑上读锁，上完读锁之后想要在保障一致性不中断的情况下换上写锁，就要大费一番周章。而如果有 RCU 的支持，这一切都不是问题。

很可惜，在 [godoc](https://godoc.org/?q=rcu) 上还未看见任何实现。为此，笔者自己封装了一个库 [rcu-go](https://github.com/wweir/rcu-go)，为了能够直接修改读写锁里的非导出字段，中间使用了很多 unsafe 的操作，使用之前需要确认在自己的 golang 版本上能否正常运行。

## 感言

一致性的问题一直以来都不是一个简单的问题，寥寥数千字，难言其中十之一二，如果需要了解更多的内容，建议在有一定基础之后直接阅读  [英特尔开发人员手册](https://www.intel.cn/content/www/cn/zh/architecture-and-technology/64-ia-32-architectures-software-developer-manual-325462.html)。

阅读本文需要较深的功底和一些并发场景的处理经验，如果看完觉得还是一头雾水，完全可以选择忽略，因为需要用到这些知识点的机会本就少之又少。正如 [The Go Memory Model](https://golang.org/ref/mem) 所言：

> If you must read the rest of this document to understand the behavior of your program, you are being too clever.
>
> Don't be clever.