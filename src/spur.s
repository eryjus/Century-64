;==============================================================================================
;
; spur.s
;
; This file contains the IRQ (interrupt) handler for handling spurious interrupts.
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
;    Date     Tracker  Pgmr  Description
; ----------  -------  ----  ------------------------------------------------------------------
; 2014/12/28  Initial  ADCL  Initial version
;
;==============================================================================================

%define     __SPUR_S__
%include    'private.inc'

;==============================================================================================
; This is the .bss section.  It contains uninitialized data.
;==============================================================================================

                section     .bss

spurCount:      resq        1

;==============================================================================================
; This is the code section of the source file.  It will be part of the kernel.
;==============================================================================================

                section     .text
                bits        64

;----------------------------------------------------------------------------------------------
; void SpurInit(void) -- Initialze the spurious interrupt handler.
;----------------------------------------------------------------------------------------------

                global      SpurInit

SpurInit:       push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame

                mov.q       rax,spurCount           ; get the address of the variable
                mov.q       [rax],0                 ; initialize the count to 0

;----------------------------------------------------------------------------------------------
; register the IRQ handler
;----------------------------------------------------------------------------------------------

                mov.q       rax,IST2                ; we want IST2
                push        rax                     ; push it on the stack
                mov.q       rax,SpurHandler         ; this is our handler address
                push        rax                     ; push that on the stack
                push        0x27                    ; finally we want interrupt 0x27
                call        RegisterHandler         ; now, register our IRQ handler
                add.q       rsp,24                  ; clean up the stack

                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; SpurHandler -- This is the Interrupt handler for IRQ7.  It will be called with each spurious
;                interrupt.  It will also be called for any LPT1 interrupt, so we will need
;                to be careful with this.
;
; Keep in mind that this 'function' does not have a normal entry process or exit process.  We
; need to be particularly careful about saving and restoring EVERYTHING we will touch.
;----------------------------------------------------------------------------------------------

SpurHandler:
                push        rbp                     ; save the interrupted process's frame
                mov.q       rbp,rsp                 ; we want our own frame
                push        rax                     ; yes, we even save rax

;----------------------------------------------------------------------------------------------
; check if it is a spurious interrupt
;----------------------------------------------------------------------------------------------

                mov.q       rax,pic                 ; get the pic interface structure
                mov.q       rax,[rax+PIC.readISR]   ; get the ReadISR fucntion address
                call        rax                     ; do we have an interrupt
                test.q      rax,0x80                ; test bit 7
                jz          .eoi                    ; we have a real interrupt; ack it

                mov.q       rax,spurCount           ; get the counter address
                inc         qword [rax]             ; increment the count

%ifndef DISABLE_DBG_CONSOLE
                mov.q       rax,spurIntRcvd         ; get the text address
                push        rax                     ; put it on the stack
                call        DbgConsolePutString     ; write it to the console
                add.q       rsp,8                   ; clean up the stack
%endif
                jmp         .out                    ; go exit

.eoi:           mov.q       rax,pic                 ; get the pic interface structure
                mov.q       rax,[rax+PIC.eoi]       ; get the EOI fucntion address
                push        qword 0x07              ; we need to ack IRQ7
                call        rax                     ; do we have an interrupt
                add.q       rsp,8                   ; clean up the stack

.out:           pop         rax                     ; restore rax
                pop         rbp                     ; restore rbp
                iretq

;==============================================================================================

;==============================================================================================
; This is the read only data (.rodata) and will be included in the .text section at link
;==============================================================================================

                section     .rodata

spurIntRcvd     db          '(Spurious Interrupt)',0
