;==============================================================================================
;
; dbg-console.s
;
; This file contains functions needed to write debugging information to the serial port.  The
; functions in this file are written to be disabled when we are ready for a "production" build.
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
;
; The following functions are published in this file:
;
; The following functions are internal functions:
;
; The following are interrupt service handlers located in this file:

;    Date     Tracker  Pgmr  Description
; ----------  -------  ----  ------------------------------------------------------------------
; 2014/12/23  Initial  ADCL  Initial code
;
;==============================================================================================

%ifndef DISABLE_DBG_CONSOLE

%define         __DBG_CONSOLE_S__
%include        'private.inc'

DBG_PORT        equ         0x3f8

;==============================================================================================
; This is the code section of the source file.  It will be part of the kernel.
;==============================================================================================

                section     .text
                bits        64

;----------------------------------------------------------------------------------------------
; void DbgConsoleInit(void) -- Initialize the serial port for use as a debugging console.
;----------------------------------------------------------------------------------------------

                global      DbgConsoleInit

DbgConsoleInit:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rdx                     ; save rdx

                xor.q       rax,rax                 ; clear the entire rax register
                mov.q       rdx,(DBG_PORT+1)        ; we want the IER port
                out         dx,al                   ; disable interrupts

                mov.b       al,0x80                 ; need to setup the baud rate divisor
                mov.q       rdx,(DBG_PORT+3)        ; we want the LCR port
                out         dx,al                   ; enable the DLAB registers

                mov.b       al,0x03                 ; the divisor is 3 for 38.4K baud
                mov.q       rdx,(DBG_PORT+0)        ; we want the base port
                out         dx,al                   ; send the lo byte to the UART

                mov.b       al,0x00                 ; set the upper byte
                mov.q       rdx,(DBG_PORT+1)        ; we want the base port + 1
                out         dx,al                   ; send the hi byte to the UART

                mov.b       al,0x03                 ; disable DLAB, set bits to 8-N-1
                mov.q       rdx,(DBG_PORT+3)        ; we want the LCR port
                out         dx,al                   ; set the line setup

                mov.b       al,0xc7                 ; we don't need a FIFO
                mov.q       rdx,(DBG_PORT+2)        ; we want the FCR port
                out         dx,al                   ; set the FIFO parms

                mov.b       al,0x0b                 ; we don't want interrupts
                mov.q       rdx,(DBG_PORT+4)        ; we want the MCR port
                out         dx,al                   ; No interrupts

                pop         rdx                     ; restore rdx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void DbgConsolePutChar(qword char) -- output a character to the serial console
;----------------------------------------------------------------------------------------------

                global      DbgConsolePutChar

DbgConsolePutChar:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rdx                     ; save rdx

.loop:          mov.q       rdx,(DBG_PORT+5)        ; we want the LSR
                in          al,dx                   ; read the port
                test.b      al,0x20                 ; mask out the transmit buffer flag
                jz          .loop                   ; loop until it is empty

                mov.q       rdx,(DBG_PORT+0)        ; we want the serial port
                mov.q       rax,[rbp+16]            ; get the character to write
                cmp.q       rax,13                  ; is the char a <CR>?
                jne         .put                    ; if not, put it on the serial port

                mov.q       rax,10                  ; make it a LF

.put:           out         dx,al                   ; write the char to the serial port

                pop         rdx                     ; restore rdx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void DbgConsolePutHexByte(uint8 b) -- print the value of a hex byte to the serially attached
;                                       debugging console
;----------------------------------------------------------------------------------------------

                global      DbgConsolePutHexByte

DbgConsolePutHexByte:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx

                mov.q       rbx,dbgConsoleHexPre    ; get the address of the prefix
                push        rbx                     ; push the prefix on the stack
                call        DbgConsolePutString     ; and write it to the serial debugging log
                add.q       rsp,8                   ; clean up the stack

                mov.q       rax,[rbp+16]            ; get the byte to print (8-byte filled)
                call        DbgConsoleOutputHex     ; print the byte

                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void DbgConsolePutHexWord(uint16 w) -- print the value of a hex word to the serially attached
;                                        debugging console
;----------------------------------------------------------------------------------------------

                global      DbgConsolePutHexWord

DbgConsolePutHexWord:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx

                mov.q       rbx,dbgConsoleHexPre    ; get the address of the prefix
                push        rbx                     ; push that on the stack
                call        DbgConsolePutString     ; and write it to the serial debugging log
                add.q       rsp,8                   ; clean up the stack

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,8                   ; get the upper byte from the word
                call        DbgConsoleOutputHex     ; print the byte

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                and.q       rax,0xff                ; get the lower byte from the word
                call        DbgConsoleOutputHex     ; print the byte

                pop         rbx                     ; restore rbx
                pop         rbp                     ; and caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void DbgConsolePutHexDWord(uint32 dw) -- print the value of a hex dword to the serially
;                                          attached debugging console
;----------------------------------------------------------------------------------------------

                global      DbgConsolePutHexDWord

DbgConsolePutHexDWord:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx

                mov.q       rbx,dbgConsoleHexPre    ; get the address of the prefix
                push        rbx                     ; push it on the stack
                call        DbgConsolePutString     ; and write it to the serial debugging log
                add.q       rsp,8                   ; clean up the stack

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,24                  ; get the upper byte from the dword
                and.q       rax,0xff                ; get the lower byte from the dword
                call        DbgConsoleOutputHex     ; print the byte

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,16                  ; get the 2nd byte from the dword
                and.q       rax,0xff                ; get the lower byte from the dword
                call        DbgConsoleOutputHex     ; print the byte

                push        '_'                     ; push it on the stack
                call        DbgConsolePutChar       ; and write it to the log
                add.q       rsp,8                   ; clean up the stack


                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,8                   ; get the 3rd byte from the dword
                and.q       rax,0xff                ; get the lower byte from the dword
                call        DbgConsoleOutputHex     ; print the byte

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                and.q       rax,0xff                ; get the lower byte from the word
                call        DbgConsoleOutputHex     ; print the byte

                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void DbgConsolePutHexQWord(uint32 qw) -- print the value of a hex qword to the serially
;                                          attached debugging console
;----------------------------------------------------------------------------------------------

                global      DbgConsolePutHexQWord

DbgConsolePutHexQWord:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx

                mov.q       rbx,dbgConsoleHexPre    ; get the address of the prefix
                push        rbx                     ; push it on the stack
                call        DbgConsolePutString     ; and write it to the serial debugging log
                add.q       rsp,8                   ; clean up the stack

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,56                  ; get the upper byte from the qword
                and.q       rax,0xff                ; get the lower byte from the qword
                call        DbgConsoleOutputHex     ; print the byte

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,48                  ; get the 2nd byte from the qword
                and.q       rax,0xff                ; get the lower byte from the qword
                call        DbgConsoleOutputHex     ; print the byte

                push        '_'                     ; push it on the stack
                call        DbgConsolePutChar       ; and display it
                add.q       rsp,8                   ; clean up the stack

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,40                  ; get the 3rd byte from the qword
                and.q       rax,0xff                ; get the lower byte from the qword
                call        DbgConsoleOutputHex     ; print the byte

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,32                  ; get the 4th byte from the qword
                and.q       rax,0xff                ; get the lower byte from the qword
                call        DbgConsoleOutputHex     ; print the byte

                push        '_'                     ; push it on the stack
                call        DbgConsolePutChar       ; and display it
                add.q       rsp,8                   ; clean up the stack

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,24                  ; get the 5th byte from the qword
                and.q       rax,0xff                ; get the lower byte from the qword
                call        DbgConsoleOutputHex     ; print the byte

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,16                  ; get the 6th byte from the qword
                and.q       rax,0xff                ; get the lower byte from the qword
                call        DbgConsoleOutputHex     ; print the byte

                push        '_'                     ; push it on the stack
                call        DbgConsolePutChar       ; and display it
                add.q       rsp,8                   ; clean up the stack

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,8                   ; get the 7th byte from the dword
                and.q       rax,0xff                ; get the lower byte from the dword
                call        DbgConsoleOutputHex     ; print the byte

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                and.q       rax,0xff                ; get the lower byte from the word
                call        DbgConsoleOutputHex     ; print the byte

                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void DbgConsolePutString(char *str) -- put a null-terminated string of characters to the
;                                        serially attached debugging log
;----------------------------------------------------------------------------------------------

                global      DbgConsolePutString

DbgConsolePutString:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rsi                     ; save rsi

                sub.q       rsp,8                   ; make room on the stack for a parm

                mov.q       rsi,[rbp+16]            ; get the address of the string

.loop:          xor.q       rax,rax                 ; clear the rax reg
                mov.b       al,byte[rsi]            ; get the next byte to write
                cmp.b       al,0                    ; are we at null?
                je          .out                    ; if so, exit

                mov.q       [rsp],rax               ; put the 8-byte aligned parameter
                call        DbgConsolePutChar       ; put the character on the screen
                inc         rsi                     ; move to the next character
                jmp         .loop                   ; loop until done

.out:           add.q       rsp,8                   ; remove the working parameter
                pop         rsi                     ; restore rsi
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void DbgConsoleOutputHex(register uint8 b) -- This is the working function for outputting hex
;                                               numbers to the serially attached debugging
;                                               console.  Note that the byte with which to work
;                                               is passed in through rax (the lowest 8 bits).
;                                               The function will only output 2 characters into
;                                               the debugging log.  All other formatting is
;                                                outside this function.
;----------------------------------------------------------------------------------------------

DbgConsoleOutputHex:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frmae
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdx                     ; save rdx
                push        rsi                     ; save rsi

                mov.q       rsi,dbgHex              ; get the address of the char array
                xor.q       rdx,rdx                 ; clear out rdx
                mov.b       dl,al                   ; get the byte
                shr.b       dl,4                    ; we want the upper 4 bits of the byte

                xor.q       rcx,rcx                 ; clear rcx
                add.q       rsi,rdx                 ; move to the offset
                mov.b       cl,[rsi]                ; get the hex digit

                push        rax                     ; we need to keep this value
                push        rcx                     ; push it on the stack
                call        DbgConsolePutChar       ; and display it
                add.q       rsp,8                   ; clean up the stack
                pop         rax                     ; now restore this value

                mov.q       rsi,dbgHex              ; get the address of the char array
                xor.q       rdx,rdx                 ; clear out rdx
                and.q       rax,0x0f                ; we want the lower 4 bits of the byte

                xor.q       rcx,rcx                 ; clear rcx
                add.q       rsi,rax                 ; move to the offset
                mov.b       cl,[rsi]                ; get the hex digit

                push        rcx                     ; push it on the stack
                call        DbgConsolePutChar       ; and display it
                add.q       rsp,8                   ; clean up the stack

                pop         rsi                     ; restore rbx
                pop         rdx                     ; restore rbx
                pop         rcx                     ; restore rbx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;==============================================================================================
; The .rodata segment will hold all constant strings and will be added to the end of the .text
; section at link time.
;==============================================================================================

                section     .rodata

dbgHex         db          '0123456789abcdef'       ; a string of hexidecimal digits
dbgConsoleHexPre    db     '0x',0                   ; the prefix for a hex number

%endif
