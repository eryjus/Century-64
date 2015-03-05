;==============================================================================================
;
; scheduler.s
;
; This file contains the functions and structures needed to schedule processes and preemptively
; perform multitasking.
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
; So, our scheduler file is responsible for changing from one process to another.  All of the
; variables and structures related to the process scheduler will be kept in a consolidated
; structure.  Though I am not fully confident, I expect that there will be one instance for
; each processor.  On the other hand, I might be able to have one for the whole system and
; have all processes shared among all CPUs.  This latter situation would be better for
; workload management.
;
; My big internal debate on this topic is how to replace the registers on each task switch.
; There are several things that can trigger a task switch.  However, the stack is not
; consistent for each one.  For example, the quantum might expire and therefore a task
; needs to be removed from the CPU and allow another one to be executed.  Then that happens,
; the CPU will set a new stack for the interrupt handler.  This means that any registers
; that get pushed on the stack will be on the kernel ESP0 stack, not the process ESP3 stack.
; I can replace the registers in a SwitchToTask function, but leaving the interrupt will
; put the registers back to the old state, foiling the process change.  I could easily adjust
; the register values on the stack, but then what to do when a process os blocked via some
; other mechanism -- such as waiting for a message.  Now, on the other hand, these will be
; system calls, at which point I should be able to handle the change the same (or a similar)
; manner.  I will go forward on this assumption and hope I don't have too much rework to do.
;
; OK, let's discuss how to handle a task swap.  I need a function SwitchToProcess that
; will pre-emptively switch to the specified process (by address).  This function will be
; responsible for establishing the state for the new process only.  It will not need to be
; responsibel for saving the state for the current process.  The reason for this is singular,
; though rather complicated in detail: I need to have a single path out of the the task swap
; that is consistent so that I can be sure to set a known state.  On the other hand, the
; reason I might be doing a task swap (and therefore the path into the task swap) can be
; many and therefore the condition of the stacks (yes, multiple) will all be in different.
; I will know how I am getting to the task swap (quantum expires, process sleeps, message
; unblocks a higher priority process, trying to acquire a lock and donating the remaining
; quantum to the process holding a lock, DMA transfer completes, etc.).  Therefore, it is
; easier in my mind to save the state properly on the process stack even if that means
; copying a few extra bytes during an interrupt so that we can have a consistent path out
; of the interrupt to resume the process code.  To make a long story short, I will have
; multiple flavors of SaveProcessState to implement (I see 2 for now -- interrupted and
; procedure call).
;
; So, let's start with the way the stacks will need to be prepared for return to user code.
;
; |           |          |
; +-----------+----------+
; |  RSP+200  |          | <-- The last known RSP address to which we return
; +-----------+----------+
; |  RSP+192  |    SS    | <-- This is the SS from User Land (most likely CPL=3)
; +-----------+----------+
; |  RSP+184  |   RSP    | <-- This is the RSP address of the last know RSP address (above)
; +-----------+----------+
; |  RSP+176  |  RFLAGS  | <-- This is the flags state (including interrupts) to which we ret
; +-----------+----------+
; |  RSP+168  |    CS    | <-- This is the CS from User Land (most likely CPL=3)
; +-----------+----------+
; |  RSP+160  |   RIP    | <-- This is the interrupted/pre-empted instruction in User Land
; +-----------+----------+
; |  RSP+152  |   RBP    | <-- This and the following are the interrupted/preempted register
; +-----------+----------+     values stored on the user's stack.  They will be resotred as
; |  RSP+144  |   RAX    |     such.
; +-----------+----------+
; |  RSP+136  |   RBX    |
; +-----------+----------+
; |  RSP+128  |   RCX    |
; +-----------+----------+
; |  RSP+120  |   RDX    |
; +-----------+----------+
; |  RSP+112  |   RSI    |
; +-----------+----------+
; |  RSP+104  |   RDI    |
; +-----------+----------+
; |   RSP+96  |    R8    |
; +-----------+----------+
; |   RSP+88  |    R9    |
; +-----------+----------+
; |   RSP+80  |   R10    |
; +-----------+----------+
; |   RSP+72  |   R11    |
; +-----------+----------+
; |   RSP+64  |   R12    |
; +-----------+----------+
; |   RSP+56  |   R13    |
; +-----------+----------+
; |   RSP+48  |   R14    |
; +-----------+----------+
; |   RSP+40  |   R15    |
; +-----------+----------+
; |   RSP+32  |    DS    |
; +-----------+----------+
; |   RSP+24  |    ES    |
; +-----------+----------+
; |   RSP+16  |    FS    |
; +-----------+----------+
; |   RSP+8   |    GS    |
; +-----------+----------+
; |    RSP    | TSwapTgt | <-- This is the TaskSwapTarget address in code.  When this stack is
; +-----------+----------+     put in place, we should be running at CPL=0, so we should be
;                              prepared to set this stack in place and execute a number of
;                              statements to restore the state:
;
; 1) set CR3 from saved value in Process
; 2) set SS from saved value in Process
; 3) set RSP from saved value in Process
; 4) execute a ret, giving TSwapTgt control
; 5) Reset the quantum on the process
; 6) TSwapTgt restores all the registers from the user stack
; 7) TSwapTgt then executes an iretq to properly drop back into the user process
;
; So, now the question becomes what to do when we are in an interrupt and the quantum is
; expired.  In this case, all of the values we need to save are in regs and RSP0 stack and we
; will want to get them off this stack and onto the user process stack.  However, we only want
; to do this if we are actually going to change tasks.  If, for example, we are only executing
; the idle task and nothing else is in the queue, then there will be nothing to switch to and
; therefore no need to save anything.  So, the algorithm we will use to get to the call to
; SwitchToProcess is:
; A) If the quantum is expired, call GetNextProcess to get the next process in the queue
; B) If next process == currentProcess, reset the quantum and exit (no need to change) and exit
; C) Otherwise, subtract 200 from the User Stack
; D) Copy SS to RIP from the RSP0 to the User Stack
; E) Copy RBP to GS from registers and the RSP0 to the User Stack
; F) Put TSwapTgt into [RSP] -- this should take up all the positions on the stack
; G) Save RSP and SS in the Process structure
; H) Save CR3 in the Process Structure
; I) Now, call SwitchToProcess to execute a task switch to the newly selected process
;
; Finally, IRQ0 will need an EOI to be generated in order to allow timer interrupts to flow
; freely again.  This must be done at the end of SwitchToProcess.  However, not all calls to
; SwitchToProcess need to generate an EOI.  Therefore we will need to add it as a parameter.
;
; The following functions are published in this source:
;
; The following functions are internal to the source file:
;
; The following function is an error reporting function from which there is no return:
;
;    Date     Tracker  Pgmr  Description
; ----------  -------  ----  ------------------------------------------------------------------
; 2014/12/07  Initial  ADCL  Initial version
;
;==============================================================================================

%define     __SCHEDULER_S__
%include    'private.inc'

;==============================================================================================
; In this first section (before we get into any real data or code), we will define some
; constants and such to make out coding easier.
;==============================================================================================

;----------------------------------------------------------------------------------------------
; The following structure aggregates all the information needed to manage and schedule
; processes for execution on the processor.
;----------------------------------------------------------------------------------------------

struc           Scheduler
    .enabled        resq    1
    .rdyKern:
    .rdyKern.prev   resq    1
    .rdyKern.next   resq    1
    .rdyHigh:
    .rdyHigh.prev   resq    1
    .rdyHigh.next   resq    1
    .rdyNorm:
    .rdyNorm.prev   resq    1
    .rdyNorm.next   resq    1
    .rdyLow:
    .rdyLow.prev    resq    1
    .rdyLow.next    resq    1
    .rdyIdle:
    .rdyIdle.prev   resq    1
    .rdyIdle.next   resq    1
    .waitQ:
    .waitQ.prev     resq    1
    .waitQ.next     resq    1
    .stackAddr      resq    1
    .stackPtr       resq    1
endstruc

;==============================================================================================
; This is the .bss section.  It contains uninitialized data.
;==============================================================================================

                section     .bss

sched:          resb        Scheduler_size
timerCounter    resq        1

;==============================================================================================
; This is the code section of the source file.  It will be part of the kernel.
;==============================================================================================

                section     .text
                bits        64

;----------------------------------------------------------------------------------------------
; void SchedulerInit(void) -- This function inialized the scheduler.  This consists of
;                             setting up the lists to be empty and ensuring the scheduler is
;                             disabled for now.
;----------------------------------------------------------------------------------------------

                global      SchedulerInit

SchedulerInit:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx

;----------------------------------------------------------------------------------------------
; maks sure the scheduler is disabled
;----------------------------------------------------------------------------------------------

                mov.q       rbx,sched               ; get the structure address
                mov.q       [rbx+Scheduler.enabled],0   ; the scheduler is disabled for now

;----------------------------------------------------------------------------------------------
; initialize the Kernel Priority Ready List to empty
;----------------------------------------------------------------------------------------------

                lea.q       rax,[rbx+Scheduler.rdyKern] ; get address of the Kernel Rdy List
                InitializeList      rax             ; initialize the list to empty

;----------------------------------------------------------------------------------------------
; initialize the High Priority Ready List to empty
;----------------------------------------------------------------------------------------------

                lea.q       rax,[rbx+Scheduler.rdyHigh] ; get address of the High Rdy List
                InitializeList      rax             ; initialize the list to empty

;----------------------------------------------------------------------------------------------
; initialize the Normal Priority Ready List to empty
;----------------------------------------------------------------------------------------------

                lea.q       rax,[rbx+Scheduler.rdyNorm] ; get address of the Normal Rdy List
                InitializeList      rax             ; initialize the list to empty

;----------------------------------------------------------------------------------------------
; initialize the Low Priority Ready List to empty
;----------------------------------------------------------------------------------------------

                lea.q       rax,[rbx+Scheduler.rdyLow] ; get address of the Low Rdy List
                InitializeList      rax             ; initialize the list to empty

;----------------------------------------------------------------------------------------------
; initialize the Idle Priority Ready List to empty
;----------------------------------------------------------------------------------------------

                lea.q       rax,[rbx+Scheduler.rdyIdle] ; get address of the Idle Rdy List
                InitializeList      rax             ; initialize the list to empty

;----------------------------------------------------------------------------------------------
; initialize the Process Wait Queue to empty
;----------------------------------------------------------------------------------------------

                lea.q       rax,[rbx+Scheduler.waitQ] ; get address of the Qait Queue List
                InitializeList      rax             ; initialize the list to empty

;----------------------------------------------------------------------------------------------
; Get a stack for the IRQ0 handler and set it in the strcuture
;----------------------------------------------------------------------------------------------

                call        AllocStack              ; get a stack
                mov.q       [rbx+Scheduler.stackAddr],rax   ; set it in the struct
                add.q       rax,STACK_SIZE          ; get to the top of the stack
                mov.q       [rbx+Scheduler.stackPtr],rax    ; set it in the struct

;----------------------------------------------------------------------------------------------
; initialize the PIC. We are looking for a frequency of 500 cycles per second.  This is
; calculated as 1.193182MHz/500 (or 1193182/500 == 2386 [rounded], or 0x0952)
;----------------------------------------------------------------------------------------------

                call        picInit                 ; Initialize the 8259 PIC

                mov.b       al,0x36                 ; we want to program the clock frequency
                out         0x43,al                 ; send the request to the PIT

                mov.b       al,0x52                 ; send the low byte to the PIT
                out         0x40,al                 ; send it

                mov.b       al,0x09                 ; send the high byte to the PIT
                out         0x40,al                 ; send it

;----------------------------------------------------------------------------------------------
; now, install the IRQ0 handler and enable the IRQ
;----------------------------------------------------------------------------------------------

                mov.q       rax,IST2                ; we want IST2
                push        rax                     ; push it on the stack
                mov.q       rax,IRQ0Handler         ; this is our handler address
                push        rax                     ; push that on the stack
                push        0x20                    ; finally we want interrupt 0x20
                call        RegisterHandler         ; now, regoster our IRQ handler
                add.q       rsp,24                  ; clean up the stack

                push        0                       ; we will enable irq 0
                mov.q       rax,pic                 ; get the pic structure address
                mov.q       rax,[rax+PIC.enableIRQ] ; get the function to enable an IRQ
                call        rax                     ; call the function
                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void RdyKernQAdd(qword list) -- Add a Process to the Kernel Ready Queue (by passing in the
;                                 Process.stsQ address)
;----------------------------------------------------------------------------------------------

                global      RdyKernQAdd

RdyKernQAdd:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame

%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,addKern             ; get the debug string
                push        rax                     ; push it on the stack
                call        dbgprintf               ; call the function to print to console
                add.q       rsp,8                   ; clean up the stack
%endif

                mov.q       rax,sched               ; get the scheduler structure address
                lea.q       rax,[rax+Scheduler.rdyKern] ; get the address of the ready queue
                push        rax                     ; push that on the stack

                mov.q       rax,[rbp+16]            ; get the address of the list structure
                push        rax                     ; push that on the stack
                call        ListAddTail             ; add the Process to the list at the tail

                add.q       rsp,16                  ; clean up the stack

                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void RdyHighQAdd(qword list) -- Add a Process to the High Ready Queue (by passing in the
;                                 Process.stsQ address)
;----------------------------------------------------------------------------------------------

                global      RdyHighQAdd

RdyHighQAdd:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame

%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,addHigh             ; get the debug string
                push        rax                     ; push it on the stack
                call        dbgprintf               ; call the function to print to console
                add.q       rsp,8                   ; clean up the stack
%endif

                mov.q       rax,sched               ; get the scheduler structure address
                lea.q       rax,[rax+Scheduler.rdyHigh] ; get the address of the ready queue
                push        rax                     ; push that on the stack

                mov.q       rax,[rbp+16]            ; get the address of the list structure
                push        rax                     ; push that on the stack
                call        ListAddTail             ; add the Process to the list at the tail

                add.q       rsp,16                  ; clean up the stack

                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void RdyNormQAdd(qword list) -- Add a Process to the Normal Ready Queue (by passing in the
;                                 Process.stsQ address)
;----------------------------------------------------------------------------------------------

                global      RdyNormQAdd

RdyNormQAdd:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame

%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,addNorm             ; get the debug string
                push        rax                     ; push it on the stack
                call        dbgprintf               ; call the function to print to console
                add.q       rsp,8                   ; clean up the stack
%endif

                mov.q       rax,sched               ; get the scheduler structure address
                lea.q       rax,[rax+Scheduler.rdyNorm] ; get the address of the ready queue
                push        rax                     ; push that on the stack

                mov.q       rax,[rbp+16]            ; get the address of the list structure
                push        rax                     ; push that on the stack
                call        ListAddTail             ; add the Process to the list at the tail

                add.q       rsp,16                  ; clean up the stack

                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void RdyLowQAdd(qword list) -- Add a Process to the Low Ready Queue (by passing in the
;                                Process.stsQ address)
;----------------------------------------------------------------------------------------------

                global      RdyLowQAdd

RdyLowQAdd:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame

%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,addLow              ; get the debug string
                push        rax                     ; push it on the stack
                call        dbgprintf               ; call the function to print to console
                add.q       rsp,8                   ; clean up the stack
%endif

                mov.q       rax,sched               ; get the scheduler structure address
                lea.q       rax,[rax+Scheduler.rdyLow] ; get the address of the ready queue
                push        rax                     ; push that on the stack

                mov.q       rax,[rbp+16]            ; get the address of the list structure
                push        rax                     ; push that on the stack
                call        ListAddTail             ; add the Process to the list at the tail

                add.q       rsp,16                  ; clean up the stack

                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void RdyIdleQAdd(qword list) -- Add a Process to the Idle Ready Queue (by passing in the
;                                 Process.stsQ address)
;----------------------------------------------------------------------------------------------

                global      RdyIdleQAdd

RdyIdleQAdd:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame

%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,addIdle             ; get the debug string
                push        rax                     ; push it on the stack
                call        dbgprintf               ; call the function to print to console
                add.q       rsp,8                   ; clean up the stack
%endif

                mov.q       rax,sched               ; get the scheduler structure address
                lea.q       rax,[rax+Scheduler.rdyIdle] ; get the address of the ready queue
                push        rax                     ; push that on the stack

                mov.q       rax,[rbp+16]            ; get the address of the list structure
                push        rax                     ; push that on the stack
                call        ListAddTail             ; add the Process to the list at the tail

                add.q       rsp,16                  ; clean up the stack

                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void SwitchToProcess(qword procAddr, qword eoi) -- Execute the switch to the process
;                                                    identified by the structure at the addr.
;
; Remember that this is a special case function and does not have a normal return path in that
; it will not return to the calling function.  Ever.  We will be replacing the stack in this
; function and returning on that new stack.  This function also has no need to save any
; registers as the function "returned to" will restore all registers from the new stack.
;
; Finally, based on the value in eoi, we will be issuing an eoi to the PIC if non-zero.  Or
; course this will happen as late as possible in this function and we will not be enabling
; interrupts in this function.
;----------------------------------------------------------------------------------------------

                global      SwitchToProcess

SwitchToProcess:
                push        rbp                     ; save the caller's frame (on old stack)
                mov.q       rbp,rsp                 ; create our own (even though not needed)

;----------------------------------------------------------------------------------------------
; get the parameters from the old stack and hold them for later
;----------------------------------------------------------------------------------------------
                mov.q       rbx,[rbp+16]            ; get the process address
                mov.q       rcx,[rbp+24]            ; get the eoi flag

;----------------------------------------------------------------------------------------------
; now, get the CR3, SS, and RSP values from the structure
;----------------------------------------------------------------------------------------------
                mov.q       rax,[rbx+Process.cr3]   ; get cr3
                mov.q       rdi,[rbx+Process.rsp]   ; get rsp
                mov.q       rdx,[rbx+Process.ss]    ; get ss

;----------------------------------------------------------------------------------------------
; set CR3, and then SS & RSP from registers
;----------------------------------------------------------------------------------------------
                mov         cr3,rax                 ; set paging tables
                mov.w       ss,dx                   ; set the SS
                mov.q       rsp,rdi                 ; IMMEDIATELY followed by RSP

;----------------------------------------------------------------------------------------------
; remove the next process from the ready queue
;----------------------------------------------------------------------------------------------
                mov.q       rax,[rbp+16]            ; get the process struct address from stack
                lea.q       rax,[rax+Process.stsQ]  ; get the address of the queue
                push        rax                     ; and push it on the stack
                call        ListDelInit             ; remove it from the list
                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; do some variable and structure housekeeping
;----------------------------------------------------------------------------------------------
                mov.q       rsi,currentProcess      ; get the currentProcess var address
                mov.q       rax,[rsi]               ; get the actual current process address

                push        rax                     ; push the parm
                call        ReadyProcess            ; put the process on the ready queue
                add.q       rsp,8                   ; clean up the stack

                mov.q       [rsi],rbx               ; make the new process the currentProcess

                push        rbx                     ; push this process on the stack
                call        ProcessResetQtm         ; reset the quantum
                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; now, we have the stack in place for the process we are swapping to.  check for an eoi
;----------------------------------------------------------------------------------------------
                cmp.q       rcx,0                   ; are we skipping eoi?
                je          .out                    ; if so, go straight to exit

.eoi:           mov.q       rax,pic                 ; get the pic strucutre
                mov.q       rax,[rax+PIC.eoi]       ; get the address of the eoi function
                push        0                       ; perform EOI for IRQ0
                call        rax                     ; do the eoi
                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; At this point, we will return to the TSwapTgt to restore the registers and finally return to
; the interrupted process.  Note that the previous stack is abandonned but ready for re-use.
;----------------------------------------------------------------------------------------------

.out:           ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword GetNextProcess(void) -- Get the next process in line to execute.  If nothing else is
;                               in the ready queue, then return the currentProcess.
;
; We also need to keep in mind that the current process has a priority and we do not want to
; preempt that process in favor os a lower priority process
;----------------------------------------------------------------------------------------------

                global      GetNextProcess

GetNextProcess:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        r9                      ; save r9

;----------------------------------------------------------------------------------------------
; perform some initialization
;----------------------------------------------------------------------------------------------

                mov.q       rbx,sched               ; get the scheduler struct address

                mov.q       rax,currentProcess      ; get the address for the current Proc var
                mov.q       rax,[rax]               ; get the contents, the addr of Proc struct
                xor.q       rcx,rcx                 ; clear rcx
                mov.b       cl,[rax+Process.procPty]; get the process priority

                mov.q       r9,rax                  ; assume we will return the current process

;----------------------------------------------------------------------------------------------
; go through each queue in order and find the next process to take.  Start with the kernel
; priority processes.  Since nothing can be higher than that, we do not need to check the
; currentProcess priority against the scheduler
;----------------------------------------------------------------------------------------------

.kern:

%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,chkKern             ; get the debug string
                push        rax                     ; push it on the stack
                call        dbgprintf               ; call the function to print to console
                add.q       rsp,8                   ; clean up the stack
%endif

                lea.q       rax,[rbx+Scheduler.rdyKern] ; get the list for kernel priority
                push        rax                     ; push the address on the stack
                call        ListNext                ; get the next entry, 0 if none
                add.q       rsp,8                   ; clean up the stack

                cmp.q       rax,0                   ; 0 means the queue was empty
                je          .high                   ; <> 1 means we have an empty queue

                sub.q       rax,Process.stsQ        ; convert the List addr to the Process addr
                jmp         .out                    ; we found something, return it

;----------------------------------------------------------------------------------------------
; Now, we get a bit trickier.  The running process might be a kernel priority.  If it is, then
; there is no way that the running process should be preempted in favor of a high priority
; process, since the running process is higher.  So, we start by checking the running process
; and exit returning the running process if that process is a kernel priority.
;----------------------------------------------------------------------------------------------

.high:
                cmp.b       cl,PTY_KERN             ; is the running process a kernel pty?
                je          .default                ; return the currentProcess

%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,chkHigh             ; get the debug string
                push        rax                     ; push it on the stack
                call        dbgprintf               ; call the function to print to console
                add.q       rsp,8                   ; clean up the stack
%endif

                lea.q       rax,[rbx+Scheduler.rdyHigh] ; get the list for high priority
                push        rax                     ; push the address on the stack
                call        ListNext                ; get the next entry, 0 if none
                add.q       rsp,8                   ; clean up the stack

                cmp.q       rax,0                   ; 0 means the queue was empty
                je          .norm                   ; <> 1 means we have an empty queue

                sub.q       rax,Process.stsQ        ; convert the List addr to the Process addr
                jmp         .out                    ; we found something, return it

;----------------------------------------------------------------------------------------------
; Still a bit trickier.  We know at this point: 1) there is nothing in the kernel queue; 2)
; there is nothing in the high queue; and, 3) the current process is not a kernel priority.
; So, we only need to check the current process for a high priority -- if it is, we will return
; it as the next process.  If not, we will check the normal queue.
;----------------------------------------------------------------------------------------------

.norm:
                cmp.b       cl,PTY_HIGH             ; is the running process a high pty?
                je          .default                ; return the currentProcess

%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,chkNorm             ; get the debug string
                push        rax                     ; push it on the stack
                call        dbgprintf               ; call the function to print to console
                add.q       rsp,8                   ; clean up the stack
%endif

                lea.q       rax,[rbx+Scheduler.rdyNorm] ; get the list for normal priority
                push        rax                     ; push the address on the stack
                call        ListNext                ; get the next entry, 0 if none
                add.q       rsp,8                   ; clean up the stack

                cmp.q       rax,0                   ; 0 means the queue was empty
                je          .low                    ; <> 1 means we have an empty queue

                sub.q       rax,Process.stsQ        ; convert the List addr to the Process addr
                jmp         .out                    ; we found something, return it

;----------------------------------------------------------------------------------------------
; Now we get to be repetitive.  Check the currentProcess against PTY_NORM and check the low
; queue.
;----------------------------------------------------------------------------------------------

.low:
                cmp.b       cl,PTY_NORM             ; is the running process a normal pty?
                je          .default                ; return the currentProcess

%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,chkLow              ; get the debug string
                push        rax                     ; push it on the stack
                call        dbgprintf               ; call the function to print to console
                add.q       rsp,8                   ; clean up the stack
%endif

                lea.q       rax,[rbx+Scheduler.rdyLow] ; get the list for low priority
                push        rax                     ; push the address on the stack
                call        ListNext                ; get the next entry, 0 if none
                add.q       rsp,8                   ; clean up the stack

                cmp.q       rax,0                   ; 0 means the queue was empty
                je          .idle                   ; <> 1 means we have an empty queue

                jmp         .out                    ; we found something, return it

;----------------------------------------------------------------------------------------------
; Finally, we check the running process against low, and then check the idle queue.  This
; condition should almost never happen.  It means that the only running user process ended
; (not blocked and waiting for some I/O, as another driver would take over) and we need the
; idle process to run.
;----------------------------------------------------------------------------------------------

.idle:
                cmp.b       cl,PTY_LOW              ; is the running process a low pty?
                je          .default                ; return the currentProcess

%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,chkIdle             ; get the debug string
                push        rax                     ; push it on the stack
                call        dbgprintf               ; call the function to print to console
                add.q       rsp,8                   ; clean up the stack
%endif

                lea.q       rax,[rbx+Scheduler.rdyIdle] ; get the list for kernel priority
                push        rax                     ; push the address on the stack
                call        ListNext                ; get the next entry, 0 if none
                add.q       rsp,8                   ; clean up the stack

                cmp.q       rax,0                   ; 0 means the queue was empty
                je          .default                ; <> 1 means we have an empty queue

                jmp         .out                    ; we found something, return it

;----------------------------------------------------------------------------------------------
; Finally, at this point, the running process is the idle process, and there is no other work
; to do.
;----------------------------------------------------------------------------------------------

.default:

%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,dftGetNxtProc       ; get the debug string
                push        rax                     ; push it on the stack
                call        dbgprintf               ; call the function to print to console
                add.q       rsp,8                   ; clean up the stack
%endif

                mov.q       rax,r9                  ; set the return value

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:

%ifndef DISABLE_DBG_CONSOLE
                push        rax                     ; we will save rax on the stack
                lea.q       rax,[rax+Process.name]  ; get the name address
                push        rax                     ; push it on the stack
                mov.q       rax,rsltGetNxtProc      ; get the debug string
                push        rax                     ; push it on the stack
                call        dbgprintf               ; call the function to print to console
                add.q       rsp,16                  ; clean up the stack
                pop         rax                     ; and get our return value back
%endif

                pop         r9                      ; restore r9
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; IRQ0Handler -- This is the Interrupt handler for IRQ0.  It will be called with each Timer
;                tick.  Therefore, when there is nothing to do, we want to get in and get out
;                quickly,  On the other hand, when we are ready to preempt a process, we also
;                need to make that happen quickly.
;
; Keep in mind that this 'function' does not have a normal entry process or exit process.  We
; need to be particularly careful about saving and restoring EVERYTHING we will touch.
;----------------------------------------------------------------------------------------------

IRQ0Handler:
                cmp.q       [rsp+8],8
                je          .ll

                BREAK

.ll:
                push        rbp                     ; save the interrupted process's frame
                mov.q       rbp,rsp                 ; we want our own frame
                push        rax                     ; yes, we even save rax
                push        rbx                     ; save rbx
                push        rsi                     ; save rsi
                push        rdi                     ; save rdi

                cmp.q       [rbp+40],0x10
                je          .lll

                BREAK

.lll:

                mov.q       rax,timerCounter        ; get the address of the var
                inc         qword [rax]             ; increment the counter

%if 0
                mov.q       rbx,[rax]               ; get the value in a work register
                and.q       rbx,0x01ff              ; is it time to update the screen?
                cmp.q       rbx,0x0100              ; are these bits 0?
                je          .clr                    ; it's time to clear the byte

                cmp.q       rbx,0                   ; which state to which to update
                jne         .eoi                    ; we're fine, get out

                mov.b       al,'*'
                jmp         .upd

.clr:           mov.b       al,' '
.upd:           mov.b       [0xb8000],al
%endif

;----------------------------------------------------------------------------------------------
; Now, some housekeeping for the running process
;----------------------------------------------------------------------------------------------

                mov.q       rbx,currentProcess      ; get the running process address var
                mov.q       rbx,[rbx]               ; get the current proc struct addr
                inc         qword [rbx+Process.totQtm]  ; increment the quantum
                dec         byte [rbx+Process.quantum]  ; one less quantum left

                cmp.b       [rbx+Process.quantum],0 ; has time run out?
                jg          .eoi                    ; if not, exit

;----------------------------------------------------------------------------------------------
; Here we know the quantum has expired for the current process.  We really want to execute a
; task switch.  In order to do this, we first need to figure out what the next task is.  In
; fact, we only want to switch tasks if the running task is different than the newly selected
; task.
;----------------------------------------------------------------------------------------------

%ifndef DISABLE_DBG_CONSOLE
                push        rax                     ; save rax
                mov.q       rax,qtmExpired          ; get the text to write
                push        rax                     ; push it on the stack
                call        dbgprintf               ; write it to the debug console
                add.q       rsp,8                   ; clean up the stack
                pop         rax                     ; restore rax
%endif

                call        GetNextProcess          ; get the next process structure addr
                cmp.q       rax,rbx                 ; are they the same?
                jne         .swap                   ; if not the same, we will swap tasks

%ifndef DISABLE_DBG_CONSOLE
                push        rax                     ; save rax
                mov.q       rax,resettingQtm        ; get the var address for the current proc
                push        rax                     ; push the name on the stack
                call        dbgprintf               ; put the name to the debug console
                add.q       rsp,8                   ; clean up the stack
                pop         rax                     ; restore rax
%endif

                push        rax                     ; push the process to reset
                call        ProcessResetQtm         ; reset the quantum
                add.q       rsp,8                   ; clean up the stack

%ifndef DISABLE_DBG_CONSOLE
                push        rax                     ; save rax
                mov.q       rax,currentProcess      ; get the var address for the current proc
                mov.q       rax,[rax]               ; get the proc structure address
                lea.q       rax,[rax+Process.name]  ; get the name
                push        rax                     ; push the name on the stack
                mov.q       rax,hasControl          ; get the rest of the string
                push        rax                     ; push the name on the stack
                call        dbgprintf               ; put the name to the debug console
                add.q       rsp,16                  ; clean up the stack
                pop         rax                     ; restore rax
%endif

                jmp         .eoi                    ; jump to issue EOI

;----------------------------------------------------------------------------------------------
; We have gotten to this point we know we need to save the state of the current running
; process.  This next section should work since we are operating under the interrupted
; process's paging tables.
;----------------------------------------------------------------------------------------------

.swap:
                mov.q       rsi,rax                 ; save the target process structure

%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,swapStart           ; get the address of the message
                push        rax                     ; push it on the stack
                call        dbgprintf               ; write it to the debug console
                add.q       rsp,8                   ; clean up the stack
%endif

                mov.q       rdi,[rbp+32]            ; get the user stack pointer
                sub.q       rdi,200                 ; make room for the registers

                mov.q       rax,[rbp+40]            ; get SS from the stack
                mov.q       [rdi+192],rax           ; set SS into the user stack

                mov.q       rax,[rbp+32]            ; get RSP from the stack
                mov.q       [rdi+184],rax           ; set RSP into the user stack

                mov.q       rax,[rbp+24]            ; get the RFLAGS from the stack
                mov.q       [rdi+176],rax           ; set RFLAGS into the user stack

                mov.q       rax,[rbp+16]            ; get the CS from the stack
                mov.q       [rdi+168],rax           ; set the CS into the user stack

                mov.q       rax,[rbp+8]             ; get RIP from the stack
                mov.q       [rdi+160],rax           ; set RIP into the user stack

                mov.q       rax,[rbp]               ; get RBP from the stack
                mov.q       [rdi+152],rax           ; set RBP into the user stack

                mov.q       rax,[rbp-8]             ; get RAX from the stack
                mov.q       [rdi+144],rax           ; set RAX into the user stack

                mov.q       rax,[rbp-16]            ; get RBX from the stack
                mov.q       [rdi+136],rax           ; set RBX into the user stack

                mov.q       [rdi+128],rcx           ; set RCX into the user stack
                mov.q       [rdi+120],rdx           ; set RDX into the user stack

                mov.q       rax,[rbp-24]            ; get RSI from the stack
                mov.q       [rdi+112],rax           ; set RSI into the user stack

                mov.q       rax,[rbp-32]            ; get RDI from the stack
                mov.q       [rdi+104],rax           ; set RDI into the user stack

                mov.q       [rdi+96],r8             ; set R8 into the user stack
                mov.q       [rdi+88],r9             ; set R9 into the user stack
                mov.q       [rdi+80],r10            ; set R10 into the user stack
                mov.q       [rdi+72],r11            ; set R11 into the user stack
                mov.q       [rdi+64],r12            ; set R12 into the user stack
                mov.q       [rdi+56],r13            ; set R13 into the user stack
                mov.q       [rdi+48],r14            ; set R14 into the user stack
                mov.q       [rdi+40],r15            ; set R15 into the user stack

                xor.q       rax,rax                 ; clear upper rax
                mov.w       ax,ds                   ; get ds
                mov.q       [rdi+32],rax            ; set DS into the user stack

                mov.w       ax,es                   ; get ds
                mov.q       [rdi+24],rax            ; set DS into the user stack

                mov.w       ax,fs                   ; get ds
                mov.q       [rdi+16],rax            ; set DS into the user stack

                mov.w       ax,gs                   ; get ds
                mov.q       [rdi+8],rax             ; set DS into the user stack

                mov.q       rax,TSwapTgt            ; get the Task Swap target address
                mov.q       [rdi],rax               ; and set it on the stack

;----------------------------------------------------------------------------------------------
; Nearly there.  Now we need to save the state of the CR3, SS, and RSP in the process structure
;----------------------------------------------------------------------------------------------
                mov.q       rax,[rbp+40]            ; get SS from the stack
                mov.q       [rbx+Process.ss],rax    ; set SS into the Process structure

%ifndef DISABLE_DBG_CONSOLE
                cmp.q       rax,0x10                ; do we ahve a valid ss
                je          .l                      ; if so, continue on

                push        rax                     ; save rax
                push        rax                     ; push the value
                mov.q       rax,ssVal               ; get the string
                push        rax                     ; push that on the stack
                call        dbgprintf               ; output the message
                add.q       rsp,16                  ; clean up the stack
                pop         rax                     ; restore rax

                BREAK
.l:
%endif
                mov.q       rax,cr3                 ; get CR3
                mov.q       [rbx+Process.cr3],rax   ; and set it into the Process structure

                mov.q       [rbx+Process.rsp],rdi   ; set the stack into the Process structure

;----------------------------------------------------------------------------------------------
; Now, we come to the critical part, and this is important to understand.  We have the task we
; will be swapping to and we know we need to issue an EOI at the end of SwitchToProcess.  The
; last thing to do is call SwitchToProcess.  Switch to task will restore the CR3 page tables
; and the SS:RSP values and then return.  However, we will not be returing on THIS STACK.  This
; is important to fully grasp.  SwitchToProcess does not return to this point.  We will be
; abandoning the stack for the user stack and SwitchToProcess will actually return to
; TSwapTgt.  The stack will not get used after this call and can be trashed by the next IRQ to
; use that stack.  There will be no need to clean up the stack.
;----------------------------------------------------------------------------------------------

                push        1                       ; we need an EOI
                push        rsi                     ; push the Process structure to switch
                call        SwitchToProcess         ; go and execute the process change

                ; =================================================
                ; !!!!!  Control never returns to this point  !!!!!
                ; =================================================

;----------------------------------------------------------------------------------------------
; For now, we will send the EOI to the 8259 PIC; this will have to change when we implmement
; the APIC driver -- not sure how we will accomplish this yet.
;----------------------------------------------------------------------------------------------

.eoi:
%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,currentProcess      ; get the address of the currentProcess
                mov.q       rax,[rax]               ; get the currentProcess Struct addr
                xor.q       rbx,rbx                 ; clear rbx
                mov.b       bl,[rax+Process.quantum]; get the current quantum
                push        rbx                     ; save this to the stack
                call        DbgConsolePutHexByte    ; write it to the screen
                add.q       rsp,8                   ; clean up the stack
%endif

                push        0                       ; we need to ackowledge EOI for IRQ 0
                mov.q       rax,pic                 ; get the pic structure address
                mov.q       rax,[rax+PIC.eoi]       ; get the function to call
                call        rax                     ; call the eoi function
                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; clean up and return from the interrupt
;----------------------------------------------------------------------------------------------

                pop         rdi                     ; restore rdi
                pop         rsi                     ; restore rsi
                pop         rbx                     ; restore rbx
                pop         rax                     ; restore rax
                pop         rbp                     ; restore rbp

                iretq

;==============================================================================================

;----------------------------------------------------------------------------------------------
; TSwapTgt -- This is not a function that will be called.  Instead this is a return point after
;             each task swap is executed.  It will NEVER be called directly.
;
; The responsibility of this slice of code is to restore the state of the user process and
; return (most likely to user land [CPL=3]) and allow the process to continue on.  Before
; getting to this point, the paging tables have been reloaded and the stack has been restored.
; We should be at CPL=0 (I cannot imagine why we wouldn't be) and when we iretq from this
; code, we will likely have a priveledge change.
;----------------------------------------------------------------------------------------------

                global      TSwapTgt

TSwapTgt:
%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,currentProcess      ; get the var address for the current proc
                mov.q       rax,[rax]               ; get the proc structure address
                lea.q       rax,[rax+Process.name]  ; get the name
                push        rax                     ; push the name on the stack
                mov.q       rax,hasControl          ; get the rest of the string
                push        rax                     ; push the name on the stack
                call        dbgprintf               ; put the name to the debug console
                add.q       rsp,16                  ; clean up the stack
%endif

                pop         rax                     ; restore GS from the stack
                mov.w       gs,ax                   ; set the value

                pop         rax                     ; restore FS from the stack
                mov.w       fs,ax                   ; set the value

                pop         rax                     ; restore ES from the stack
                mov.w       es,ax                   ; set the value

                pop         rax                     ; restore DS from the stack
                mov.w       ds,ax                   ; set the value

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
                pop         rbp                     ; restore rbp

                iretq                               ; return to user-land

;==============================================================================================

;==============================================================================================
; The .rodata segment will hold all data related to the kernel
;==============================================================================================

                section     .rodata

%ifndef DISABLE_DBG_CONSOLE
hasControl      db          'Process %s now has CPU control',13,0

eoiStart        db          'Sending EOI to PIC',13,0
swapStart       db          'Beginning process swap',13,0
qtmExpired      db          'Quantum Expired',13,0
resettingQtm    db          'Resetting Quantum',13,0

rsltGetNxtProc  db          'The resulting process from GetNextProcess() is %s',13,0
dftGetNxtProc   db          'GetNextProcess() is defaulting to the current process',13,0
chkKern         db          'Checking Kernel queue...',13,0
chkHigh         db          'Checking High queue...',13,0
chkNorm         db          'Checking Normal queue...',13,0
chkLow          db          'Checking Low queue...',13,0
chkIdle         db          'Checking Idle queue...',13,0
addKern         db          'Adding to the Kernel Queue...',13,0
addHigh         db          'Adding to the High Queue...',13,0
addNorm         db          'Adding to the Normal Queue...',13,0
addLow          db          'Adding to the Low Queue...',13,0
addIdle         db          'Adding to the Idle Queue...',13,0

ssVal           db          'Invalid SS value: %p',13,0
%endif
