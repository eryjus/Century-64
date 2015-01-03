;==============================================================================================
;
; pic.s
;
; This file contains the implmentation of the PIC driver, which is included in the OS kernel.
; the PIC driver will be one of the few device drivers that will be included in the kernel.
; A separate driver will be used to control the IOAPIC, some functions of which will replace
; these functions.  However, since the interrupts and IRQs are a part of the kernel, I have
; opted to include this driver with the kernel.
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
; This file will also provide the abstraction for the PIC/IOAPIC.  As such, function addresses
; will be registered in a structure during initialization (similar to a virtual function
; address) and called dynamically (as a far function call).  I have chosen to include the
; abstraction layer in this file since there is guaranteed to be a compatible device on the
; system (and with a 64-bit kernel, I'm sure there is also guaranteed to be an IOAPIC for each
; processesor as well; but until I see this documented I am not making that assumption).
;
; The following functions are published in this file:
;
; The following functions are internal functions:
;
;    Date     Tracker  Pgmr  Description
; ----------  -------  ----  ------------------------------------------------------------------
; 2014/12/24  Initial  ADCL  Initial code
;
;==============================================================================================

%define         __PIC_S__
%include        'private.inc'

PIC1            equ         0x20
PIC1_DATA       equ         0x21

PIC2            equ         0xa0
PIC2_DATA       equ         0xa1

PIC_READ_ISR    equ         0x0b
PIC_READ_IRR    equ         0x0a

;==============================================================================================
; This is the .data section.  It contains initialized data.
;==============================================================================================

                section     .data

                global      pic

pic:            istruc      PIC
.enableAll      dq          picEnableAll
.disableAll     dq          picDisableAll
.enableIRQ      dq          picEnableIRQ
.disableIRQ     dq          picDisableIRQ
.eoi            dq          picEOI
.readISR        dq          picReadISR
.readIRR        dq          picReadIRR
                iend

;==============================================================================================
; This is the code section of the source file.  It will be part of the kernel.
;==============================================================================================

                section     .text
                bits        64

                global      picInit

picInit:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame

;----------------------------------------------------------------------------------------------
; reprogram the 8259 PIC to set the proper IRQ numbers
;----------------------------------------------------------------------------------------------

                mov.b       al,0x11                 ; set the byte to output
                out         0x20,al                 ; initialize the master PIC
                nop                                 ; force some time to pass
                nop                                 ; force some time to pass

                mov.b       al,0x11                 ; set the byte to output
                out         0xa0,al                 ; initialize the slave PIC
                nop                                 ; force some time to pass
                nop                                 ; force some time to pass

                mov.b       al,0x20                 ; set the byte to output
                out         0x21,al                 ; we want IRQ0 to be on interrupt 0x20
                nop                                 ; force some time to pass
                nop                                 ; force some time to pass

                mov.b       al,0x28                 ; set the byte to output
                out         0xa1,al                 ; we want IRQ8 to be on int 0x28
                nop                                 ; force some time to pass
                nop                                 ; force some time to pass

                mov.b       al,0x04                 ; set the master to have the slave on IRQ2
                out         0x21,al                 ; we want IRQ0 to be on interrupt 0x20
                nop                                 ; force some time to pass
                nop                                 ; force some time to pass

                mov.b       al,0x02                 ; set the slave to use IRQ2
                out         0xa1,al                 ; we want IRQ8 to be on int 0x28
                nop                                 ; force some time to pass
                nop                                 ; force some time to pass

                mov.b       al,0x01                 ; use 8086 mode
                out         0x21,al                 ; we want IRQ0 to be on interrupt 0x20
                nop                                 ; force some time to pass
                nop                                 ; force some time to pass

                mov.b       al,0x01                 ; use 8086 mode
                out         0xa1,al                 ; we want IRQ8 to be on int 0x28
                nop                                 ; force some time to pass
                nop                                 ; force some time to pass

                mov.b       al,0x00                 ; use 8086 mode
                out         0x21,al                 ; we want IRQ0 to be on interrupt 0x20
                nop                                 ; force some time to pass
                nop                                 ; force some time to pass

                mov.b       al,0x00                 ; use 8086 mode
                out         0xa1,al                 ; we want IRQ8 to be on int 0x28
                nop                                 ; force some time to pass
                nop                                 ; force some time to pass

                call        picDisableAll           ; disable all IRQs

                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void picEnableAll(void) -- Enable all IRQ interrupts on the 8259 PIC
;----------------------------------------------------------------------------------------------

picEnableAll:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame

                mov.b       al,0x00                 ; 0 is enabled; 1 is disabled
                out         PIC2_DATA,al            ; enable all 8 IRQs on the slave PIC
                out         PIC1_DATA,al            ; enable all 8 IRQs on the master PIC

                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void picDisableAll(void) -- Disable all IRQ interrupts on the 8259 PIC
;----------------------------------------------------------------------------------------------

picDisableAll:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame

                mov.b       al,0xff                 ; 0 is enabled; 1 is disabled
                out         PIC2_DATA,al            ; enable all 8 IRQs on the slave PIC
                out         PIC1_DATA,al            ; enable all 8 IRQs on the master PIC

                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void picEnableIRQ(byte irq) -- Enable the IRQ in the low byte of the qword parameter, not
;                                impacting any other IRQs.
;----------------------------------------------------------------------------------------------

picEnableIRQ:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdx                     ; save rdx

;----------------------------------------------------------------------------------------------
; First we need to get the current IRQ mask.  This is complicated by the fact that there are
; 2 PICs -- a master and a slave.  If the parm is < 8 (0-7), then we are dealing with the
; master PIC; 8-15 and we are dealing with the slave PIC.  IRQ2 is the chain IRQ, so that is
; treated normally.
;
; First a sanity check to make sure we are dealing with a valid IRQ number: 0-15.
;----------------------------------------------------------------------------------------------

                mov.q       rcx,[rbp+16]            ; get the irq number
                cmp.q       rcx,15                  ; compare to 0
                ja          .out                    ; if > (unsigned)15, then we just exit

;----------------------------------------------------------------------------------------------
; so, now we know we are dealing with an IRQ from 0-15.  Now, we check for the master or slave
; PIC and set the port properly.
;----------------------------------------------------------------------------------------------

                mov.q       rdx,PIC1_DATA           ; assume we are dealing with the master PIC
                cmp.q       rcx,8                   ; check if we need IRQ8 or above
                jb          .getMask                ; if master PIC, we can go get the mask

                mov.q       rdx,PIC2_DATA           ; set for the slave PIC
                sub.q       rcx,8                   ; adjust down for the slave PIC

;----------------------------------------------------------------------------------------------
; Now it is time to get the current mask and update it
;----------------------------------------------------------------------------------------------

.getMask:       in          al,dx                   ; get the current mask byte
                mov.q       rbx,1                   ; set the bit
                shl.b       bl,cl                   ; shift that bit left to the irq # we need

                not.b       bl                      ; negate this result
                and.b       al,bl                   ; now, clear the bit we need

                out         dx,al                   ; write the result back to the PIC

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void picDisableIRQ(byte irq) -- Disable the IRQ in the low byte of the qword parameter, not
;                                 impacting any other IRQs.
;----------------------------------------------------------------------------------------------

picDisableIRQ:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdx                     ; save rdx

;----------------------------------------------------------------------------------------------
; First we need to get the current IRQ mask.  This is complicated by the fact that there are
; 2 PICs -- a master and a slave.  If the parm is < 8 (0-7), then we are dealing with the
; master PIC; 8-15 and we are dealing with the slave PIC.  IRQ2 is the chain IRQ, so that is
; treated normally.
;
; First a sanity check to make sure we are dealing with a valid IRQ number: 0-15.
;----------------------------------------------------------------------------------------------

                mov.q       rcx,[rbp+16]            ; get the irq number
                cmp.q       rcx,15                  ; compare to 0
                ja          .out                    ; if > (unsigned)15, then we just exit

;----------------------------------------------------------------------------------------------
; so, now we know we are dealing with an IRQ from 0-15.  Now, we check for the master or slave
; PIC and set the port properly.
;----------------------------------------------------------------------------------------------

                mov.q       rdx,PIC1_DATA           ; assume we are dealing with the master PIC
                cmp.q       rcx,8                   ; check if we need IRQ8 or above
                jb          .getMask                ; if master PIC, we can go get the mask

                mov.q       rdx,PIC2_DATA           ; set for the slave PIC
                sub.q       rcx,8                   ; adjust down for the slave PIC

;----------------------------------------------------------------------------------------------
; Now it is time to get the current mask and update it
;----------------------------------------------------------------------------------------------

.getMask:       in          al,dx                   ; get the current mask byte
                mov.q       rbx,1                   ; set the bit
                shl.b       bl,cl                   ; shift that bit left to the irq # we need

                or.b        al,bl                   ; now, set the bit we need

                out         dx,al                   ; write the result back to the PIC

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void picEOI(byte irq) -- Issue an End Of Interrupt (EOI) to the PIC for the specified IRQ
;                          number.
;----------------------------------------------------------------------------------------------

picEOI:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rcx                     ; save rcx

;----------------------------------------------------------------------------------------------
; get the irq number for which to issue EOI
;
; First a sanity check to make sure we are dealing with a valid IRQ number: 0-15.
;----------------------------------------------------------------------------------------------

                mov.q       rcx,[rbp+16]            ; get the irq number
                cmp.q       rcx,15                  ; compare to 0
                ja          .out                    ; if > (unsigned)15, then we just exit

;----------------------------------------------------------------------------------------------
; so, now we know we are dealing with an IRQ from 0-15.  Now, we check for the master or slave
; IRQ and and issue the EOI properly.
;----------------------------------------------------------------------------------------------

                mov.q       rax,0x20                ; set the EOI code in al
                cmp.q       rcx,8                   ; check if we need IRQ8 or above
                jb          .masterEOI              ; if not >= 8, we can skip the slave EOI

                mov.q       rdx,PIC2                ; set for the slave PIC
                out         dx,al                   ; issue the slave EOI
                sub.q       rcx,8                   ; adjust down for the slave PIC

.masterEOI:     mov.q       rdx,PIC1                ; set for the slave PIC
                out         dx,al                   ; issue the master EOI

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                pop         rcx                     ; restore rcx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; word picReadISR(void) -- Read the ISR registers from both PICs and return the results in ax.
;----------------------------------------------------------------------------------------------

picReadISR:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rdx                     ; save rdx


;----------------------------------------------------------------------------------------------
; no sanity checks -- get right into it
;----------------------------------------------------------------------------------------------

                mov.q       rax,PIC_READ_ISR        ; set the command to read the ISR reg
                out         PIC1,al                 ; set the PIC1 to read the ISR
                out         PIC2,al                 ; set the PIC2 to read the ISR

                xor.q       rax,rax                 ; zero out rax
                in          al,PIC2                 ; get the PIC2 ISR reg
                mov.b       ah,al                   ; move the data into the upper half
                in          al,PIC1                 ; get the PIC1 ISR reg

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                pop         rdx                     ; restore rdx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; word picReadIRR(void) -- Read the IRR registers from both PICs and return the results in ax.
;----------------------------------------------------------------------------------------------

picReadIRR:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rdx                     ; save rdx


;----------------------------------------------------------------------------------------------
; no sanity checks -- get right into it
;----------------------------------------------------------------------------------------------

                mov.q       rax,PIC_READ_IRR        ; set the command to read the IRR reg
                out         PIC1,al                 ; set the PIC1 to read the IRR
                out         PIC2,al                 ; set the PIC2 to read the IRR

                xor.q       rax,rax                 ; zero out rax
                in          al,PIC2                 ; get the PIC2 IRR reg
                mov.b       ah,al                   ; move the data into the upper half
                in          al,PIC1                 ; get the PIC1 IRR reg

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                pop         rdx                     ; restore rdx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

