;==============================================================================================
;
; gdt-tss.s
;
; This file contains the definitions and interfaces needed for the GDT and TSS structures.
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
; Well, I was hoping to get much further into development before having to figure out the TSS
; structure.  That strategy did not work out for me since the IDT depends on this structure
; for stacks that will be used for interrupts to ensure that an interrupt gets a clean stack.
;
; I am taking inspiration for this souce from the following discussion on osdev.org:
; http://forum.osdev.org/viewtopic.php?t=13678.  We will need 1 TSS for each processor.  For
; now, I am only supporting 1 processor, but in the future, I will want to support multiple
; processors and without limit.  Redmine #214 was created to track this thought.
;
; However, as a result of the above statement, the TSS will be dynamically allocated from
; the kernel heap.  Even with 256 processors, this will not take up too much space from the
; 16TB heap.  The only concern is whether the structure can split page boundaries.
;
; The Intel manual has the following description:
;   "If paging is used:
;    * Avoid placing a page boundary in the part of the TSS that the processor reads during a
;      task switch (the first 104 bytes).  The processor may not correctly perform address
;      translation if a boundary occurs in this area.  During a task switch, the processor
;      reads and writes into the first 104 bytes of each TSS (using contiguous physical
;      addresses beginning with the physical address of the first byte of the TSS).  So,
;      after TSS access begins, if part of the 104 bytes is not physically contiguous, the
;      processor will access incorrect information without generating a page-fault exception."
;
; I have the following topic opened on OSDev.org asking the above question:
; http://forum.osdev.org/viewtopic.php?f=1&t=28799
;
; Failing any satisfactory authoritative response saying I do not need to, I will be using
; full pages for the TSSs, which can hold 32 TSSs (size adjusted to 128 bytes) each 4K page
; without any bitmap.  This means that 256 TSSs can be managed in 8 pages.  I'm trying hard
; not to impose artificial limits on anything in this system, but this might be one place I
; have to compromise.  I may also come back to test this page boundary myself if I get bored.
;
; One other thing to keep in mind is that the GDT Entry for a TSS (like an LDT) is 16 bytes
; long (2 qwords).  So, this needs to be taken into account when allocating the GDT.
;
; So, with all that said, I have reserved the space from 0xffff ff7f fff0 0000 to
; 0xffff ff7f ffff efff (which is 1MB less 4KB, or 255 pages) for TSSs.  This space will hold
; 8,160 TSSs in total.  This ridiculous amount should be FAR more than I ever need.
;
; Added into this file will be the API needed to maintain the GDT as well.
;
; The following functions are published in this file:
;   void GDTInit(void);
;
; The following functions are internal functions:
;
;    Date     Tracker  Pgmr  Description
; ----------  ------   ----  ------------------------------------------------------------------
; 2014/11/30  Initial  ADCL  Initial code
;
;==============================================================================================

%define         __GDT_TSS_S__
%include        'private.inc'

TSS_PER_PAGE    equ         32                      ; number of TSS structs that fit in a page
TSS_START       equ         0xffffff7ffff00000      ; this is the start of the TSS space

TSS_ADDL        equ         0                       ; the number of additional TSSs to setup

GDT_NULL        equ         0                       ; GDT Entry 0 is the null entry
GDT_KCODE       equ         1                       ; GDT Entry 1 is the kernel code
GDT_KDATA       equ         2                       ; GDT Entry 2 is the kernel data
GDT_UCODE       equ         3                       ; GDT Entry 3 is the user code
GDT_UDATA       equ         4                       ; GDT Entry 4 is the user data
GDT_TSS         equ         5                       ; GDT Entry 5/6 is the first TSS entry

TSS_LIMIT       equ         103                     ; == 104 - 1 (the size of the TSS struct)

;----------------------------------------------------------------------------------------------
; In the following flags constants, the following flags have these meanings:
;   G = granularity (0=byte; 1=4K)
;   D/B = default operation size (0=16-bit segments; 1=32-bit segments)
;   L = Long (1=64-bit code segment and requires d/b = 0)
;   AVL = Available
;   P = Present
;   DPL = Descriptor Privilege Level (0-3)
;   S = Descriptor Type (0=System; 1=Code/Data)
;----------------------------------------------------------------------------------------------

KCODE_FLAGS     equ         0xa09a          ; (G d/b L avl) ... (P DPL=0 S) (Code/Exec/Rd)
KDATA_FLAGS     equ         0xa092          ; (G d/b L avl) ... (P DPL=0 S) (Data/Wr/Rd)
UCODE_FLAGS     equ         0xa0fa          ; (G d/b L avl) ... (P DPL=3 S) (Code/Exec/Rd)
UDATA_FLAGS     equ         0xa0f2          ; (G d/b L avl) ... (P DPL=3 S) (Data/Wr/Rd)

;----------------------------------------------------------------------------------------------
; The TSS structure is used to provide offsets for each of the data members.
;
; This structure is artificailly aligned to 128 bytes (bigger than the 104 bytes required by
; the CPU) for no other reason than to make the math separating a 4K page easy.
;----------------------------------------------------------------------------------------------

struc TSS
    .res1       resd        1
    .rsp0       resq        1
    .rsp1       resq        1
    .rsp2       resq        1
    .res2       resq        1
    .ist1       resq        1
    .ist2       resq        1
    .ist3       resq        1
    .ist4       resq        1
    .ist5       resq        1
    .ist6       resq        1
    .ist7       resq        1
    .res3       resq        1
    .res4       resw        1
    .iomba      resw        1
    .fill       resq        3
endstruc

;----------------------------------------------------------------------------------------------
; The TSSCtrl structure is used to control the allocation and usage of the TSS structures.  I
; do not expect to ever need to de-allocate a TSS, so that will not be built into this
; interface.
;----------------------------------------------------------------------------------------------

struc TSSCtrl
    .pages      resq        1
    .curIdx     resq        1
    .maxIdx     resq        1
    .tssNeeds   resq        1
endstruc

;==============================================================================================
; This is the .bss section.  It contains uninitialized data.
;==============================================================================================

                section     .bss

tssCtrl         resb        TSSCtrl_size                ; this is the TSS management struct

gdtr:
gdtLimit        resw        1                           ; this is the GDT limit
gdtBase         resq        1                           ; this is the GDT pointer
                resw        3                           ; we put the .bss out of alignment

;==============================================================================================
; this .text section contains the code to implement the Task State Segments (and their
; interfaces)
;==============================================================================================

                section     .text
                bits        64

;----------------------------------------------------------------------------------------------
; void GDTInit(void) -- Allocate a new GDT from the kernel heap and initialize it with the
;                       proper values.  Put this new GDT in play.
;----------------------------------------------------------------------------------------------

                global      GDTInit

GDTInit:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rdx                     ; save rdx (see NewTSSEntry)
                push        rsi                     ; save rsi
                push        r9                      ; save r9

;----------------------------------------------------------------------------------------------
; First, in order to construct our GDT, we need to know how many TSS segments we need.  We will
; get this number by first calling TSSInit(), which will tell us how many we will get.
;----------------------------------------------------------------------------------------------

                call        TSSInit                 ; Initalize the TSSCtrl structure
                mov.q       r9,rax                  ; save the result for later
                shl.q       rax,1                   ; each TSS takes up 2 qwords; account now
                add.q       rax,5                   ; we will be adding 5 add'l qword entries
                shl.q       rax,3                   ; each entry is a qword

;----------------------------------------------------------------------------------------------
; now, we will go get the memory we need for the GDT
;----------------------------------------------------------------------------------------------

                push        rax                     ; push the number of bytes on the stack
                call        kmalloc                 ; go get the requested memory
                                                    ; stack cleanup happens below

;----------------------------------------------------------------------------------------------
; set the variables
;----------------------------------------------------------------------------------------------

                mov.q       rbx,gdtBase             ; get the address of the var
                mov.q       [rbx],rax               ; store the pointer for later
                mov.q       rsi,rax                 ; we also need the address in a work reg

                pop         rax                     ; now clean up stack; we need bytes back
                dec         rax                     ; we need 1 less than the total bytes
                mov.q       rbx,gdtLimit            ; get the address of the var
                mov.w       [rbx],ax                ; store the limit in the variable

;----------------------------------------------------------------------------------------------
; Now, let's setup the GDT entries; first we set up the NULL entry -- trivial
;----------------------------------------------------------------------------------------------

                mov.q       [rsi+(GDT_NULL<<3)],0   ; set the null descriptor to... ummm, NULL!

;----------------------------------------------------------------------------------------------
; next we set up the kernel code entry.
;----------------------------------------------------------------------------------------------

                mov.q       rax,KCODE_FLAGS         ; get the kernel flags
                push        rax                     ; push that on the stack
                call        CrtDescriptor           ; create the descriptor
                add.q       rsp,8                   ; clean up the stack

                mov.q       [rsi+(GDT_KCODE<<3)],rax; set the entry in the GDT

;----------------------------------------------------------------------------------------------
; next we set up the kernel data entry.
;----------------------------------------------------------------------------------------------

                mov.q       rax,KDATA_FLAGS         ; get the kernel flags
                push        rax                     ; push that on the stack
                call        CrtDescriptor           ; create the descriptor
                add.q       rsp,8                   ; clean up the stack

                mov.q       [rsi+(GDT_KDATA<<3)],rax; set the entry in the GDT

;----------------------------------------------------------------------------------------------
; next we set up the user code entry.
;----------------------------------------------------------------------------------------------

                mov.q       rax,UCODE_FLAGS         ; get the kernel flags
                push        rax                     ; push that on the stack
                call        CrtDescriptor           ; create the descriptor
                add.q       rsp,8                   ; clean up the stack

                mov.q       [rsi+(GDT_UCODE<<3)],rax; set the entry in the GDT

;----------------------------------------------------------------------------------------------
; next we set up the user data entry.
;----------------------------------------------------------------------------------------------

                mov.q       rax,UDATA_FLAGS         ; get the kernel flags
                push        rax                     ; push that on the stack
                call        CrtDescriptor           ; create the descriptor
                add.q       rsp,8                   ; clean up the stack

                mov.q       [rsi+(GDT_UDATA<<3)],rax; set the entry in the GDT

;----------------------------------------------------------------------------------------------
; for now, I'm only going to setup 1 TSS..  Later, this will need to be added into a loop
;----------------------------------------------------------------------------------------------

                call        NewTSS                  ; create a TSS Structure and init fields

                push        rax                     ; push the address on the stack
                call        NewTSSEntry             ; get the GDT entry for the TSS
                add.q       rsp,8                   ; clean up the stack

                mov.q       [rsi+(GDT_TSS<<3)],rax  ; set the entry in the GDT
                mov.q       [rsi+((GDT_TSS+1)<<3)],rdx  ; set the entry in the GDT

;----------------------------------------------------------------------------------------------
; finally, put the new GDT into action
;----------------------------------------------------------------------------------------------

                mov.q       rax,gdtr                ; get the address of the gdt register val
                lgdt        [rax]                   ; and load the gdt

                mov.q       rax,.gdtEnable          ; get the jmp address
                jmp         rax                     ; and far jump to set the cs selector

.gdtEnable:     mov.q       rax,0x10                ; the selector for data
                mov.w       ds,ax                   ; set the ds selector
                mov.w       es,ax                   ; set the es selector
                mov.w       fs,ax                   ; set the fs selector
                mov.w       gs,ax                   ; set the gs selector
                mov.w       ss,ax                   ; set the ss selector
                mov.q       rsp,rsp                 ; and ALWAYS set the stack pointer

;----------------------------------------------------------------------------------------------
; and load the task register
;----------------------------------------------------------------------------------------------

                mov.q       rax,GDT_TSS<<3          ; get the segment selector for the TSS
                ltr         ax                      ; and load the task reg

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

                pop         r9                      ; restore r9
                pop         rsi                     ; restore rsi
                pop         rdx                     ; restore rdx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword CrtDescriptor(qword flags) -- Create a descriptor based on the information passed in
;                                     the parameters.  Note that in 64-bit mode, the limit is
;                                     not used and is assumed to be 0.  In addition, we are
;                                     using a base address of 0 for all segments so we will
;                                     assume that as 0 as well.
;----------------------------------------------------------------------------------------------

CrtDescriptor:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame

                mov.q       rax,[rbp+16]            ; get the flags
                and.q       rax,0xf0ff              ; mask out the flags we want
                shl.q       rax,40                  ; position the flags correctly

                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; GetCPUCount is a stub function to return the number of CPUs on the system.  This function
; will likely be relocated to another source and will read the ACPI information (indirectly) to
; get the specifics.  In the meantime, we support only 1 CPU and we will hard-code this.
;----------------------------------------------------------------------------------------------

GetCPUCount:    mov.q       rax,1
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword TSSInit(void) -- This function will initialize the tssCtrl structure and allocate the
;                        proper number of frames required to support the number of CPUs and any
;                        additional TSSs required on the system.
;
; Note that for the initial implementation, only 1 TSS is needed.  Later when SMP is supported,
; the numebr of CPUs will be determined by the system.  This function will certainly change at
; that point.
;----------------------------------------------------------------------------------------------

TSSInit:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdx                     ; save rdx

;----------------------------------------------------------------------------------------------
; first, we need to know how many CPUs we have on the system.  go get that info and then adjust
; for the number of pages we need.
;----------------------------------------------------------------------------------------------

                call        GetCPUCount             ; get the CPU count on the system
                add.q       rax,TSS_ADDL            ; rax holds the CPU count; add in any add'l

                test.q      rax,0x001f              ; do we have any partial pages?
                jz          .countOK                ; if an even break, jump over the adj

                add.q       rax,TSS_PER_PAGE        ; round out page so we can truncate
                mov.q       rdx,rax                 ; save this final count for later

.countOK:       shr.q       rax,5                   ; get the number of pages we want

;----------------------------------------------------------------------------------------------
; now, we need to ask the VMM for these pages
;----------------------------------------------------------------------------------------------

                push        rax                     ; push the number of pages
                mov.q       rax,TSS_START           ; get the starting virtual address
                push        rax                     ; push the address
                call        VMMAlloc                ; get the pages

                cmp.q       rax,VMM_ERR_NOMEM       ; did we have a problem?
                je          .out                    ; exit for now; do something better later

                add.q       rsp,8                   ; remove the virtual address from stack
                pop         rcx                     ; we need our page count back

;----------------------------------------------------------------------------------------------
; so, with the information we have now, let's populate the management structure
;----------------------------------------------------------------------------------------------

                mov.q       rbx,tssCtrl             ; get the address of the struct
                mov.q       rax,TSS_START           ; get the starting address of the TSS pages
                mov.q       [rbx+TSSCtrl.pages],rax ; store the address of the TSS pages

                mov.q       [rbx+TSSCtrl.curIdx],0  ; the next one to use

                shl.q       rcx,5                   ; adjust pages back to TSS structures
                mov.q       [rbx+TSSCtrl.maxIdx],rcx; set the numebr of TSS structs we support

                mov.q       [rbx+TSSCtrl.tssNeeds],rdx  ; set the number TSSs we really need

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:           mov.q       rax,rdx                 ; return the number of TSS entries

                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword NewTSS(void) -- Allocate and create a new TSS, initializing all its members properly.
;
; There is a finite amount of space for TSS structures, so there will be a few sanity checks
; that need to take place as we go through this procedure:
; 1)  tssCtrl.curIdx < tssCtrl.maxIdx
; 2)  tssCtrl.curIdx < tssCtrl.tssNeeds
;----------------------------------------------------------------------------------------------

NewTSS:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdx                     ; save rdx
                push        rdi                     ; save rdi
                push        r9                      ; save r9

                xor.q       rax,rax                 ; set the temp reurn value

;----------------------------------------------------------------------------------------------
; first sanity check: tssCtrl.curIdx < tssCtrl.maxIdx
;----------------------------------------------------------------------------------------------

                mov.q       r9,tssCtrl              ; get the address of the tss structure
                mov.q       rcx,[r9+TSSCtrl.curIdx] ; get the current count
                mov.q       rdx,[r9+TSSCtrl.maxIdx] ; get the max count

                cmp.q       rcx,rdx                 ; do we have room for this TSS?
                jae         .out                    ; nope, exit and return 0

;----------------------------------------------------------------------------------------------
; second sanity check: tssCtrl.curIdx < tssCtrl.tssNeeds
;----------------------------------------------------------------------------------------------

                mov.q       rdx,[r9+TSSCtrl.tssNeeds] ; get the number we need

                cmp.q       rcx,rdx                 ; do we have room for this TSS?
                jae         .out                    ; nope, exit and return 0

;----------------------------------------------------------------------------------------------
; calculate the byte offset into tssCtrl.pages for the TSS we will use
;----------------------------------------------------------------------------------------------

                shl.q       rcx,7                   ; multiply by 128 to get bytes
                mov.q       rbx,[r9+TSSCtrl.pages]  ; get the starting address
                add.q       [r9+TSSCtrl.curIdx],1   ; increment the current count
                mov.q       rbx,[rbx+rcx]           ; get the address of the TSS

;----------------------------------------------------------------------------------------------
; for good measure, let's clear the TSS
;----------------------------------------------------------------------------------------------

                mov.q       rdi,rbx                 ; set the destination address
                mov.q       rcx,TSSCtrl_size        ; get the number of bytes to clear
                shr.q       rcx,3                   ; convert bytes to qwords
                xor.q       rax,rax                 ; clear rax

                rep         stosq                   ; clear the structure

;----------------------------------------------------------------------------------------------
; now we need to populate this structure with 10 stack pointers.  Each stack is a consistent
; size so we just need to call our stack allocation routine to get the stack and then store the
; resulting stack pointer at the end of the stack (stack grows down, so we need to high
; address).
;----------------------------------------------------------------------------------------------

                call        AllocStack              ; get a stack
                add         rax,STACK_SIZE          ; move to the end of the stack
                mov.q       [rbx+TSS.rsp0],rax      ; store the stack pinter

                call        AllocStack              ; get a stack
                add         rax,STACK_SIZE          ; move to the end of the stack
                mov.q       [rbx+TSS.rsp1],rax      ; store the stack pinter

                call        AllocStack              ; get a stack
                add         rax,STACK_SIZE          ; move to the end of the stack
                mov.q       [rbx+TSS.rsp2],rax      ; store the stack pinter

                call        AllocStack              ; get a stack
                add         rax,STACK_SIZE          ; move to the end of the stack
                mov.q       [rbx+TSS.ist1],rax      ; store the stack pinter

                call        AllocStack              ; get a stack
                add         rax,STACK_SIZE          ; move to the end of the stack
                mov.q       [rbx+TSS.ist2],rax      ; store the stack pinter

                call        AllocStack              ; get a stack
                add         rax,STACK_SIZE          ; move to the end of the stack
                mov.q       [rbx+TSS.ist3],rax      ; store the stack pinter

                call        AllocStack              ; get a stack
                add         rax,STACK_SIZE          ; move to the end of the stack
                mov.q       [rbx+TSS.ist4],rax      ; store the stack pinter

                call        AllocStack              ; get a stack
                add         rax,STACK_SIZE          ; move to the end of the stack
                mov.q       [rbx+TSS.ist5],rax      ; store the stack pinter

                call        AllocStack              ; get a stack
                add         rax,STACK_SIZE          ; move to the end of the stack
                mov.q       [rbx+TSS.ist6],rax      ; store the stack pinter

                call        AllocStack              ; get a stack
                add         rax,STACK_SIZE          ; move to the end of the stack
                mov.q       [rbx+TSS.ist7],rax      ; store the stack pinter

                mov.q       rax,TSS_size            ; get the size of the TSS struct
                mov.w       [rbx+TSS.iomba],ax      ; store the addr of the io bitmap

                mov.q       rax,rbx                 ; set the return value

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:           pop         r9                      ; restore r9
                pop         rdi                     ; restore rdi
                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword:qword NewTSSEntry(qword tss) -- given the pointer to the TSS structure already
;                                       initialized, create the GDT entries for that structure
;
; There are a couple of important notes with this function:
; 1) The structure as defined in this file is 128 bytes.  However, the CPU is expecting a
;    structure size of 104 bytes.  When we establish the limit of this segment, we need to be
;    sure we use the limit the CPU is expecting for the structure size.
; 2) This function will DESTROY RDX as rdx will be used as part of the return value.  It is the
;    responsbility of any calling function to preserve any value in rdx as a result.
;----------------------------------------------------------------------------------------------

NewTSSEntry:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx

                xor.q       rax,rax                 ; clear rax
                xor.q       rdx,rdx                 ; clear rdx

;----------------------------------------------------------------------------------------------
; rdx is easy...  let's start with the top 32 bits of the base address
;----------------------------------------------------------------------------------------------

                mov.q       rcx,[rbp+16]            ; get the address
                shr.q       rcx,32                  ; get down to the upper 32 bits
                mov.q       rbx,0x00000000ffffffff  ; set the bit mask
                and.q       rcx,rbx                 ; mask off these bits
                mov.d       edx,ecx                 ; move these into the return value

;----------------------------------------------------------------------------------------------
; now, rax.  we start with the upper 32 bits, which we will build in the lower 32 bits
; and then shift up.
;----------------------------------------------------------------------------------------------

                mov.q       rcx,[rbp+16]            ; get the address again
                mov.q       rbx,0x00000000ff000000  ; set the bit mask
                and.q       rcx,rbx                 ; mask out those bits
                or.q        rax,rcx                 ; move that into rax
                or.q        rax,0x0000000000908900  ; set the flags for the TSS

                mov.q       rcx,[rbp+16]            ; get the address again
                shr.q       rcx,16                  ; we want bits 16-23
                and.q       rcx,0x00000000000000ff  ; mask off these bits
                or.q        rax,rcx                 ; move them into the rax reg

                shl.q       rax,32                  ; move to the upper bits

                mov.q       rcx,[rbp+16]            ; get the address again
                and.q       rcx,0x000000000000ffff  ; mask out lower 16 bits
                shl.q       rcx,16                  ; move them up to upper word
                or.q        rax,rcx                 ; move them into the return value

                mov.q       rcx,TSS_LIMIT           ; get the limit
                or.q        rax,rcx                 ; and move them into the return reg

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:           pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

