;==============================================================================================
;
; process.s
;
; This file contains the functions and structures needed to manage processes in the kernel.
; This file does not contain any code or structures related to scheduling or switching threads.
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
; So, let's take on the discussion about PID versus the Process structure address.  There are
; several functions that will need to take a process as an argument.  The debate is whether to
; use the PID as that functional parameter, or to use the Process structure address as that
; functional parameter.  True, the PID is the identifier by which the users will want to
; interact with the process.  However, looking through a linked list each time to identify the
; process structure (upon which we really need to operate) for each function is wasteful.
; Therefore, all internal functions and representations of the process will be with the
; process structure address.  A function will be created to convert a PID to a structure
; address, which will be called when a PID is passed, and then the process structure will be
; used from then on internally.
;
; Next I originally thought that there would be a global process queue per processor.  Well,
; that doesn't make sense.  Global means global.  I will add a global variable for the
; global process queue.  Issue resolved.
;
; The following functions are published in this source:
;   void ProcessInit(void);
;   void ReadyProcess(qword proc);
;   void ProcessResetQtm(qword proc);
;   void ProcessSetPty(qword proc, byte Pty);
;   qword CreateProcess(qword cmdStr, qword entryAddr, qword numParms, ...);
;
; The following functions are internal to the source file:
;
; The following function is an error reporting function from which there is no return:
;
;    Date     Tracker  Pgmr  Description
; ----------  -------  ----  ------------------------------------------------------------------
; 2014/12/07  Initial  ADCL  Initial version
; 2015/01/04  #247     ADCL  Recreated the idle process as the butler process and then created
;                            a pure (clean) idle process.
;
;==============================================================================================

%define     __PROCESS_S__
%include    'private.inc'

;==============================================================================================
; In this first section (before we get into any real data or code), we will define some
; constants and such to make out coding easier.
;==============================================================================================

;----------------------------------------------------------------------------------------------
; The uPush macro is used to simulate a push opcode on a register other than rsp.
;
;  !!!THIS MACRO TRASHES RAX!!!
;----------------------------------------------------------------------------------------------

%macro          uPush       2
                sub.q       %1,8                    ; make room on the stack for a new value
                mov.q       rax,%2                  ; get the value in rax
                mov.q       [%1],rax                ; and put the value on the stack
%endmacro

;----------------------------------------------------------------------------------------------
; This is the initial flags value for a process being started
;----------------------------------------------------------------------------------------------

PROC_FLAGS      equ         0x0000000000000202      ; interrupts enabled (and req'd bit 1 set)

;----------------------------------------------------------------------------------------------
; Each of these statuses are used to indicate what the running process is really doing from the
; OS perspective (and potentially on which queue to find the process).
;----------------------------------------------------------------------------------------------

PROC_INIT       equ         0                       ; process is initing; just before 1st ready
PROC_RUN        equ         1                       ; process is actually running on the CPU
PROC_RDY        equ         2                       ; process is ready to run
PROC_END        equ         4                       ; process is ending; process clean-up
PROC_ZOMB       equ         0xff                    ; process has crashed & ready for clean-up

;==============================================================================================
; This is the .bss section.  It contains uninitialized data.
;==============================================================================================

                section     .bss

nextPID         resq        1

                global      currentProcess
currentProcess  resq        1

GlobalProcessQ  resb        List_size

;==============================================================================================
; This is the code section of the source file.  It will be part of the kernel.
;==============================================================================================

                section     .text
                bits        64

;----------------------------------------------------------------------------------------------
; void ProcessInit(void) -- This function inializes the idle process and will insert the
;                           process structure into the ready queue (at the head) and will
;                           set the current process.
;----------------------------------------------------------------------------------------------

                global      ProcessInit

ProcessInit:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rsi                     ; save rsi
                push        rdi                     ; save rdi

;----------------------------------------------------------------------------------------------
; first allocate a process structure
;----------------------------------------------------------------------------------------------

                push        qword Process_size      ; set the size we want
                call        kmalloc                 ; get a structure
                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; assume we got a good block of memory -- if we didn't we have bigger problems for now
; initialize the block to 0.
;----------------------------------------------------------------------------------------------

                mov.q       rbx,rax                 ; save the Process pointer
                mov.q       rdi,rax                 ; set the destination pointer
                mov.q       rcx,Process_size        ; get the byte size
                xor.q       rax,rax                 ; clear the rax register

                rep         stosb                   ; clear the block

;----------------------------------------------------------------------------------------------
; Set up the process name
;----------------------------------------------------------------------------------------------

                mov.q       rsi,butler              ; set the pointer to the butler proc name
                lea.q       rdi,[rbx+Process.name]  ; get the address of the name
                mov.q       rcx,PROC_NAME_LEN       ; get the length to copy
                sub.q       rcx,1                   ; leave room for the terminating NULL

                repnz       movsb                   ; copy the name to the process struct

;----------------------------------------------------------------------------------------------
; Set the PID and initialize the variables
;----------------------------------------------------------------------------------------------

                mov.q       [rbx+Process.pid],1     ; set the process ID number
                mov.q       rax,nextPID             ; get the address of the next PID
                mov.q       [rax],2                 ; set the next PID

                mov.q       rax,currentProcess      ; get the address of the current proc var
                mov.q       [rax],rbx               ; set the current process structure ptr

;----------------------------------------------------------------------------------------------
; Set some additional fields
;----------------------------------------------------------------------------------------------

                mov.b       [rbx+Process.procSts],PROC_RUN  ; this is the running process!
                mov.q       [rbx+Process.totQtm],0  ; clear total quantum
                mov.b       [rbx+Process.procPty],PTY_KERN  ; This will become the Butler proc
                mov.b       [rbx+Process.quantum],0 ; clear total quantum
                mov.q       [rbx+Process.stackAddr],0   ; stackAddr
                mov.q       [rbx+Process.ss],0      ; ss
                mov.q       [rbx+Process.rsp],0     ; rsp

;----------------------------------------------------------------------------------------------
; The rest of the fields will be populated on a process change
;
; Here we need to insert this process into the Global Process Queue
;----------------------------------------------------------------------------------------------

                lea.q       rax,[rbx+Process.glbl]  ; get the address of the queue head
                InitializeList      rax             ; initialize the list to empty

                lea.q       rax,[rbx+Process.stsQ]  ; get the address of the queue head
                InitializeList      rax             ; initialize the list to empty

                mov.q       rax,GlobalProcessQ      ; get the address of the queue head
                InitializeList      rax             ; initialize the list to empty

                push        rax                     ; push the head on the stack
                lea.q       rax,[rbx+Process.glbl]  ; get the address of the process glbl List
                push        rax                     ; push that offset on the stack
                call        ListAddHead             ; add it to the list -- first in line
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; Report the results
;----------------------------------------------------------------------------------------------
%ifndef DISABLE_DBG_CONSOLE
                push        rbx                     ; push the address of the process
                mov.q       rax,butlerProcMsg       ; get the message to print
                push        rax                     ; push is on the stack
                call        dbgprintf               ; write it to the debug console
                add.q       rsp,16                  ; clean up the stack
%endif

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

                pop         rdi                     ; restore rdi
                pop         rsi                     ; restore rsi
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void ReadyProcess(qword proc) -- Ready a process on the ready queue, keeping in mind that
;                                  there are actually several ready queues and we need to find
;                                  the right one to which to add the process based on the
;                                  priority.
;----------------------------------------------------------------------------------------------

                global      ReadyProcess

ReadyProcess:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdx                     ; save rdx
                pushfq                              ; save the flags
                cli                                 ; since we don't want to be interrupted

;----------------------------------------------------------------------------------------------
; For debugging purposes, show the process we are readying
;----------------------------------------------------------------------------------------------
%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,currentProcess      ; get the var address...
                mov.q       rax,[rax]               ; and get the process address structure
                lea.q       rax,[rax+Process.name]  ; and then get the name of the process
                push        rax                     ; and push it on the stack
                mov.q       rax,[rbp+16]            ; get the process address we are readying
                lea.q       rax,[rax+Process.name]  ; and get the name
                push        rax                     ; and push it on the stack
                mov.q       rax,readying            ; get the address of the string
                push        rax                     ; and push it on the stack
                call        dbgprintf               ; call the function to print to dbg console
                add.q       rsp,24                  ; clean up the stack
%endif

;----------------------------------------------------------------------------------------------
; Perform some initialization
;----------------------------------------------------------------------------------------------
                mov.q       rax,[rbp+16]            ; get the address of the Process Structure
                mov.q       rbx,currentProcess      ; get the addr of the current process var
                mov.q       rbx,[rbx]               ; now, get the address of the struct

;----------------------------------------------------------------------------------------------
; Now, we check the priority of the current process against the process we are readying...  If
; the process we are readying is higher than the current process (this one executing this
; function call), then we yield and execute a task switch.
;----------------------------------------------------------------------------------------------

                mov.b       cl,[rax+Process.procPty]; get the new proc pty
                mov.b       ch,[rbx+Process.procPty]; get the current process pty

                cmp.b       cl,ch                   ; determine which is greater
                jbe         .ready                  ; if <=, we just put it on the ready queue

;----------------------------------------------------------------------------------------------
; OK, we have gotten here.  We are going to execute a task swap.  The good news is that we
; already have our own stack (we don't have a special stack we need to maintain).  So, we just
; start pushing things to match the expectation.
;----------------------------------------------------------------------------------------------

%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,swapping            ; get the address of the string
                push        rax                     ; and push it on the stack
                call        dbgprintf               ; call the function to print to dbg console
                add.q       rsp,8                   ; clean up the stack
%endif

                xor.q       rax,rax                 ; clear rax
                mov.w       ax,ss                   ; get the stack seg
                push        rax                     ; and push it on the stack

                pushfq                              ; save the flags

                xor.q       rax,rax                 ; clear rax
                mov.w       ax,cs                   ; get the code seg
                push        rax                     ; and push it on the stack

                mov.q       rax,ReadyProcess.out2   ; get ret addr for when this gets control
                push        rax                     ; ... again and push it on the stack

                push        rbp                     ; save rbp
                push        rax                     ; rax contains garbage -- save it anyway
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
                mov.w       ax,ds                   ; get the ds
                push        rax                     ; push it on the stack

                mov.w       ax,es                   ; get the es
                push        rax                     ; push it on the stack

                mov.w       ax,fs                   ; get the fs
                push        rax                     ; push it on the stack

                mov.w       ax,gs                   ; get the gs
                push        rax                     ; push it on the stack

                mov.q       rax,TSwapTgt            ; get the Task Swap Target address
                push        rax                     ; push it on the stack

                xor.q       rax,rax                 ; clear rax
                mov.w       ax,ss                   ; get the ss
                mov.q       [rbx+Process.ss],rax    ; save the ss in the current process

                mov.q       rax,cr3                 ; get cr3 register
                mov.q       [rbx+Process.cr3],rax   ; save it in the process structure

                mov.q       [rbx+Process.rsp],rsp   ; save the rsp register

                push        0                       ; we do not need an EOI
                push        qword [rbp+16]          ; push the structure we are switching to
                call        SwitchToProcess         ; go execute the process switch

                ; =================================================
                ; !!!!!  Control never returns to this point  !!!!!
                ; =================================================

;----------------------------------------------------------------------------------------------
; remove the process from any queue it might be in
;----------------------------------------------------------------------------------------------

.ready:         mov.q       rax,[rbp+16]            ; get the address of the Process Structure
                lea.q       rbx,[rax+Process.stsQ]  ; now get address of stsQ list structure

                push        rbx                     ; push this address on the stack
                call        ListDelInit             ; remove this structure from the list
                                                    ; we will use the stsQ addr in next call

;----------------------------------------------------------------------------------------------
; now, we need to check priorities, to make sure we put the process in the right queue
;
; start with the kernel queue
;----------------------------------------------------------------------------------------------

.kern:          mov.q       rax,[rbp+16]            ; get the process struct addr
                lea.q       rax,[rax+Process.procPty]   ; get the address of the process pty

                cmp.b       [rax],PTY_KERN          ; is it a kernel priority?
                jne         .high                   ; if not, go to the next check

                call        RdyKernQAdd             ; add it to the ready queue
                jmp         .out                    ; exit

;----------------------------------------------------------------------------------------------
; check the high queue
;----------------------------------------------------------------------------------------------

.high:          cmp.b       [rax],PTY_HIGH          ; is it a high priority?
                jne         .norm                   ; if not, go to the next check

                call        RdyHighQAdd             ; add it to the ready queue
                jmp         .out                    ; exit

;----------------------------------------------------------------------------------------------
; check the norm queue
;----------------------------------------------------------------------------------------------

.norm:          cmp.b       [rax],PTY_NORM          ; is it a norm priority?
                jne         .low                    ; if not, go to the next check

                call        RdyNormQAdd             ; add it to the ready queue
                jmp         .out                    ; exit

;----------------------------------------------------------------------------------------------
; check the low queue
;----------------------------------------------------------------------------------------------

.low:           cmp.b       [rax],PTY_LOW           ; is it a low priority?
                jne         .idle                   ; if not, go to the next check

                call        RdyLowQAdd              ; add it to the ready queue
                jmp         .out                    ; exit

;----------------------------------------------------------------------------------------------
; assume it is an idle process
;----------------------------------------------------------------------------------------------

.idle:          call        RdyIdleQAdd             ; add it to the ready queue

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:           add.q       rsp,8                   ; clean up the stack

%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,doneReady           ; get the address of the string
                push        rax                     ; and push it on the stack
                call        dbgprintf               ; call the function to print to dbg console
                add.q       rsp,8                   ; clean up the stack
%endif

.out2:          popfq                               ; pop the flags from the stack
                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void ProcessResetQtm(qword proc) -- Reset the quantum to that provided by the priority.
;----------------------------------------------------------------------------------------------

                global      ProcessResetQtm

ProcessResetQtm:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx

;----------------------------------------------------------------------------------------------
; This is pretty trivial -- get the process address, get the priotity, and put it in the
; quantum field.
;----------------------------------------------------------------------------------------------

                xor.q       rax,rax                 ; clear rax
                mov.q       rbx,[rbp+16]            ; get the process struct address
                mov.b       al,[rbx+Process.procPty]; get the priority, which is also quantum
                mov.b       [rbx+Process.quantum],al; set the quantum

;----------------------------------------------------------------------------------------------
; Clean up and exit
;----------------------------------------------------------------------------------------------
.out:
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void ProcessSetPty(qword proc, byte Pty) -- Sets the specified process priority
;
; The big question here is whether to allow a process to increase its priority to, say,
; PTY_KERN to get a bigger timslice.  For now, this function will take any process and will
; update that process's priority to whatever is specified (within reason -- it MUS be one of
; the 5 allowed priorities).  Anything out of that tolerance will be dropped to the PTY_NORM
; priority.
;----------------------------------------------------------------------------------------------

                global      ProcessSetPty

ProcessSetPty:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx

;----------------------------------------------------------------------------------------------
; For debugging purposes, show the process we are setting the priority
;----------------------------------------------------------------------------------------------
%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,currentProcess      ; get the var address...
                mov.q       rax,[rax]               ; and get the process address structure
                lea.q       rax,[rax+Process.name]  ; and then get the name of the process
                push        rax                     ; and push it on the stack
                mov.q       rax,[rbp+16]            ; get the process address we are readying
                lea.q       rax,[rax+Process.name]  ; and get the name
                push        rax                     ; and push it on the stack
                mov.q       rax,setPty              ; get the address of the string
                push        rax                     ; and push it on the stack
                call        dbgprintf               ; call the function to print to dbg console
                add.q       rsp,24                  ; clean up the stack
%endif

;----------------------------------------------------------------------------------------------
; So, first the sanity check -- make sure the priority we are dealing with is one of the
; 5 allowed priorities
;----------------------------------------------------------------------------------------------

                mov.q       rax,[rbp+24]            ; get the priority parameter - only al used
                cmp.b       al,PTY_KERN             ; is this a kernel pty request?
                je          .good                   ; ok, we are good

                cmp.b       al,PTY_HIGH             ; is this a high pty request?
                je          .good                   ; ok, we are good

                cmp.b       al,PTY_LOW              ; is this a low pty request?
                je          .good                   ; ok, we are good

                cmp.b       al,PTY_IDLE             ; is this an idle pty request?
                je          .good                   ; ok, we are good

;----------------------------------------------------------------------------------------------
; OK, so we have gotten here and one of 2 things has happened: 1) we have a bad pty requested
; -- in which case we will set the PTY to be PTY_NORM; or, 2) we have a request for PTY_NORM
; -- in which case we do not want the extra branch and will just overwrite the pty requested
; with PTY_NORM (the same value).
;----------------------------------------------------------------------------------------------

                mov.b       al,PTY_NORM             ; set the requested value

.good:          mov.q       rbx,[rbp+16]            ; get the process structure address
                mov.b       [rbx+Process.procPty],al; set the new priority

;----------------------------------------------------------------------------------------------
; Now, we have some housekeeping to do to keep the structures in a proper state.  First of all,
; if the process is the current process we need to determine if we will need to reschedule it.
; Also, if we just raised a priority over the currently running process, we need to preempt
; the current process.  Finally, if we changed a priority of a process in the ready queue, we
; need to move it to the proper queue (which in theory should take care of a reschedule).
;
; None of this is coded at the moment.
;----------------------------------------------------------------------------------------------


;----------------------------------------------------------------------------------------------
; Clean up and exit
;----------------------------------------------------------------------------------------------
.out:
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword CreateProcess(qword cmdStr, qword entryAddr, qword numParms, ...) --
;                                   Create a process.  This function will take a variable
;                                   number of parameters and put them on the new stack for the
;                                   user process to accept (this functionality will likely
;                                   change when we get to a command line initiator).
;
; This function is a bit complicated since the function has to create a process structure and
; initialize it, add the process into the global queue, create a stack, and initialize the
; stack to meet the needs of a task swap.
;
; In order to get a working function, we will take some shortcuts keeping the process running
; at ring 0, using the kernel CR3 register, and allocating a stack from the kernel stack list.
; These will be cleaned up later.
;
; We will accomplish this function in the following manner:
; A) Allocate a Process structure
; B) Allocate a stack from the kernel stacks
; C) Initialize the process structure
; D) Add the process to the Global Process Queue (in an initializing status)
; E) Set the parameters on the process stack
; F) Set the return address from the entry point to be EndProcess
; G) Set the "iretq address" from the the next task swap to be the entry point
; H) Set the initial register values on the stack to be 0
; I) Ready the process
;----------------------------------------------------------------------------------------------

                global      CreateProcess
                extern      TSwapTgt

CreateProcess:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rsi                     ; save rsi
                push        rdi                     ; save rdi
                push        r9                      ; save r9
                pushfq                              ; save the flags
                cli                                 ; no interrupts -- atomic next PID access

;----------------------------------------------------------------------------------------------
; Create some debugging text for the debug console
;----------------------------------------------------------------------------------------------
%ifndef DISABLE_DBG_CONSOLE
                push        qword [rbp+24]          ; push the starting address
                push        qword [rbp+16]          ; push the process name
                mov.q       rax,procCreate          ; get the string to print
                push        rax                     ; push it on the stack
                call        dbgprintf               ; write the string
                add.q       rsp,24                  ; clean up the stack
%endif

;----------------------------------------------------------------------------------------------
; First step A) Allocate a new Process structure
;----------------------------------------------------------------------------------------------

                push        qword Process_size      ; push the size to allocate
                call        kmalloc                 ; allocate from the heap
                add.q       rsp,8                   ; clean up the stack

                cmp.q       rax,0                   ; if no memory, exit
                je          .out                    ; exit if kmalloc fails

                mov.q       rbx,rax                 ; save the structure in rbx

%ifndef DISABLE_DBG_CONSOLE
                push        rbx                     ; push the address on the stack
                mov.q       rax,procAddr            ; get the msg on the stack
                push        rax                     ; and push it on the stack
                call        dbgprintf               ; write the string
                add.q       rsp,16                  ; clean up the stack
%endif

;----------------------------------------------------------------------------------------------
; Step B) Allocate a stack
;----------------------------------------------------------------------------------------------
                call        AllocStack              ; go get a stack
                cmp.q       rax,0                   ; did we get a stack?
                je          .out2                   ; if we didn't get a stack, exit

                mov.q       r9,rax                  ; save the stack in r9

%ifndef DISABLE_DBG_CONSOLE
                push        r9                      ; push the address on the stack
                mov.q       rax,procStack           ; get the msg on the stack
                push        rax                     ; and push it on the stack
                call        dbgprintf               ; write the string
                add.q       rsp,16                  ; clean up the stack
%endif

;----------------------------------------------------------------------------------------------
; Step C) Initialize the Process structure
;----------------------------------------------------------------------------------------------

                mov.q       rax,nextPID             ; get the address of the next PID
                mov.q       rcx,[rax]               ; get the next PID
                inc         qword [rax]             ; increment the next PID

                mov.q       [rbx+Process.pid],rcx   ; save the PID in the structure

                mov.q       rsi,[rbp+16]            ; get the command string
                lea.q       rdi,[rbx+Process.name]  ; get the destination address
                mov.q       rcx,PROC_NAME_LEN       ; get the length to copy
                dec         rcx                     ; leave room for terminating NULL

.loop:          cmp.q       rcx,0                   ; did we use up all out spaces?
                je          .nullTerm               ; go terminate with a null
                cmp.b       [rsi],0                 ; did we reach the end of the string?
                je          .nullTerm               ; if so, we can terminate with a null

                movsb                               ; copy a character

                dec         rcx                     ; 1 less spot available
                jmp         .loop                   ; go copy another character

.nullTerm:      mov.b       [rdi],0                 ; put a terminating NULL on the string

                mov.q       [rbx+Process.totQtm],0  ; we have used NO quantum yet
                mov.b       [rbx+Process.procSts],PROC_INIT ; we are initializing
                mov.b       [rbx+Process.procPty],PTY_NORM  ; normal proiority
                mov.b       [rbx+Process.quantum],0 ; no current quantum
                mov.b       [rbx+Process.fill],0    ; just to be clean
                mov.q       [rbx+Process.stackAddr],r9  ; save the stack address
                mov.q       [rbx+Process.ss],ss     ; save stack segment
                mov.q       rax,cr3                 ; get the PML4 address
                mov.q       [rbx+Process.cr3],rax   ; save that in the structure

                lea.q       rax,[rbx+Process.stsQ]  ; get the address of the status list struct
                InitializeList      rax             ; initialize the list

                lea.q       rax,[rbx+Process.glbl]  ; get the address of the global list
                InitializeList      rax             ; initialize the list

;----------------------------------------------------------------------------------------------
; Step D) Add the process to the global process list
;----------------------------------------------------------------------------------------------

                mov.q       rax,GlobalProcessQ      ; get the address of the global Process
                push        rax                     ; push it on the stack
                lea.q       rax,[rbx+Process.glbl]  ; get the address of the list pointer
                push        rax                     ; push it on the stack
                call        ListAddTail             ; add the process to the global proc list
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; Step E) Set the parameters on the process stack
;----------------------------------------------------------------------------------------------

                add.q       r9,STACK_SIZE           ; get to the end of the stack

                mov.q       rcx,[rbp+32]            ; get the parameter count
                shl.q       rcx,3                   ; convert a count to qwords

.parmLoop:      cmp.q       rcx,0                   ; have we reached 0 parameters?
                je          .endProc                ; go add the end Proc to the stack

                uPush       r9,[rbp+24+rcx]         ; put the parm on the stack
                sub.q       rcx,8                   ; move to the PREV parm (right to left)
                jmp         .parmLoop               ; go push another one

;----------------------------------------------------------------------------------------------
; Step F) Set the return address from the entry point to be EndProcess
;----------------------------------------------------------------------------------------------

.endProc:       uPush       r9,EndProc              ; push the process termination address

;----------------------------------------------------------------------------------------------
; Step G) Set the "iretq address" from the the next task swap to be the entry point
;----------------------------------------------------------------------------------------------

                mov.q       rcx,r9                  ; get the stack pointer at this point
                uPush       r9,[rbx+Process.ss]     ; Push the SS on the user stack
                uPush       r9,rcx                  ; Push the RSP value on the stack
                uPush       r9,PROC_FLAGS           ; Push the initial process flags on stack
                uPush       r9,cs                   ; Push the code segment on the stack
                uPush       r9,[rbp+24]             ; Push the entry point on the stack

;----------------------------------------------------------------------------------------------
; Step H) Set the initial register values on the stack to be 0
;----------------------------------------------------------------------------------------------

                uPush       r9,0                    ; saved RBP register
                uPush       r9,0                    ; saved RAX register
                uPush       r9,0                    ; saved RBX register
                uPush       r9,0                    ; saved RCX register
                uPush       r9,0                    ; saved RDX register
                uPush       r9,0                    ; saved RSI register
                uPush       r9,0                    ; saved RDI register
                uPush       r9,0                    ; saved R8 register
                uPush       r9,0                    ; saved R9 register
                uPush       r9,0                    ; saved R10 register
                uPush       r9,0                    ; saved R11 register
                uPush       r9,0                    ; saved R12 register
                uPush       r9,0                    ; saved R13 register
                uPush       r9,0                    ; saved R14 register
                uPush       r9,0                    ; saved R15 register
                uPush       r9,ds                   ; saved DS register
                uPush       r9,ds                   ; saved ES register
                uPush       r9,ds                   ; saved FS register
                uPush       r9,ds                   ; saved GS register
                uPush       r9,TSwapTgt             ; Return point required by scheduler

                mov.q       [rbx+Process.rsp],r9    ; save the stack pointer in Process struct

;----------------------------------------------------------------------------------------------
; Report the results
;----------------------------------------------------------------------------------------------

%ifndef DISABLE_DBG_CONSOLE
                push        rbx                     ; push the address of the structure
                lea.q       rax,[rbx+Process.name]  ; get the name of the process
                push        rax                     ; push it on the stack
                mov.q       rax,procAddrMsg         ; get the debugging string
                push        rax                     ; push it on the stack
                call        dbgprintf               ; write it to the debug console
                add.q       rsp,24                  ; clean up the stack
%endif

;----------------------------------------------------------------------------------------------
; Step I) Ready the process
;----------------------------------------------------------------------------------------------
                push        rbx                     ; push process struct addr
                call        ReadyProcess            ; ready the process
                add.q       rsp,8                   ; clean up the stack

                jmp         .out                    ; time to exit

;----------------------------------------------------------------------------------------------
; We need to clean up the allocated process and exit
;----------------------------------------------------------------------------------------------

.out2:
                push        rbx                     ; push the Process struct on the stack
                call        kfree                   ; go free the memory
                add.q       rsp,8                   ; clean up the stack

                xor.q       rax,rax                 ; return NULL

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:

%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,doneCrtProc         ; get the debugging string
                push        rax                     ; push it on the stack
                call        dbgprintf               ; write it to the debug console
                add.q       rsp,8                   ; clean up the stack
%endif
                mov.q       rax,rbx                 ; set the return value

                popfq                               ; restore flags
                pop         r9                      ; restore r9
                pop         rdi                     ; restore rdi
                pop         rsi                     ; restore rsi
                pop         rbx                     ; restore rbx
                pop         rcx                     ; restore rcx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; EndProc -- The following will become the return point when a process is completed.  It is
;            responsible for the cleanup from a process perspective.  The challenge here is
;            that this process will gain control while in user mode, not in kernel mode.  So,
;            we will not have access to the kernel structures that are required to manage the
;            process.
;
; So, our first challenge is to get into kernel mode.  I think the best way to do this will be
; to perform a system call for the process to commit suicide (kill(currentProcess)).  Another
; possibility here is to send a message to a process reaper task (i.e. the butler task) to
; perform all the cleanup.
;
; The second problem is going to be stack management.  We cannot do stack cleanup while using
; the same stack we need to clean.  On the other hand, we cannot use a common stack without a
; lot of synchronization primitives (for which care needs to be taken to prevent deadlock).
;
; The final challenge is going to be lock management, where locks held by the process need to
; be released.  This will most likely cause a number of possible reschedules and we really
; should consider waiting until all of the locks have been freed before performing a reschedule
; as a higher priority process might be released to work after another normal priorirty process
; has been freed.  If we reschedule too early, we might be giving the CPU to an incorrect
; process.
;
; For now, we will change the status to be PROC_END and take it off any of the Status Queues.
; All of the structures and locks will remain allocated, which will cause all kinds of problems
; in the very near future.  But for now, it is the best and most complete I have (until I get
; either messaging or system calls implemented).  The last thing to do will be to reschedule
; to the next process.
;----------------------------------------------------------------------------------------------

EndProc:        cli                                 ; make sure we are not interrupted
                mov.q       rbx,currentProcess      ; get the current process pointer addr
                mov.q       rbx,[rbx]               ; get the current process struct addr
                mov.b       [rbx+Process.procSts],PROC_END  ; note that we are ending this proc

                lea.q       rax,[rbx+Process.stsQ]  ; get the status Queue address
                push        rax                     ; push that on the stack
                call        ListDelInit             ; remove it and init it to point to itself
                add.q       rsp,8                   ; clean up the stack

                call        GetNextProcess          ; get the next process to give the CPU to

                push        qword 0                 ; we do not need an EOI
                push        rax                     ; push the new process
                call        SwitchToProcess         ; give the CPU back to the next process

                ; =================================================
                ; !!!!!  Control never returns to this point  !!!!!
                ; =================================================

                jmp         EndProc                 ; need to put in a panic function here

;==============================================================================================
; This is the read only data (.rodata) and will be included in the .text section at link
;==============================================================================================

                section     .rodata

butler          db          'butler',0

%ifndef DISABLE_DBG_CONSOLE
butlerProcMsg   db          'butler: The Process strcuture is located at: %p',13,0
procAddrMsg     db          '%s: The Process structure is loated at: %p',13,0
readying        db          'Readying %s (%s is the active process)',13,0
setPty          db          'Setting process priority for %s (%s is the active process)',13,0
swapping        db          ' (new process is a higher priority; swapping)',13,0
doneReady       db          'ReadyProcess() is complete',13,0
doneCrtProc     db          'CreateProcess() is complete',13,0

procCreate      db          'Creating new process %s (starting addr=%p)',13,0
procAddr        db          '   * process structure address: %p',13,0
procStack       db          '   * stack address: %p',13,0
%endif
