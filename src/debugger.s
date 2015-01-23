;==============================================================================================
;
; debugger.s
;
; This file contains the debugger.  Once entering this file, all functions will be self-
; contained within this file.  This means that the debugger will not rely on any part of the
; OS to perform its functions.  Yes, there is a LOT of duplication.
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
; 2014/12/04  Initial  ADCL  Initial code
; 2015/01/05  #244     ADCL  Output the error code with the error message in the debugger
; 2015/01/06  #237     ADCL  Created a basic panic function.  This will evolve over time
;
;==============================================================================================

;----------------------------------------------------------------------------------------------
; So, there is not need to include private.inc since we will not be looking at any external
; functions.  If we need to review data members, we will explicitly define them here as
; 'extern'.
;
; The drawback to not including 'private.inc' is that the eqates that replace the short opcode
; with a more verbose one is not available.  We will have to code long-hand.  I might come back
; and copy the equates in to save my fingers.
;----------------------------------------------------------------------------------------------



;==============================================================================================
; This is the code section of the source file.  It will be part of the kernel.
;==============================================================================================

                section     .text
                bits        64

;----------------------------------------------------------------------------------------------
; Finally, we need a way to disable the debugger and have it completely skipped at compile
; time.  This file will be quite large once we have everything we need.  Once we go into
; a production-like build, we do not want this HUGE bit of code making the kernel unnecessarily
; large.
;----------------------------------------------------------------------------------------------

                global      debugger

%ifdef DISABLE_DEBUGGER

;----------------------------------------------------------------------------------------------
; this is what is included if the debugger is disabled at compile.  We still want something at
; the label, and eventually there will be a full-blown BSoD-type error.  However, for now, we
; will just output the message and halt the system.
;----------------------------------------------------------------------------------------------

%define         __DEBUGGER_S__
%include        'private.inc'

panic:
debugger:       cli                                 ; stop all interrupts NOW!
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame for stack traceback

;----------------------------------------------------------------------------------------------
; we will not save any other registers since we will be killing everything
;----------------------------------------------------------------------------------------------

                push        qword 0x4f              ; we want bright white on red
                call        TextSetAttr             ; set the attribute

                mov.q       rax,[rbp+24]            ; get the error message address
                mov.q       [rsp],rax               ; and set it on the stack
                call        TextPutString           ; write the message to the string
                add.q       rsp,8                   ; clean up the stack

.loop:          hlt                                 ; halt the processor
                jmp         .loop                   ; infinite loop -- just in case

;----------------------------------------------------------------------------------------------
; This function does not return!!
;----------------------------------------------------------------------------------------------

;==============================================================================================

%else

;----------------------------------------------------------------------------------------------
; Now, if the debugger is not disabled, then the real meat and potatoes comes here.  Hang on
; to your hats and glasses, folks!  We will be putting a LOT of code here.  First, we will
; put in the support functions starting with the text output functions.
;----------------------------------------------------------------------------------------------

;**********************************************************************************************
;**********************************************************************************************
;**********************************************************************************************
;*********************************     S C R E E N     ****************************************
;**********************************************************************************************
;**********************************************************************************************
;**********************************************************************************************
;**                                                                                          **
;**  For these functions to be short and effective, some limitations will be placed on the   **
;**  operations that we will allow.  The following functions are not supported here:         **
;**  1) Scrolling at the end of the screen                                                   **
;**  2) Text Wrapping at the end of the line                                                 **
;**  3) All Control characters are uninterpreted -- they print whatever they are             **
;**  4) The cursor is disabled and not moved on the screen                                   **
;**                                                                                          **
;**********************************************************************************************

;----------------------------------------------------------------------------------------------
; The following functions are debug specific and are used to get text the screen.  We make no
; attempt to preserve the screen for the kernel as all is likely lost already and there is no
; hope for recovery -- we will eventually shut the system off anyway.
;----------------------------------------------------------------------------------------------

VID_MEM         equ         0xb8000                 ; video memory buffer address
ROWS            equ         25                      ; number of rows on the screen
COLS            equ         80                      ; number of columns on the screen
BUFF            equ         (ROWS*COLS)             ; the number of bytes on the screen

;----------------------------------------------------------------------------------------------
; now, create some color constants to make coding easier (we will not use blink)
;----------------------------------------------------------------------------------------------

HL              equ         0x8                     ; highlight bit

;----------------------------------------------------------------------------------------------
; The following color constants can be used as either foreground or background colors
;----------------------------------------------------------------------------------------------

BLACK           equ         0x0                     ; bits for black
BLUE            equ         0x1                     ; bits for blue
GREEN           equ         0x2                     ; bits for green
CYAN            equ         0x3                     ; bits for cyan
RED             equ         0x4                     ; bits for red
MAGENTA         equ         0x5                     ; bits for magenta
BROWN           equ         0x6                     ; bits for brown
LT_GREY         equ         0x7                     ; bits for light grey

;----------------------------------------------------------------------------------------------
; The following color constants can only be used as foreground colors
;----------------------------------------------------------------------------------------------

DK_GREY         equ         (BLACK|HL)              ; bits for dark grey
LT_BLUE         equ         (BLUE|HL)               ; bits for light blue
LT_GREEN        equ         (GREEN|HL)              ; bits for light green
LT_CYAN         equ         (CYAN|HL)               ; bits for light cyan
LT_RED          equ         (RED|HL)                ; bits for light red
LT_MAGENTA      equ         (MAGENTA|HL)            ; bits for light magenta
YELLOW          equ         (BROWN|HL)              ; bits for yellow
WHITE           equ         (LT_GREY|HL)            ; bits for white

;----------------------------------------------------------------------------------------------
; a quick define to make color selection simpler
;----------------------------------------------------------------------------------------------

%define COLOR(f,b) (((b&0x7)<<4)|(f&0xf))           ; to build a color const at assembly time


;==============================================================================================
; This is the code section of the source file.  It will be part of the kernel.
;==============================================================================================

                section     .text
                bits        64

;----------------------------------------------------------------------------------------------
; void dbgClearScreen(byte attr) -- clear the screen, setting the whole screen to have the
;                                   specified attribute
;----------------------------------------------------------------------------------------------

dbgClearScreen:
                push        rbp                     ; save the caller's stack frame
                mov         rbp,rsp                 ; create our own stack frame
                push        rcx                     ; save rcx
                push        rdi                     ; save rdi

;----------------------------------------------------------------------------------------------
; This is simple by now, go clear the screen
;----------------------------------------------------------------------------------------------

                mov         ah,byte [rbp+16]        ; get the character to write
                mov         al,' '                  ; clear the screen to spaces

                mov         rcx,BUFF                ; get the screen size
                mov         rdi,VID_MEM             ; get the video memory location

                rep         stosw                   ; fill the screen with blanks

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

                pop         rdi                     ; restore rdi
                pop         rcx                     ; restore rcx
                pop         rbp                     ; restore the caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void dbgNoCursor(void) -- Turn off the cursor
;----------------------------------------------------------------------------------------------

dbgNoCursor:
                push        rbp                         ; save caller's frame
                mov         rbp,rsp                     ; create our own frame
                push        rdx                         ; save rdx

                mov         dx,0x3d4                    ; set the 6845 control reg
                mov         al,0x0a                     ; set the cursor start register
                out         dx,al                       ; send the byte fo the 6845

                inc         dx                          ; set the 6845 data register
                mov         rax,1                       ; we want to start on scan line 1
                out         dx,al                       ; send the byte to the 6845

                mov         dx,0x3d4                    ; set the 6845 control reg
                mov         al,0x0b                     ; cursor end register
                out         dx,al                       ; send the byte

                inc         dx                          ; move to 6845 data reg
                xor         rax,rax                     ; clear the ending scan line (0)
                out         dx,al                       ; set the bottom scan line

                pop         rdx                         ; restore rbx
                pop         rbp                         ; and rbp
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void dbgPutChar(byte row, byte col, byte attr, byte char) -- At row,col, put the character
;                                                              char with attribute attr.
;
; It is important to remember that these values are all expanded to qwords when pushed on the
; stack.
;
; Finally, no checking is performed to ensure that the position is actually on the screen.  If
; the math works, it works.  If is doesn't, we could have, "a cascade failure in the
; motherboard." -- Tim Allen (The Santa Clause 3)  -- Pathetic, I know.
;----------------------------------------------------------------------------------------------

dbgPutChar:
                push        rbp                         ; save caller's frame
                mov         rbp,rsp                     ; create our own frame
                push        rcx                         ; save rcx
                push        rdi                         ; save rdi

                xor         rax,rax                     ; clear rax
                mov         al,byte [rbp+16]            ; get the row number
                mov         ah,COLS                     ; get the number of columns
                mul         ah                          ; ax not = al * ah

                xor         rcx,rcx                     ; we need to clear rcx
                mov         cl, byte [rbp+24]           ; get the col number
                add         ax,cx                       ; add the col to the offset

                shl         rax,1                       ; multiply by 2
                mov         rdi,VID_MEM                 ; get the video memory loc
                add         rdi,rax                     ; get the position on the screen

                mov         ah,byte [rbp+32]            ; get the attribute
                mov         al,byte [rbp+40]            ; get the character

                mov         word [rdi],ax               ; put the char/attr pair on the screen

                pop         rdi                         ; restore rdi
                pop         rcx                         ; restore rcx
                pop         rbp                         ; and rbp
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void dbgPutString(byte row, byte col, byte attr, qword str) -- At row,col, put the string str
;                                                                char with attribute attr.
;
; It is important to remember that these values are all expanded to qwords when pushed on the
; stack.
;----------------------------------------------------------------------------------------------

dbgPutString:
                push        rbp                         ; save caller's frame
                mov         rbp,rsp                     ; create our own frame
                push        rsi                         ; save rsi

                sub         rsp,32                      ; create room for some parameters

                mov         rsi,[rbp+40]                ; get the string
.loop:          cmp         byte [rsi],0                ; do we have a terminating null?
                je          .out                        ; of we do, we can exit

                xor         rax,rax                     ; clear rax
                mov         al,byte [rsi]               ; get the character
                mov         qword [rsp+24],rax          ; put it on the stack

                mov         al,byte [rbp+32]            ; get the attr
                mov         qword [rsp+16],rax          ; put it on the stack

                mov         al,byte [rbp+24]            ; get the col
                mov         qword [rsp+8],rax           ; put it on the stack

                mov         al,byte [rbp+16]            ; get the row
                mov         qword [rsp],rax             ; put it on the stack

                call        dbgPutChar                  ; write the char

                inc         rsi                         ; move to the next char
                inc         qword [rbp+24]              ; move to the next column
                jmp         .loop                       ; loop

.out:           add         rsp,32                      ; clean up the stack

                pop         rsi                         ; restore rdi
                pop         rbp                         ; and rbp
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void dbgPutHex(byte row, byte col, byte attr, qword val, byte size) -- At row,col, put the
;                                                   hex number on the screen.  The size parm
;                                                   is the number of bytes to write, each byte
;                                                   taking 2 positions on the screen.
;
; It is important to remember that these values are all expanded to qwords when pushed on the
; stack.
;----------------------------------------------------------------------------------------------

dbgPutHex:
                push        rbp                     ; save caller's frame
                mov         rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdx                     ; save rdx

;----------------------------------------------------------------------------------------------
; First, lets calculate how many words were printing
;----------------------------------------------------------------------------------------------

                mov         rdx,[rbp+48]            ; get the bytes to print
                cmp         rdx,1                   ; did we ask for a single byte?
                je          .singleByte             ; if so, go and print 1 byte

;----------------------------------------------------------------------------------------------
; We know we are printing even bytes from here.  Convert it to words and make sure it is
; "rounded" up to the next byte.  Also, cap the number of words to 4.
;----------------------------------------------------------------------------------------------

                inc         rdx                     ; add 1 byte in case size was odd
                shr         rdx,1                   ; convert bytes to words
                cmp         rdx,4                   ; printing qword or less?
                jbe         .goodSize               ; if 4 or less, no nees to adjust

;----------------------------------------------------------------------------------------------
; cap at 4 words (1 qword)
;----------------------------------------------------------------------------------------------

                mov         rdx,4                   ; 4 words

.goodSize:      dec         rdx                     ; make it 0 based

;----------------------------------------------------------------------------------------------
; now we need to bring an upper word down to the bottom word for dbgPutWord
;----------------------------------------------------------------------------------------------

.loop:          mov         rcx,rdx                 ; get word count back in rax
                shl         rcx,4                   ; 16 bits per word; rax is # bits to shift
                mov         rbx,[rbp+40]            ; get the value to print
                shr         rbx,cl                  ; bring over the word
                and         rbx,0xffff              ; mask it out

;----------------------------------------------------------------------------------------------
; now call dbgPutWord
;----------------------------------------------------------------------------------------------

                push        rbx                     ; The word to print
                push        qword [rbp+32]          ; push the attr on the stack
                push        qword [rbp+24]          ; push the col on the stack
                push        qword [rbp+16]          ; push the row on the stack
                call        dbgPutWord              ; put the word on the screen
                add         rsp,32                  ; clean up the stack
                add         qword [rbp+24],4        ; move the col

;----------------------------------------------------------------------------------------------
; did we just print word 0?
;----------------------------------------------------------------------------------------------

                cmp         rdx,0                   ; did we just print the last word?
                je          .out                    ; if so, exit

                dec         rdx                     ; 1 less word in line

;----------------------------------------------------------------------------------------------
; put a space between the words
;----------------------------------------------------------------------------------------------

                push        ' '                     ; The space to print
                push        qword [rbp+32]          ; push the attr on the stack
                push        qword [rbp+24]          ; push the col on the stack
                push        qword [rbp+16]          ; push the row on the stack
                call        dbgPutChar              ; put the space on the screen
                add         rsp,32                  ; clean up the stack
                add         qword [rbp+24],1        ; move the col

                jmp         .loop                   ; go do it all again

;----------------------------------------------------------------------------------------------
; here we print a single byte
;----------------------------------------------------------------------------------------------

.singleByte:    mov         rbx,[rbp+40]            ; get the value to print
                and         rbx,0x00ff              ; mask out a byte

                push        rbx                     ; push the byte
                push        qword [rbp+32]          ; push the attr on the stack
                push        qword [rbp+24]          ; push the col on the stack
                push        qword [rbp+16]          ; push the row on the stack
                call        dbgPutByte              ; put the byte on the screen
                add         rsp,32                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:           pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void dbgPutByte(byte row, byte col, byte attr, byte val) -- At row,col, put the byte sized
;                                                   hex number on the screen.  The size parm
;                                                   is the number of bytes to write, each byte
;                                                   taking 2 positions on the screen.
;
; It is important to remember that these values are all expanded to qwords when pushed on the
; stack.
;----------------------------------------------------------------------------------------------

dbgPutByte:
                push        rbp                     ; save caller's frame
                mov         rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx

                mov         rbx,dbgHex              ; get the hex map

;----------------------------------------------------------------------------------------------
; At this point, we gan get to brute force...  each byte will take 2 character positions.
;----------------------------------------------------------------------------------------------

                mov         rcx,[rbp+40]            ; get the byte to print
                shr         rcx,4                   ; get the most significant nibble
                and         rcx,0x0f                ; mask out the nibble

                xor         rax,rax                 ; clear rax upper bits
                mov         al,[rbx+rcx]            ; get the letter to print

                push        rax                     ; push the letter on the stack
                push        qword [rbp+32]          ; push the attr on the stack
                push        qword [rbp+24]          ; push the col on the stack
                push        qword [rbp+16]          ; push the row on the stack
                call        dbgPutChar              ; put the space on the screen
                add         rsp,32                  ; clean up the stack
                add         qword [rbp+24],1        ; move the col

;----------------------------------------------------------------------------------------------
; now deal with the lower nibble
;----------------------------------------------------------------------------------------------

                mov         rcx,[rbp+40]            ; get the byte to print
                and         rcx,0x0f                ; mask out the nibble

                xor         rax,rax                 ; clear rax upper bits
                mov         al,[rbx+rcx]            ; get the letter to print

                push        rax                     ; push the letter on the stack
                push        qword [rbp+32]          ; push the attr on the stack
                push        qword [rbp+24]          ; push the col on the stack
                push        qword [rbp+16]          ; push the row on the stack
                call        dbgPutChar              ; put the space on the screen
                add         rsp,32                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void dbgPutWord(byte row, byte col, byte attr, word val) -- At row,col, put the word sized
;                                                   hex number on the screen.  The size parm
;                                                   is the number of bytes to write, each byte
;                                                   taking 2 positions on the screen.
;
; It is important to remember that these values are all expanded to qwords when pushed on the
; stack.
;----------------------------------------------------------------------------------------------

dbgPutWord:
                push        rbp                     ; save caller's frame
                mov         rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx

;----------------------------------------------------------------------------------------------
; At this point, we gan get to brute force...  each word will take 4 character positions.
; We will print both bytes regardless.
;----------------------------------------------------------------------------------------------

                mov         rcx,[rbp+40]            ; get the word to print
                shr         rcx,8                   ; get the most significant byte
                and         rcx,0x00ff              ; mask out the byte

                push        rcx                     ; push the byte on the stack
                push        qword [rbp+32]          ; push the attr on the stack
                push        qword [rbp+24]          ; push the col on the stack
                push        qword [rbp+16]          ; push the row on the stack
                call        dbgPutByte              ; put the space on the screen
                add         rsp,32                  ; clean up the stack
                add         qword [rbp+24],2        ; move the col

;----------------------------------------------------------------------------------------------
; now deal with the lower byte
;----------------------------------------------------------------------------------------------

                mov         rcx,[rbp+40]            ; get the word to print
                and         rcx,0x00ff              ; mask out the byte

                push        rcx                     ; push the byte on the stack
                push        qword [rbp+32]          ; push the attr on the stack
                push        qword [rbp+24]          ; push the col on the stack
                push        qword [rbp+16]          ; push the row on the stack
                call        dbgPutByte              ; put the space on the screen
                add         rsp,32                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================




;**********************************************************************************************
;**********************************************************************************************
;**********************************************************************************************
;***********************     D E B U G G E R   C O N T R O L     ******************************
;**********************************************************************************************
;**********************************************************************************************
;**********************************************************************************************

DBG_EXIT        equ         0                       ; request to exit debugger
DBG_DIE         equ         1                       ; request to kill the system
DBG_BASIC       equ         2                       ; request the basic information screen

;==============================================================================================
; This is the .bss section.  It contains uninitialized data.
;==============================================================================================

                section     .bss

dbgScreen       resq        1

;==============================================================================================
; This is the code section of the source file.  It will be part of the kernel.
;==============================================================================================

                section     .text
                bits        64

;----------------------------------------------------------------------------------------------
; void dbgBasicScreen(qword framePtr, qword msg) -- display the basic information screen
;----------------------------------------------------------------------------------------------

dbgBasicScreen:
                push        rbp                     ; save the caller's frame
                mov         rbp,rsp                 ; create our own frame
                push        rcx                     ; save rcx
                push        rdx                     ; save rdx
                push        rsi                     ; save rsi

                sub         rsp,40                  ; create room for 5 parameters

;----------------------------------------------------------------------------------------------
; clear the screen and display the header
;----------------------------------------------------------------------------------------------

                mov         qword [rsp],COLOR(RED,CYAN)   ; set the color for the screen
                call        dbgClearScreen          ; clear the screen

                mov         rax,debuggerHdr         ; get the header string address
                mov         [rsp+24],rax            ; put the string on the stack
                mov         qword [rsp+16],COLOR(RED,CYAN); put the attr on the stack
                mov         qword [rsp+8],37        ; put the col # on the stack
                mov         qword [rsp],0           ; put the row # on the stack
                call        dbgPutString            ; print the string

                mov         rax,[rbp+24]            ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+16],COLOR(RED,CYAN); put the attr on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],1           ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         qword [rsp+32],8        ; put the # bytes for hex value on stack
                mov         rax,[rbp+16]            ; get the frame block pointer
                mov         rax,[rax+8]             ; get the error code from the frame
                mov         [rsp+24],rax            ; put the message on the stack
                call        dbgPutHex               ; print the screen

;----------------------------------------------------------------------------------------------
; Put the labels doen the left side of the screen
;----------------------------------------------------------------------------------------------

                mov         rax,dbgRAX              ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+16],COLOR(BLACK,CYAN); put the attr on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],3           ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgRBX              ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],4           ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgRCX              ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],5           ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgRDX              ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],6           ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgRSI              ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],7           ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgRDI              ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],8           ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgRBP              ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],9           ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgRSP              ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],10          ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgRIP              ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],11          ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgR8               ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],12          ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgR9               ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],13          ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgR10              ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],14          ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgR11              ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],15          ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgR12              ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],16          ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgR13              ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],17          ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgR14              ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],18          ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgR15              ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],19          ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgCR2              ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],20          ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgCR3              ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],21          ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgFLG              ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],22          ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,dbgCR0              ; get the message parm
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],0         ; put the col on the stack
                mov         qword [rsp],23          ; put the row on the stack
                call        dbgPutString            ; print the screen

;----------------------------------------------------------------------------------------------
; Put the registers on the screen
;----------------------------------------------------------------------------------------------

                mov         qword [rsp+32],8        ; put the # bytes for hex value on stack
                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax-8]             ; get the RAX register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+16],COLOR(BLACK,CYAN); put the attr on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],3           ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax-16]            ; get the RBX register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],4           ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax-24]            ; get the RCX register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],5           ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax-32]            ; get the RDX register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],6           ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax-40]            ; get the RSI register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],7           ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax-48]            ; get the RDI register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],8           ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax]               ; get the RBP register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],9           ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax+40]            ; get the RSP register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],10          ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax+16]            ; get the RIP register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],11          ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax-56]            ; get the R8 register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],12          ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax-64]            ; get the R9 register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],13          ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax-72]            ; get the R10 register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],14          ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax-80]            ; get the R11 register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],15          ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax-88]            ; get the R12 register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],16          ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax-96]            ; get the R13I register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],17          ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax-104]           ; get the R14 register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],18          ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax-112]           ; get the R15 register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],19          ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax-160]           ; get the CR2 register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],20          ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax-168]           ; get the CR3 register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],21          ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax+32]            ; get the RFLAGS register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],22          ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rax,[rax-152]           ; get the CR0 register value
                mov         [rsp+24],rax            ; put the message on the stack
                mov         qword [rsp+8],4         ; put the col on the stack
                mov         qword [rsp],23          ; put the row on the stack
                call        dbgPutHex               ; print the screen

;----------------------------------------------------------------------------------------------
; put the bar separators on the screen
;----------------------------------------------------------------------------------------------

                mov         rcx,3                   ; we start with row #3
                mov         rdx,0xa0                ; the top line has offset 0xa0
.loop1:         cmp         rcx,23                  ; are we past row #23
                jg          .stack                  ; if we are done, go put the stack on scrn

                mov         qword [rsp+24],'|'      ; put the message on the stack
                mov         qword [rsp+8],23        ; put the col on the stack
                mov         [rsp],rcx               ; put the row on the stack
                call        dbgPutChar              ; print the screen

                mov         qword [rsp+8],48        ; put the col on the stack
                call        dbgPutChar              ; print the screen

                mov         qword [rsp+24],'+'      ; put the message on the stack
                mov         qword [rsp+8],49        ; put the col on the stack
                mov         [rsp],rcx               ; put the row on the stack
                call        dbgPutChar              ; print the screen

                mov         qword [rsp+32],1        ; put the size to print on the stack
                mov         qword [rsp+24],rdx      ; put the message on the stack
                mov         qword [rsp+8],50        ; put the col on the stack
                mov         [rsp],rcx               ; put the row on the stack
                call        dbgPutHex               ; print the screen

                mov         qword [rsp+24],':'      ; put the message on the stack
                mov         qword [rsp+8],52        ; put the col on the stack
                mov         [rsp],rcx               ; put the row on the stack
                call        dbgPutChar              ; print the screen

                inc         rcx                     ; inc to the next row
                sub         rdx,8                   ; sub the next offset
                jmp         .loop1                  ; loop

;----------------------------------------------------------------------------------------------
; Finally, put the stack on the screen
;----------------------------------------------------------------------------------------------

.stack:         mov         rcx,23                  ; set the bottom line to start
                xor         rdx,rdx                 ; clear rdx - not at bottom of stack
                mov         rax,[rbp+16]            ; get the frame as passed
                mov         rsi,[rax+40]            ; get the stack pointer address

                mov         rax,dbgRSP              ; get the message on the stack
                mov         qword [rsp+24],rax      ; put the message on the stack
                mov         qword [rsp+8],49        ; put the col on the stack
                mov         [rsp],rcx               ; put the row on the stack
                call        dbgPutString            ; print the screen

                mov         rax,rsi                 ; get user stack pointer in working reg
                and         rax,0x03fff             ; stacks are 16K and 16K aligned
                cmp         rax,0                   ; are the remainder bits 0?
                jnz         .stackVal               ; go write the stack

                inc         rdx                     ; increment rdx to non-zero
                mov         rax,dbgBotOfStack       ; get the message on the stack
                mov         qword [rsp+24],rax      ; put the message on the stack
                mov         qword [rsp+8],53        ; put the col on the stack
                mov         [rsp],rcx               ; put the row on the stack
                call        dbgPutString            ; print the screen

                jmp         .stackMore              ; go put more stack values on the screen

.stackVal:      mov         rax,[rsi]               ; get the stack value
                mov         qword [rsp+32],8        ; put the hex size on the stack
                mov         qword [rsp+24],rax      ; put the message on the stack
                mov         qword [rsp+8],53        ; put the col on the stack
                mov         [rsp],rcx               ; put the row on the stack
                call        dbgPutHex               ; print the screen

.stackMore:     dec         rcx                     ; move to the prev line on screen
                add         rsi,8                   ; move 'down' on the stack

.stackLoop:     cmp         rcx,3                   ; have we passed row 3
                jb          .exit                   ; if so, exit

                cmp         rdx,0                   ; have we set BottomOfStack flag?
                jnz         .prtBOS                 ; go print bottom of stack

                mov         rax,rsi                 ; get user stack pointer in working reg
                and         rax,0x03fff             ; stacks are 16K and 16K aligned
                cmp         rax,0                   ; are the remainder bits 0?
                jnz         .prtVal                 ; go write the stack

                inc         rdx                     ; increment rdx to non-zero
.prtBOS:        mov         rax,dbgBotOfStack       ; get the message on the stack
                mov         qword [rsp+24],rax      ; put the message on the stack
                mov         qword [rsp+8],53        ; put the col on the stack
                mov         [rsp],rcx               ; put the row on the stack
                call        dbgPutString            ; print the screen

                jmp         .prtMore                ; go put more stack values on the screen

.prtVal:        mov         rax,[rsi]               ; get the stack value
                mov         qword [rsp+32],8        ; put the hex size on the stack
                mov         qword [rsp+24],rax      ; put the message on the stack
                mov         qword [rsp+8],53        ; put the col on the stack
                mov         [rsp],rcx               ; put the row on the stack
                call        dbgPutHex               ; print the screen

.prtMore:       dec         rcx                     ; move to the prev line on screen
                add         rsi,8                   ; move 'down' on the stack

                jmp         .stackLoop              ; go back and do it again

;----------------------------------------------------------------------------------------------
; set the next state
;----------------------------------------------------------------------------------------------

.exit:          mov         rax,dbgScreen           ; get the screen state var address
                mov         qword [rax],DBG_DIE     ; set the screen state to be basic info

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

                add         rsp,40                  ; clean up the stack

                pop         rsi                     ; restore rsi
                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void debugger(qword framePtr, qword msg) -- Enter the debugger and take complete control of
;                                             the computer.  Essentially, we are implementing
;                                             a kernel within a kernel.
;----------------------------------------------------------------------------------------------

debugger:
                push        rbp                     ; save the caller's frame
                mov         rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx

;----------------------------------------------------------------------------------------------
; Let's start by clearing the screen
;----------------------------------------------------------------------------------------------

                mov         rax,dbgScreen           ; get the screen state var address
                mov         qword [rax],DBG_BASIC   ; set the screen state to be basic info

                call        dbgNoCursor             ; turn off the cursor

;----------------------------------------------------------------------------------------------
; now for the main loop; based on the screen state, we will display the appropriate screen
;----------------------------------------------------------------------------------------------

.loop:          mov         rax,dbgScreen           ; get the address of the screen state
                mov         rax,[rax]               ; get the screen state from the var

                shl         rax,3                   ; convert scalar to qword
                mov         rbx,dbgJump             ; get the jump table address
                mov         rax,[rbx+rax]           ; get the jump target

                jmp         rax                     ; jump to the screen handler

;----------------------------------------------------------------------------------------------
; basic screen handler
;----------------------------------------------------------------------------------------------

.basic:         push        qword [rbp+24]          ; push the message
                push        qword [rbp+16]          ; push the frame pointer
                call        dbgBasicScreen          ; display the basic information screen
                add         rsp,16                  ; clean up the stack

                jmp         .loop                   ; loop

;----------------------------------------------------------------------------------------------
; we will terminate processing in here
;----------------------------------------------------------------------------------------------

.die:           cli
                hlt

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:           pop         rbx                     ; restore rbx
                pop         rbp                     ; restore the caller's frame
                ret

;==============================================================================================

                section     .rodata

debuggerHdr:    db          'Debugger',0
dbgHex:         db          '0123456789ABCDEF'

dbgRAX:         db          'RAX:',0
dbgRBX:         db          'RBX:',0
dbgRCX:         db          'RCX:',0
dbgRDX:         db          'RDX:',0
dbgRSI:         db          'RSI:',0
dbgRDI:         db          'RDI:',0
dbgRBP:         db          'RBP:',0
dbgRSP:         db          'RSP:',0
dbgRIP:         db          'RIP:',0
dbgR8:          db          ' R8:',0
dbgR9:          db          ' R9:',0
dbgR10:         db          'R10:',0
dbgR11:         db          'R11:',0
dbgR12:         db          'R12:',0
dbgR13:         db          'R13:',0
dbgR14:         db          'R14:',0
dbgR15:         db          'R15:',0
dbgCR2:         db          'CR2:',0
dbgCR3:         db          'CR3:',0
dbgFLG:         db          'FLG:',0
dbgCR0:         db          'CR0:',0

dbgBotOfStack   db          '<< Bottom of Stack >>',0

dbgJump         dq          debugger.out
                dq          debugger.die
                dq          debugger.basic

%endif
