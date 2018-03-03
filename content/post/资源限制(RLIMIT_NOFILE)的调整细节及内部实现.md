---
title: "资源限制(RLIMIT_NOFILE)的调整细节及内部实现"
date: 2018-03-01T17:38:11+08:00
lastmod: 2018-03-01T17:38:11+08:00
draft: false
tags: ["linux","rlimit"]
categories: ["ops"]
---

# 前言

这是一段两年前的研究，当时也写了篇数千字的长文，因为经验、行文方面的不足，可读性不高，没有对外公开。这里依当时的研究成果，重写一篇来介绍配置`资源限制`过程中的一些细节，及`最大打开文件描述符数量(RLIMIT_NOFILE)`的部分源码实现。

资源限制（resource limit），一般用 `rlimit` 来表示，是内核对占用的资源的一个限额。避免某一用户、进程过多占用系统资源，造成系统资源紧张。 `ulimit` 命令是在 `bash` 中观察资源限制的一个常用手段，还可以查看 `/proc/$PID/limits` 文件来观察特定进程的资源限制。

最大打开文件描述符数限制 (`RLIMIT_NOFILE`,`ulimit -n`)，是一个常见的资源限制，因其默认值比较小(1024)，所以运行一些需要打开大量文件描述符（文件、连接等）的进程，如 MySQL、nginx，经常会触发这个限制。如果在错误日志中看到包含以下字样的内容，很可能就是遇到了这个限制。

```
too many open files
```

# 调整方式

## 调整的权限

资源限制有软、硬限制之分，其中实际生效的是软限制，硬限制是软限制调节的一个限度，即：软限制 <= 硬限制。普通用户可以自由修改软限制，和调小自己的硬限制，`root` 用户可以自由修改自己的软、硬限制。

Linux 系统除了提供了用户级的权限管理机制，还提供了更加细化的权限管理方式，比如：[capabilities](https://linux.die.net/man/7/capabilities)。因此，在拥有合适的 capability 后，以普通用户权限运行的进程，也具有修改硬限制的能力。与资源限制相关的 capabilities 有 `CAP_SYS_RESOURCE` 和 `CAP_SYS_ADMIN`，可以在 man 文档中找到二者的具体作用。

## 临时配置

通常我们通过 [ulimit](https://linux.die.net/man/3/ulimit) 命令修改当前环境的软、硬资源限制，如：`ulimit -Hn 1048576`。需要注意，ulimit 是 bash 内置的一条命令，其它 shell 也可以有一套不同的实现。如：

- csh 对应的命令是 `limit`
- dash(debian/ubuntu 中的 `sh`) 提供的命令也是 `ulimit`，但参数不同

### 在线配置

前面提到的这个配置方式，需要在进程启动前就将相关的环境配好，对修改运行中的进程的资源限制就无能为力了。在稍新的系统中（[`linux`](https://www.kernel.org/pub/linux/kernel/) ≥ 2.6.36），还有两种修改运行中的进程资源限制的方式：

- 使用 [`prlimit`](https://linux.die.net/man/2/prlimit) ([`util-linux`](https://www.kernel.org/pub/linux/utils/util-linux/) ≥ 2.21) 修改指定进程的资源限制
- 直接修改进程对应的 `/proc/$PID/limits` 文件

### RLIMIT_NOFILE

根据前文可以了解到，以 root 运行或带有 capability(CAP_SYS_RESOURCE) 的进程，可以自由调整 RLIMIT_NOFILE 的软、硬限制。实际上，这里的调整也算不上完全自由，还有一些其它限制在起作用：

- 硬限制不能超过 `/proc/sys/fs/nr_open` 文件中的数字，默认是`1048576(1<<20)`。老版本内核的系统中没有这个文件，值硬编码为`1048576`
  - `ulimit -Sn` <= `ulimit -Hn` <= `cat /proc/sys/fs/nr_open`
- 内核能打开的最大文件描述符数量为 `/proc/sys/fs/file-max` 里的数值，该值根据机器性能而定
- 虽然调节前两项中对应的文件的数字可以将软、硬限制调大，但最终受限于机器的硬件性能

## 持久化配置

直接使用 `ulimit` 命令的方式，日常操作中这么操作没什么问题。但在持久化这个配置时，直接在 shell 的配置文件中使用这样的命令，未免显得 low，同时也不利于权限、资源限制的细化管理。

### 用户级配置

操作系统中，提供了一套用来配置各用户(组)的资源限制的方式，配置文件在：

```sh
/etc/security/limits.conf
/etc/security/limits.d/*
```

配置文件支持配置各个资源限制项的软、硬限制，支持从用户、用户组、全局三个层级进行配置。

对于一些拥有单独运行用户的服务，建议使用这种方式进行配置。特别是一些本身由数个在同一用户下运行的进程构成的服务，配置一次，数个进程都能受到影响。

### 进程级配置

对于那些直接运行在主用户或 root 用户下的进程，直接修改对应用户的配置也是可以的，不过算不上优雅。同时，在自己封装一些服务的安装包或者安装脚本的时候，必须考虑各种可能的运行环境，还必须尽量少的影响用户自己的环境设置，这就必须考虑做进程级的资源限制配置了。

#### systemd

这在 CentOS 7 等以 [`systemd`](https://wiki.archlinux.org/index.php/systemd_(%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87)) 作为启动管理器的操作系统中很好实现。只要在对应的 service 文件中写入

```
LimitNOFILE = 1048576
```

 就可以了，全部的资源限制的配置方式在 [systemd 的文档](https://www.freedesktop.org/software/systemd/man/systemd.exec.html#Process%20Properties)中。

#### SysVinit

在使用 [SysVinit](https://wiki.archlinux.org/index.php/SysVinit_(%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87)) 作为启动管理器的操作系统时，就没那么好办了。如果服务自身有变更资源限制的支持的话，可以使用服务自身的配置；如果服务提供了变更用户的支持的话，可以以 root 用户启动，在启动脚本中加入 ulimit 相关命令。令人高兴的是，这两个功能 MySQL 都有支持。

服务自身没提供那么完备的支持又该怎么办呢？比较直接的办法有两种：

1. 可以修改源码的话，可以给程序自身加上相应的支持。
2. 以 root 启动，在启动脚本中执行 `ulimit`，再以 `su`/`sudo` 执行对应命令。这里还有些需要注意的点将在下一节讲述。

上面介绍的两种启动管理器，已经能够覆盖大多数场景了。这里还需要注意，debian/ubuntu 的一些版本混用 systemd 和 SysVinit，需要自己判断用哪套方案。另外，ubuntu 历史上使用过 [`Upstart`](http://upstart.ubuntu.com/) 作为启动管理器，因过于小众且已弃用，这里不做介绍。

### 变更用户

写这一节是源于 debian 系和 rhel 系操作系统的一个默认配置的不同，导致资源限制在使用 `su` 后呈现不同的状态。让我们来重现一下二者对应的行为：

1. 在 `/etc/security/limits.conf` 中配置某用户(A)一项资源限制(num1)
2. 登陆另一用户(B)，执行 `ulimit` 修改该项资源限制(num2)，并使修改后的值与配置的值不同(num1 != num2)
3. 执行 `su` 命令，`su` 到我们配置过的那个用户(A) ，使用 `ulimit` 来查看当前的资源限制数
   - Centos 在 `su` 前后资源限制数相同(num2)
   - Debian/Ubuntu 在 `su` 之后，资源限制变为我们在文件中配置的值(num1)
4. 执行 `sudo ` 命令，二者的行为与 Centos 下 `su` 的行为相同

二者对应的行为，是由 [PAM](https://wiki.archlinux.org/index.php/PAM_(%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87)) 模块控制的。阅读  [`util-linux`](https://www.kernel.org/pub/linux/utils/util-linux/) 中 `su` 和 `sudo` 的实现源码可以了解到，在执行完必要的工作后，其调用了 PAM 模块的接口，实现相应的权限变更，其中包括对资源限制的控制。

PAM 模块在系统中的配置文件在：

```
/etc/pam.conf
/etc/pam.d/*
```

分析并对比二者 `/etc/pam.d/` 下 `su` 对应的配置文件可知，二者行为差别，来自于 `pam_limits.so` 的调用与否。

# 源码分析

先说明一下，本文所用到的源码，均可以在 linux kernel [网站](https://www.kernel.org)下载，也可以在 github 上下载和查看。kernel 网站的 git 链接如下：

```sh
git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
git://git.kernel.org/pub/scm/utils/util-linux/util-linux.git
```

## 从文档入手

Linux 源码库中有个显眼的目录 [`Documentation`](https://github.com/torvalds/linux/tree/master/Documentation)。没错，里面放了 kernel 的各式文档，想找哪个资料，直接查找这个目录就好了。

与我们今天的主题 `RLIMIT_NOFILE` 相关的文档，集中在 [linux/Documentation/sysctl/fs.txt](https://github.com/torvalds/linux/blob/v4.5-rc6/Documentation/sysctl/fs.txt#L114) 中。文档全文较长，这里截取两小段，印证一下之前的一些描述：

> file-max & file-nr:
>
> The value in file-max denotes the maximum number of file-
> handles that the Linux kernel will allocate.
>
> ----
>
> nr_open:
>
> This denotes the maximum number of file-handles a process can
> allocate. Default value is 1024*1024 (1048576) which should be
> enough for most machines. Actual limit depends on RLIMIT_NOFILE
> resource limit.

## RLIMIT_NOFILE 的控制逻辑

RLIMIT_NOFILE 控制的是进程最多能打开文件描述符数的数量，控制的逻辑自然应该在打开新文件描述符的过程中。让我们来看看具体是怎么打开新文件描述符的，代码在 [linux/fs/file.c](https://github.com/torvalds/linux/blob/v4.5-rc6/fs/file.c#L497)：

```C
static int alloc_fd(unsigned start, unsigned flags)
{
	return __alloc_fd(current->files, start, rlimit(RLIMIT_NOFILE), flags);
}
```

```C
/*
 * allocate a file descriptor, mark it busy.
 */
int __alloc_fd(struct files_struct *files,
	       unsigned start, unsigned end, unsigned flags)
{
...
  	spin_lock(&files->file_lock);
repeat:
	fdt = files_fdtable(files);
	fd = start;
	if (fd < files->next_fd)
		fd = files->next_fd;

	if (fd < fdt->max_fds)
		fd = find_next_fd(fdt, fd);
...
	/*
	 * N.B. For clone tasks sharing a files structure, this test
	 * will limit the total number of files that can be opened.
	 */
	error = -EMFILE;
	if (fd >= end)
		goto out;
...
out:
	spin_unlock(&files->file_lock);
	return error;
}
```

内核用一个链表来保存文件描述符，这也解决了文件描述符的计数问题。当链表最后一个文件描述符的计数（已打开文件描述符数）大于进程的 RLIMIT_NOFILE 对应的值时，返回 `EMFILE` 错误，也就是我们常看到的 `Too many open files`。

这个链表的实现，可以在 [include/linux/fdtable.h](https://github.com/torvalds/linux/blob/master/include/linux/fdtable.h#L48) 找到具体定义：

```C
/*
 * Open file table structure
 */
struct files_struct {
...
	struct fdtable __rcu *fdt;
	struct fdtable fdtab;
...
	int next_fd;
...
};

struct fdtable {
	unsigned int max_fds;
	struct file __rcu **fd;      /* current fd array */
	unsigned long *close_on_exec;
	unsigned long *open_fds;
	unsigned long *full_fds_bits;
	struct rcu_head rcu;
};
```

## 资源限制信息的保存

资源限制信息保存在进程上，准确地说，是保存在进程控制块 (PCB) 中的 `signal_struct *signal` 中。不仅是资源限制，这个结构还保存了很多其它进程的信息，内核的进程调度离不开这个结构。

因为该结构里面包含了不少我们平时常见的东西，值得了解，就稍微多贴一些代码，在这先说声抱歉。相应的代码在 [include/linux/sched.h](https://github.com/torvalds/linux/blob/v4.5-rc6/include/linux/sched.h#L1389)：

```C
struct task_struct {
	volatile long state;	/* -1 unrunnable, 0 runnable, >0 stopped */
	void *stack;
	atomic_t usage;
...
	struct mm_struct *mm, *active_mm;
	/* per-thread vma caching */
	u32 vmacache_seqnum;
struct vm_area_struct *vmacache[VMACACHE_SIZE];
...
  /* task state */
	int exit_state;
	int exit_code, exit_signal;
...
	pid_t pid;
	pid_t tgid;

	/*
	 * pointers to (original) parent process, youngest child, younger sibling,
	 * older sibling, respectively.  (p->father can be replaced with
	 * p->real_parent->pid)
	 */
	struct task_struct __rcu *real_parent; /* real parent process */
	struct task_struct __rcu *parent; /* recipient of SIGCHLD, wait4() reports */
...
/* open file information */
	struct files_struct *files;
...
/* signal handlers */
	struct signal_struct *signal;
...
	struct sigpending pending;
...
};
```

`signal_struct` 的定义在 [include/linux/sched.h](https://github.com/torvalds/linux/blob/v4.5-rc6/include/linux/sched.h#L657)：

```C
struct signal_struct {
...
	/* current thread group signal load-balancing target: */
	struct task_struct *curr_target;
...
	/*
	 * We don't bother to synchronize most readers of this at all,
	 * because there is no reader checking a limit that actually needs
	 * to get both rlim_cur and rlim_max atomically, and either one
	 * alone is a single word that can safely be read normally.
	 * getrlimit/setrlimit use task_lock(current->group_leader) to
	 * protect this instead of the siglock, because they really
	 * have no need to disable irqs.
	 */
	struct rlimit rlim[RLIM_NLIMITS];
...
}
```

## RLIMIT_NOFILE 的两个默认值

为了解 RLIMIT_NOFILE 软、硬限制的两个默认值的由来，我们需要知道一些进程相关的基础知识，这里做个简单的描述：

- 子进程会继承父进程的资源限制
- 我们在系统中看到的进程都是 1 号进程(systemd/SysVinit)的子、孙等后辈进程。
- 执行 ulimit 命令看到的是 shell(bash) 进程自身的信息，即 1 号进程的后辈进程的信息
- 1 号进程是 0 号进程的子进程，而 0 号进程是在内核中生成的
- 因 PAM 模块会变更资源限制，不保证我们实际看到的资源限制数值和将要介绍的数值完全一致

查看 [linux/include/asm-generic/resource.h](https://github.com/torvalds/linux/blob/v4.5-rc6/include/asm-generic/resource.h#L10)，我们可以找到初始化资源限制定义的代码：

```c
/*
 * boot-time rlimit defaults for the task:
 */
#define INIT_RLIMITS							\
{									\
...
	[RLIMIT_NOFILE]		= {   INR_OPEN_CUR,   INR_OPEN_MAX },	\
...
}

#endif
```

而其中的 `INR_OPEN_CUR` 与 `INR_OPEN_MAX` 在 [linux/include/uapi/linux/fs.h](https://github.com/torvalds/linux/blob/v4.5-rc6/include/uapi/linux/fs.h#L28) 有具体定义：

```c
#define INR_OPEN_CUR 1024	/* Initial setting for nfile rlimits */
#define INR_OPEN_MAX 4096	/* Hard limit for nfile rlimits */
```

由此可知，软、硬资源的这两个初始值，是在内核里就已经有定义的。去掉所有外部调整资源限制的操作，我们看到的应当是 `1024` 和 `4096` 这两个数字。

# 纠误与总结

通过前面的代码分析，我们大致可以得出这样一个结论，就是资源限制的相关信息（数值、控制逻辑）是绑定在进程上的，脱离了具体进程讨论资源限制是没有意义的。

## 纠误

在我们查找相关资料的过程中，经常会看到这样一个观点：资源限制是绑定在 session 上的属性，会随用户会话的变更而变化。

而实际上，进程的的继承使资源限制在父子进程间以线性的形式展现在我们面前。由于 PAM 的存在，使得资源限制的表现看起来像是绑定在用户、session 上的属性。其内部实现与用户、session 并无直接关系。

## 总结

资源限制导致的错误很常见，特别是 RLIMIT_NOFILE，掌握配置它的方法已经成了 DBA 的一个必备技能。但实际生活中，很少有人理解其内部的工作机理，在笔者做这个研究时，甚至没能找到一篇文章能清楚的说明资源限制在传递过程中的关键点。

目前，很高兴地看到很多软件已经提供了 RLIMIT_NOFILE 的支持。特别是应用广泛的 [`docker`](https://github.com/moby/moby)，docker 在自身的启动脚本中进行了相关的配置，其自身及容器中进程的 RLIMIT_NOFILE 已经变成了 `1048576`。这样我们在做一些容器化的服务时就不必过多考虑资源限制的事了，但面对一些无法容器化的场景，还需要我们来进行手工配置。