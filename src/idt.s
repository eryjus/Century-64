;==============================================================================================
;
; idt.s
;
; This file contains the definitions and interfaces needed to maintain the Interrupt Descriptor
; Table (IDT).
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
; The system supports up to 256 interrupt handlers.  The addresses of these handlers are stored
; in 16 byte entries in an Interrupt Descriptor Table.  These are numbered from 0 to 255 and
; the interrupt number represents a 16-byte offset into the table.
;
; So, there are several ways to handle interrupts in code.  One would be to code a common
; handler (typically done from macros so that the interrupt number can be pushed onto the stack
; before the actual handler is called.  The actual handler would lookup the function to use to
; handle the actual interrupt and then call that function.
;
; The second would be to install the function into the interrupt gate directly and have the
; handler be the very first thing to get control.  Since this is being written in assembly, I
; feel this latter implementation to be the better one.  This solution will give me a bit more
; control over the interrupt gate and allow me to assign a stack to the interrupts from the
; Interrupt Stack Table (IST) located in the TSS.
;
; However, as I have been testing, this is a bit of a misnomber.  I can set up different stacks
; for different interrupts, but the IST addresses in the TSS are constant (or constant untill
; I change them).  Therefore, if 2 interrupts share the same IST number, they are sharing the
; same stack, but more to the point the same stack starting address and the exact same address
; space.  If I get 2 exceptions at the same time (or nested exceptions), I will have problems.
; The solution is as follows:
; 1) Use the ISTs sparingly
; 2) Keep a RSP0 pointer in the process structure and manually set RSP0 in the TSS on a task
;    change (need to think about the details on this)
; 3) Allow a nested exceptions to stack on top of each other on the same stack
; As a result of the above changes, several changes will be needed in this source.
;
; What gives me some debate at the moment is how to handle multiple devices that utilize the
; same IRQ number (which is the same interrupt).  I need some way to "multiplex" an IRQ
; interrupt, and I really do not want too much of this to be handled in the kernel.
;
; Brendan (I think) mentioned something about having each driver as a process and when an IRQ
; interrupt comes in, the interrupt handler is only responsible for signaling all the drivers
; hooked to the interrupt.  It is then each driver's responsibility to query their device to
; see if the interrupt is their responsbility to address.  At any rate, that sounds very
; feasible and I can build a common IRQ driver to handle such a thing.
;
; So, the following table identifies the interrupts, where the handler is located, and which
; stack to use.
;
; 00  #DE  Fault        RSP0  Kernel  -- Divide Error Exception
; 01  #DB  Trap/Fault   RSP0  Kernel  -- Debug Exception
; 02  MNI  N/A          IST7  Kernel  -- Non Maskable Interrupt
; 03  #BP  Trap         IST1  Kernel  -- Breakpoint Exception
; 04  #OF  Trap         RSP0  Kernel  -- Overflow Exception
; 05  #BR  Fault        RSP0  Kernel  -- BOUND Range Exceeded Exception
; 06  #UD  Fault        RSP0  Kernel  -- Invalid Opcode Exception
; 07  #NM  Fault        RSP0  Kernel  -- Device Not Available Exception
; 08  #DF  Abort        IST6  Kernel  -- Double Fault Exception
; 09  N/A  N/A          N/A   None    -- Old Coprocessor Segment Overrun -- no longer used
; 0A  #TS  Fault        RSP0  Kernel  -- Invalid TSS Exception
; 0B  #NP  Fault        RSP0  Kernel  -- Segment Not Present
; 0C  #SS  Fault        RSP0  Kernel  -- Stack Fault Exception
; 0D  #GP  Fault        RSP0  Kernel  -- General Protection Exception
; 0E  #PF  Fault        RSP0  Kernel  -- Page Fault Exception
; 0F  N/A  N/A          N/A   None    -- Unused
; 10  #MF  Fault        RSP0  Kernel  -- x87 Floating Point Error
; 11  #AC  Fault        RSP0  Kernel  -- Alignment Check Exception
; 12  #MC  Abort        IST5  Kernel  -- Machine Check Exception
; 13  #XM  Fault        RSP0  Kernel  -- SIMD Floating Point Exception
; 14 - 1F are reserved by Intel and will not be used
; 20    IRQ0            RSP0  Driver
; 21    IRQ1            RSP0  Driver
; 22    IRQ2            RSP0  Driver
; 23    IRQ3            RSP0  Driver
; 24    IRQ4            RSP0  Driver
; 25    IRQ5            RSP0  Driver
; 26    IRQ6            RSP0  Driver
; 27    IRQ7            RSP0  Driver
; 28    IRQ8            RSP0  Driver
; 29    IRQ9            RSP0  Driver
; 2A    IRQ10           RSP0  Driver
; 2B    IRQ11           RSP0  Driver
; 2C    IRQ12           RSP0  Driver
; 2D    IRQ13           RSP0  Driver
; 2E    IRQ14           RSP0  Driver
; 2F    IRQ15           RSP0  Driver
;
; From the above chart, the following stacks in the TSS are used in specific manners.  This is
; formalized in the following table:
;
;  RSP0 -- Exceptions resulting from poorly written code
;  RSP1 -- Unused
;  RSP2 -- Unused
;  IST1 -- Debugger
;  IST2 -- Unused
;  IST3 -- Unused
;  IST4 -- Unused
;  IST5 -- Machine Check (since it can occur during a task swap)
;  IST6 -- Double Faule (in case it is as a result a stack problem)
;  IST7 -- NMI (since it can occur during a task swap)
;
; The following functions are published in this file:
;   void IDTInit(void);
;   void RegisterHandler(qword intNbr, qword addr, qword ist);
;
; The following functions are internal functions:
;
; The following are interrupt service handlers located in this file:
;   DE_Fault
;   DB_Exception
;   NMI
;   BP_Trap
;   OF_Trap
;   BR_Fault
;   UD_Fault
;   NM_Fault
;   DF_Abort
;   TS_Fault
;   NP_Fault
;   SS_Fault
;   GP_Fault
;   PF_Fault
;   MF_Fault
;   AC_Fault
;   MC_Abort
;   XM_Fault
;
;    Date     Tracker  Pgmr  Description
; ----------  -------  ----  ------------------------------------------------------------------
; 2014/12/04  Initial  ADCL  Initial code
; 2014/12/16  #224     ADCL  With the initial debugger, all interrupts are now call the
;                            debugger.
; 2015/01/05  #244     ADCL  Output the error code with the error message in the debugger
; 2015/01/22  #255     ADCL  Need to better utilize the ISTs in the TSS.  I have been over-
;                            using them which has led to several issues.  Some significant
;                            changes are going to be made around this change, and I might have
;                            lots of additional changes as a result in other files.
;
;==============================================================================================

%define         __IDT_S__
%include        'private.inc'

IDT_ENTRIES     equ         0x30                    ; we want 48 interrupts for now

;==============================================================================================
; This is the .bss section.  It contains uninitialized data.
;==============================================================================================

                section     .bss

idtAddr         resq        1                           ; this holds the address of the IDT

idtr:
idtLimit        resw        1                           ; this is the IDT limit
idtBase         resq        1                           ; this is the IDT pointer
                resw        3                           ; we put the .bss out of alignment

;==============================================================================================
; this .text section contains the code to implement the Interrupt Descriptor Table (IDT) and
; the associated interfaces
;==============================================================================================

                section     .text
                bits        64

;----------------------------------------------------------------------------------------------
; void IDTInit(void) -- Initialize the IDT structures and load the idt register.
;----------------------------------------------------------------------------------------------

                global      IDTInit

IDTInit:
                push        rbp                         ; save the caller's frame
                mov.q       rbp,rsp                     ; create our own frame
                push        rcx                         ; save rcx
                push        rdi                         ; save rdi

;----------------------------------------------------------------------------------------------
; allocate space for the IDT
;----------------------------------------------------------------------------------------------

                mov.q       rax,IDT_ENTRIES             ; get the number of entries we need
                shl.q       rax,4                       ; each is 16 bytes long
                mov.q       rcx,rax                     ; we need the byte count for later
                push        rax                         ; push the size on the stack
                call        kmalloc                     ; get allocate the memory
                add.q       rsp,8                       ; clean up the stack

                mov.q       rdi,idtAddr                 ; get the variable address
                mov.q       [rdi],rax                   ; store the address

;----------------------------------------------------------------------------------------------
; load the memory for the idt register
;----------------------------------------------------------------------------------------------

                dec         rcx                         ; we need the length - 1 for the IDTR
                mov.q       rbx,idtLimit                ; get the address of the limit
                mov.w       [rbx],cx                    ; move the limit into the var

                mov.q       rbx,idtBase                 ; get the address of the idt base
                mov.q       [rbx],rax                   ; store the address

;----------------------------------------------------------------------------------------------
; clear the IDT table to make sure we don't create a different problem
;----------------------------------------------------------------------------------------------

                inc         rcx                         ; adjust back to the size
                shr.q       rcx,3                       ; convert bytes to qwords
                mov.q       rdi,rax                     ; get the address in rdi
                xor.q       rax,rax                     ; clear rax

                rep         stosq                       ; clear the table

;----------------------------------------------------------------------------------------------
; Finally, load the IDT
;----------------------------------------------------------------------------------------------

                mov.q       rax,idtr                    ; get the structure address
                lidt        [rax]                       ; and load the IDT

;----------------------------------------------------------------------------------------------
; Now, load the handlers
;
; INT0 -- #DE -- Divide Error
;----------------------------------------------------------------------------------------------

                push        RSP0                        ; use RSP0
                mov.q       rax,DE_Fault                ; get the address of the handler
                push        rax                         ; and push it on the stack
                push        0                           ; set INT0
                call        RegisterHandler             ; register the handler
                add.q       rsp,24                      ; clean up the stack

;----------------------------------------------------------------------------------------------
; INT1 -- #DB -- Debug Exception
;----------------------------------------------------------------------------------------------

                push        RSP0                        ; use RSP0
                mov.q       rax,DB_Exception            ; get the address of the handler
                push        rax                         ; and push it on the stack
                push        1                           ; set INT1
                call        RegisterHandler             ; register the handler
                add.q       rsp,24                      ; clean up the stack

;----------------------------------------------------------------------------------------------
; INT2 -- NMI -- Non-Maskable Interrupt
;----------------------------------------------------------------------------------------------

                push        IST7                        ; use IST7
                mov.q       rax,NMI                     ; get the address of the handler
                push        rax                         ; and push it on the stack
                push        2                           ; set INT2
                call        RegisterHandler             ; register the handler
                add.q       rsp,24                      ; clean up the stack

;----------------------------------------------------------------------------------------------
; INT3 -- #BP -- Breakpoint Trap
;----------------------------------------------------------------------------------------------

                push        IST1                        ; use IST1
                mov.q       rax,BP_Trap                 ; get the address of the handler
                push        rax                         ; and push it on the stack
                push        3                           ; set INT3
                call        RegisterHandler             ; register the handler
                add.q       rsp,24                      ; clean up the stack

;----------------------------------------------------------------------------------------------
; INT4 -- #OF -- Overflow Trap
;----------------------------------------------------------------------------------------------

                push        RSP0                        ; use RSP0
                mov.q       rax,OF_Trap                 ; get the address of the handler
                push        rax                         ; and push it on the stack
                push        4                           ; set INT4
                call        RegisterHandler             ; register the handler
                add.q       rsp,24                      ; clean up the stack

;----------------------------------------------------------------------------------------------
; INT5 -- #BR -- BOUND Range Exceeded Fault
;----------------------------------------------------------------------------------------------

                push        RSP0                        ; use RSP0
                mov.q       rax,BR_Fault                ; get the address of the handler
                push        rax                         ; and push it on the stack
                push        5                           ; set INT5
                call        RegisterHandler             ; register the handler
                add.q       rsp,24                      ; clean up the stack

;----------------------------------------------------------------------------------------------
; INT6 -- #UD -- Invalid Opcode Fault
;----------------------------------------------------------------------------------------------

                push        RSP0                        ; use RSP0
                mov.q       rax,UD_Fault                ; get the address of the handler
                push        rax                         ; and push it on the stack
                push        6                           ; set INT6
                call        RegisterHandler             ; register the handler
                add.q       rsp,24                      ; clean up the stack

;----------------------------------------------------------------------------------------------
; INT7 -- #NM -- Device Not Available Fault
;----------------------------------------------------------------------------------------------

                push        RSP0                        ; use RSP0
                mov.q       rax,NM_Fault                ; get the address of the handler
                push        rax                         ; and push it on the stack
                push        7                           ; set INT7
                call        RegisterHandler             ; register the handler
                add.q       rsp,24                      ; clean up the stack

;----------------------------------------------------------------------------------------------
; INT8 -- #DF -- Double Fault Abort
;----------------------------------------------------------------------------------------------

                push        IST6                        ; use IST6
                mov.q       rax,DF_Abort                ; get the address of the handler
                push        rax                         ; and push it on the stack
                push        8                           ; set INT8
                call        RegisterHandler             ; register the handler
                add.q       rsp,24                      ; clean up the stack

;----------------------------------------------------------------------------------------------
; INT 9 -- unused
; INT10 -- #TS -- Invalid TSS
;----------------------------------------------------------------------------------------------

                push        RSP0                        ; use RSP0
                mov.q       rax,TS_Fault                ; get the address of the handler
                push        rax                         ; and push it on the stack
                push        10                          ; set INT10
                call        RegisterHandler             ; register the handler
                add.q       rsp,24                      ; clean up the stack

;----------------------------------------------------------------------------------------------
; INT11 -- #NP -- Segment Not Present Fault
;----------------------------------------------------------------------------------------------

                push        RSP0                        ; use RSP0
                mov.q       rax,NP_Fault                ; get the address of the handler
                push        rax                         ; and push it on the stack
                push        11                          ; set INT11
                call        RegisterHandler             ; register the handler
                add.q       rsp,24                      ; clean up the stack

;----------------------------------------------------------------------------------------------
; INT12 -- #SS -- Stack Fault
;----------------------------------------------------------------------------------------------

                push        RSP0                        ; use RSP0
                mov.q       rax,SS_Fault                ; get the address of the handler
                push        rax                         ; and push it on the stack
                push        12                          ; set INT12
                call        RegisterHandler             ; register the handler
                add.q       rsp,24                      ; clean up the stack

;----------------------------------------------------------------------------------------------
; INT13 -- #GP -- General Protection Fault
;----------------------------------------------------------------------------------------------

                push        RSP0                        ; use RSP0
                mov.q       rax,GP_Fault                ; get the address of the handler
                push        rax                         ; and push it on the stack
                push        13                          ; set INT13
                call        RegisterHandler             ; register the handler
                add.q       rsp,24                      ; clean up the stack

;----------------------------------------------------------------------------------------------
; INT14 -- #PF -- Page Fault
;----------------------------------------------------------------------------------------------

                push        RSP0                        ; use RSP0
                mov.q       rax,PF_Fault                ; get the address of the handler
                push        rax                         ; and push it on the stack
                push        14                          ; set INT14
                call        RegisterHandler             ; register the handler
                add.q       rsp,24                      ; clean up the stack

;----------------------------------------------------------------------------------------------
; INT15 -- unused
; INT16 -- #MF -- FPU Fault
;----------------------------------------------------------------------------------------------

                push        RSP0                        ; use RSP0
                mov.q       rax,MF_Fault                ; get the address of the handler
                push        rax                         ; and push it on the stack
                push        16                          ; set INT16
                call        RegisterHandler             ; register the handler
                add.q       rsp,24                      ; clean up the stack

;----------------------------------------------------------------------------------------------
; INT17 -- #AC -- Alignment Check Fault
;----------------------------------------------------------------------------------------------

                push        RSP0                        ; use RSP0
                mov.q       rax,AC_Fault                ; get the address of the handler
                push        rax                         ; and push it on the stack
                push        17                          ; set INT17
                call        RegisterHandler             ; register the handler
                add.q       rsp,24                      ; clean up the stack

;----------------------------------------------------------------------------------------------
; INT18 -- #MC -- Machine Check Abort
;----------------------------------------------------------------------------------------------

                push        IST5                        ; use IST5
                mov.q       rax,MC_Abort                ; get the address of the handler
                push        rax                         ; and push it on the stack
                push        18                          ; set INT18
                call        RegisterHandler             ; register the handler
                add.q       rsp,24                      ; clean up the stack

;----------------------------------------------------------------------------------------------
; INT19 -- #XM -- SIMD Floating Point Fault
;----------------------------------------------------------------------------------------------

                push        RSP0                        ; use RSP0
                mov.q       rax,XM_Fault                ; get the address of the handler
                push        rax                         ; and push it on the stack
                push        19                          ; set INT19
                call        RegisterHandler             ; register the handler
                add.q       rsp,24                      ; clean up the stack

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                pop         rdi                         ; restore rdi
                pop         rcx                         ; restore rcx
                pop         rbp                         ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void RegisterHandler(qword intNbr, qword addr, qword ist) -- Build a new entry for the IDT
;                                                              and insert it into the proper
;                                                              location of the IDT.
;
; A couple of sanity checks take place here:
; 1) intNbr must be less than IDT_ENTRIES; if not then nothing happens
; 2) ist is masked down to 3 bits (values 0-7); any bits above bit #2 are ignored
; 3) the IDT entry needs a segment selector.  This selector is assumed to be CS.
;
; Finally, this function can be called with interrupts enabled.  Therefore care will be taken
; to clear interrupts before making a change in the IDT since it must be done in 2 parts, and
; care will be taken to ensure that the time interrupts are disabled is minimal.
;----------------------------------------------------------------------------------------------

                global      RegisterHandler

RegisterHandler:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdx                     ; save rdx
                push        rsi                     ; save rsi
                push        rdi                     ; save rdi
                push        r9                      ; save r9
                push        r15                     ; save r15

;----------------------------------------------------------------------------------------------
; first, let's get the intNbr and take care of the sanity check
;----------------------------------------------------------------------------------------------

                mov.q       rcx,[rbp+16]            ; get the intNbr
                cmp.q       rcx,IDT_ENTRIES         ; are we within bounds?
                jae         .out                    ; if out of bounds, just exit

;----------------------------------------------------------------------------------------------
; check and massage the IST value
;----------------------------------------------------------------------------------------------

                mov.q       r9,[rbp+32]             ; get the IST number
                and.q       r9,0x0007               ; mask this value down to 3 bits

;----------------------------------------------------------------------------------------------
; finally, get the handler address and the structure base address
;----------------------------------------------------------------------------------------------

                mov.q       rsi,[rbp+24]            ; get the address
                mov.q       rdi,idtAddr             ; get the idt base address pointer
                mov.q       rdi,[rdi]               ; get the address of the idt table
                shl.q       rcx,4                   ; adjust the entry number to byte offset

;----------------------------------------------------------------------------------------------
; so, here is what we are doing from here:
; * rax remains a working register
; * rbx will be used to build the upper qword of the entry
; * rcx is the byte offset to the IDT entry
; * rdx will be used to build the lower qword of the entry
; * rsi holds the handler address
; * rdi holds the base address of the IDT table
; * r9 holds the IST to use
;
; We need to build these upper and lower values and prepare to push them into the IDT Entry.
; Start with the lower half since it is more complicated to build
;----------------------------------------------------------------------------------------------

                xor.q       rdx,rdx                 ; clear rdx
                mov.w       dx,cs                   ; get the code segment selector
                shl.q       rdx,16                  ; put it in the right location

                mov.q       rax,rsi                 ; get the address
                and.q       rax,0x0000ffff          ; mask out the lower 16 bits
                or.q        rdx,rax                 ; drop that in the entry

                mov.q       rax,rsi                 ; get the address again
                mov.q       r15,0xffff0000          ; set the mask we want
                and.q       rax,r15                 ; mask out bits 16:32
                or.q        rax,0x00008e00          ; set the type and other flags
                or.q        rax,r9                  ; lay in the IST

                shl.q       rax,32                  ; shift it up the the upper half
                or.q        rdx,rax                 ; lay this into the register

;----------------------------------------------------------------------------------------------
; the upper 64 bits are easy to prepare
;----------------------------------------------------------------------------------------------

                mov.q       rbx,rsi                 ; get the address again
                shr.q       rbx,32                  ; shift down the address
                mov.q       r15,0xffffffff          ; set the mask
                and.q       rbx,r15                 ; mask out the address

;----------------------------------------------------------------------------------------------
; now, we are ready to update the IDT entry.  clear interrupts and make the changes!
;----------------------------------------------------------------------------------------------

                pushfq                              ; save interrupts state
                cli                                 ; no interrupts
                mov.q       [rdi+rcx],rdx           ; set the lower 64 bits
                mov.q       [rdi+rcx+8],rbx         ; set the upper 64 bits
                popfq                               ; pop interrupts state

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                pop         r15                     ; restore r15
                pop         r9                      ; restore r9
                pop         rdi                     ; restore rdi
                pop         rsi                     ; restore rsi
                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restpre rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================


;==============================================================================================
;==============================================================================================
;==============================================================================================
;==============================================================================================
;==============================================================================================
;==============================================================================================
;======         The following are the interrupt handlers installed by the kernel.       =======
;==============================================================================================
;==============================================================================================
;==============================================================================================
;==============================================================================================
;==============================================================================================
;==============================================================================================

;----------------------------------------------------------------------------------------------
; When this exception handler gets control of the system the following is the stack contents:
; |                |          |
; +----------------+----------+
; |                |          |
; +----------------+----------+
; |       SS       | [rbp+48] |  +40
; +----------------+----------+
; |      RSP       | [rbp+40] |  +32
; +----------------+----------+
; |     RFLAGS     | [rbp+32] |  +24
; +----------------+----------+
; |       CS       | [rbp+24] |  +16
; +----------------+----------+
; |      RIP       | [rbp+16] |  +8
; +----------------+----------+
; |   Error Code   | [rbp+8]  |  +0 (If present; If not, we will push 0)
; +----------------+----------+
;
; Interrupts will be disabled.  The other register contents will need to be saved before doing
; anything.  Therefore, we will push in this order:
;
; RBP [rbp] (and create a new frame)
; RAX [rbp-8]
; RBX [rbp-16]
; RCX [rbp-24]
; RDX [rbp-32]
; RSI [rbp-40]
; RDI [rbp-48]
; R8  [rbp-56]
; R9  [rbp-64]
; R10 [rbp-72]
; R11 [rbp-80]
; R12 [rbp-88]
; R13 [rbp-96]
; R14 [rbp-104]
; R15 [rbp-112]
; DS  [rbp-120]
; ES  [rbp-128]
; FS  [rbp-136]
; GS  [rbp-144]
; CR0 [rbp-152]
; CR2 [rbp-160]
; CR3 [rbp-168]
;
; Now, any function that is called later and would like to query/update any of these register
; values, then all that need be done is pass rbp as a parameter and it becomes a base pointer
; to the rest of the registers.
;
; For the initial implementation, the course of action  for these exceptions will be as Brendan
; outlined in the following thread on OSDev:
; http://forum.osdev.org/viewtopic.php?f=1&t=28814#p243553, where unrecoverable errors will
; panic the kernel.  I hope to be able to put a slightly more refined approach into the
; handlers.
;----------------------------------------------------------------------------------------------

;==============================================================================================

;----------------------------------------------------------------------------------------------
; DE_Fault -- The following is the interrupt handler that is evoked with a #DE Fault.
;
; This fault does not produce an error code, so one will have to be pushed to align the stack.
; then all the other registers will need to be pushed on the stack.  We will push them all
; individually since we have a defined order to push them.
;
; Per Brendan, this fault is ALWAYS unrecoverable.  For now, we will launch the debugger.
;
; However, I also feel that this exception should not kill the OS, especially if the error
; comes from a user-space program.  Therefore, I will ultimately implement a check on where
; the error occurred (likely by checking CS and checking the CPL) and launch the debugger (or
; just panic) if the error occurs in ring 0 code; or, just kill the process if the code is
; running at CPL 3.
;
; After some additional research, I think I will allow a process to install it's own handler
; for Exceptions 0, 4, & 5.  In this manner, programming languages that have a defined
; exception handler for these exceptions can "install" the handler on the process and have it
; called instead.
;----------------------------------------------------------------------------------------------

DE_Fault:
                push        qword 0                 ; align the stack
                INT_HANDLER_PREAMBLE                ; save all the registers

;----------------------------------------------------------------------------------------------
; report the error
;----------------------------------------------------------------------------------------------

                mov.q       rax,DEMsg               ; get the error message
                push        rax                     ; push it on the stack
                push        rbp                     ; push the frame as parm
                call        debugger
                add.q       rsp,16

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                INT_HANDLER_CLEANUP                 ; restore all the registers
                iretq

;==============================================================================================

;----------------------------------------------------------------------------------------------
; DB_Exception -- The following is the interrupt handler that is evoked with a #DB Exception.
;                 This exception can encompass several different types of exceptions, some
;                 considered faults (where RIP points to the instruction generating the
;                 exception) and others are traps (with RIP pointing to the instruction
;                 following the exception).  Therefore, at this point in the development
;                 it is easier to just halt the system.
;
; This exception does not produce an error code, so one will have to be pushed to align the
; stack.  Then all the other registers will need to be pushed on the stack.  We will push them
; all individually since we have a defined order to push them.
;
; According to Brendan, this exception should always be able to return successfully.  For now,
; since my exception handler is not very robust, I'm going to just neter the debugger.  I will
; revisit this exception as I am able to better defined how and when I will generate this
; exception.
;----------------------------------------------------------------------------------------------

DB_Exception:
                push        qword 0                 ; align the stack
                INT_HANDLER_PREAMBLE                ; save all the registers

;----------------------------------------------------------------------------------------------
; report the error
;----------------------------------------------------------------------------------------------

                mov.q       rax,DBMsg               ; get the error message
                push        rax                     ; push it on the stack
                push        rbp                     ; push the frame as parm
                call        debugger
                add.q       rsp,16

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                INT_HANDLER_CLEANUP                 ; restore all the registers
                iretq

;==============================================================================================

;----------------------------------------------------------------------------------------------
; NMI -- This interrupt handler will be processed on the receipt of a Non-Maskable Interrupt
;        (NMI).
;
; According to Brendan, this exception should indicate something rather faulty in the hardware
; and therefore should panic the kernel.  I'm going to take his advice.  For now, I will call
; the debugger.
;----------------------------------------------------------------------------------------------

NMI:
                push        qword 0                 ; align the stack
                INT_HANDLER_PREAMBLE                ; save all the registers

;----------------------------------------------------------------------------------------------
; report the error
;----------------------------------------------------------------------------------------------

                mov.q       rax,NMIMsg              ; get the error message
                push        rax                     ; push it on the stack
                push        rbp                     ; push the frame as parm
                call        debugger
                add.q       rsp,16

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                INT_HANDLER_CLEANUP                 ; restore all the registers
                iretq

;==============================================================================================

;----------------------------------------------------------------------------------------------
; BP_Trap -- The following is the interrupt handler that is evoked with a #BP Trap.
;
; According to Brendan, we can use this for just about anything.  I'm going to use this to
; launch the debugger.
;----------------------------------------------------------------------------------------------

BP_Trap:
                push        qword 0                 ; align the stack
                INT_HANDLER_PREAMBLE                ; save all the registers

;----------------------------------------------------------------------------------------------
; report the error
;----------------------------------------------------------------------------------------------

                mov.q       rax,BPMsg               ; get the error message
                push        rax                     ; push it on the stack
                push        rbp                     ; push the frame as parm
                call        debugger
                add.q       rsp,16

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                INT_HANDLER_CLEANUP                 ; restore all the registers
                iretq

;==============================================================================================

;----------------------------------------------------------------------------------------------
; OF_Trap -- The following is the interrupt handler that is evoked with a #OF Trap.
;
; We do nothing with the #OF trap, so we will just record the event and halt
;
; According to Brendan, this is always unrecoverable.  For now, we will jsut drop into the
; debugger.
;
; After some additional research, I think I will allow a process to install it's own handler
; for Exceptions 0, 4, & 5.  In this manner, programming languages that have a defined
; exception handler for these exceptions can "install" the handler on the process and have it
; called instead.
;----------------------------------------------------------------------------------------------

OF_Trap:
                push        qword 0                 ; align the stack
                INT_HANDLER_PREAMBLE                ; save all the registers

;----------------------------------------------------------------------------------------------
; report the error
;----------------------------------------------------------------------------------------------

                mov.q       rax,OFMsg               ; get the error message
                push        rax                     ; push it on the stack
                push        rbp                     ; push the frame as parm
                call        debugger
                add.q       rsp,16

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                INT_HANDLER_CLEANUP                 ; restore all the registers
                iretq

;==============================================================================================

;----------------------------------------------------------------------------------------------
; BR_Fault -- The following is the interrupt handler that is evoked with a #BR Fault
;
; We do nothing with the #BR fault, so we will just record the event and halt
;
; According to Brendan, this is always unrecoverable.  For now, we will jsut drop into the
; debugger.
;
; After some additional research, I think I will allow a process to install it's own handler
; for Exceptions 0, 4, & 5.  In this manner, programming languages that have a defined
; exception handler for these exceptions can "install" the handler on the process and have it
; called instead.
;----------------------------------------------------------------------------------------------

BR_Fault:
                push        qword 0                 ; align the stack
                INT_HANDLER_PREAMBLE                ; save all the registers

;----------------------------------------------------------------------------------------------
; report the error
;----------------------------------------------------------------------------------------------

                mov.q       rax,BRMsg               ; get the error message
                push        rax                     ; push it on the stack
                push        rbp                     ; push the frame as parm
                call        debugger
                add.q       rsp,16

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                INT_HANDLER_CLEANUP                 ; restore all the registers
                iretq

;==============================================================================================

;----------------------------------------------------------------------------------------------
; UD_Fault -- The following is the interrupt handler that is evoked with a #UD Fault
;
; We might use this to emulate an instruction that is not available on the CPU.  For now, I
; know of none.  Therefore, we will just drop into the debugger when this happens.
;----------------------------------------------------------------------------------------------

UD_Fault:
                push        qword 0                 ; align the stack
                INT_HANDLER_PREAMBLE                ; save all the registers

;----------------------------------------------------------------------------------------------
; report the error
;----------------------------------------------------------------------------------------------

                mov.q       rax,UDMsg               ; get the error message
                push        rax                     ; push it on the stack
                push        rbp                     ; push the frame as parm
                call        debugger
                add.q       rsp,16

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                INT_HANDLER_CLEANUP                 ; restore all the registers
                iretq

;==============================================================================================

;----------------------------------------------------------------------------------------------
; NM_Fault -- The following is the interrupt handler that is evoked with a #NM Fault
;
; According to Brendan, this has a lot of possibilities, such as not reloading the FPU/MMX/etc
; registers on a task switch, or emulating other rather large precisions numbers.  That being
; the case (along with the fact that I am not supporting floating point numbers in the OS yet),
; we will just drop into the debugger at this point.
;----------------------------------------------------------------------------------------------

NM_Fault:
                push        qword 0                 ; align the stack
                INT_HANDLER_PREAMBLE                ; save all the registers

;----------------------------------------------------------------------------------------------
; report the error
;----------------------------------------------------------------------------------------------

                mov.q       rax,NMMsg               ; get the error message
                push        rax                     ; push it on the stack
                push        rbp                     ; push the frame as parm
                call        debugger
                add.q       rsp,16

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                INT_HANDLER_CLEANUP                 ; restore all the registers
                iretq

;==============================================================================================

;----------------------------------------------------------------------------------------------
; DF_Abort -- The following interrupt handler is invoked for a #DF Exception.
;
; According to Brendan, this is always unrecoverable.  However, I am not totally convinced.  I
; believe that we might be able to terminate an offending user process and continue on, rather
; than panicking the kernel.  All-in-all, I would like to get to a point where I could restart
; a driver if it fails.
;----------------------------------------------------------------------------------------------

DF_Abort:
                INT_HANDLER_PREAMBLE                ; save all the registers

;----------------------------------------------------------------------------------------------
; report the error
;----------------------------------------------------------------------------------------------

                mov.q       rax,DFMsg               ; get the error message
                push        rax                     ; push it on the stack
                push        rbp                     ; push the frame as parm
                call        debugger
                add.q       rsp,16

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                INT_HANDLER_CLEANUP                 ; restore all the registers
                iretq

;==============================================================================================

;----------------------------------------------------------------------------------------------
; TS_Fault -- The following interrupt handler is invoked for a #TS Fault.
;
; According to Brendan, this is always unrecoverable.  Again, I am not totally sure I agree.
; For now, this will be an error, but I might be able to dynamically load a TSS when this fault
; occurs and try again.  For now, we will drop into the debugger.
;----------------------------------------------------------------------------------------------

TS_Fault:
                INT_HANDLER_PREAMBLE                ; save all the registers

;----------------------------------------------------------------------------------------------
; report the error
;----------------------------------------------------------------------------------------------

                mov.q       rax,TSMsg               ; get the error message
                push        rax                     ; push it on the stack
                push        rbp                     ; push the frame as parm
                call        debugger
                add.q       rsp,16

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                INT_HANDLER_CLEANUP                 ; restore all the registers
                iretq

;==============================================================================================

;----------------------------------------------------------------------------------------------
; NP_Fault -- The following interrupt handler is invoked for a #NP Fault.
;
; According to Brandan, this is likely always uncoverable.  I tend to agree, as paging is
; beingused in this kernel.  We will drop into the debugger.
;----------------------------------------------------------------------------------------------

NP_Fault:
                INT_HANDLER_PREAMBLE                ; save all the registers

;----------------------------------------------------------------------------------------------
; report the error
;----------------------------------------------------------------------------------------------

                mov.q       rax,NPMsg               ; get the error message
                push        rax                     ; push it on the stack
                push        rbp                     ; push the frame as parm
                call        debugger
                add.q       rsp,16

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                INT_HANDLER_CLEANUP                 ; restore all the registers
                iretq

;==============================================================================================

;----------------------------------------------------------------------------------------------
; SS_Fault -- The following interrupt handler is invoked for a #SS Fault.
;
; According to Brendan, this is always unrecoverable.  For now I agree and will drop into the
; debugger.  I reserve the right to disagree with Brendan in the future.
;----------------------------------------------------------------------------------------------

SS_Fault:
                INT_HANDLER_PREAMBLE                ; save all the registers

;----------------------------------------------------------------------------------------------
; report the error
;----------------------------------------------------------------------------------------------

                mov.q       rax,SSMsg               ; get the error message
                push        rax                     ; push it on the stack
                push        rbp                     ; push the frame as parm
                call        debugger
                add.q       rsp,16

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                INT_HANDLER_CLEANUP                 ; restore all the registers
                iretq

;==============================================================================================

;----------------------------------------------------------------------------------------------
; GP_Fault -- The following interrupt handler is invoked for a #GP Fault.
;
; Brendan uses this to do some special tricks in the OS.  There are LOTS of reasons a system
; will issue a GPF.  Some will need to be looked at in-depth.  However, for now, I agree with
; Brendan.  Until I get a more intelligent handler written, we will just drop into the
; debugger.
;----------------------------------------------------------------------------------------------

GP_Fault:
                INT_HANDLER_PREAMBLE                ; save all the registers

;----------------------------------------------------------------------------------------------
; report the error
;----------------------------------------------------------------------------------------------

                mov.q       rax,GPMsg               ; get the error message
                push        rax                     ; push it on the stack
                push        rbp                     ; push the frame as parm
                call        debugger
                add.q       rsp,16

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                INT_HANDLER_CLEANUP                 ; restore all the registers
                iretq

;==============================================================================================

;----------------------------------------------------------------------------------------------
; PF_Fault -- The following interrupt handler is invoked for a #PF Fault.
;
; We can do a lot with this and will end up being installed/replaced by a component of the
; Virtual Memory Manager.  The Page Fault will be a major component of the operating system.
;----------------------------------------------------------------------------------------------

PF_Fault:
                INT_HANDLER_PREAMBLE                ; save all the registers

;----------------------------------------------------------------------------------------------
; report the error
;----------------------------------------------------------------------------------------------

                mov.q       rax,PFMsg               ; get the error message
                push        rax                     ; push it on the stack
                push        rbp                     ; push the frame as parm
                call        debugger
                add.q       rsp,16

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                INT_HANDLER_CLEANUP                 ; restore all the registers
                iretq

;==============================================================================================

;----------------------------------------------------------------------------------------------
; MF_Fault -- The following is the interrupt handler that is evoked with a #MF Fault.
;
; According to Brendan, implementing any recovery on this is just a waste of time.
;
; I am not sure I agree at this point; I might write a driver and install a new version of this
; handler from that driver.  In the meantime, I will drop into the debugger.
;----------------------------------------------------------------------------------------------

MF_Fault:
                push        qword 0                 ; align the stack
                INT_HANDLER_PREAMBLE                ; save all the registers

;----------------------------------------------------------------------------------------------
; report the error
;----------------------------------------------------------------------------------------------

                mov.q       rax,MFMsg               ; get the error message
                push        rax                     ; push it on the stack
                push        rbp                     ; push the frame as parm
                call        debugger
                add.q       rsp,16

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                INT_HANDLER_CLEANUP                 ; restore all the registers
                iretq

;==============================================================================================

;----------------------------------------------------------------------------------------------
; AC_Fault -- The following is the interrupt handler that is evoked with a #AC Fault.
;
; May be able to use this to profile performance concerns.  In order to do this, we will need
; to enable alignment checking and when an interrupt occurs, make a note, disable alignment
; checking, return to execute the faulting instruction, and then devise a mechanism to
; re-enable alignment checking on the next instruction.  Brendon refers to INT3, but I might
; prefer to set a single-step flag instead.
;----------------------------------------------------------------------------------------------

AC_Fault:
                push        qword 0                 ; align the stack
                INT_HANDLER_PREAMBLE                ; save all the registers

;----------------------------------------------------------------------------------------------
; report the error
;----------------------------------------------------------------------------------------------

                mov.q       rax,ACMsg               ; get the error message
                push        rax                     ; push it on the stack
                push        rbp                     ; push the frame as parm
                call        debugger
                add.q       rsp,16

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                INT_HANDLER_CLEANUP                 ; restore all the registers
                iretq

;==============================================================================================

;----------------------------------------------------------------------------------------------
; MC_Abort -- The following is the interrupt handler that is evoked with a #MC Abort.
;
; According to Brendan, this should not be installed.  Perhaps so.  However, I believe we will
; double fault first before resetting so I will leave this installed and point it to the
; debugger.
;----------------------------------------------------------------------------------------------

MC_Abort:
                INT_HANDLER_PREAMBLE                ; save all the registers

;----------------------------------------------------------------------------------------------
; report the error
;----------------------------------------------------------------------------------------------

                mov.q       rax,MCMsg               ; get the error message
                push        rax                     ; push it on the stack
                push        rbp                     ; push the frame as parm
                call        debugger
                add.q       rsp,16

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                INT_HANDLER_CLEANUP                 ; restore all the registers
                iretq

;==============================================================================================

;----------------------------------------------------------------------------------------------
; XM_Fault -- The following is the interrupt handler that is evoked with a #XM Fault.
;
; Again, according to Brendan, this is always unrecoverable.  However, I might take the
; position that a user-space program can install its own handler here and have it chained
; to this interrupt.
;----------------------------------------------------------------------------------------------

XM_Fault:
                push        qword 0                 ; align the stack
                INT_HANDLER_PREAMBLE                ; save all the registers

;----------------------------------------------------------------------------------------------
; report the error
;----------------------------------------------------------------------------------------------

                mov.q       rax,XMMsg               ; get the error message
                push        rax                     ; push it on the stack
                push        rbp                     ; push the frame as parm
                call        debugger
                add.q       rsp,16

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                INT_HANDLER_CLEANUP                 ; restore all the registers
                iretq

;==============================================================================================

                section     .rodata

DEMsg           db          '              HALTING: Divide error (#DE): ',0
DBMsg           db          '    HALTING: Debug Exception (#DB) with no debugger: ',0
NMIMsg          db          '    RESUMING: Non-Maskable Interrupt (NMI) received: ',0
BPMsg           db          '    RESUMING: Breakpoint Trap (#BP) with no debugger: ',0
OFMsg           db          '          HALTING: Overflow Trap (#OF) received: ',0
BRMsg           db          '   HALTING: BOUND Range Exceeded Fault (#BR) received: ',0
UDMsg           db          '      HALTING: Invalid Opcode Fault (#UD) received: ',0
NMMsg           db          '   HALTING: Device Not Available Fault (#NM) received: ',0
DFMsg           db          '       HALTING: Double Fault Abort (#DF) received: ',0
TSMsg           db          'HALTING: Invalid TSS Fault (#TS) received - seg selector: ',0
NPMsg           db          '   HALTING: Segment Not Present Fault (#NP) received: ',0
SSMsg           db          '          HALTING: Stack Fault (#SS) received: ',0
GPMsg           db          '    HALTING: General Protection Fault (#GP) received: ',0
PFMsg           db          '          HALTING: Page Fault (#PF) received: ',0
MFMsg           db          '  HALTING: x87 FPU Floating Point Fault (#MF) received: ',0
ACMsg           db          '     HALTING: Alignment Check Fault (#AC) received: ',0
MCMsg           db          '      HALTING: Machine Check Abort (#MC) received: ',0
XMMsg           db          '     HALTING: SIMD Floating Point Fault (#XM) received: ',0


Ext             db          ' (External)',0
IDT             db          ' (IDT Entry)',0

Pres            db          ' (Present) ',0
NPres           db          ' (Not Pres)',0

Read            db          ' (Read) ',0
Write           db          ' (Write)',0

User            db          ' (User)',0
Supr            db          ' (Supr)',0

Instr           db          ' (Instr)',0
Data            db          ' (Data) ',0

Rsvd            db          ' (Rsvd)',0
NRsvd           db          '       ',0

