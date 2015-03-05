;==============================================================================================
;
; kprintf.s
;
; This file contains the implementations of somewhat watered down versions of printf() and
; sprintf().
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
; This file contains some of the implementation that are common in the standard C library.
; These implementations are included in order to make coding easier.  Case-in-point, the number
; of lines of code in mb1.s was cut in half after replacing calls to TextPut*() with kprintf().
;
; Keep in mind that kprintf() is dependent on the Heap being initialized.  Therefore, kprintf()
; cannot be called before HeapInit().
;
; The following functions are provided in this source file:
;   qword kprintf(qword fmt, ...);
;   qword dbgprintf(qword fmt, ...);
;   qword ksprintf(qword tgt, qword fmt, ...);
;   qword ksnprintf(qword tgt, qword len, qword fmt, ...);
;   qword kvprintf(qword fmt, qword args);
;   qword dbgvprintf(qword fmt, qword args);
;   qword kvsprintf(qword tgt, qword fmt, qword args);
;   qword kvsnprintf(qword tgt, qword fmt, qword len, qword args);
;   qword kstrlen(qword str);
;
; The following are internal functions also in this source file:
;   qword DecString(qword str, qword dec, qword len, qword flags);
;   qword HexString(qword str, qword dec, qword len, qword flags);
;
;----------------------------------------------------------------------------------------------
;
; TODO: There are several formatting constructs that sill need to be implemented:
; ** Precision (after the "." in a formatting phrase)
; ** Floating point numbers
; ** Runtime-defined width and precision (the "*" in the formatting phrase)
;
;----------------------------------------------------------------------------------------------
;
;    Date     Tracker  Pgmr  Description
; ----------  -------  ----  ------------------------------------------------------------------
; 2015/02/20  Initial  ADCL  Initial code
;
;==============================================================================================

%define         __KPRINTF_S__
%include        'private.inc'

;==============================================================================================
; In this first section (before we get into any real data or code), we will define some
; constants and such to make out coding easier.
;==============================================================================================

LONGFLAG        equ         0x00000001
LONGLONGFLAG    equ         0x00000002
HALFFLAG        equ         0x00000004
HALFHALFFLAG    equ         0x00000008
SIZETFLAG       equ         0x00000010
ALTFLAG         equ         0x00000020
CAPSFLAG        equ         0x00000040
SHOWSIGNFLAG    equ         0x00000080
SIGNEDFLAG      equ         0x00000100
LEFTFORMATFLAG  equ         0x00000200
LEADZEROFLAG    equ         0x00000400

MAXWORKINGSTR   equ         1024*8                  ; this is the largest working string
NUMSTR          equ         40                      ; the target string for a number

;==============================================================================================
; This is the code section of the source file.  It will be part of the kernel.
;==============================================================================================

                section     .text
                bits        64

;----------------------------------------------------------------------------------------------
; qword kprintf(qword fmt, ...) -- This is an implmentation of printf()
;----------------------------------------------------------------------------------------------
                global      kprintf
kprintf:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame

                lea.q       rax,[rbp+24]            ; get the address of the parameters
                push        rax                     ; push it on the stack
                push        qword [rbp+16]          ; push the format on the stack
                call        kvprintf                ; call the working function
                add.q       rsp,16                  ; clean up the stack

                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

%ifndef DISABLE_DBG_CONSOLE
;----------------------------------------------------------------------------------------------
; qword dbgprintf(qword fmt, ...) -- This is an implmentation of printf() that prints to the
;                                  debug console.
;----------------------------------------------------------------------------------------------
                global      dbgprintf
dbgprintf:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame

                lea.q       rax,[rbp+24]            ; get the address of the parameters
                push        rax                     ; push it on the stack
                push        qword [rbp+16]          ; push the format on the stack
                call        dbgvprintf              ; call the working function
                add.q       rsp,16                  ; clean up the stack

                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================
%endif

;----------------------------------------------------------------------------------------------
; qword ksprintf(qword tgt, qword fmt, ...) -- This is an implmentation of sprintf()
;----------------------------------------------------------------------------------------------
                global      ksprintf
ksprintf:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame

                lea.q       rax,[rbp+32]            ; get the address of the parameters
                push        rax                     ; push it on the stack
                push        qword [rbp+24]          ; push the format on the stack
                push        qword [rbp+16]          ; push the target on the stack
                call        kvsprintf               ; call the working function
                add.q       rsp,24                  ; clean up the stack

                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword ksnprintf(qword tgt, qword len, qword fmt, ...) -- This is an implmentation of
;                                                          snprintf()
;----------------------------------------------------------------------------------------------
                global      ksnprintf
ksnprintf:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame

                lea.q       rax,[rbp+40]            ; get the address of the parameters
                push        rax                     ; push it on the stack
                push        qword [rbp+32]          ; push the length on the stack
                push        qword [rbp+24]          ; push the format on the stack
                push        qword [rbp+16]          ; push the target on the stack
                call        kvsnprintf              ; call the working function
                add.q       rsp,32                  ; clean up the stack

                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword kvprintf(qword fmt, qword args) -- This is an implmentation of vprintf().  For this
;                                          function to work at this point, we will be
;                                          allocating space from the kernel heap and using that
;                                          space as a working location.
;----------------------------------------------------------------------------------------------
                global      kvprintf
kvprintf:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        r9                      ; save r9 -- holds our working string

;----------------------------------------------------------------------------------------------
; go get some memory
;----------------------------------------------------------------------------------------------
                push        qword MAXWORKINGSTR     ; get the size to allocate
                call        kmalloc                 ; get some working memory
                add.q       rsp,8                   ; clean up the stack

                cmp.q       rax,0                   ; did we get memory?
                je          .out                    ; no, exit with 0 chars written

                mov.q       r9,rax                  ; hold onto our address

;----------------------------------------------------------------------------------------------
; use sprintf to write to the sting first
;----------------------------------------------------------------------------------------------
                push        qword [rbp+24]          ; push the address of the parameters
                push        qword [rbp+16]          ; push the format on the stack
                push        qword MAXWORKINGSTR     ; get the size to allocate
                push        rax                     ; push the working buffer on the stack
                call        kvsnprintf              ; call the working function
                add.q       rsp,32                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; now, call the API to print the string to the screen
;----------------------------------------------------------------------------------------------
                push        r9                      ; push the string
                call        TextPutString           ; go write it to the screen
                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; clean up the allocated memory
;----------------------------------------------------------------------------------------------
                push        r9                      ; want to free our string
                call        kfree                   ; go free our string
                add.q       rsp,8                   ; clean up the stack

.out:           pop         r9                      ; restore r9
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

%ifndef DISABLE_DBG_CONSOLE
;----------------------------------------------------------------------------------------------
; qword dbgvprintf(qword fmt, qword args) -- This is an implmentation of vprintf().  For this
;                                            function to work at this point, we will be
;                                            allocating space from the kernel heap and using
;                                            that space as a working location.  This function
;                                            will only be used to send debugging info to the
;                                            debugging console.
;----------------------------------------------------------------------------------------------
                global      dbgvprintf
dbgvprintf:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        r9                      ; save r9 -- holds our working string

;----------------------------------------------------------------------------------------------
; go get some memory
;----------------------------------------------------------------------------------------------
                push        qword MAXWORKINGSTR     ; get the size to allocate
                call        kmalloc                 ; get some working memory
                add.q       rsp,8                   ; clean up the stack

                cmp.q       rax,0                   ; did we get memory?
                je          .out                    ; no, exit with 0 chars written

                mov.q       r9,rax                  ; hold onto our address

;----------------------------------------------------------------------------------------------
; use sprintf to write to the sting first
;----------------------------------------------------------------------------------------------
                push        qword [rbp+24]          ; push the address of the parameters
                push        qword [rbp+16]          ; push the format on the stack
                push        qword MAXWORKINGSTR     ; get the size to allocate
                push        rax                     ; push the working buffer on the stack
                call        kvsnprintf              ; call the working function
                add.q       rsp,32                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; now, call the API to print the string to the screen
;----------------------------------------------------------------------------------------------
                push        r9                      ; push the string
                call        DbgConsolePutString     ; go write it to the debugging console
                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; clean up the allocated memory
;----------------------------------------------------------------------------------------------
                push        r9                      ; want to free our string
                call        kfree                   ; go free our string
                add.q       rsp,8                   ; clean up the stack

.out:           pop         r9                      ; restore r9
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================
%endif

;----------------------------------------------------------------------------------------------
; qword kvsprintf(qword tgt, qword fmt, qword args) -- This is an implmentation of vsprintf()
;----------------------------------------------------------------------------------------------
                global      kvsprintf
kvsprintf:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame

                push        qword [rbp+32]          ; push the address of the parameters
                push        qword MAXWORKINGSTR     ; push the length on the stack
                push        qword [rbp+24]          ; push the format on the stack
                push        qword [rbp+16]          ; push the target on the stack
                call        kvsnprintf              ; call the working function
                add.q       rsp,32                  ; clean up the stack

                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword kstrlen(qword str) -- calculate the length of the string
;----------------------------------------------------------------------------------------------
                global      kstrlen
kstrlen:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rcx                     ; save rcx -- our counter
                push        rsi                     ; save rsi -- our string pointer

                xor.q       rcx,rcx                 ; clear the counter
                mov.q       rsi,[rbp+16]            ; get the start of the string

.loop:          mov.b       al,[rsi]                ; get the character
                cmp.b       al,0                    ; are we at the end?
                je          .out                    ; if so, exit

                inc         rcx                     ; increment a char
                inc         rsi                     ; move to the next char
                jmp         .loop                   ; go back and do it again


.out:           mov.q       rax,rcx                 ; set the return value

                pop         rsi                     ; restore rsi
                pop         rcx                     ; restore rcx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword DecString(qword str, qword dec, qword len, qword flags) -- This function will convert
;                                                                  an integer to a string
;----------------------------------------------------------------------------------------------
DecString:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx -- str array
                push        rcx                     ; save rcx -- for pos
                push        rdx                     ; save rdx -- negative flag
                push        r9                      ; save r9 -- work register

;----------------------------------------------------------------------------------------------
; perform initialization tasks
;----------------------------------------------------------------------------------------------

                mov.q       rbx,[rbp+16]            ; get the str array address
                mov.q       rcx,[rbp+32]            ; get the length passed in
                xor.q       rdx,rdx                 ; no negative

;----------------------------------------------------------------------------------------------
; if we want a sign (SIGNEDFLAG) and the number is negative...
;----------------------------------------------------------------------------------------------

                test.q      [rbp+40],SIGNEDFLAG     ; do we want a sign?
                jz          .l00001                 ; if not, jump ahead

                cmp.q       [rbp+24],0              ; is the number < 0
                jge         .l00001                 ; if no then jump ahead

                inc         rdx                     ; now we want a negative number
                neg.q       [rbp+24]                ; make the number positive

;----------------------------------------------------------------------------------------------
; set the end of the string to a NULL
;----------------------------------------------------------------------------------------------

.l00001:        dec         rcx                     ; move to the last position of array
                mov.b       [rbx+rcx],0             ; set the terminating null

;----------------------------------------------------------------------------------------------
; as long as the number is >= 10
;----------------------------------------------------------------------------------------------

.l00002:        cmp.q       [rbp+24],10             ; are we still >= 10?
                jl          .l00003                 ; if < 10, jump out

;----------------------------------------------------------------------------------------------
; do the division and get the quotient and remainder
;----------------------------------------------------------------------------------------------
                push        rdx                     ; save rdx
                xor.q       rdx,rdx                 ; clear upper bytes
                mov.q       rax,[rbp+24]            ; get the current number
                mov.q       r9,10                   ; set the divisor
                div         r9                      ; div RDX:RAX/R9 --> Quo in RAX; rem in RDX
                mov.q       [rbp+24],rax            ; this is the new number
                mov.q       rax,rdx                 ; put it in the work register
                pop         rdx                     ; restore rdx

;----------------------------------------------------------------------------------------------
; convert the digit to an ascii character and put it in the string
;----------------------------------------------------------------------------------------------
                add.q       rax,'0'                 ; ascii adjust the remainder
                dec         rcx                     ; move to the previous position
                mov.b       [rbx+rcx],al            ; move the byte into the string

                jmp         .l00002                 ; loop and do it again

;----------------------------------------------------------------------------------------------
; now, get the most significant digit
;----------------------------------------------------------------------------------------------
.l00003:        mov.b       al,[rbp+24]             ; get the last of the number
                add.b       al,'0'                  ; ascii adjust it
                dec         rcx                     ; move to the prev position
                mov.b       [rbx+rcx],al            ; put the char in the string

;----------------------------------------------------------------------------------------------
; finally, if we have a negative number....
;----------------------------------------------------------------------------------------------
                cmp.q       rdx,0                   ; if the flag set?
                je          .l00004                 ; move on to the next check

;----------------------------------------------------------------------------------------------
; put a negative sign...
;----------------------------------------------------------------------------------------------
                dec         rcx                     ; move to the previous position
                mov.b       [rbx+rcx],'-'           ; place a negative sign

;----------------------------------------------------------------------------------------------
; were we asked for a positive sign?
;----------------------------------------------------------------------------------------------
.l00004:        test.q      [rbp+40],SIGNEDFLAG     ; did we want a sign?
                jz          .l00005                 ; if not, we go on

;----------------------------------------------------------------------------------------------
; put a positive sign...
;----------------------------------------------------------------------------------------------
                dec         rcx                     ; move to the previous position
                mov.b       [rbx+rcx],'+'           ; place a negative sign

;----------------------------------------------------------------------------------------------
; last thing, set the return address of the string
;----------------------------------------------------------------------------------------------
.l00005:        lea.q       rax,[rbx+rcx]           ; this is the start of the string

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------
                pop         r9                      ; restore r9
                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword HexString(qword str, qword dec, qword len, qword flags) -- This function will convert
;                                                                  an integer to a string
;----------------------------------------------------------------------------------------------
HexString:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx -- str array
                push        rcx                     ; save rcx -- for pos
                push        rdx                     ; save rdx -- negative flag
                push        r9                      ; save r9 -- hex table pointer

;----------------------------------------------------------------------------------------------
; perform initialization tasks
;----------------------------------------------------------------------------------------------

                mov.q       rbx,[rbp+16]            ; get the str array address
                mov.q       rcx,[rbp+32]            ; get the length passed in
                xor.q       rdx,rdx                 ; no negative

;----------------------------------------------------------------------------------------------
; if we want upper case(CAPSFLAG)...
;----------------------------------------------------------------------------------------------

                test.q      [rbp+40],CAPSFLAG       ; do we want capital hex digits?
                jnz         .l00000                 ; if not, jump ahead

                mov.q       rax,hexTable            ; get the lower case table address
                jmp         .l00001                 ; move on and set the reg

.l00000:        mov.q       rax,hexTABLE            ; get the upper case table address
.l00001:        mov.q       r9,rax                  ; put the result in the right register

;----------------------------------------------------------------------------------------------
; set the end of the string to a NULL
;----------------------------------------------------------------------------------------------

                dec         rcx                     ; move to the last position of array
                mov.b       [rbx+rcx],0             ; set the terminating null

;----------------------------------------------------------------------------------------------
; top of the loop; we will check conditions at the bottom of the loop
;----------------------------------------------------------------------------------------------
.l00002:        mov.q       rax,[rbp+24]            ; get the current number
                shr.q       [rbp+24],4              ; divide by 16
                and.q       rax,0x0000000f          ; get the remainder

;----------------------------------------------------------------------------------------------
; convert the digit to an ascii character and put it in the string
;----------------------------------------------------------------------------------------------
                mov.b       al,[r9+rax]             ; get the proper character
                dec         rcx                     ; move to the previous position
                mov.b       [rbx+rcx],al            ; move the byte into the string

;----------------------------------------------------------------------------------------------
; check if we have processed all the digits
;----------------------------------------------------------------------------------------------
                cmp.q       [rbp+24],0              ; have we reached 0?
                jne         .l00002                 ; loop and do it again

;----------------------------------------------------------------------------------------------
; last thing, set the return address of the string
;----------------------------------------------------------------------------------------------
                lea.q       rax,[rbx+rcx]           ; this is the start of the string

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------
                pop         r9                      ; restore r9
                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword kvsnprintf(qword tgt, qword len, qword fmt, qword args) -- This is an implmentation of
;                                                                  vsnprintf()
;
; This function is the meat and potatoes of this entire quite of functions.  It is quite
; large and uses a host of registers and local variables.  So, to maintain the consistency
; needed for all register usage, the following is how the registers will be used:
; rax -- working register and return value
; rbx -- the address of current argument in the args list
; rcx -- number of characters written -- will be the return value
; rdx -- the flags
; rsi -- the current position in the fmt string
; rdi -- the current position in the tgt string
; r8  -- the current value of the current argument
; r9  -- the number of positions for the formatting (width)
; r10 -- the pointer to the number string buffer for func calls (will be on the stack)
; r11 -- counter for outputting strings when width is used
;----------------------------------------------------------------------------------------------
                global      kvsnprintf
kvsnprintf:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx -- pointer to current arg
                push        rcx                     ; save rcx -- number of chars written
                push        rdx                     ; save rdx -- formatting flags
                push        rsi                     ; save rsi -- current position in fmt
                push        rdi                     ; save rdi -- current postiion in tgt
                push        r8                      ; save r8  -- format width
                push        r9                      ; save r9  -- ptr to start nbr string buf
                push        r10                     ; save r10 -- pointer to a string to output
                push        r11                     ; save r11 -- counter for outputting string

                sub.q       rsp,NUMSTR              ; create room on the stack for the buffer

;----------------------------------------------------------------------------------------------
; Perform the initialization
;----------------------------------------------------------------------------------------------
                xor.q       rax,rax                 ; clear the working register
                xor.q       rcx,rcx                 ; clear the number of char written
                mov.q       r9,rsp                  ; set the string buffer pointer
                mov.q       rsi,[rbp+32]            ; get the formatting string
                mov.q       rdi,[rbp+16]            ; get the destination string
                mov.q       rbx,[rbp+40]            ; get the addr of first arg
                dec         qword [rbp+24]          ; sub 1 now, no need at each cmp

;----------------------------------------------------------------------------------------------
; This is the top of the outer loop and the start of an inner loop to write normal chars
;----------------------------------------------------------------------------------------------
.l00001:        mov.b       al,[rsi]                ; get the next char in the format string
                inc         rsi                     ; move to the next character
                cmp.b       al,0                    ; did we reach the end of the string?
                je          .done                   ; if so, we jump out of the loop

;----------------------------------------------------------------------------------------------
; Did we just start a format?
;----------------------------------------------------------------------------------------------
                cmp.b       al,'%'                  ; are we fealing with a format?
                je          .l00002                 ; if so, jump to that code

;----------------------------------------------------------------------------------------------
; output the character and check length
;----------------------------------------------------------------------------------------------
                mov.b       [rdi],al                ; move the char into the target
                inc         rdi                     ; move to the next pos
                inc         rcx                     ; inc the number of chars written
                cmp.q       rcx,[rbp+24]            ; are we at the end?
                je          .done                   ; if so, just exit

;----------------------------------------------------------------------------------------------
; loop back around for the next character
;----------------------------------------------------------------------------------------------
                jmp         .l00001                 ; loop

;----------------------------------------------------------------------------------------------
; start processing the format we just identified
;----------------------------------------------------------------------------------------------
.l00002:        xor.q       rdx,rdx                 ; clear the flags
                xor.q       r8,r8                   ; clear the format width

;----------------------------------------------------------------------------------------------
; start processing the next format
;----------------------------------------------------------------------------------------------
.nextFormat:    mov.b       al,[rsi]                ; get the next format character
                inc         rsi                     ; move to the next character
                cmp.b       al,0                    ; did we hit the end of the line?
                je          .done                   ; if so, exit

;----------------------------------------------------------------------------------------------
; do we have '0'-'9'?
;----------------------------------------------------------------------------------------------
                cmp.b       al,'0'                  ; have a '0'?
                je          .case0..9               ; if so, jump to the code

                cmp.b       al,'1'                  ; have a '1'?
                je          .case0..9               ; if so, jump to the code

                cmp.b       al,'2'                  ; have a '2'?
                je          .case0..9               ; if so, jump to the code

                cmp.b       al,'3'                  ; have a '3'?
                je          .case0..9               ; if so, jump to the code

                cmp.b       al,'4'                  ; have a '4'?
                je          .case0..9               ; if so, jump to the code

                cmp.b       al,'5'                  ; have a '5'?
                je          .case0..9               ; if so, jump to the code

                cmp.b       al,'6'                  ; have a '6'?
                je          .case0..9               ; if so, jump to the code

                cmp.b       al,'7'                  ; have a '7'?
                je          .case0..9               ; if so, jump to the code

                cmp.b       al,'8'                  ; have a '8'?
                je          .case0..9               ; if so, jump to the code

                cmp.b       al,'9'                  ; have a '9'?
                je          .case0..9               ; if so, jump to the code

;----------------------------------------------------------------------------------------------
; do we have a '.'?  if so, we will just eat the format and move on
;----------------------------------------------------------------------------------------------
                cmp.b       al,'.'                  ; have a '.'?
                je          .nextFormat             ; if so, loop back and continue

;----------------------------------------------------------------------------------------------
; do we have a '%'?
;----------------------------------------------------------------------------------------------
                cmp.b       al,'%'                  ; have a '%'?
                je          .casePct                ; if so, jump to the code

;----------------------------------------------------------------------------------------------
; do we have a 'c'?
;----------------------------------------------------------------------------------------------
                cmp.b       al,'c'                  ; have a 'c'?
                je          .caseC                  ; if so, jump to the code

;----------------------------------------------------------------------------------------------
; do we have a 's'?
;----------------------------------------------------------------------------------------------
                cmp.b       al,'s'                  ; have a 's'?
                je          .caseS                  ; if so, jump to the code

;----------------------------------------------------------------------------------------------
; do we have a '-'?
;----------------------------------------------------------------------------------------------
                cmp.b       al,'-'                  ; have a '-'?
                je          .caseMinus              ; if so, jump to the code

;----------------------------------------------------------------------------------------------
; do we have a '+'?
;----------------------------------------------------------------------------------------------
                cmp.b       al,'+'                  ; have a '+'?
                je          .casePlus               ; if so, jump to the code

;----------------------------------------------------------------------------------------------
; do we have a '#'?
;----------------------------------------------------------------------------------------------
                cmp.b       al,'#'                  ; have a '#'?
                je          .caseHash               ; if so, jump to the code

;----------------------------------------------------------------------------------------------
; do we have a 'l'?
;----------------------------------------------------------------------------------------------
                cmp.b       al,'l'                  ; have a 'l'?
                je          .caseL                  ; if so, jump to the code

;----------------------------------------------------------------------------------------------
; do we have a 'h'?
;----------------------------------------------------------------------------------------------
                cmp.b       al,'h'                  ; have a 'h'?
                je          .caseH                  ; if so, jump to the code

;----------------------------------------------------------------------------------------------
; do we have a 'z'?
;----------------------------------------------------------------------------------------------
                cmp.b       al,'z'                  ; have a 'z'?
                je          .caseZ                  ; if so, jump to the code

;----------------------------------------------------------------------------------------------
; do we have a 'D'?
;----------------------------------------------------------------------------------------------
                cmp.b       al,'D'                  ; have a 'D'?
                je          .caseDD                 ; if so, jump to the code

;----------------------------------------------------------------------------------------------
; do we have a 'i' or 'd'?
;----------------------------------------------------------------------------------------------
                cmp.b       al,'i'                  ; have a 'i'?
                je          .caseI                  ; if so, jump to the code

                cmp.b       al,'d'                  ; have a 'd'?
                je          .caseI                  ; if so, jump to the code

;----------------------------------------------------------------------------------------------
; do we have a 'U'?
;----------------------------------------------------------------------------------------------
                cmp.b       al,'U'                  ; have a 'U'?
                je          .caseUU                 ; if so, jump to the code

;----------------------------------------------------------------------------------------------
; do we have a 'u'?
;----------------------------------------------------------------------------------------------
                cmp.b       al,'u'                  ; have a 'u'?
                je          .caseU                  ; if so, jump to the code

;----------------------------------------------------------------------------------------------
; do we have a 'p'?
;----------------------------------------------------------------------------------------------
                cmp.b       al,'p'                  ; have a 'p'?
                je          .caseP                  ; if so, jump to the code

;----------------------------------------------------------------------------------------------
; do we have a 'X'?
;----------------------------------------------------------------------------------------------
                cmp.b       al,'X'                  ; have a 'X'?
                je          .caseXX                 ; if so, jump to the code

;----------------------------------------------------------------------------------------------
; do we have a 'x'?
;----------------------------------------------------------------------------------------------
                cmp.b       al,'x'                  ; have a 'x'?
                je          .caseX                  ; if so, jump to the code

;----------------------------------------------------------------------------------------------
; do we have a 'n'?
;----------------------------------------------------------------------------------------------
                cmp.b       al,'n'                  ; have a 'n'?
                je          .caseN                  ; if so, jump to the code

;----------------------------------------------------------------------------------------------
; OK, we get here and we do not have a valid format; output the '%' char and the char
;----------------------------------------------------------------------------------------------
                mov.b       [rdi],'%'               ; move '%' into the target
                inc         rdi                     ; move to the next pos
                inc         rcx                     ; inc the number of chars written
                cmp.q       rcx,[rbp+24]            ; are we at the end?
                je          .done                   ; if so, just exit

;----------------------------------------------------------------------------------------------
; This next section does double duty...  it falls through from above and
;
; For this section, we are working on a '%%' combination; just output the char
;----------------------------------------------------------------------------------------------
.casePct:       mov.b       [rdi],al                ; move the char into the target
                inc         rdi                     ; move to the next pos
                inc         rcx                     ; inc the number of chars written
                cmp.q       rcx,[rbp+24]            ; are we at the end?
                je          .done                   ; if so, just exit

                jmp         .l00001                 ; go back and do it all again

;----------------------------------------------------------------------------------------------
; This is the section that processes the digits in the format; it is responsible for setting
; up the width of the output.
;----------------------------------------------------------------------------------------------
.case0..9:      cmp.b       al,'0'                  ; is the digit a '0'?
                jne         .l00003                 ; if not, we can move on

                cmp.q       r8,0                    ; fo we have a format yet?
                jne         .l00003                 ; if not, we can move on

                or.q        rdx,LEADZEROFLAG        ; we need to print leading 0
                jmp         .nextFormat             ; move on to the next format char

.l00003:        imul        r8,r8,10                ; r8 = r8 * 10
                sub.b       al,'0'                  ; convert ascii to number
                add.q       r8,rax                  ; add in the character
                jmp         .nextFormat             ; move on to the next format char

;----------------------------------------------------------------------------------------------
; For this section, we are trying to print a character from an argument
;----------------------------------------------------------------------------------------------
.caseC:         mov.q       rax,[rbx]               ; get the next var arg
                add.q       rbx,8                   ; move to the next arg

                mov.b       [rdi],al                ; move the char into the target
                inc         rdi                     ; move to the next pos
                inc         rcx                     ; inc the number of chars written
                cmp.q       rcx,[rbp+24]            ; are we at the end?
                je          .done                   ; if so, just exit

                jmp         .l00001                 ; go back and do it all again

;----------------------------------------------------------------------------------------------
; For this section, we are trying to print a string from an argument
;----------------------------------------------------------------------------------------------
.caseS:         mov.q       r10,[rbx]               ; get the next var arg
                add.q       rbx,8                   ; move to the next arg

                cmp.q       r10,0                   ; did we get a null?
                jne         .outputString           ; if not null, just jump to output string

                mov.q       rax,nullStr             ; get the "<null>" constant
                mov.q       r10,rax                 ; put the address in the right register
                jmp         .outputString           ; We need to output a string of chars

;----------------------------------------------------------------------------------------------
; For this section, we are looking to left justify a format
;----------------------------------------------------------------------------------------------
.caseMinus:     or.q        rdx,LEFTFORMATFLAG      ; set the left format flag
                jmp         .nextFormat             ; go get another format specifier

;----------------------------------------------------------------------------------------------
; For this section, we need to show a sign
;----------------------------------------------------------------------------------------------
.casePlus:      or.q        rdx,SHOWSIGNFLAG        ; set the sign flag
                jmp         .nextFormat             ; go get another format specifier

;----------------------------------------------------------------------------------------------
; For this section, we need to set the ALTFLAG formatting
;----------------------------------------------------------------------------------------------
.caseHash:      or.q        rdx,ALTFLAG             ; set the sign flag
                jmp         .nextFormat             ; go get another format specifier

;----------------------------------------------------------------------------------------------
; For this section, we will determine the number of longs appear before the integer
;----------------------------------------------------------------------------------------------
.caseL:         test.q      rdx,LONGFLAG            ; have we set the long flag already?
                jz          .l00004                 ; if not set, we will go set it

                or.q        rdx,LONGLONGFLAG        ; set the long long flag
                jmp         .nextFormat             ; go get another format

.l00004:        or.q        rdx,LONGFLAG            ; set the long flag
                jmp         .nextFormat             ; go get another format

;----------------------------------------------------------------------------------------------
; For this section, we will determine the number of halfs appear before the integer
;----------------------------------------------------------------------------------------------
.caseH:         test.q      rdx,HALFFLAG            ; have we set the half flag already?
                jz          .l00005                 ; if not set, we will go set it

                or.q        rdx,HALFHALFFLAG        ; set the half half flag
                jmp         .nextFormat             ; go get another format

.l00005:        or.q        rdx,HALFFLAG            ; set the half flag
                jmp         .nextFormat             ; go get another format

;----------------------------------------------------------------------------------------------
; For this section, we will we will set a size_t flag
;----------------------------------------------------------------------------------------------
.caseZ:         or.q        rdx,SIZETFLAG           ; set the size_t flag
                jmp         .nextFormat             ; go get another format

;----------------------------------------------------------------------------------------------
; For this section, we will be printing a long decimal
;----------------------------------------------------------------------------------------------
.caseDD:        or.q        rdx,LONGFLAG            ; set the long flag

;----------------------------------------------------------------------------------------------
; If we fall through from above, or get here directly, we will be printing a decimal
;----------------------------------------------------------------------------------------------
.caseI:         mov.q       rax,[rbx]               ; get the next var arg
                add.q       rbx,8                   ; move to the next arg

                or.q        rdx,SIGNEDFLAG          ; we need a signed flag

                test.q      rdx,LONGLONGFLAG        ; are we looking for a long long int?
                jnz         .l00006                 ; if so, go to that section

                test.q      rdx,LONGFLAG            ; are we looking for a long int?
                jnz         .l00007                 ; if so, go to that section

                test.q      rdx,HALFHALFFLAG        ; are we looking for a half half int?
                jnz         .l00008                 ; if so, go to that section

                test.q      rdx,HALFFLAG            ; are we looking for a half int?
                jnz         .l00009                 ; if so, go to that section

                test.q      rdx,SIZETFLAG           ; are we looking for a size_t?
                jnz         .l00007                 ; if so, go to that section

;----------------------------------------------------------------------------------------------
; We are going to print an int.
;----------------------------------------------------------------------------------------------
.l00009:        and.q       rax,0xffff              ; we are going to treat an int as 16-bits
                cwd                                 ; convert word to dword
                cdq                                 ; convert dword to qword
                jmp         .l00006                 ; go on to print an int

;----------------------------------------------------------------------------------------------
; We are going to print an byte.
;----------------------------------------------------------------------------------------------
.l00008:        and.q       rax,0xff                ; we are going to treat an int as 8-bits
                cbw                                 ; convert byte to word
                cwd                                 ; convert word to dword
                cdq                                 ; convert dword to qword
                jmp         .l00006                 ; go on to print an int

;----------------------------------------------------------------------------------------------
; We are going to print an long int.
;----------------------------------------------------------------------------------------------
.l00007:        mov.q       r10,0xffffffff          ; prepare to mask out the lower 32 bits
                and.q       rax,r10                 ; we are going to treat an int as 32-bits
                cdq                                 ; convert dword to qword
                jmp         .l00006                 ; go on to print an int

;----------------------------------------------------------------------------------------------
; We are going to print a long long int, or the target for all other types
;----------------------------------------------------------------------------------------------
.l00006:        push        rdx                     ; push the flags
                push        qword NUMSTR            ; push the length of the num string
                push        rax                     ; push the number
                push        r9                      ; push the array of the num string
                call        DecString               ; convert the number to a string
                add.q       rsp,32                  ; clean up the stack

                mov.q       r10,rax                 ; move the string to the right register
                jmp         .outputString           ; go to write the string

;----------------------------------------------------------------------------------------------
; For this section, we will be printing a long unsigned decimal
;----------------------------------------------------------------------------------------------
.caseUU:        or.q        rdx,LONGFLAG            ; set the long flag

;----------------------------------------------------------------------------------------------
; If we fall through from above, or get here directly, we will be printing a decimal
;----------------------------------------------------------------------------------------------
.caseU:         mov.q       rax,[rbx]               ; get the next var arg
                add.q       rbx,8                   ; move to the next arg

                test.q      rdx,LONGLONGFLAG        ; are we looking for a long long int?
                jnz         .l00010                 ; if so, go to that section

                test.q      rdx,LONGFLAG            ; are we looking for a long int?
                jnz         .l00011                 ; if so, go to that section

                test.q      rdx,HALFHALFFLAG        ; are we looking for a half half int?
                jnz         .l00012                 ; if so, go to that section

                test.q      rdx,HALFFLAG            ; are we looking for a half int?
                jnz         .l00013                 ; if so, go to that section

                test.q      rdx,SIZETFLAG           ; are we looking for a size_t?
                jnz         .l00011                 ; if so, go to that section

;----------------------------------------------------------------------------------------------
; We are going to print an int.
;----------------------------------------------------------------------------------------------
.l00013:        and.q       rax,0xffff              ; we are going to treat an int as 16-bits
                jmp         .l00010                 ; go on to print an int

;----------------------------------------------------------------------------------------------
; We are going to print an byte.
;----------------------------------------------------------------------------------------------
.l00012:        and.q       rax,0xff                ; we are going to treat an int as 8-bits
                jmp         .l00010                 ; go on to print an int

;----------------------------------------------------------------------------------------------
; We are going to print an long int.
;----------------------------------------------------------------------------------------------
.l00011:        mov.q       r10,0xffffffff          ; prepare to mask out the lower 32 bits
                and.q       rax,r10                 ; we are going to treat an int as 32-bits
                jmp         .l00010                 ; go on to print an int

;----------------------------------------------------------------------------------------------
; We are going to print a long long int, or the target for all other types
;----------------------------------------------------------------------------------------------
.l00010:        push        rdx                     ; push the flags
                push        qword NUMSTR            ; push the length of the num string
                push        rax                     ; push the number
                push        r9                      ; push the array of the num string
                call        DecString               ; convert the number to a string
                add.q       rsp,32                  ; clean up the stack

                mov.q       r10,rax                 ; move the string to the right register
                jmp         .outputString           ; go to write the string

;----------------------------------------------------------------------------------------------
; For this section, print a pointer
;----------------------------------------------------------------------------------------------
.caseP:         or.q        rdx,LONGLONGFLAG|ALTFLAG|LEADZEROFLAG ; set the flags for a pointer
                mov.q       r8,16                   ; force the size
                jmp         .caseX                  ; go on to print the hex value

;----------------------------------------------------------------------------------------------
; For this section, print hex number with CAPS
;----------------------------------------------------------------------------------------------
.caseXX:        or.q        rdx,CAPSFLAG            ; set the flags for a pointer

;----------------------------------------------------------------------------------------------
; If we fall through from above, or get here directly, we will be printing a lc hex number
;----------------------------------------------------------------------------------------------
.caseX:         mov.q       rax,[rbx]               ; get the next var arg
                add.q       rbx,8                   ; move to the next arg

                test.q      rdx,LONGLONGFLAG        ; are we looking for a long long int?
                jnz         .l00014                 ; if so, go to that section

                test.q      rdx,LONGFLAG            ; are we looking for a long int?
                jnz         .l00015                 ; if so, go to that section

                test.q      rdx,HALFHALFFLAG        ; are we looking for a half half int?
                jnz         .l00016                 ; if so, go to that section

                test.q      rdx,HALFFLAG            ; are we looking for a half int?
                jnz         .l00017                 ; if so, go to that section

                test.q      rdx,SIZETFLAG           ; are we looking for a size_t?
                jnz         .l00015                 ; if so, go to that section

;----------------------------------------------------------------------------------------------
; We are going to print an int.
;----------------------------------------------------------------------------------------------
.l00017:        and.q       rax,0xffff              ; we are going to treat an int as 16-bits
                jmp         .l00014                 ; go on to print an int

;----------------------------------------------------------------------------------------------
; We are going to print an byte.
;----------------------------------------------------------------------------------------------
.l00016:        and.q       rax,0xff                ; we are going to treat an int as 8-bits
                jmp         .l00014                 ; go on to print an int

;----------------------------------------------------------------------------------------------
; We are going to print an long int.
;----------------------------------------------------------------------------------------------
.l00015:        mov.q       r10,0xffffffff          ; prepare to mask out the lower 32 bits
                and.q       rax,r10                 ; we are going to treat an int as 32-bits
                jmp         .l00014                 ; go on to print an int

;----------------------------------------------------------------------------------------------
; We are going to print a long long int, or the target for all other types
;----------------------------------------------------------------------------------------------
.l00014:        push        rdx                     ; push the flags
                push        qword NUMSTR            ; push the length of the num string
                push        rax                     ; push the number
                push        r9                      ; push the array of the num string
                call        HexString               ; convert the number to a string
                add.q       rsp,32                  ; clean up the stack

                mov.q       r10,rax                 ; move the string to the right register

;----------------------------------------------------------------------------------------------
; If we are printing the hex prologue, we should check and do it now
;----------------------------------------------------------------------------------------------
                test.q      rdx,ALTFLAG             ; is the ALT Flag on?
                jz          .outputString           ; if not, jump directly to output the str

                mov.b       [rdi],'0'               ; move the char into the target
                inc         rdi                     ; move to the next pos
                inc         rcx                     ; inc the number of chars written
                cmp.q       rcx,[rbp+24]            ; are we at the end?
                je          .done                   ; if so, just exit

                test.q      rdx,CAPSFLAG            ; are we printing caps
                jz          .l00018                 ; if not set the lower case
                mov.b       [rdi],'X'               ; move the char into the target
                jmp         .l00019                 ; go on to print the char
.l00018:        mov.b       [rdi],'x'               ; move the char into the target

.l00019:        inc         rdi                     ; move to the next pos
                inc         rcx                     ; inc the number of chars written
                cmp.q       rcx,[rbp+24]            ; are we at the end?
                je          .done                   ; if so, just exit

;----------------------------------------------------------------------------------------------
; Wrap up with printing the string
;----------------------------------------------------------------------------------------------
                jmp         .outputString           ; go to write the string

;----------------------------------------------------------------------------------------------
; Finally, we need to report the number of chars printed so far; but we will not implement
;----------------------------------------------------------------------------------------------
.caseN:         jmp         .l00001                 ; go back and do it all again

;----------------------------------------------------------------------------------------------
; We have a string within a string to print, in R10
;----------------------------------------------------------------------------------------------
.outputString:  test.q      rdx,LEFTFORMATFLAG      ; are we left justifying?
                jz          .l00020                 ; if not, move on

;----------------------------------------------------------------------------------------------
; we are going to left justify the output, padding on the right as necessary
;----------------------------------------------------------------------------------------------
                xor.q       r11,r11                 ; clear r11

.l00022:        mov.b       al,[r10]                ; get the next character
                cmp.b       al,0                    ; did we find terminating null?
                je          .l00021                 ; if so, exit the loop

                mov.b       [rdi],al                ; move the char into the target
                inc         rdi                     ; move to the next pos
                inc         rcx                     ; inc the number of chars written
                cmp.q       rcx,[rbp+24]            ; are we at the end?
                je          .done                   ; if so, just exit

                inc         r10                     ; move to the next character
                inc         r11                     ; add 1 to the character
                jmp         .l00022                 ; loop to next character

;----------------------------------------------------------------------------------------------
; now we just need to pad any characters to the right.....
;----------------------------------------------------------------------------------------------
.l00021:        cmp.q       r11,r8                  ; check the total length...
                jge         .l00001                 ; if done, loop around again

                mov.b       [rdi],' '               ; move the char into the target
                inc         rdi                     ; move to the next pos
                inc         rcx                     ; inc the number of chars written
                cmp.q       rcx,[rbp+24]            ; are we at the end?
                je          .done                   ; if so, just exit

                inc         r11                     ; we added another character
                jmp         .l00021                 ; add another ' '

;----------------------------------------------------------------------------------------------
; we are going to right justify the output, padding on the left as necessary
;----------------------------------------------------------------------------------------------
.l00020:        push        r10                     ; we need to get the length of the string
                call        kstrlen                 ; get the number of characters
                add.q       rsp,8                   ; clean up the stack
                mov.q       r11,rax                 ; save the length

                test.q      rdx,LEADZEROFLAG        ; are we paddign with 0 or ' '
                jz          .l00023                 ; if not, go set to blank
                mov.b       al,'0'                  ; set the leading char to '0'
                jmp         .l00024                 ; move on
.l00023:        mov.b       al,' '                  ; set the leading char to ' '

.l00024:        cmp.q       r11,r8                  ; check the total length...
                jge         .l00025                 ; if done, loop around again

                mov.b       [rdi],al                ; move the char into the target
                inc         rdi                     ; move to the next pos
                inc         rcx                     ; inc the number of chars written
                cmp.q       rcx,[rbp+24]            ; are we at the end?
                je          .done                   ; if so, just exit

                inc         r11                     ; we added another character
                jmp         .l00024                 ; add another ' '

.l00025:        mov.b       al,[r10]                ; get the char of the string
                inc         r10                     ; move to the next source char
                cmp.b       al,0                    ; are we at the end
                je          .l00001                 ; all the way back to the beginning

                mov.b       [rdi],al                ; move the char into the target
                inc         rdi                     ; move to the next pos
                inc         rcx                     ; inc the number of chars written
                cmp.q       rcx,[rbp+24]            ; are we at the end?
                je          .done                   ; if so, just exit

                jmp         .l00025                 ; loop back to the next char

;----------------------------------------------------------------------------------------------
; terminate the string and prepare to exit
;----------------------------------------------------------------------------------------------
.done:          mov.b       [rdi],0                 ; move the final NULL to the target
                mov.q       rax,rcx                 ; set the return value

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------
                add.q       rsp,NUMSTR              ; release the buffer on stack
                pop         r11                     ; restore r11
                pop         r10                     ; restore r10
                pop         r9                      ; restore r9
                pop         r8                      ; restore r8
                pop         rdi                     ; restore rdi
                pop         rsi                     ; restore rsi
                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================


;==============================================================================================
; This is the read only data section of the source file.  It will be part of the kernel.
;==============================================================================================

                section     .rodata

hexTable        db          '0123456789abcdef'
hexTABLE        db          '0123456789ABCDEF'
nullStr         db          '<null>',0
