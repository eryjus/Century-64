;==============================================================================================
;
; text.s
;
; This file contains the functions required to manipulate the text screen after entering 64-bit
; long mode.  These functions are expected to be called when interrupts are enabled.
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
; The functions provided in this file are:
;   void TextClear(void);
;   void TextPutChar(uint8 ch);
;   void TextPutHexByte(uint8 b);
;   void TextPutHexWord(uint16 w);
;   void TextPutHexDWord(uint32 dw);
;   void TextPutHexQWord(uint64 qw);
;   void TextPutString(char *str);
;   void TextSetAttr(uint8 attr);
;   void TextSetBlockCursor(void);
;
; Internal functions:
;   void TextOutputHex(register uint8 b);
;   void TextScrollUp(void);
;   void TextSetCursor(void);
;
;    Date     Tracker  Pgmr  Description
; ----------  -------  ----  ------------------------------------------------------------------
; 2014/10/05  Initial  ADCL  Initial coding
; 2014/10/12  #169     ADCL  For me, the ABI standard is causing me issues. For whatever reason,
;                            I am having trouble keeping track of "registers I want to save as
;                            the caller" rather than "saving all registers I will modify as the
;                            callee". I will adopt the latter standard so that debugging will
;                            be easier to manage, with the exception of rax.  DF in rFLAGS will
;                            be maintained as clear.
;                            At the same time reformat for spacing
; 2014/10/13  #172     ADCL  OK, found that the textNumRows and textNumCols variables were
;                            misnamed and misused.  I am renaming them to the way they will be
;                            used, which is textMaxRow and textMaxCol (the upper limit).
; 2014/10/20  #177     ADCL  Found that the number of columns was not being calculated properly
;                            in function TextScrollUp after applying the fix for #172.  The
;                            code was still taking the max column number as the total number of
;                            columns.  Added 1 to this value to convert max column number to
;                            number of columns (since the screen positions are 0-based) and it
;                            now works.
; 2014/11/05  #190     ADCL  Also found that the TextClear was having the same issues as #177
;                            above.  Fixed the calculations and all is right again.
; 2014/12/23  #205     ADCL  Add the debugging console.
; 2014/12/23  #193     ADCL  At the same time as above, clean up the coding standard.
;
;==============================================================================================

%define         __TEXT_S__
%include        'private.inc'

;==============================================================================================
; The .data segment will hold all data related to the kernel
;==============================================================================================

                section     .data

textRow         db          0                       ; treat as unsigned
textCol         db          0                       ; treat as unsigned
textBuf         dd          0xb8000                 ; treat as unsigned
textAttr        db          0x0f                    ; treat as unsigned
textMaxRow      db          24                      ; treat as unsigned
textMaxCol      db          79                      ; treat as unsigned

textHex         db          '0123456789abcdef'      ; a string of hexidecimal digits
textHexPre      db          '0x',0                  ; the prefix for a hex number

;==============================================================================================
; The .text section is the 64-bit kernel proper
;==============================================================================================

                section     .text
                bits        64

;----------------------------------------------------------------------------------------------
; void TextClear(void) -- clear the screen using the current textAttr in the current textBuf
;                         with textNumRows and textNumCols.  Reset the textRow and textCol
;                         back to 0,0 and finally move the cursor.
;----------------------------------------------------------------------------------------------

                global      TextClear

TextClear:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdi                     ; save rdi
                pushfq                              ; save the flags
                cli                                 ; no interrupts, please

;----------------------------------------------------------------------------------------------
; clear the screen
;----------------------------------------------------------------------------------------------

                mov.q       rbx,textBuf             ; get the address of the buffer var
                xor.q       rdi,rdi                 ; clear rdi for safety
                mov.d       edi,[rbx]               ; and load its contents into rdi

                mov.q       rbx,textMaxRow          ; get the address of the max rows #
                inc         rbx                     ; convert to number of rows
                mov.b       al,[rbx]                ; and load its contents into al

                mov.q       rbx,textMaxCol          ; get the address of the max col #
                inc         rbx                     ; convert to number of cols
                mov.b       ah,[rbx]                ; and load its contents into ah

                mul         ah                      ; mul rows by cols -- result in ax

                xor.q       rcx,rcx                 ; now load rcx with the number of words
                mov.w       cx,ax                   ; cx is the result we want

                mov.q       rbx,textAttr            ; get the address of the attr var
                mov.b       ah,[rbx]                ; and load its contents into ah
                mov.b       al,0x20                 ; and the low byte is " "

;----------------------------------------------------------------------------------------------
; Now, reset the internal cursor position (textRow and textCol)
;----------------------------------------------------------------------------------------------

                mov.q       rbx,textRow             ; get the address of the current Row
                mov.b       [rbx],0                 ; and set it to 0

                mov.q       rbx,textCol             ; get the address of the current Col
                mov.b       [rbx],0                 ; and set it to 0

                rep         stosw                   ; now, clear the screen

;----------------------------------------------------------------------------------------------
; Position the cursor on the screen
;----------------------------------------------------------------------------------------------

                call        TextSetCursor           ; position the cursor

;----------------------------------------------------------------------------------------------
; Clean up on the way out
;----------------------------------------------------------------------------------------------

                popfq                               ; restore flags (specifically IF)
                pop         rdi                     ; restore rdi
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextSetAttr(unsigned char attr) -- This function will set the attribute to be used for
;                                         all subsequent characters (until it is changed
;                                         again)
;----------------------------------------------------------------------------------------------

                global      TextSetAttr

TextSetAttr:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx

                mov.q       rax,[rbp+16]            ; get the new attr (8-byte aligned)
                mov.q       rbx,textAttr            ; get the address of the var
                mov.b       [rbx],al                ; and set the new value

                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret


;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextPutChar(unsigned char ch) -- Put a character on the screen, handling newlines and
;                                       carriage returns as well as scrolling when the cursor
;                                       reaches the bottom of the screen.
;----------------------------------------------------------------------------------------------

                global      TextPutChar

TextPutChar:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rdx
                push        rdx                     ; save rdx
                push        rdi                     ; save rdi
                pushfq                              ; save the flags
                cli                                 ; no interrupts, please

                mov.q       rax,[rbp+16]            ; get the char to write (8-byte align)

;----------------------------------------------------------------------------------------------
; Do we have a \n or \r character?
;----------------------------------------------------------------------------------------------

                cmp.b       al,13                   ; do we have a carriage return?
                je          .newline                ; if so, we have to process a newline
                cmp.b       al,10                   ; do we have a newline?
                jne         .other                  ; if not, we have a real char

;----------------------------------------------------------------------------------------------
; we have to start a new line, whether by wrapping or by a char; set the current column to 0
; and increment the current row by 1.
;----------------------------------------------------------------------------------------------

.newline:
                mov.q       rbx,textCol             ; get the address of the current col
                mov.b       [rbx],0                 ; and set the value to 0

                mov.q       rbx,textRow             ; get the address of the current row
                add.b       [rbx],1                 ; and add 1 to it
                mov.b       dl,[rbx]                ; and then save the result

                mov.q       rbx,textMaxRow          ; get the address of the max row #
                cmp.b       dl,[rbx]                ; compare  row ?? #rows
                jbe         .out                    ; if not above (unsigned >), skip

;----------------------------------------------------------------------------------------------
; We know we need to scroll the screen
;----------------------------------------------------------------------------------------------

                call        TextScrollUp            ; we need to scroll the screen

;----------------------------------------------------------------------------------------------
; Reset the cursor position
;----------------------------------------------------------------------------------------------

                mov.q       rbx,textCol             ; get the address of the current col
                mov.b       [rbx],0                 ; and set the value to 0

                mov.q       rbx,textMaxRow          ; get the address of the max row #
                mov.b       dl,[rbx]                ; get total # rows

                mov.q       rbx,textRow             ; get the address of the current row
                mov.b       [rbx],dl                ; store the result

                jmp         .out                    ; we've done all we need to do

;----------------------------------------------------------------------------------------------
; Output a regular character
;----------------------------------------------------------------------------------------------

.other:
                mov.q       rbx,textAttr            ; get the address of the var
                mov.b       ah,[rbx]                ; get the ttribute as well

                mov.q       rdx,rax                 ; save the rax register
                xor.q       rax,rax                 ; clear rax

                mov.q       rbx,textRow             ; get the address of the text row
                mov.b       al,[rbx]                ; and get its value

                mov.q       rbx,textMaxCol          ; get the address of the max col #
                mov.b       ah,[rbx]                ; and get its value
                inc         ah                      ; adjust it for # cols

                mul         ah                      ; the result is in ax

                mov.q       rbx,textCol             ; get the address of the text col
                mov.b       cl,[rbx]                ; and get its value
                xor.b       ch,ch                   ; zero out the upper bits

                add.w       ax,cx                   ; add the 2 numbers
                shl.q       rax,1                   ; multiply by 2 (attr/char paris)

                xor.q       rdi,rdi                 ; clear rdi
                mov.q       rbx,textBuf             ; get the address of the screen buffer
                mov.d       edi,[rbx]               ; and get its address

                add.q       rdi,rax                 ; add the offset to the buffer addr
                mov.w       [rdi],dx                ; and put the character on the screen

;----------------------------------------------------------------------------------------------
; move the cursor to the next position on the screen
;----------------------------------------------------------------------------------------------

                xor.q       rax,rax                 ; clear rax
                mov.q       rbx,textMaxCol          ; get the address of the max col #
                mov.b       al,[rbx]                ; and get its value

                mov.q       rbx,textCol             ; get the address of the current col
                add.b       [rbx],1                 ; and add 1 to it

                cmp.b       [rbx],al                ; compare: curcol ?? maxcols
                ja          .newline                ; if curcol >= maxcols, wrap line

;----------------------------------------------------------------------------------------------
; Finally, if enabled, output the character to the serial console
;----------------------------------------------------------------------------------------------
.out:
%ifndef DISABLE_DBG_CONSOLE
                push        qword [rbp+16]          ; push the character on the stack
                call        DbgConsolePutChar       ; put the character on the serial port
                add.q       rsp,8                   ; clean up the stack
%endif


;----------------------------------------------------------------------------------------------
; move the cursor, clean up, and exit
;----------------------------------------------------------------------------------------------

                call        TextSetCursor           ; position the cursor

                popfq                               ; restore IF
                pop         rdi                     ; restore rdx
                pop         rdx                     ; restore rdi
                pop         rcx                     ; restore rdx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; and caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextPutHexByte(uint8 b) -- print the value of a hex byte on the screen
;----------------------------------------------------------------------------------------------

                global      TextPutHexByte

TextPutHexByte:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx

                mov.q       rbx,textHexPre          ; get the address of the prefix
                push        rbx                     ; push the prefix on the stack
                call        TextPutString           ; and write it on the screen
                add.q       rsp,8                   ; clean up the stack

                mov.q       rax,[rbp+16]            ; get the byte to print (8-byte filled)
                call        TextOutputHex           ; print the byte

                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextPutHexWord(uint16 w) -- print the value of a hex word on the screen
;----------------------------------------------------------------------------------------------

                global      TextPutHexWord

TextPutHexWord:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx

                mov.q       rbx,textHexPre          ; get the address of the prefix
                push        rbx                     ; push that on the stack
                call        TextPutString           ; and write it on the screen
                add.q       rsp,8                   ; clean up the stack

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,8                   ; get the upper byte from the word
                call        TextOutputHex           ; print the byte

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                and.q       rax,0xff                ; get the lower byte from the word
                call        TextOutputHex           ; print the byte

                pop         rbx                     ; restore rbx
                pop         rbp                     ; and caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextPutHexDWord(uint32 dw) -- print the value of a hex dword on the screen
;----------------------------------------------------------------------------------------------

                global      TextPutHexDWord

TextPutHexDWord:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx

                mov.q       rbx,textHexPre          ; get the address of the prefix
                push        rbx                     ; push it on the stack
                call        TextPutString           ; and write it on the screen
                add.q       rsp,8                   ; clean up the stack

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,24                  ; get the upper byte from the dword
                and.q       rax,0xff                ; get the lower byte from the dword
                call        TextOutputHex           ; print the byte

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,16                  ; get the 2nd byte from the dword
                and.q       rax,0xff                ; get the lower byte from the dword
                call        TextOutputHex           ; print the byte

                push        '_'                     ; push it on the stack
                call        TextPutChar             ; and display it
                add.q       rsp,8                   ; clean up the stack


                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,8                   ; get the 3rd byte from the dword
                and.q       rax,0xff                ; get the lower byte from the dword
                call        TextOutputHex           ; print the byte

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                and.q       rax,0xff                ; get the lower byte from the word
                call        TextOutputHex           ; print the byte

                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextPutHexQWord(uint32 qw) -- print the value of a hex qword on the screen
;----------------------------------------------------------------------------------------------

                global      TextPutHexQWord

TextPutHexQWord:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx

                mov.q       rbx,textHexPre          ; get the address of the prefix
                push        rbx                     ; push it on the stack
                call        TextPutString           ; and write it on the screen
                add.q       rsp,8                   ; clean up the stack

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,56                  ; get the upper byte from the qword
                and.q       rax,0xff                ; get the lower byte from the qword
                call        TextOutputHex           ; print the byte

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,48                  ; get the 2nd byte from the qword
                and.q       rax,0xff                ; get the lower byte from the qword
                call        TextOutputHex           ; print the byte

                push        '_'                     ; push it on the stack
                call        TextPutChar             ; and display it
                add.q       rsp,8                   ; clean up the stack

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,40                  ; get the 3rd byte from the qword
                and.q       rax,0xff                ; get the lower byte from the qword
                call        TextOutputHex           ; print the byte

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,32                  ; get the 4th byte from the qword
                and.q       rax,0xff                ; get the lower byte from the qword
                call        TextOutputHex           ; print the byte

                push        '_'                     ; push it on the stack
                call        TextPutChar             ; and display it
                add.q       rsp,8                   ; clean up the stack

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,24                  ; get the 5th byte from the qword
                and.q       rax,0xff                ; get the lower byte from the qword
                call        TextOutputHex           ; print the byte

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,16                  ; get the 6th byte from the qword
                and.q       rax,0xff                ; get the lower byte from the qword
                call        TextOutputHex           ; print the byte

                push        '_'                     ; push it on the stack
                call        TextPutChar             ; and display it
                add.q       rsp,8                   ; clean up the stack

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                shr.q       rax,8                   ; get the 7th byte from the dword
                and.q       rax,0xff                ; get the lower byte from the dword
                call        TextOutputHex           ; print the byte

                mov.q       rax,[rbp+16]            ; get the word to print (8-byte filled)
                and.q       rax,0xff                ; get the lower byte from the word
                call        TextOutputHex           ; print the byte

                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextPutString(char *str) -- put a null-terminated string of characters onto the screen
;----------------------------------------------------------------------------------------------

                global      TextPutString

TextPutString:
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
                call        TextPutChar             ; put the character on the screen
                inc         rsi                     ; move to the next character
                jmp         .loop                   ; loop until done

.out:           add.q       rsp,8                   ; remove the working parameter
                pop         rsi                     ; restore rsi
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextOutputHex(register uint8 b) -- This is the working function for outputting hex
;                                         numbers on the screen.  Note that the byte with
;                                         which to work is passed in through rax (the lowest
;                                         8 bits).  The function will only output 2 characters
;                                         on the screen.  All other formatting is handled
;                                         outside this function.
;----------------------------------------------------------------------------------------------

TextOutputHex:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frmae
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdx                     ; save rdx
                push        rsi                     ; save rsi

                mov.q       rsi,textHex             ; get the address of the char array
                xor.q       rdx,rdx                 ; clear out rdx
                mov.b       dl,al                   ; get the byte
                shr.b       dl,4                    ; we want the upper 4 bits of the byte

                xor.q       rcx,rcx                 ; clear rcx
                add.q       rsi,rdx                 ; move to the offset
                mov.b       cl,[rsi]                ; get the hex digit

                push        rax                     ; we need to keep this value
                push        rcx                     ; push it on the stack
                call        TextPutChar             ; and display it
                add.q       rsp,8                   ; clean up the stack
                pop         rax                     ; now restore this value

                mov.q       rsi,textHex             ; get the address of the char array
                xor.q       rdx,rdx                 ; clear out rdx
                and.q       rax,0x0f                ; we want the lower 4 bits of the byte

                xor.q       rcx,rcx                 ; clear rcx
                add.q       rsi,rax                 ; move to the offset
                mov.b       cl,[rsi]                ; get the hex digit

                push        rcx                     ; push it on the stack
                call        TextPutChar             ; and display it
                add.q       rsp,8                   ; clean up the stack

                pop         rsi                     ; restore rbx
                pop         rdx                     ; restore rbx
                pop         rcx                     ; restore rbx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextScrollUp(void) -- This function will scroll the screen.  For now, I am assuming that
;                            I will no l onger maintain a status bar at the bottom of the
;                            screen.  If I choose to add it later, this function will need to
;                            be modified to account for it.
;----------------------------------------------------------------------------------------------

TextScrollUp:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rsi                     ; save rsi
                push        rdi                     ; save rdi
                pushfq                              ; save the flags
                cli                                 ; no interrupts

                xor.q       rax,rax                 ; clear rax
                xor.q       rdi,rdi                 ; clear rdi
                mov.q       rbx,textBuf             ; get the address of the buffer var
                mov.d       edi,[rbx]               ; now get the buffer address

                xor.q       rcx,rcx                 ; clear rcx
                mov.q       rbx,textMaxCol          ; get the address for the max col #
                mov.b       cl,[rbx]                ; get the max column number
                inc         cl                      ; add 1 to it to get the number of cols
                mov.b       ah,cl                   ; save this value for later
                shl.q       rcx,1                   ; multiply by 2 to get words
                mov.q       rdx,rcx                 ; save this value to clear the blank line
                mov         rsi,rcx                 ; move it to the rsi reg as well
                add         rsi,rdi                 ; now get the source to cpy; 1 row down

                mov.q       rbx,textMaxRow          ; get the address of the max row #
                mov.b       al,[rbx]                ; and get the number of rows

                mul         ah                      ; mult by ah, results in ax
                mov.q       rcx,rax                 ; set the counter

                rep         movsw                   ; move the data

                mov.q       rbx,textAttr            ; get the address of the attr var
                mov.b       ah,[rbx]                ; and load its contents into ah
                mov.b       al,0x20                 ; and the low byte is " "
                mov.q       rcx,rdx                 ; restore the column count

                rep         stosw                   ; clear the last line

                popfq                               ; restore the IF
                pop         rdi                     ; restore rbx
                pop         rsi                     ; restore rsi
                pop         rcx                     ; restore rbx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextSetCursor(void) -- This function will position the cursor on the screen based on
;                             the values in textRow and textCol.  The offset is calcualted with
;                             the formula: textRow * textNumCols + textCol
;
; NOTE this function is expected to be called with interrupts disabled.  Undesireable results
; may occur...
;----------------------------------------------------------------------------------------------

TextSetCursor:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdx                     ; save rdx

;----------------------------------------------------------------------------------------------
; Calculate the proper offset
;----------------------------------------------------------------------------------------------

                xor.q       rax,rax                 ; clear rax for consistency
                mov.q       rbx,textRow             ; get the address of the textRow var
                mov.b       al,[rbx]                ; and load the value into al

                mov.q       rbx,textMaxCol          ; get address of the max col #
                mov.b       ah,[rbx]                ; and load the value into ah
                inc         ah                      ; reset this to be the # cols

                mul         ah                      ; multiply; result in ax

                xor.q       rcx,rcx                 ; clear rcx for consistency
                mov.q       rbx,textCol             ; get the address of the textCol var
                mov.b       cl,[rbx]                ; and load the value into cl
                add.w       ax,cx                   ; add to ax (ch is clear); ax holds off

                mov.b       bl,ah                   ; save the MSB in bl
                mov.b       cl,al                   ; save the LSB in cl

;----------------------------------------------------------------------------------------------
; Tell the controller where to position the cursor
;----------------------------------------------------------------------------------------------

                mov.w       dx,0x3d4                ; set the IO control port
                mov.b       al,0x0e                 ; we want the MSB of cursor pos
                out         dx,al                   ; tell the port what is coming next

                inc         dx                      ; move the the data port
                mov.b       al,bl                   ; get our MSB
                out         dx,al                   ; and write it to the data port

                dec         dx                      ; go back to the control port
                mov.b       al,0x0f                 ; we want the LSB of cursor pos
                out         dx,al                   ; tell the port what is coming next

                inc         dx                      ; move back to the data port
                mov.b       al,cl                   ; get our LSB
                out         dx,al                   ; and write it to the data port

                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextSetBlockCursor(void) -- This function will change the cursor to be a block-style
;                                  cursor.
;----------------------------------------------------------------------------------------------

                global      TextSetBlockCursor

TextSetBlockCursor:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rdx                     ; save rdx

                mov.w       dx,0x3d4                ; set the 6845 control reg
                mov.b       al,0x0a                 ; set the cursor start register
                out         dx,al                   ; send the byte fo the 6845

                inc         dx                      ; set the 6845 data register
                xor.q       rax,rax                 ; we want to start on scan line 0
                out         dx,al                   ; send the byte to the 6845

                mov.w       dx,0x3d4                ; again, set 6845 control reg
                mov.b       al,0x09                 ; scan line register
                in          al,dx                   ; get the byte

                and.b       al,0x1f                 ; mask out the scan line
                push        rax                     ; save the value -- we will overwrite

                mov.w       dx,0x3d4                ; set the 6845 control reg
                mov.b       al,0x0b                 ; cursor end register
                out         dx,al                   ; send the byte

                inc         dx                      ; move to 6845 data reg
                pop         rax                     ; get our value back
                add.d       eax,4                   ; add 4 additional scan lines
                out         dx,al                   ; set the bottom scan line

                pop         rdx                     ; restore rbx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================
