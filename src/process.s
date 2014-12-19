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
;       Copyright (C) 2014  Adam Scott Clark
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

%define     __PROCESS_S__
%include    'private.inc'

;==============================================================================================
; In this first section (before we get into any real data or code), we will define some
; constants and such to make out coding easier.
;==============================================================================================

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

                mov.q       rsi,idle                ; set the pointer to the idle process name
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

                mov.q       [rbx+Process.procSts],PROC_RUN  ; this is the running process!

;----------------------------------------------------------------------------------------------
; The rest of the fields will be populated on a process change
;
; Here we need to insert this process into the Global Process Queue
;----------------------------------------------------------------------------------------------

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
                pushfq                              ; save the flags
                cli                                 ; since we don't want to be interrupted

;----------------------------------------------------------------------------------------------
; remove the process from any queue it might be in
;----------------------------------------------------------------------------------------------

                mov.q       rax,[rbp+16]            ; get the address of the Process Structure
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

                popfq                               ; pop the flags from the stack
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

;==============================================================================================
; This is the read only data (.rodata) and will be included in the .text section at link
;==============================================================================================

                section     .rodata

idle            db          'idle',0
