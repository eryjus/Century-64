;==============================================================================================
;
; mb1.s
;
; This file contains the function for reading the MultiBoot 1 Information Structure.
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
; This file is intended to replace the mbcheck.s file.
;
; The following functions are provided in this source file:
;   void ReadMB1(void);
;
; The following are internal functions also in this source file:
;   void MB1ElfHdr(qword cnt, qword size, qword addr, qword ndx);
;
;    Date     Tracker  Pgmr  Description
; ----------  -------  ----  ------------------------------------------------------------------
; 2015/02/20  Initial  ADCL  Initial code
;
;==============================================================================================

%define         __MB1_S__
%include        'private.inc'

;----------------------------------------------------------------------------------------------
; This structure is duplicated in mbcheck.s.  It needs to be consolidated into a single
; definition.
;----------------------------------------------------------------------------------------------
struc MB1
    .flags      resd        1
    .memLower   resd        1
    .memUpper   resd        1
    .bootDevice resd        1
    .cmdLine    resd        1
    .modsCount  resd        1
    .modsAddr   resd        1
    .symsA      resd        1
    .symsB      resd        1
    .symsC      resd        1
    .symsD      resd        1
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

;----------------------------------------------------------------------------------------------
; I have a feeling that this next structure will end up being relocated to a file specifically
; for loading elf files....  But, in the meantime, it will be here so that we can find the
; symbol table.
;----------------------------------------------------------------------------------------------
struc ElfSH
    .name       resd        1
    .type       resd        1
    .flags      resq        1
    .addr       resq        1
    .offset     resq        1
    .size       resq        1
    .link       resd        1
    .info       resd        1
    .addralign  resq        1
    .entsize    resq        1
endstruc


;==============================================================================================
; The .boot2 section is the 64-bit initialization code
;==============================================================================================

                section     .boot2
                bits        64

;----------------------------------------------------------------------------------------------
; void ReadMB1(void) -- read the MB1 Information structure and report the results.
;----------------------------------------------------------------------------------------------
                global      ReadMB1
ReadMB1:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx

                mov.d       eax,[mbEAX]             ; get the magic number
                cmp.d       eax,MAGIC1              ; make sure we have an MB1 magic number
                jne         .error                  ; if not, we have an error

                mov.d       ebx,[mbEBX]             ; get the structure address
                mov.d       ecx,[ebx+MB1.flags]     ; get the flags from the structure

                push        rcx                     ; push the flags on the stack
                mov.q       rax,intro               ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the address of the function
                call        rax                     ; call the function
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; Check for bit 0 -- memory limits -- and report the results
;----------------------------------------------------------------------------------------------
.bit0:          test.q      rcx,1<<0                ; is the bit set?
                jz          .noBit0                 ; if not set, move on

                mov.d       eax,[rbx+MB1.memUpper]  ; get the address of the value
                push        rax                     ; push it on the stack
                mov.d       eax,[rbx+MB1.memLower]  ; get the address of the value
                push        rax                     ; push it on the stack
                mov.q       rax,bit0Set             ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,24                  ; clean up the stack

                jmp         .bit1                   ; go to the next check

;----------------------------------------------------------------------------------------------
; Bit 0 -- data not provided
;----------------------------------------------------------------------------------------------
.noBit0:        push        qword 0                 ; print bit 0
                mov.q       rax,bitClear            ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; Check for bit 1 -- boot device -- and report the results
;----------------------------------------------------------------------------------------------
.bit1:          test.q      rcx,1<<1                ; is the bit set?
                jz          .noBit1                 ; if not set, move on

                mov.d       eax,[rbx+MB1.bootDevice]; get the address of the value
                push        rax                     ; push it on the stack
                mov.q       rax,bit1Set             ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,16                  ; clean up the stack

                jmp         .bit2                   ; go to the next check

;----------------------------------------------------------------------------------------------
; Bit 1 -- data not provided
;----------------------------------------------------------------------------------------------
.noBit1:        push        qword 1                 ; print bit 1
                mov.q       rax,bitClear            ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; Check for bit 2 -- command line -- and report the results
;----------------------------------------------------------------------------------------------
.bit2:          test.q      rcx,1<<2                ; is the bit set?
                jz          .noBit2                 ; if not set, move on

                mov.d       eax,[rbx+MB1.cmdLine]   ; get the address of the value
                push        rax                     ; push it on the stack (string)
                push        rax                     ; push it on the stack (address)
                mov.q       rax,bit2Set             ; get the string to write
                push        rax                     ; and push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,24                  ; clean up the stack

                jmp         .bit3                   ; go to the next check

;----------------------------------------------------------------------------------------------
; Bit 2 -- data not provided
;----------------------------------------------------------------------------------------------
.noBit2:        push        qword 2                 ; print bit 2
                mov.q       rax,bitClear            ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; Check for bit 3 -- Modules -- and report the results
;----------------------------------------------------------------------------------------------
.bit3:          test.q      rcx,1<<3                ; is the bit set?
                jz          .noBit3                 ; if not set, move on

                mov.d       eax,[rbx+MB1.modsAddr]  ; get the address of the value
                push        rax                     ; push it on the stack
                mov.d       eax,[rbx+MB1.modsCount] ; get the address of the value
                push        rax                     ; push it on the stack
                mov.q       rax,bit3Set             ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,24                   ; clean up the stack

                jmp         .bit4                   ; go to the next check

;----------------------------------------------------------------------------------------------
; Bit 3 -- data not provided
;----------------------------------------------------------------------------------------------
.noBit3:        push        qword 3                 ; print bit 3
                mov.q       rax,bitClear            ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; Check for bit 4 -- a.out symbol table -- and report the results
;----------------------------------------------------------------------------------------------
.bit4:          test.q      rcx,1<<4                ; is the bit set?
                jz          .noBit4                 ; if not set, move on

                mov.d       eax,[rbx+MB1.symsC]     ; get the address of the value
                push        rax                     ; push it on the stack
                mov.d       eax,[rbx+MB1.symsB]     ; get the address of the value
                push        rax                     ; push it on the stack
                mov.d       eax,[rbx+MB1.symsA]     ; get the address of the value
                push        rax                     ; push it on the stack
                mov.q       rax,bit4Set             ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,32                   ; clean up the stack

                jmp         .bit5                   ; go to the next check

;----------------------------------------------------------------------------------------------
; Bit 4 -- data not provided
;----------------------------------------------------------------------------------------------
.noBit4:        push        qword 4                 ; print bit 4
                mov.q       rax,bitClear            ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; Check for bit 5 -- elf symbol table -- and report the results
;----------------------------------------------------------------------------------------------
.bit5:          test.q      rcx,1<<5                ; is the bit set?
                jz          .noBit5                 ; if not set, move on


                mov.d       eax,[rbx+MB1.symsD]     ; get the address of the value
                push        rax                     ; push it on the stack
                mov.d       eax,[rbx+MB1.symsC]     ; get the address of the value
                push        rax                     ; push it on the stack
                mov.d       eax,[rbx+MB1.symsB]     ; get the address of the value
                push        rax                     ; push it on the stack
                mov.d       eax,[rbx+MB1.symsA]     ; get the address of the value
                push        rax                     ; push it on the stack
                mov.q       rax,bit5Set             ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,8                   ; clean  the fmt string off the stack

                call        MB1ElfHdr               ; go report the elf header contents
                add.q       rsp,32                  ; clean up the stack

                jmp         .bit6                   ; go to the next check

;----------------------------------------------------------------------------------------------
; Bit 5 -- data not provided
;----------------------------------------------------------------------------------------------
.noBit5:        push        qword 5                 ; print bit 5
                mov.q       rax,bitClear            ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; Check for bit 6 -- memory map -- and report the results
;----------------------------------------------------------------------------------------------
.bit6:          test.q      rcx,1<<6                ; is the bit set?
                jz          .noBit6                 ; if not set, move on

                mov.d       eax,[rbx+MB1.mmapAddr]  ; get the address of the value
                push        rax                     ; push it on the stack
                mov.d       eax,[rbx+MB1.mmapLength]; get the address of the value
                push        rax                     ; push it on the stack
                mov.q       rax,bit6Set             ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,24                  ; clean up the stack

                jmp         .bit7                   ; go to the next check

;----------------------------------------------------------------------------------------------
; Bit 6 -- data not provided
;----------------------------------------------------------------------------------------------
.noBit6:        push        qword 6                 ; print bit 6
                mov.q       rax,bitClear            ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; Check for bit 7 -- Drives table -- and report the results
;----------------------------------------------------------------------------------------------
.bit7:          test.q      rcx,1<<7                ; is the bit set?
                jz          .noBit7                 ; if not set, move on

                mov.d       eax,[rbx+MB1.drivesAddr]; get the address of the value
                push        rax                     ; push it on the stack
                mov.d       eax,[rbx+MB1.drivesLen] ; get the address of the value
                push        rax                     ; push it on the stack
                mov.q       rax,bit7Set             ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,24                  ; clean up the stack

                jmp         .bit8                   ; go to the next check

;----------------------------------------------------------------------------------------------
; Bit 7 -- data not provided
;----------------------------------------------------------------------------------------------
.noBit7:        push        qword 7                 ; print bit 7
                mov.q       rax,bitClear            ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; Check for bit 8 -- BIOS Config table -- and report the results
;----------------------------------------------------------------------------------------------
.bit8:          test.q      rcx,1<<8                ; is the bit set?
                jz          .noBit8                 ; if not set, move on

                mov.d       eax,[rbx+MB1.configTbl] ; get the address of the value
                push        rax                     ; push it on the stack
                mov.q       rax,bit8Set             ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,16                  ; clean up the stack

                jmp         .bit9                   ; go to the next check

;----------------------------------------------------------------------------------------------
; Bit 8 -- data not provided
;----------------------------------------------------------------------------------------------
.noBit8:        push        qword 8                 ; print bit 8
                mov.q       rax,bitClear            ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; Check for bit 9 -- Boot Loader Name -- and report the results
;----------------------------------------------------------------------------------------------
.bit9:          test.q      rcx,1<<9                ; is the bit set?
                jz          .noBit9                 ; if not set, move on

                mov.d       eax,[rbx+MB1.bootLdrNm] ; get the address of the value
                push        rax                     ; push it on the stack (string)
                push        rax                     ; push it on the stack (address)
                mov.q       rax,bit9Set             ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,24                  ; clean up the stack

                jmp         .bit10                  ; go to the next check

;----------------------------------------------------------------------------------------------
; Bit 9 -- data not provided
;----------------------------------------------------------------------------------------------
.noBit9:        push        qword 9                 ; print bit 9
                mov.q       rax,bitClear            ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; Check for bit 10 -- APM Table -- and report the results
;----------------------------------------------------------------------------------------------
.bit10:         test.q      rcx,1<<10               ; is the bit set?
                jz          .noBit10                ; if not set, move on

                mov.d       eax,[rbx+MB1.apmTable]  ; get the address of the value
                push        rax                     ; push it on the stack
                mov.q       rax,bit10Set            ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,16                  ; clean up the stack

                jmp         .bit11                  ; go to the next check

;----------------------------------------------------------------------------------------------
; Bit 10 -- data not provided
;----------------------------------------------------------------------------------------------
.noBit10:       push        qword 10                ; print bit 10
                mov.q       rax,bitClear            ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; Check for bit 11 -- VBE Info -- and report the results
;----------------------------------------------------------------------------------------------
.bit11:         test.q      rcx,1<<11               ; is the bit set?
                jz          .noBit11                ; if not set, move on

                mov.d       eax,[rbx+MB1.vbeMode]   ; get the address of the value
                push        rax                     ; push it on the stack
                mov.d       eax,[rbx+MB1.vbeModeInf]; get the address of the value
                push        rax                     ; push it on the stack
                mov.d       eax,[rbx+MB1.vbeCtrlInf]; get the address of the value
                push        rax                     ; push it on the stack
                mov.q       rax,bit11Set            ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,32                  ; clean up the stack

                jmp         .done                   ; go to the next check

;----------------------------------------------------------------------------------------------
; Bit 11 -- data not provided
;----------------------------------------------------------------------------------------------
.noBit11:       push        qword 11                ; print bit 11
                mov.q       rax,bitClear            ; get the address of the message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the function address to write string
                call        rax                     ; this must be a far call
                add.q       rsp,16                  ; clean up the stack

.done:          jmp         .out                    ; jump to the exit code

;----------------------------------------------------------------------------------------------
; Write an error message about the invalid magic number
;----------------------------------------------------------------------------------------------

.error:         mov.q       rax,notMB1Sig           ; get the address of the error message
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the address of the proc to write str
                call        rax                     ; this must be a far call
                add.q       rsp,8                   ; clean  up the stack

;----------------------------------------------------------------------------------------------
; Clean up and exit
;----------------------------------------------------------------------------------------------

.out:           pop         rcx                     ; restire rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void MB1ElfHdr(qword cnt, qword size, qword addr, qword ndx) -- Report the contents of the
;                                                                 Elf Section Header
;----------------------------------------------------------------------------------------------
MB1ElfHdr:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rdx -- string table section header
                push        rcx                     ; save rcx -- section counter
                push        rsi                     ; save rsi -- section pointer

;----------------------------------------------------------------------------------------------
; complete some initialization
;----------------------------------------------------------------------------------------------
                mov.q       rcx,[rbp+16]            ; get the number of sections
                mov.q       rsi,[rbp+32]            ; get the address of the sections
                mov.q       rax,[rbp+40]            ; get the string table index
                mul         qword [rbp+24]          ; multiply by size
                add.q       rax,rsi                 ; rax now has the address of the strtab sh
                mov.q       rbx,rax                 ; save in the right register
                mov.q       rbx,[rbx+ElfSH.addr]    ; get the address of the actual section

;----------------------------------------------------------------------------------------------
; top of the loop -- check for the end
;----------------------------------------------------------------------------------------------
.loop:          cmp.q       rcx,0                   ; have we reached the end?
                je          .out                    ; if so, exit

                push        qword [rsi+ElfSH.addr]  ; push the starting addr of the section
                mov.d       eax,[rsi+ElfSH.name]    ; get the offset of the name
                lea.q       rax,[rbx+rax]           ; get the address of the name string
                push        qword rax               ; push the string on the stack
                mov.d       eax,[rsi+ElfSH.name]    ; get the name offset
                push        rax                     ; push it on the stack
                mov.q       rax,sectHdr             ; get the address of the section Hdr string
                push        rax                     ; push it on the stack
                mov.q       rax,kprintf             ; get the address of the function to write
                call        rax                     ; from this section, it must be a far call
                add.q       rsp,32                  ; clean up the stack

                add.q       rsi,[rbp+24]            ; move to the next section
                dec         rcx                     ; 1 less to print
                jmp         .loop                   ; loop again

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------
.out:           pop         rsi                     ; restore rsi
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;==============================================================================================
; The .rodata section is read-only data
;==============================================================================================
                section     .rodata

notMB1Sig       db          'MB1 Magic Number does not match',13,0
intro           db          13,'Multiboot 1 compliant loader report flags: %#08lx',13,0
bitClear        db          'Bit %2d clear',13,0

bit0Set         db          'Bit  0 is set: lower mem limit=%ld KB; upper mem limit=%ld KB',13,0
bit1Set         db          'Bit  1 is set: Boot Device ID=%#08lx',13,0
bit2Set         db          'Bit  2 is set: Command Line=%#08lx (%s)',13,0
bit3Set         db          'Bit  3 is set: Mods Count=%ld; Mods Addr=%#08lx',13,0
bit4Set         db          'Bit  4 is set: Table Size=%ld; String Size=%ld; SymTab Addr=%#08lx',13,0
bit5Set         db          'Bit  5 is set: Num=%ld; Sz=%ld; Addr=%#08lx; StrTab Ndx=%ld',13,0
bit6Set         db          'Bit  6 is set: MMap Length=%ld; MMap Addr=%#08lx',13,0
bit7Set         db          'Bit  7 is set: Drives Length=%ld; Drives Addr=%#08lx',13,0
bit8Set         db          'Bit  8 is set: BIOS Config Tbl Addr=%#09lx',13,0
bit9Set         db          'Bit  9 is set: Loader Name=%#08lx (%s)',13,0
bit10Set        db          'Bit 10 is set: APM Tbl Addr=%#08lx',13,0
bit11Set        db          'Bit 11 is set: VBE2 Ctl Addr=%#08lx; Mode Addr=%#08lx; Mode=%#08lx',13,0

sectHdr         db          '  Section (offset = %ld): %s at addr %p',13,0
