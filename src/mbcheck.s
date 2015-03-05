;==============================================================================================
;
; mbcheck.s
;
; This file contains the functions that will parse and report the multiboot structures as
; requested.
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
; The following functions are provided in this source file:
;   qword CheckMB(void);
;   qword GetMemLimit(void);
;   qword GetFreeFirst(void);
;   qword GetFreeNext(void);
;
; The following are internal functions also in this source file:
;   qword MB1GetMemLimit(void);
;   qword MB2GetMemLimit(void);
;   qword OthGetMemLimit(void);
;   qword MB1GetFreeFirst(void);
;   qword MB1GetFreeNext(void);
;   qword FreeSetNULL(void);
;
;    Date     Tracker  Pgmr  Description
; ----------  -------  ----  ------------------------------------------------------------------
; 2014/10/07  Initial  ADCL  Initial code
; 2014/10/12  #169     ADCL  For me, the ABI standard is causing me issues. For whatever reason,
;                            I am having trouble keeping track of "registers I want to save as
;                            the caller" rather than "saving all registers I will modify as the
;                            callee". I will adopt the latter standard so that debugging will
;                            be easier to manage, with the exception of rax.  DF in rFLAGS will
;                            be maintained as clear.
;                            At the same time reformat for spacing
; 2014/11/15  #200     ADCL  Some changes were necessary when the code was relocated.  Some
;                            function calls between the .text and .boot2 segments were required
;                            to be far calls.
; 2014/11/21  #200     ADCL  So, I think it is time to completely gut this source file and
;                            rewrite it from (nearly) scratch.  Rather than taking the approach
;                            that I need to collect all information possible before I start
;                            initializing, I think it would be better to accept queries for
;                            specific information and reporting the results.  Of particular
;                            note in this area is the physical memory manager.  While I am
;                            writing this comment, the function to report the results of the
;                            MultiBoot Information structure is responsible for the
;                            initialization details of the physical memory manager.  I cannot
;                            see this as correct approach.  Instead, I can see the PMM
;                            initialization function asking for a highest possible address and
;                            asking for a block of free memory as reported by Multiboot.  So,
;                            the resulting source file after this next commit is going to be
;                            quite different from the previuos commits.
;
;==============================================================================================

%define         __MBCHECK_S__
%include        'private.inc'

DFT_MEM         equ         4*1024*1024*1024

struc MB1
    .flags      resd        1
    .memLower   resd        1
    .memUpper   resd        1
    .bootDevice resd        1
    .cmdLine    resd        1
    .modsCount  resd        1
    .modsAddr   resd        1
    .syms       resd        4
    .mmapLength resd        1
    .mmapAddr   resd        1
    .drivesLen  resd        1
    .drivesAddr resd        1
    .configTbl  resd        1
    .bootLdrNm  resd        1
    .apmTable   resd        1
    .vbeCtrlInf resd        1
    .vbeModeInf resd        1
    .vbeMode    resd        1
    .vbeIfcSeg  resd        1
    .vbeIfcOff  resd        1
    .vbeIfcLen  resd        1
endstruc

struc MB1MMap
    .size       resd        1
    .baseAddr   resq        1
    .length     resq        1
    .type       resd        1
endstruc

MB1_MMAP_FLAG   equ         1<<6

;==============================================================================================
; The .data section contains variables for this source module.
;==============================================================================================

                section     .data

MBType          dq          0                       ; 0=Other; 1=MB2; 2=<B2
MBMMAPGood      db          0                       ; 0=Not good; <>0 good
                align       8

mbFreeMem       istruc      FreeMem
.str            dq          0
.end            dq          0
.addr           dd          0
.len            dd          0
                iend

_GetMemLimit    dq          OthGetMemLimit
                dq          MB1GetMemLimit
                dq          MB2GetMemLimit

_GetFreeFirst   dq          FreeSetNULL
                dq          MB1GetFreeFirst
                dq          FreeSetNULL

_GetFreeNext    dq          FreeSetNULL
                dq          MB1GetFreeNext
                dq          FreeSetNULL

;==============================================================================================
; The .boot2 section is the 64-bit initialization code
;==============================================================================================

                section     .boot2
                bits        64

;----------------------------------------------------------------------------------------------
; qword CheckMB(void) -- Check the multiboot magic number and determine if the kernel was
;                        booted with a compliant boot loader.
;----------------------------------------------------------------------------------------------

                global      CheckMB

CheckMB:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; we will modify rbx

;----------------------------------------------------------------------------------------------
; get the original value given to us by multiboot
;----------------------------------------------------------------------------------------------

                xor.q       rax,rax                 ; clear rax
                mov.q       rbx,mbEAX               ; get the address of the var
                mov.d       eax,[rbx]               ; get the value -- lower 32 bits

;----------------------------------------------------------------------------------------------
; Check for a Multiboot 1 signature
;----------------------------------------------------------------------------------------------

                cmp.d       eax,MAGIC1              ; multiboot 1?
                jne         .chk2                   ; if not check mb2

                mov.q       rbx,MBType              ; get the address for MBType var
                mov.q       [rbx],1                 ; set the Multiboot type to 1
                jmp         .out                    ; we can skip the rest

;----------------------------------------------------------------------------------------------
; Check for a Multiboot 2 signature
;----------------------------------------------------------------------------------------------

.chk2:          cmp.d       eax,MAGIC2              ; multiboot 2?
                jne         .other                  ; if not, report another boot loader

                mov.q       rbx,MBType              ; get the address for MBType var
                mov.q       [rbx],2                 ; set the Multiboot type to 2
                jmp         .out                    ; we can skip the rest

;----------------------------------------------------------------------------------------------
; Anything else and we just don't know
;----------------------------------------------------------------------------------------------

.other:         mov.q       rbx,MBType              ; get the address for MBType var
                mov.q       [rbx],0                 ; set the Multiboot type to 3 (other)

;----------------------------------------------------------------------------------------------
; Clean up and exit
;----------------------------------------------------------------------------------------------

.out:           mov.q       rax,[rbx]               ; set the return value

                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword GetFreeFirst(void) -- Returns an address to a structure containing a memory start/end
;                             of free memory.
;----------------------------------------------------------------------------------------------

                global      GetFreeFirst

GetFreeFirst:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx

                mov.q       rax,MBType              ; get the address of the MBType var
                mov.q       rax,[rax]               ; now get its contents
                shl.q       rax,3                   ; convert to qwords (by 8)

                mov.q       rbx,_GetFreeFirst       ; get the offset into the address array
                mov.q       rax,[rbx+rax]           ; get the address of the real function
                call        rax                     ; this is a far call

                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword GetFreeNext(void) -- Returns an address to a structure containing a memory start/end
;                            of free memory.
;----------------------------------------------------------------------------------------------

                global      GetFreeNext

GetFreeNext:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx

                mov.q       rax,MBType              ; get the address of the MBType var
                mov.q       rax,[rax]               ; now get its contents
                shl.q       rax,3                   ; convert to qwords (by 8)

                mov.q       rbx,_GetFreeNext        ; get the offset into the address array
                mov.q       rax,[rbx+rax]           ; get the address of the real function
                call        rax                     ; this is a far call

                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword MB1GetFreeFirst(void) -- For the MB1 structures, return the first free block of memory
;                                by setting up the structures in mbFreeMem and then return the
;                                pointer to this structure.  If nothing is free, then set the
;                                structures to 0 and return 0.  Keep in mind that this is
;                                highly unlikely if we have a good memory map.
;
; We have already done all the pre-checking for this when we call GetMemLimit(), which is
; guaranteed to be called prior to this call.  So, we can just check the MBMMAPGood flag.
;----------------------------------------------------------------------------------------------

MB1GetFreeFirst:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdx                     ; save rdx
                push        rsi                     ; save rsi
                push        rdi                     ; save rdi

;----------------------------------------------------------------------------------------------
; quick sanity check: do we have a good mmap?
;----------------------------------------------------------------------------------------------

                mov.q       rax,MBMMAPGood          ; get the address of the flag
                cmp.b       [rax],0                 ; do we have a good mmap?
                je          .noGood                 ; if not good, jump out

;----------------------------------------------------------------------------------------------
; start by getting the MBI address and then the address & length of the table.
;----------------------------------------------------------------------------------------------

                xor.q       rbx,rbx                 ; clear the upper bits of rbx
                mov.d       ebx,mbEBX               ; get the address of the MBI var
                mov.d       ebx,[ebx]               ; get the structure address

                mov.d       ecx,[rbx+MB1.mmapLength]; get the length of the total table
                mov.d       ebx,[rbx+MB1.mmapAddr]  ; get the address of the first mmap entry

;----------------------------------------------------------------------------------------------
; Now we look for the first free entry in the tables.  We might not get one (unlikely), but
; check for going past the end of the table anyway.
;----------------------------------------------------------------------------------------------

.loop:          cmp.q       rcx,0                   ; have we used up all our bytes?
                jle         .noGood                 ; if so, we can exit (note -- signed cmp)

                xor.q       rdx,rdx                 ; clear rdx
                mov.d       edx,[rbx+MB1MMap.size]  ; get the size of the mmap entry
                cmp.q       rdx,0                   ; is the size of the entry 0?
                je          .noGood                 ; if so, let's assume we can exit

                add.q       rdx,4                   ; be sure to include the size field

;----------------------------------------------------------------------------------------------
; do we have a free block?
;----------------------------------------------------------------------------------------------

                mov.d       edi,[rbx+MB1MMap.type]  ; get the type
                cmp.d       edi,1                   ; is this a free block?
                jne         .iter                   ; if not, get the next block

;----------------------------------------------------------------------------------------------
; At this point, we have our free block to return.  We need to calculate the ending address
; and return the pointer to the structure.
;----------------------------------------------------------------------------------------------

                mov.q       rsi,mbFreeMem           ; get the address of our structure
                mov.q       rax,[rbx+MB1MMap.baseAddr]  ; get the base address
                mov.q       [rsi+FreeMem.str],rax   ; and store it in the field

                mov.q       rax,[rbx+MB1MMap.length]; get the block length
                mov.q       [rsi+FreeMem.size],rax  ; set the block size

                add.q       rbx,rdx                 ; move to the next block
                sub.q       rcx,rdx                 ; sub the byte count

                mov.q       [rsi+FreeMem.addr],rbx  ; save the current pointer
                mov.q       [rsi+FreeMem.len],rcx   ; save the current length

                mov.q       rax,rsi                 ; finally, set our return value

                jmp         .out                    ; go to the exit code

;----------------------------------------------------------------------------------------------
; check the next entry
;----------------------------------------------------------------------------------------------

.iter:
                add.q       rbx,rdx                 ; move the the next entry
                sub.q       rcx,rdx                 ; remove the bytes from the remaining size
                jmp         .loop                   ; loop again

;----------------------------------------------------------------------------------------------
; we do not have a good free entry in the mmap table.  mark it so and exit
;----------------------------------------------------------------------------------------------

.noGood:        mov.q       rax,mbFreeMem           ; get the address of the structure
                mov.q       [rax+FreeMem.str],0     ; set the start address to 0
                mov.q       [rax+FreeMem.size],0    ; set the block size to 0
                mov.q       [rax+FreeMem.addr],0    ; set the current entry addr to 0
                mov.q       [rax+FreeMem.len],0     ; set the remaining length to 0
                xor.q       rax,rax                 ; set the return address to NULL

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                pop         rdi                     ; restore rdi
                pop         rsi                     ; restore rsi
                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword MB1GetFreeNext(void) -- For the MB1 structures, return the next free block of memory
;                               by setting up the structures in mbFreeMem and then return the
;                               pointer to this structure.  If nothing is free, then set the
;                               structures to 0 and return 0.  Keep in mind that this is
;                               highly unlikely if we have a good memory map.
;
; We have already done all the pre-checking for this when we call GetMemLimit(), which is
; guaranteed to be called prior to this call.  So, we can just check the MBMMAPGood flag.
;----------------------------------------------------------------------------------------------

MB1GetFreeNext:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdx                     ; save rdx
                push        rsi                     ; save rsi
                push        rdi                     ; save rdi

;----------------------------------------------------------------------------------------------
; quick sanity check: do we have a good mmap?
;----------------------------------------------------------------------------------------------

                mov.q       rax,MBMMAPGood          ; get the address of the flag
                cmp.b       [rax],0                 ; do we have a good mmap?
                je          .noGood                 ; if not good, jump out

;----------------------------------------------------------------------------------------------
; Get the state from the other fields and prepare to continue searching
;----------------------------------------------------------------------------------------------

                xor.q       rbx,rbx                 ; clear upper rbx bits
                xor.q       rcx,rcx                 ; clear upper rcx bits

                mov.q       rax,mbFreeMem           ; get the address of our structure
                mov.d       ebx,[rax+FreeMem.addr]  ; get the address of the next entry
                mov.d       ecx,[rax+FreeMem.len]   ; get the current remaining length

;----------------------------------------------------------------------------------------------
; Now we look for the first free entry in the tables.  We might not get one (unlikely), but
; check for going past the end of the table anyway.
;----------------------------------------------------------------------------------------------

.loop:          cmp.q       rcx,0                   ; have we used up all our bytes?
                jle         .noGood                 ; if so, we can exit (note -- signed cmp)

                xor.q       rdx,rdx                 ; clear rdx
                mov.d       edx,[rbx+MB1MMap.size]  ; get the size of the mmap entry
                cmp.q       rdx,0                   ; is the size of the entry 0?
                je          .noGood                 ; if so, let's assume we can exit

                add.q       rdx,4                   ; be sure to include the size field

;----------------------------------------------------------------------------------------------
; do we have a free block?
;----------------------------------------------------------------------------------------------

                mov.d       edi,[rbx+MB1MMap.type]  ; get the type
                cmp.d       edi,1                   ; is this a free block?
                jne         .iter                   ; if not, get the next block

;----------------------------------------------------------------------------------------------
; At this point, we have our free block to return.  We need to calculate the ending address
; and return the pointer to the structure.
;----------------------------------------------------------------------------------------------

                mov.q       rsi,mbFreeMem           ; get the address of our structure
                mov.q       rax,[rbx+MB1MMap.baseAddr]  ; get the base address
                mov.q       [rsi+FreeMem.str],rax   ; and store it in the field

                mov.q       rax,[rbx+MB1MMap.length]; get the block length
                mov.q       [rsi+FreeMem.size],rax  ; and add it to the blocks size field

                add.q       rbx,rdx                 ; move to the next block
                sub.q       rcx,rdx                 ; sub the byte count

                mov.q       [rsi+FreeMem.addr],rbx  ; save the current pointer
                mov.q       [rsi+FreeMem.len],rcx   ; save the current length

                mov.q       rax,rsi                 ; finally, set our return value

                jmp         .out                    ; go to the exit code

;----------------------------------------------------------------------------------------------
; check the next entry
;----------------------------------------------------------------------------------------------

.iter:
                add.q       rbx,rdx                 ; move the the next entry
                sub.q       rcx,rdx                 ; remove the bytes from the remaining size
                jmp         .loop                   ; loop again

;----------------------------------------------------------------------------------------------
; we do not have a good free entry in the mmap table.  mark it so and exit
;----------------------------------------------------------------------------------------------

.noGood:        mov.q       rax,mbFreeMem           ; get the address of the structure
                mov.q       [rax+FreeMem.str],0     ; set the start address to 0
                mov.q       [rax+FreeMem.size],0    ; set the block size to 0
                mov.q       [rax+FreeMem.addr],0    ; set the current entry addr to 0
                mov.q       [rax+FreeMem.len],0     ; set the remaining length to 0
                xor.q       rax,rax                 ; set the return address to NULL

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                pop         rdi                     ; restore rdi
                pop         rsi                     ; restore rsi
                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword FreeSetNULL(void) -- Sets the contents of the structure to NULL and returns NULL.
;----------------------------------------------------------------------------------------------

FreeSetNULL:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx

                xor.q       rax,rax                 ; clear rax
                mov.q       rbx,mbFreeMem.str       ; get the address of the struct member
                mov.q       [rbx],rax               ; store the NULL there

                mov.q       rbx,mbFreeMem.end       ; get the address of the struct member
                mov.q       [rbx],rax               ; store the NULL there

                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword GetMemLimit(void) -- Get the memory limit reported to us by the boot loader.
;----------------------------------------------------------------------------------------------

                global      GetMemLimit

GetMemLimit:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx

                mov.q       rax,MBType              ; get the address of the MBType var
                mov.q       rax,[rax]               ; now get its contents
                shl.q       rax,3                   ; convert to qwords (by 8)

                mov.q       rbx,_GetMemLimit        ; get the offset into the address array
                mov.q       rax,[rbx+rax]           ; get the address of the real function
                call        rax                     ; this is a far call

                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword OthGetMemLimit(void) -- Get the memory limit when loaded by non-MB compliant loader
;----------------------------------------------------------------------------------------------

OthGetMemLimit:
                mov.q       rax,DFT_MEM             ; assume 4GB
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword MB1GetMemLimit(void) -- Read through the MB1 memory map tables to pull out the highest
;                               memory block available.
;----------------------------------------------------------------------------------------------

MB1GetMemLimit:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdx                     ; save rdx
                push        rsi                     ; save rsi
                push        rdi                     ; save rdi

;----------------------------------------------------------------------------------------------
; First, do we have a good address?
;----------------------------------------------------------------------------------------------

                xor.q       rbx,rbx                 ; clear rax
                mov.q       rax,mbEBX               ; get the address of the saved pointer
                mov.d       ebx,[rax]               ; get the address of the MBInfo Struct

                cmp.q       rbx,0                   ; is the address NULL?
                je          .noGood                 ; if null, return our default

;----------------------------------------------------------------------------------------------
; Now, is the flag set?
;----------------------------------------------------------------------------------------------

                mov.d       eax,[rbx+MB1.flags]     ; get the flags dword
                test.d      eax,MB1_MMAP_FLAG       ; test if the flag is good
                jz          .noGood                 ; not set, return our default

;----------------------------------------------------------------------------------------------
; Finally, make sure the length of the memory map is > 0
;----------------------------------------------------------------------------------------------

                xor.q       rcx,rcx                 ; clear rcx
                mov.d       ecx,[rbx+MB1.mmapLength]; get the length of the memory map
                cmp.d       ecx,0                   ; is the length 0?
                je          .noGood                 ; if 0, we return our default mem size

;----------------------------------------------------------------------------------------------
; If we have reached this point in the code, we know we have a good memory map.  We need to
; loop through all the map entries and for each one that is marked "free", we need to calculate
; the ending address (start + size).  If that result is greater than the pervious ending
; address, then we need to set our new ending address and check the next block.  In the end,
; we will return the highest block's ending address and the memory limit for this system.
; Note that the blocks are not guaranteed to be in order.
;----------------------------------------------------------------------------------------------

                mov.q       rsi,MBMMAPGood          ; get the address of the good flag
                mov.b       [rsi],1                 ; set it to be a good mmap

                xor.q       rsi,rsi                 ; clear rsi
                mov.d       esi,[rbx+MB1.mmapAddr]  ; get the address of the memory map
                cmp.q       rsi,0                   ; check just in case...  no surprises
                je          .noGood                 ; if it is 0, return our default mem size

                xor         rax,rax                 ; start with a return value of 0

;----------------------------------------------------------------------------------------------
; first we will check to see if we have overrun out length.
;----------------------------------------------------------------------------------------------

.loop:          cmp.q       rcx,0                   ; have we used up all our bytes?
                jle         .out                    ; if so, we can exit (note -- signed cmp)

                xor.q       rdx,rdx                 ; clear rdx
                mov.d       edx,[rsi+MB1MMap.size]  ; get the size of the mmap entry
                cmp.q       rdx,0                   ; is the size of the entry 0?
                je          .out                    ; if so, let's assume we can exit

                add.q       rdx,4                   ; be sure to include the size field

;----------------------------------------------------------------------------------------------
; do we have a free block?
;----------------------------------------------------------------------------------------------

                mov.d       edi,[rsi+MB1MMap.type]  ; get the type
                cmp.d       edi,1                   ; is this a free block?
                jne         .iter                   ; if not, get the next block

;----------------------------------------------------------------------------------------------
; calculate the ending address
;----------------------------------------------------------------------------------------------

                mov.q       rdi,[rsi+MB1MMap.baseAddr]  ; get the base address
                mov.q       rbx,[rsi+MB1MMap.length]    ; get the block length
                add.q       rdi,rbx                 ; add them together to get the ending addr

                cmp.q       rdi,rax                 ; is the new ending address > the prev one
                jle         .iter                   ; if not, check the next block

;----------------------------------------------------------------------------------------------
; Update the new ending address
;----------------------------------------------------------------------------------------------

                mov.q       rax,rdi                 ; set the new return value

.iter:
                add.q       rsi,rdx                 ; move the the next entry
                sub.q       rcx,rdx                 ; remove the bytes from the remaining size
                jmp         .loop                   ; loop again

;----------------------------------------------------------------------------------------------
; There is some issue and we cannot get our memory map; assume 4GB
;----------------------------------------------------------------------------------------------

.noGood:
                mov.q       rax,DFT_MEM             ; assume 4GB

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                pop         rdi                     ; restore rdi
                pop         rsi                     ; restore rsi
                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword MB2GetMemLimit(void) -- Read through the MB2 memory map tables to pull out the highest
;                               memory block available.
;----------------------------------------------------------------------------------------------

MB2GetMemLimit:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame

                mov.q       rax,DFT_MEM             ; assume 4GB

                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================
