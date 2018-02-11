---
title: "系统调用在 Golang 中的实践"
date: 2018-02-06T07:39:58+08:00
lastmod: 2018-02-06T07:39:58+08:00
draft: false
tags: ["golang","syscall","linux"]
categories: ["cs"]
---

在看一些其它语言实现的基础工具时，时而发现其中有我们需要的某项特殊功能。究其源码，一般会看到两种底层实现：汇编、系统调用。这里的系统调用就是我们今天的主角了。

## 系统调用

<center>

![Linux的体系架构](../../img/Linux的体系架构.png)

</center>

系统调用在操作系统中占有重要的地位，是内核对外交互的门户，为我们提供了与底层资源交互的相对简单、安全的方式，给我们提供了一种在用户态、内核态切换的手段。

我们写的程序，通常是跑在用户态的，它对应 CPU 的 Ring 3 保护级别，而内核运行在 Ring 0 级别，拥有更高的权限。相应的，内核的代码可以运行一些用户态代码无法运行的 CPU 特权指令，实现一些用户态的代码做不到的事情，比如：控制进程的运行，使用驱动操作机器上的硬件。内核将部分自己实现的功能进行封装， 形成相对统一、方便的接口给我们进行调用，这些接口就是系统调用。

通常，我们使用某些特殊指令来通知内核去执行这些系统调用的对应代码，如：Int 0x80、sysenter、syscall。内核收到这些指令后会根据我们进程给出的参数，执行对应的功能。这时，我们的进程也会从用户态切换到内核态。

## Golang 中 syscall 的实现

打开 godoc 中 [`syscall`](https://golang.org/pkg/syscall)包的文档，可以看到标准库给这些系统调用做了不错的封装，不少常用的系统调用已经可以像普通函数一样直接调用了，除此之外，还提供了 4 个通用的封装方式，供我们执行任意的系统调用：

```go
Syscall(trap, a1, a2, a3 uintptr) (r1, r2 uintptr, err Errno)
Syscall6(trap, a1, a2, a3, a4, a5, a6 uintptr) (r1, r2 uintptr, err Errno)
RawSyscall(trap, a1, a2, a3 uintptr) (r1, r2 uintptr, err Errno)
RawSyscall6(trap, a1, a2, a3, a4, a5, a6 uintptr) (r1, r2 uintptr, err Errno)
```

从外观观察，可以知道它们可以按支持的参数个数分成两类：

- 供 4 个及 4 个以下参数的系统调用使用的 `Syscall`、`RawSyscall`
- 供 6 个及 6 个以下参数的系统调用使用的 `Syscall6`、`RawSyscall6`

而从对我们来说更有意义的实现、功用的角度看，可以分为 `Syscall`、`RawSyscall` 两类。

### Syscall

废话不多说，让我们来看下 `Syscall` 的具体实现：

```asm
// func Syscall(trap int64, a1, a2, a3 int64) (r1, r2, err int64);
// Trap # in AX, args in DI SI DX R10 R8 R9, return in AX DX
// Note that this differs from "standard" ABI convention, which
// would pass 4th arg in CX, not R10.

TEXT	·Syscall(SB),NOSPLIT,$0-56
	CALL	runtime·entersyscall(SB)
	MOVQ	a1+8(FP), DI
	MOVQ	a2+16(FP), SI
	MOVQ	a3+24(FP), DX
	MOVQ	$0, R10
	MOVQ	$0, R8
	MOVQ	$0, R9
	MOVQ	trap+0(FP), AX	// syscall entry
	SYSCALL
	CMPQ	AX, $0xfffffffffffff001
	JLS	ok
	MOVQ	$-1, r1+32(FP)
	MOVQ	$0, r2+40(FP)
	NEGQ	AX
	MOVQ	AX, err+48(FP)
	CALL	runtime·exitsyscall(SB)
	RET
ok:
	MOVQ	AX, r1+32(FP)
	MOVQ	DX, r2+40(FP)
	MOVQ	$0, err+48(FP)
	CALL	runtime·exitsyscall(SB)
	RET
```

这段汇编中，主要执行了 6 个步骤：

1. 调用 `runtime.entersyscall` 函数。通知 runtime 调度器，让出运行时间
2. 读内存，把各个参数放到合适的寄存器
3. 通知内核执行系统调用
4. 判断系统调用的执行结果，并进行跳转
5. 若执行成功，拷贝执行结果到返回值。若执行失败，置空返回值
6. 调用 `runtime.exitsyscall` 函数，恢复该 goroutine 的运行

### RawSyscall

`RawSyscall` 的汇编实现与 `Syscall` 一致，唯一的区别是没有调用 `runtime.entersyscall` 和 `runtime.exitsyscall`，也就是说，直接使用 `RawSyscall` 可能出现阻塞的情况。

提到阻塞就不得不解释下，系统调用可以分两种：快系统调用、慢系统调用。快系统调指的是不会造成阻塞的系统调用，如：获取 pid。相应的，慢系统指的就是会造成阻塞的系统调用，如：读写磁盘、网络。虽然平时可能感觉这些慢系统调用也执行的很快，但它们的速度相比 CPU 还是太慢，在某些情形下，这个速度还会被放慢很多，甚至出现假死（hang）的情况。

因此，正如 golang 邮件列表里的讨论所言，除非你对你要用的具体系统调用非常了解，同时性能要求极高，其它场景下能别用就别用 `RawSyscall`。

>  I would say that Go programs should always call Syscall.  RawSyscall exists to make it slightly 
>  more efficient to call system calls that never block, such as getpid. 
>  But it's really ann internal mechanism. 

### syscall 库的生成

观察 syscall 库源码文件的分布，可以看到除了一堆后缀名为 `.s`、`.go` 的文件，还有一些后缀名为 `.sh`、`.pl` 的文件，这些就是 syscall 库部分封装代码的自动生成脚本。

浏览这些文件可以知道，golang 中的 syscall 封装是自动完成的，主要方式是使用 `gcc` 对 [/usr/include/x86_64-linux-gnu/asm/unistd_64.h](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/uapi/asm-generic/unistd.h?id=refs/heads/master) 进行处理，再对处理的结果进行文本替换，生成平台相关的源码文件。

## 执行系统调用

有了基本的了解之后，我们就可以进行一些尝试了，尝试之前先申明下，系统调用是个与操作系统强相关的东西，不同平台的使用方式不同，这里的描述只保证在 `linux` `amd64` 平台下有效。同时，系统调用使用不当，可能使操作系统出现某些不正常的行为，使用之前需要阅读对应的系统调用的具体描述。

### 常用系统调用

Golang 的 syscall 库已经对常用系统调用进行了封装，我们只需要调用相应的函数，并传入相应的参数就可以等着执行完成，给我们返回需要的结果了。

等等，这里需要我们要传入对应的参数，还有多个返回值，这些参数该怎么填，各个返回值又是什么含义呢？很可惜，syscall 库并没有对这些内容做必要的介绍，也就是说我们需要自行寻找一个资料，提供对每个系统调用进行详细描述的相对权威的描述。

`man` 这个我们平日里经常用到的命令，除了提供各种命令的使用帮助，还提供了不少系统层面的资料，其中就有我们所需要的各个系统调用的具体描述。通过比对 `man` 里的资料与封装函数的外观，我们可以得到具体系统调用的对应实践方式。

我们除了可以在命令行直接使用 `man` 命令进行离线查阅，还可以在 [man7.org](http://man7.org/linux/man-pages/index.html) 进行在线查询，方便在开发、运行的环境不同的情况下使用。

#### mmap

多说无益，我们来做个尝试，在实现过程中来体会具体的实践方式。这里，我们选择使用 [`mmap` ](https://golang.org/pkg/syscall/#Mmap) 来实现数据的持久化存储作为示例。

首先我们需要查阅资料，对 `mmap` 有个基本了解，知道它将文件映射进内存的基本原理，以及相比传统的文件读写方式的优劣势。

然后，查看标准库对 `mmap` 这个系统调用的封装：

```go
func Mmap(fd int, offset int64, length int, prot int, flags int) (data []byte, err error)
```

接着，我们查看 `man` 对 [mmap 的介绍](http://man7.org/linux/man-pages/man2/mmap.2.html) ：

```c
void *mmap(void *addr, size_t length, int prot, int flags,
                  int fd, off_t offset);
```

这下，两边就能够对应上了，让我们来了解一下各个参数的具体定义：

- fd：映射进内存的文件描述符
- offset：映射进内存的文件段的起始位置，在文件中的偏移量
- length：映射进内存的文件段的长度，必须是正整数
- prot：protection 的缩写，用来做权限控制，golang 标准库已有预定义的值
- flags：对 `mmap` 的一些行为进行控制，golang 标准库已有预定义的值

同样，返回值也可以对应得上，不过，在形式上进行了一些转变，需要进行理解和翻译：

- data：对应 `*addr`，返回映射进内存的文件段对应的数组，持久化数据就是使用这个数组
- err：对应这个函数的返回值  `void` ，返回值的含义，在 golang 已有对应的定义

我们来试一下，根据这个文档写出实现代码：

```go
func main() {
	f, err := os.OpenFile("mmap.bin", os.O_RDWR|os.O_CREATE, 0644)
	if nil != err {
		log.Fatalln(err)
	}
	// extend file
	if _, err := f.WriteAt([]byte{byte(0)}, 1<<8); nil != err {
		log.Fatalln(err)
	}

	data, err := syscall.Mmap(int(f.Fd()), 0, 1<<8, syscall.PROT_WRITE, syscall.MAP_SHARED)
	if nil != err {
		log.Fatalln(err)
	}
	if err := f.Close(); nil != err {
		log.Fatalln(err)
	}

	for i, v := range []byte("hello syscall") {
		data[i] = v
	}

	if err := syscall.Munmap(data); nil != err {
		log.Fatalln(err)
	}
}
```

编译并执行这段代码，会在当前目录生成 `mmap.bin` 文件，执行 `hexdump -C mmap.bin` 可以看到，文件里面已有我们写入的内容。

### 任意系统调用

执行任意系统调用的实践方式与执行常用系统调用类似。不过，没被封装的系统调用，一般都是使用场景很少的系统调用，这就意味着能找到的资料少，`man` 里面的资料也未必齐全。

资料少不代表没有，golang 的资料找不到，不妨找一找 C/C++ 相关的实践，也可以直接去看执行了该系统调用的开源项目的源码。甚至，在极端情况下，我们可以直接查看该系统调用对应的内核源码。这里推荐使用 https://syscalls.kernelgrok.com 来快速定位具体系统调用的在内核源码中的具体位置。不过，这些收集资料的方式，对我们的操作系统知识、C 系语言源码的阅读能力要求较高。

找到足够的资料，就可以开始进行实现了。`syscall.Syscall` 的具体使用方式，可以在一些常用系统调用封装的源码中找到答案：

- 第一个参数为系统调用号，一般以 `SYS_` 开头。
- 后续的参数就是 `man` 里面写着的各个参数。未必是指针，也可能是一些数字，统一以 `uintptr` 类型进行传递，部分情况需要执行强制类型转换。
- 在某系统调用需要的参数小于 4 (6) 个的时候，缺少的参数项，用 0 补足

这里借用 [`gotty`](https://github.com/yudai/gotty) 中，设置 tty 行数、列数的系统调用源码作为[示例](https://github.com/yudai/gotty/blob/release-1.0/app/client_context.go#L229)：

```Go
			window := struct {
				row uint16
				col uint16
				x   uint16
				y   uint16
			}{
				rows,
				columns,
				0,
				0,
			}
			syscall.Syscall(
				syscall.SYS_IOCTL, // syscall number
				context.pty.Fd(),
				syscall.TIOCSWINSZ, // call option
				uintptr(unsafe.Pointer(&window)),
			)
```

## 是否要使用系统调用

正如本文开头所描述，系统调用可以直接与内核交互，无疑要比使用 `shell` 命令与内核进行交互的效率要高。如果标准库已经对该系统调用做了封装，直接使用对应的封装，要比使用 `shell` 命令的交互方式的优势更加明显。

所以，当代码里要实现某项功能，并且我们的代码要作为一个长期稳定运行的服务运行时，应尽量使用系统调用，而不是在源码中执行 `shell` 命令进行实现。相反，如果只是写一些临时的，对效率要求不高的工具时，哪个方便用哪个。

这里需要注意，在我们的源码中调用第三方工具，我们要为这些第三方工具的正确性负责。一是要保证以正确的方式使用，二是在第三方工具的内部实现有 bug 时，我们要有相应的能力来分析与诊断相应的问题。