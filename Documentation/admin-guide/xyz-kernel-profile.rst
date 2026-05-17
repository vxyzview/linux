.. SPDX-License-Identifier: GPL-2.0

.. _xyz_kernel_profile:

======================
XYZ x86 Kernel Profile
======================

``arch/x86/configs/xyz_defconfig`` is a latency-first, general-purpose x86
profile.  It is meant for a fast desktop, workstation, development box, or
small server where interactive response and modern networking matter more than
minimum power draw.

The profile is not a real-time profile and it is not a tiny embedded profile.
It keeps the normal Linux debugging and observability tools that are useful on
a hacker workstation, while trimming diagnostic options that are mainly useful
when chasing one specific subsystem bug.

Build target
============

Start from the profile with::

    make ARCH=x86 xyz_defconfig

The resulting kernel advertises itself with ``CONFIG_LOCALVERSION="-xyz"``.
The live configuration is available through ``/proc/config.gz`` when procfs is
mounted because the profile enables ``CONFIG_IKCONFIG_PROC``.

Scheduling and timers
=====================

The profile uses ``CONFIG_PREEMPT_LAZY`` with ``CONFIG_PREEMPT_DYNAMIC``.
Lazy preemption gives most desktop workloads low latency without forcing every
normal task to be preempted immediately.  Dynamic preemption keeps the escape
hatch open at boot time:

``preempt=lazy``
  The profile default.  Good interactive behavior with less lock-holder churn.

``preempt=full``
  Lower latency for audio, input-heavy desktops, and experiments where tail
  latency matters more than raw throughput.

``preempt=voluntary``
  A middle ground for systems that want fewer forced preemptions than full
  preemption but more explicit reschedule points than ``preempt=none``.

``preempt=none``
  More throughput-oriented behavior for batch jobs and server-style loads.

The timer tick is set to ``CONFIG_HZ_1000`` with high-resolution timers and
idle dynticks.  This favors input and scheduler responsiveness.  Systems with
many CPUs that run mostly batch jobs may prefer ``preempt=none`` before
changing the compiled tick rate.

CPU frequency and workqueues
============================

The default CPU frequency governor is ``performance``.  The intent is to make
latency predictable and avoid ramp-up delays while benchmarking or compiling.
Intel pstate is kept through the normal x86 defaults, and AMD pstate is
explicitly enabled in active EPP mode.

The AMD pstate unit-test module is disabled.  It is useful for driver testing,
not for a daily performance kernel.

``CONFIG_WQ_POWER_EFFICIENT_DEFAULT`` is disabled so per-CPU workqueues keep
their cache locality by default.  A laptop or quiet workstation can opt into
the power-saving behavior with the ``workqueue.power_efficient`` boot
parameter.

Memory
======

The profile keeps multi-generation LRU and enables zswap by default.  Zswap
uses ``lz4`` as its default compressor, which favors low CPU cost and quick
swap-cache turnaround.

Useful boot overrides:

``zswap.compressor=zstd``
  Higher compression ratio when memory pressure matters more than CPU cycles.

``zswap.enabled=0``
  Disable zswap for storage or benchmark runs where compressed swap cache
  should not participate.

Networking
==========

BBR is built in and selected as the default TCP congestion control.  The
default qdisc is ``fq`` so locally generated traffic can use TCP pacing
properly.

Runtime overrides remain available, for example::

    sysctl -w net.ipv4.tcp_congestion_control=cubic
    sysctl -w net.core.default_qdisc=fq_codel

Diagnostics policy
==================

The profile keeps tools that help understand live systems:

* BPF JIT and BTF for modern tracing and observability.
* perf events and the common hardware PMU modules.
* ftrace, kprobes, dynamic debug, and tracefs support.
* ``CONFIG_IKCONFIG_PROC`` so the running kernel can describe itself.

It trims always-on accounting and debug counters that add overhead or bulk
without helping normal operation:

* deprecated BSD process accounting;
* task delay and task I/O accounting;
* IRQ time accounting;
* power-management debug tracing;
* x86 change-page-attribute statistics;
* shrinker and zsmalloc debug statistics;
* scheduler statistics;
* build-time x86 decoder selftests.

Pressure stall information remains compiled in but disabled by default.  Boot
with ``psi=1`` when system-wide CPU, memory, and I/O pressure metrics are more
important than the small wakeup and sleep path cost.

Quick checks after boot
=======================

The following checks confirm the important runtime defaults::

    zgrep -E 'CONFIG_PREEMPT|CONFIG_HZ|CONFIG_DEFAULT_BBR|CONFIG_DEFAULT_FQ' /proc/config.gz
    cat /sys/kernel/debug/sched/preempt
    sysctl net.ipv4.tcp_congestion_control
    sysctl net.core.default_qdisc

Mount debugfs first if ``/sys/kernel/debug/sched/preempt`` is not present::

    mount -t debugfs none /sys/kernel/debug
