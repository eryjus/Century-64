;==============================================================================================
;
; private.inc
;
; This file contains the external symbols that are used in all modules throughout this system.
;
;**********************************************************************************************
;
;       Century-64 is a 64-bit Hobby Operating System written mostly in assembly.
;       Copyright (C) 2014-2015  Adam Scott Clark
;
;       This program is free software: you can redistribute it and/or modify
;       it under the terms of the GNU General Public License as published by
;       the Free Software Foundation, either version 3 of the License, or
;       any later version.
;
;       This program is distributed in the hope that it will be useful,
;       but WITHOUT ANY WARRANTY; without even the implied warranty of
;       MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;       GNU General Public License for more details.
;
;       You should have received a copy of the GNU General Public License along
;       with this program.  If not, see http://www.gnu.org/licenses/gpl-3.0-standalone.html.
;
;**********************************************************************************************
;
;    Date     Tracker  Pgmr  Description
; ----------  ------   ----  ------------------------------------------------------------------
; 2014/10/06  Initial  ADCL  Initial version
; 2015/01/04  #228     ADCL  Make sure that the virtual memory from 0xffff ff7f ffe0 0000 to
;                            0cffff ff7f ffef ffff cannot be allocated.
;
;==============================================================================================

%define         DISABLE_DBG_CONSOLE

;----------------------------------------------------------------------------------------------
; -- the following macros are to make coding simpler
;----------------------------------------------------------------------------------------------

%define         add.b       add byte
%define         add.w       add word
%define         add.d       add dword
%define         add.q       add qword

%define         and.b       and byte
%define         and.w       and word
%define         and.d       and dword
%define         and.q       and qword

%define         cmp.b       cmp byte
%define         cmp.w       cmp word
%define         cmp.d       cmp dword
%define         cmp.q       cmp qword

%define         lea.b       lea byte
%define         lea.w       lea word
%define         lea.d       lea dword
%define         lea.q       lea qword

%define         mov.b       mov byte
%define         mov.w       mov word
%define         mov.d       mov dword
%define         mov.q       mov qword

%define         neg.b       neg byte
%define         neg.w       neg word
%define         neg.d       neg dword
%define         neg.q       neg qword

%define         not.b       not byte
%define         not.w       not word
%define         not.d       not dword
%define         not.q       not qword

%define         or.b        or byte
%define         or.w        or word
%define         or.d        or dword
%define         or.q        or qword

%define         shl.b       shl byte
%define         shl.w       shl word
%define         shl.d       shl dword
%define         shl.q       shl qword

%define         shr.b       shr byte
%define         shr.w       shr word
%define         shr.d       shr dword
%define         shr.q       shr qword

%define         sub.b       sub byte
%define         sub.w       sub word
%define         sub.d       sub dword
%define         sub.q       sub qword

%define         test.b      test byte
%define         test.w      test word
%define         test.d      test dword
%define         test.q      test qword

%define         xor.b       xor byte
%define         xor.w       xor word
%define         xor.d       xor dword
%define         xor.q       xor qword

%define         BREAK       xchg bx,bx

;----------------------------------------------------------------------------------------------
; -- some macros to make development easier
;----------------------------------------------------------------------------------------------

%macro          INT_HANDLER_PREAMBLE 0
                push        rbp                     ; save the caller's frame (another stack)
                mov.q       rbp,rsp                 ; create our own frame
                push        rax                     ; save rax
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdx                     ; save rdx
                push        rsi                     ; save rsi
                push        rdi                     ; save rdi
                push        r8                      ; save r8
                push        r9                      ; save r9
                push        r10                     ; save r10
                push        r11                     ; save r11
                push        r12                     ; save r12
                push        r13                     ; save r13
                push        r14                     ; save r14
                push        r15                     ; save r15

                xor.q       rax,rax                 ; clear rax
                mov.w       ax,ds                   ; copy ds to rax register
                push        rax                     ; and save it on the stack

                xor.q       rax,rax                 ; clear rax
                mov.w       ax,es                   ; copy es to rax register
                push        rax                     ; and save it on the stack

                xor.q       rax,rax                 ; clear rax
                mov.w       ax,fs                   ; copy fs to rax register
                push        rax                     ; and save it on the stack

                xor.q       rax,rax                 ; clear rax
                mov.w       ax,gs                   ; copy gs to rax register
                push        rax                     ; and save it on the stack

                mov.q       rax,cr0                 ; get cr0
                push        rax                     ; and save it on the stack

                mov.q       rax,cr2                 ; get cr2
                push        rax                     ; and save it on the stack

                mov.q       rax,cr3                 ; get cr3
                push        rax                     ; and save it on the stack

                mov.q       rax,[rbp-16]            ; restore rax since we trashed it
%endmacro

%macro          INT_HANDLER_CLEANUP 0
                add.q       rsp,24                  ; skip past cr3, cr2, and cr0

                pop         rax                     ; get gs from the stack
                mov.w       gs,ax                   ; and restore the register

                pop         rax                     ; get fs from the stack
                mov.w       fs,ax                   ; and restore the register

                pop         rax                     ; get es from the stack
                mov.w       es,ax                   ; and restore the register

                pop         rax                     ; get ds from the stack
                mov.w       ds,ax                   ; and restore the register

                pop         r15                     ; restore r15
                pop         r14                     ; restore r14
                pop         r13                     ; restore r13
                pop         r12                     ; restore r12
                pop         r11                     ; restore r11
                pop         r10                     ; restore r10
                pop         r9                      ; restore r9
                pop         r8                      ; restore r8
                pop         rdi                     ; restore rdi
                pop         rsi                     ; restore rsi
                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rax                     ; restore rax
                pop         rbp                     ; restore caller's frame
                add.q       rsp,8                   ; clean up the error code on the stack
%endmacro

;----------------------------------------------------------------------------------------------
; -- the following symbols are added by the linker
;----------------------------------------------------------------------------------------------

                extern      bootStart
                extern      bootClear
                extern      bootEnd
                extern      bssEnd
                extern      kernelStart
                extern      kernelEnd

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in loader.s
;----------------------------------------------------------------------------------------------

VIRT_BASE       equ         0xffffffff80000000
STACK_SIZE      equ         0x0000000000004000              ; 16K

%ifndef __LOADER_S__
                extern      mbEAX
                extern      mbEBX
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in pagetables.s
;----------------------------------------------------------------------------------------------

%ifndef __PAGETABLES_S__
                extern      PagingInit
                extern      PML4Table
                extern      PDPT
                extern      PD
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in text.s
;----------------------------------------------------------------------------------------------

%ifndef __TEXT_S__
                extern      TextClear
                extern      TextPutHexByte
                extern      TextPutHexWord
                extern      TextPutHexDWord
                extern      TextPutHexQWord
                extern      TextPutChar
                extern      TextPutString
                extern      TextSetAttr
                extern      TextSetBlockCursor
                extern      TextSetNoCursor
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in mbcheck.s
;----------------------------------------------------------------------------------------------

struc FreeMem
    .str        resq        1                       ; starting address of the block
    .size       resq        1                       ; ending address of the block (not length)
    .addr       resd        1                       ; the address of the current entry
    .len        resd        1                       ; the remaining length of the mmap
endstruc

MAGIC1          equ         0x2badb002
MAGIC2          equ         0x36d76289

%ifndef __MBCHECK_S__
                extern      CheckMB
                extern      GetMemLimit
                extern      GetFreeFirst
                extern      GetFreeNext
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in physmm.s
;----------------------------------------------------------------------------------------------

%ifndef __PHYSMM_S__
                extern      PMMInit
                extern      PMMInit2
                extern      MarkBlockFree
                extern      MarkBlockUsed
                extern      AllocFrame
                extern      AllocFrameLimit
                extern      FreeFrame
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in kheap.s
;----------------------------------------------------------------------------------------------

%ifndef __KHEAP_S__
                extern      HeapInit
                extern      kmalloc
                extern      kfree
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in virtmm.s
;----------------------------------------------------------------------------------------------

VMM_SUCCESS     equ         0x0000000000000000
VMM_WARN_ALIGN  equ         0x0000000000000001
VMM_WARN_MAPPED equ         0x0000000000000002
VMM_WARN_NOTMAPPED equ      0x0000000000000003
VMM_ERR_NOMEM   equ         0xffffffffffffffff
VMM_ERR_BAD_MEM equ         0xfffffffffffffffe

VMM_PF_START    equ         0xffffff7fffe00000
VMM_PF_END      equ         0xffffff7fffefffff

%ifndef __VIRTMM_S__
                extern      VMMInit
                extern      VMMAlloc
                extern      VMMFree
                extern      ReclaimMemory
                extern      AllocStack
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in gdt-tss.s
;----------------------------------------------------------------------------------------------

BADIST1         equ         0xffffff7fffe01000
BADIST2         equ         0xffffff7fffe02000
BADIST3         equ         0xffffff7fffe03000
BADIST4         equ         0xffffff7fffe04000
BADIST5         equ         0xffffff7fffe05000
BADIST6         equ         0xffffff7fffe06000
BADIST7         equ         0xffffff7fffe07000
BADRSP0         equ         0xffffff7fffe08000
BADRSP1         equ         0xffffff7fffe09000
BADRSP2         equ         0xffffff7fffe0a000

%ifndef __GDT_TSS_S__
                extern      GDTInit
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in idt.s
;----------------------------------------------------------------------------------------------

RSP0            equ         0x00                    ; use stack RSP0/1/2 based on DPL of gate
IST1            equ         0x01                    ; use stack IST1
IST2            equ         0x02                    ; use stack IST2
IST3            equ         0x03                    ; use stack IST3
IST4            equ         0x04                    ; use stack IST4
IST5            equ         0x05                    ; use stack IST5
IST6            equ         0x06                    ; use stack IST6
IST7            equ         0x07                    ; use stack IST7

%ifndef __IDT_S__
                extern      IDTInit
                extern      RegisterHandler
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in lists.s
;----------------------------------------------------------------------------------------------

;----------------------------------------------------------------------------------------------
; This structure is the actual list structure.  In C, this would be implemented as a struct
; with defines to help with initialization.  In NASM, this will be our responsibility to
; initialize and maintain properly.
;----------------------------------------------------------------------------------------------

struc List
    .prev       resq    1
    .next       resq    1
endstruc

BADLISTPREV     equ         0xffffff7fffe00100
BADLISTNEXT     equ         0xffffff7fffe00200

%macro          InitializeList 1
                mov.q       [%1+List.prev],%1       ; set .prev member to point to itself
                mov.q       [%1+List.next],%1       ; set .next member to point to itself
%endmacro

%ifndef __LISTS_S__
                extern      ListAddHead             ; for stacks
                extern      ListAddTail             ; for queues
                extern      ListDel
                extern      ListDelInit
                extern      ListNext
                extern      ListEmpty
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in scheduler.s
;----------------------------------------------------------------------------------------------

%ifndef __SCHEDULER_S__
                extern      SchedulerInit
                extern      RdyKernQAdd
                extern      RdyHighQAdd
                extern      RdyNormQAdd
                extern      RdyLowQAdd
                extern      RdyIdleQAdd
                extern      GetNextProcess
                extern      SwitchToProcess
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in process.s
;----------------------------------------------------------------------------------------------

;----------------------------------------------------------------------------------------------
; These are the priorities that exist on the system.  These exist for 2 reasons:
; 1) to indicate to the system which processes are a higher priority (and therefore which
;    should get the CPU first).
; 2) they also become the quantum that is offered each process before being preempted (unless
;    the process blocks for some reason).
;
; There will be only 1 process with the PTY_IDLE priority per CPU: the idle process.  At least
; 1 process must be ready to run on each processor at any given time.  When only the idle
; process is ready, there will be a lot of possible context switches.  However, we should never
; perform a context switch to the current process -- it's just a waste.
;
; On the other end, kernel threads and drivers will run at the PTY_KERN priority.  Though there
; will be several driver threads, most of them will be in some kind of blocked state at any
; given moment, so they will not slow the system down.
;
; Most processes will be at a PTY_NORM priority.
;----------------------------------------------------------------------------------------------

PTY_IDLE        equ         1                       ; idle jobs get a quantum of 1
PTY_LOW         equ         5                       ; low priority jobs get a quantum of 5
PTY_NORM        equ         10                      ; normal jobs get a quantum of 10
PTY_HIGH        equ         20                      ; high priority jobs get a quantum of 20
PTY_KERN        equ         30                      ; kernel/drivers get a quantum of 30

;----------------------------------------------------------------------------------------------
; The Process structure is at the core of managing the work that is allowed to run on a CPU.
; Since the OS will preempt a process to replace it with another process (and the timer IRQ
; will have a different stack than the process), we will need to save all the registers in
; this structure as well.  Finally, there will be a global process list and the process can
; belong to one of several status queues.
;----------------------------------------------------------------------------------------------

PROC_NAME_LEN   equ         32

struc           Process
    .pid        resq        1                       ; Process ID by which it is known gloablly
    .name       resb        PROC_NAME_LEN           ; the name of the process when asked
    .totQtm     resq        1                       ; This is the total quantum used
    .procSts    resb        1                       ; This is the process status if executing
    .procPty    resb        1                       ; this is the process pty (see above)
    .quantum    resb        1                       ; quantum remaining in the timeslice
    .fill       resb        5                       ; aligning...
    .stackAddr  resq        1                       ; this is the stack address
    .ss         resq        1                       ; this is the saved ss register
    .rsp        resq        1                       ; saved rsp register
    .cr3        resq        1                       ; saved cr3 register -- proc specific PML4
    .glbl:                                          ; offset of the Global Process List struct
    .glbl.prev  resq        1                       ; List.prev
    .glbl.next  resq        1                       ; List.next
    .stsQ:                                          ; offset of the Status List struct
    .stsQ.prev  resq        1                       ; List.prev
    .stsQ.next  resq        1                       ; List.next
endstruc

%ifndef __PROCESS_S__
                extern      currentProcess

                extern      ProcessInit
                extern      ProcessResetQtm
                extern      ProcessSetPty

                extern      CreateProcess
                extern      ReadyProcess
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in pic.s
;----------------------------------------------------------------------------------------------

;----------------------------------------------------------------------------------------------
; The following structure will provide the abstraction for the 8259 PIC (Programmible Interrupt
; controller.  We will need this abstraction as we will determine if an IOAPIC (I/O Advanced
; Programmable Interrupt Controller) and replace the PIC-specific functions with IOAPIC-
; specific functions if the IOAPIC exists.  Therefore, depending on what you want to
; accomplish, simply call the functions stored in this structure and you will get the proper
; address of the function call.
;----------------------------------------------------------------------------------------------

struc           PIC
    .enableAll  resq        1                       ; function to enable all IRQs
    .disableAll resq        1                       ; function to disable all IRQs
    .enableIRQ  resq        1                       ; function to enable an IRQ
    .disableIRQ resq        1                       ; function to disable an IRQ
    .eoi        resq        1                       ; function to send an end of interrupt
    .readISR    resq        1                       ; function to read In-Service Reg (ISR)
    .readIRR    resq        1                       ; function to read Int Request Reg (IRR)
endstruc

%ifndef __PIC_S__
                extern      pic                     ; the pic structure

                extern      picInit                 ; Initialize the PIC
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in spur.s
;----------------------------------------------------------------------------------------------

%ifndef __SPUR_S__
                extern      SpurInit                ; Initialize the spurious interrupt handler
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in dbg-console.s
;----------------------------------------------------------------------------------------------

%ifndef __DBG_CONSOLE_S__
%ifndef DISABLE_DBG_CONSOLE
                extern      DbgConsoleInit
                extern      DbgConsolePutChar
                extern      DbgConsolePutString
                extern      DbgConsolePutHexByte
%endif
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in debugger.s
;----------------------------------------------------------------------------------------------

                extern      debugger

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in mb1.s
;----------------------------------------------------------------------------------------------

%ifndef __MB1_S__
                extern      ReadMB1                 ; Read the MB1 info block
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in kprintf.s
;----------------------------------------------------------------------------------------------

%ifndef __KPRINTF_S__
                extern      kprintf
                extern      ksprintf
                extern      ksnprintf
                extern      kvprintf
                extern      kvsprintf
                extern      kvsnprintf
                extern      kstrlen

%ifndef DISABLE_DBG_CONSOLE
                extern      dbgprintf
                extern      dbgvprintf
%endif
%endif

