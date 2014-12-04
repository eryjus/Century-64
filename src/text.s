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
;
;==============================================================================================


;==============================================================================================
; The .data segment will hold all data related to the kernel
;==============================================================================================

                section     .data

textRow         db          0                           ; treat as unsigned
textCol         db          0                           ; treat as unsigned
textBuf         dd          0xb8000                     ; treat as unsigned
textAttr        db          0x0f                        ; treat as unsigned
textMaxRow      db          24                          ; treat as unsigned
textMaxCol      db          79                          ; treat as unsigned

textHex         db          '0123456789abcdef'          ; a string of hexidecimal digits
textHexPre      db          '0x',0                      ; the prefix for a hex number

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
                push        rbp                         ; create a frame
                mov         rbp,rsp
                push        rbx                         ; we will modify rbx
                push        rcx                         ; we will mofidy rcx
                push        rdi                         ; we will modify rdi

;----------------------------------------------------------------------------------------------
; Make sure something else does not try to update the screen
;----------------------------------------------------------------------------------------------

                pushfq                                  ; save the flags
                cli                                     ; no interrupts, please

;----------------------------------------------------------------------------------------------
; clear the screen
;----------------------------------------------------------------------------------------------

                mov         rbx,qword textBuf           ; get the address of the buffer var
                xor         rdi,rdi                     ; clear rdi for safety
                mov         edi,dword [rbx]             ; and load its contents into rdi

                mov         rbx,qword textMaxRow        ; get the address of the max rows #
                inc         rbx                         ; convert to number of rows
                mov         al,byte [rbx]               ; and load its contents into al

                mov         rbx,qword textMaxCol        ; get the address of the max col #
                inc         rbx                         ; convert to number of cols
                mov         ah,byte [rbx]               ; and load its contents into ah

                mul         ah                          ; mul rows by cols -- result in ax

                xor         rcx,rcx                     ; now load rcx with the number of words
                mov         cx,ax                       ; cx is the result we want

                mov         rbx,qword textAttr          ; get the address of the attr var
                mov         ah,byte[rbx]                ; and load its contents into ah
                mov         al,0x20                     ; and the low byte is " "

;----------------------------------------------------------------------------------------------
; Now, reset the internal cursor position (textRow and textCol)
;----------------------------------------------------------------------------------------------

                mov         rbx,qword textRow           ; get the address of the current Row
                mov         [rbx],byte 0                ; and set it to 0

                mov         rbx,qword textCol           ; get the address of the current Col
                mov         [rbx],byte 0                ; and set it to 0

                rep         stosw                       ; now, clear the screen

;----------------------------------------------------------------------------------------------
; Position the cursor on the screen
;----------------------------------------------------------------------------------------------

                call        TextSetCursor               ; position the cursor

;----------------------------------------------------------------------------------------------
; Clean up on the way out
;----------------------------------------------------------------------------------------------

                popfq                                   ; restore the IF
                pop         rdi                         ; restore rdi
                pop         rcx                         ; restore rcx
                pop         rbx                         ; restore rbx
                pop         rbp                         ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextSetAttr(unsigned char attr) -- This function will set the attribute to be used for
;                                         all subsequent characters (until it is changed
;                                         again)
;----------------------------------------------------------------------------------------------

                global      TextSetAttr

TextSetAttr:
                push        rbp                         ; create frame
                mov         rbp,rsp
                push        rbx                         ; save rbx, since we will modify

                mov         rax,qword [rbp+16]          ; get the new attr (8-byte aligned)
                mov         rbx,qword textAttr          ; get the address of the var
                mov         [rbx],al                    ; and set the new value

                pop         rbx                         ; restore rbx
                pop         rbp                         ; and caller's frame
                ret


;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextPutChar(unsigned char ch) -- Put a character on the screen, handling newlines and
;                                       carriage returns as well as scrolling when the cursor
;                                       reaches the bottom of the screen.
;----------------------------------------------------------------------------------------------

                global      TextPutChar

TextPutChar:
                push        rbp                         ; create frame
                mov         rbp,rsp
                push        rbx                         ; save rbx, since we will modify
                push        rcx                         ; save rdx since we will modify
                push        rdx                         ; save rdx since we will modify
                push        rdi                         ; save rdi since we will modify
                pushfq                                  ; save the flags
                cli                                     ; no interrupts, please

                mov         rax,qword [rbp+16]          ; get the char to write (8-byte align)

;----------------------------------------------------------------------------------------------
; Do we have a \n or \r character?
;----------------------------------------------------------------------------------------------

                cmp         al,13                       ; do we have a carriage return?
                je          .newline                    ; if so, we have to process a newline
                cmp         al,10                       ; do we have a newline?
                jne         .other                      ; if not, we have a real char

;----------------------------------------------------------------------------------------------
; we have to start a new line, whether by wrapping or by a char; set the current column to 0
; and increment the current row by 1.
;----------------------------------------------------------------------------------------------

.newline:
                mov         rbx,qword textCol           ; get the address of the current col
                mov         byte [rbx],0                ; and set the value to 0

                mov         rbx,qword textRow           ; get the address of the current row
                add         byte [rbx],1                ; and add 1 to it
                mov         dl,byte [rbx]               ; and then save the result

                mov         rbx,qword textMaxRow        ; get the address of the max row #
                cmp         dl,byte [rbx]               ; compare  row ?? #rows
                jbe         .out                        ; if not above (unsigned >), skip

;----------------------------------------------------------------------------------------------
; We know we need to scroll the screen
;----------------------------------------------------------------------------------------------

                call        TextScrollUp                ; we need to scroll the screen

;----------------------------------------------------------------------------------------------
; Reset the cursor position
;----------------------------------------------------------------------------------------------

                mov         rbx,qword textCol           ; get the address of the current col
                mov         byte [rbx],0                ; and set the value to 0

                mov         rbx,qword textMaxRow        ; get the address of the max row #
                mov         dl,byte [rbx]               ; get total # rows

                mov         rbx,qword textRow           ; get the address of the current row
                mov         byte [rbx],dl               ; store the result

                jmp         .out                        ; we've done all we need to do

;----------------------------------------------------------------------------------------------
; Output a regular character
;----------------------------------------------------------------------------------------------

.other:
                mov         rbx,qword textAttr          ; get the address of the var
                mov         ah,[rbx]                    ; get the ttribute as well

                mov         rdx,rax                     ; save the rax register
                xor         rax,rax                     ; clear rax

                mov         rbx,qword textRow           ; get the address of the text row
                mov         al,byte [rbx]               ; and get its value

                mov         rbx,qword textMaxCol        ; get the address of the max col #
                mov         ah,byte [rbx]               ; and get its value
                inc         ah                          ; adjust it for # cols

                mul         ah                          ; the result is in ax

                mov         rbx,qword textCol           ; get the address of the text col
                mov         cl,byte [rbx]               ; and get its value
                xor         ch,ch                       ; zero out the upper bits

                add         ax,cx                       ; add the 2 numbers
                shl         rax,1                       ; multiply by 2 (attr/char paris)

                xor         rdi,rdi                     ; clear rdi
                mov         rbx,qword textBuf           ; get the address of the screen buffer
                mov         edi,dword [rbx]             ; and get its address

                add         rdi,rax                     ; add the offset to the buffer addr
                mov         word [rdi],dx               ; and put the character on the screen

;----------------------------------------------------------------------------------------------
; move the cursor to the next position on the screen
;----------------------------------------------------------------------------------------------

                xor         rax,rax                     ; clear rax
                mov         rbx,qword textMaxCol        ; get the address of the max col #
                mov         al,byte [rbx]               ; and get its value

                mov         rbx,qword textCol           ; get the address of the current col
                add         byte [rbx],1                ; and add 1 to it

                cmp         byte [rbx],al               ; compare: curcol ?? maxcols
                ja          .newline                    ; if curcol >= maxcols, wrap line

.out:
                call        TextSetCursor

                popfq                                   ; restore IF
                pop         rdi                         ; restore rdx
                pop         rdx                         ; restore rdi
                pop         rcx                         ; restore rdx
                pop         rbx                         ; restore rbx
                pop         rbp                         ; and caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextPutHexByte(uint8 b) -- print the value of a hex byte on the screen
;----------------------------------------------------------------------------------------------

                global      TextPutHexByte

TextPutHexByte:
                push        rbp                         ; create frame
                mov         rbp,rsp
                push        rbx                         ; save rbx, since we will modify

                mov         rbx,qword textHexPre        ; get the address of the prefix
                push        rbx
                call        TextPutString               ; and write it on the screen
                add         rsp,8                       ; clean up the stack

                mov         rax,[rbp+16]                ; get the byte to print (8-byte filled)
                call        TextOutputHex               ; print the byte

                pop         rbx                         ; restore rbx
                pop         rbp                         ; and caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextPutHexWord(uint16 w) -- print the value of a hex word on the screen
;----------------------------------------------------------------------------------------------

                global      TextPutHexWord

TextPutHexWord:
                push        rbp                         ; create frame
                mov         rbp,rsp
                push        rbx                         ; save rbx, since we will modify

                mov         rbx,qword textHexPre        ; get the address of the prefix
                push        rbx
                call        TextPutString               ; and write it on the screen
                add         rsp,8                       ; clean up the stack

                mov         rax,[rbp+16]                ; get the word to print (8-byte filled)
                shr         rax,8                       ; get the upper byte from the word
                call        TextOutputHex               ; print the byte

                mov         rax,[rbp+16]                ; get the word to print (8-byte filled)
                and         rax,qword 0xff              ; get the lower byte from the word
                call        TextOutputHex               ; print the byte

                pop         rbx                         ; restore rbx
                pop         rbp                         ; and caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextPutHexDWord(uint32 dw) -- print the value of a hex dword on the screen
;----------------------------------------------------------------------------------------------

                global      TextPutHexDWord

TextPutHexDWord:
                push        rbp                         ; create frame
                mov         rbp,rsp
                push        rbx                         ; save rbx, since we will modify

                mov         rbx,qword textHexPre        ; get the address of the prefix
                push        rbx
                call        TextPutString               ; and write it on the screen
                add         rsp,8                       ; clean up the stack

                mov         rax,[rbp+16]                ; get the word to print (8-byte filled)
                shr         rax,24                      ; get the upper byte from the dword
                and         rax,qword 0xff              ; get the lower byte from the dword
                call        TextOutputHex               ; print the byte

                mov         rax,[rbp+16]                ; get the word to print (8-byte filled)
                shr         rax,16                      ; get the 2nd byte from the dword
                and         rax,qword 0xff              ; get the lower byte from the dword
                call        TextOutputHex               ; print the byte

                push        qword '_'                   ; push it on the stack
                call        TextPutChar                 ; and display it
                add         rsp,8                       ; clean up the stack


                mov         rax,[rbp+16]                ; get the word to print (8-byte filled)
                shr         rax,8                       ; get the 3rd byte from the dword
                and         rax,qword 0xff              ; get the lower byte from the dword
                call        TextOutputHex               ; print the byte

                mov         rax,[rbp+16]                ; get the word to print (8-byte filled)
                and         rax,qword 0xff              ; get the lower byte from the word
                call        TextOutputHex               ; print the byte

                pop         rbx                         ; restore rbx
                pop         rbp                         ; and caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextPutHexQWord(uint32 qw) -- print the value of a hex qword on the screen
;----------------------------------------------------------------------------------------------

                global      TextPutHexQWord

TextPutHexQWord:
                push        rbp                         ; create frame
                mov         rbp,rsp
                push        rbx                         ; save rbx, since we will modify

                mov         rbx,qword textHexPre        ; get the address of the prefix
                push        rbx
                call        TextPutString               ; and write it on the screen
                add         rsp,8                       ; clean up the stack

                mov         rax,[rbp+16]                ; get the word to print (8-byte filled)
                shr         rax,56                      ; get the upper byte from the qword
                and         rax,qword 0xff              ; get the lower byte from the qword
                call        TextOutputHex               ; print the byte

                mov         rax,[rbp+16]                ; get the word to print (8-byte filled)
                shr         rax,48                      ; get the 2nd byte from the qword
                and         rax,qword 0xff              ; get the lower byte from the qword
                call        TextOutputHex               ; print the byte

                push        qword '_'                   ; push it on the stack
                call        TextPutChar                 ; and display it
                add         rsp,8                       ; clean up the stack

                mov         rax,[rbp+16]                ; get the word to print (8-byte filled)
                shr         rax,40                      ; get the 3rd byte from the qword
                and         rax,qword 0xff              ; get the lower byte from the qword
                call        TextOutputHex               ; print the byte

                mov         rax,[rbp+16]                ; get the word to print (8-byte filled)
                shr         rax,32                      ; get the 4th byte from the qword
                and         rax,qword 0xff              ; get the lower byte from the qword
                call        TextOutputHex               ; print the byte

                push        qword '_'                   ; push it on the stack
                call        TextPutChar                 ; and display it
                add         rsp,8                       ; clean up the stack

                mov         rax,[rbp+16]                ; get the word to print (8-byte filled)
                shr         rax,24                      ; get the 5th byte from the qword
                and         rax,qword 0xff              ; get the lower byte from the qword
                call        TextOutputHex               ; print the byte

                mov         rax,[rbp+16]                ; get the word to print (8-byte filled)
                shr         rax,16                      ; get the 6th byte from the qword
                and         rax,qword 0xff              ; get the lower byte from the qword
                call        TextOutputHex               ; print the byte

                push        qword '_'                   ; push it on the stack
                call        TextPutChar                 ; and display it
                add         rsp,8                       ; clean up the stack

                mov         rax,[rbp+16]                ; get the word to print (8-byte filled)
                shr         rax,8                       ; get the 7th byte from the dword
                and         rax,qword 0xff              ; get the lower byte from the dword
                call        TextOutputHex               ; print the byte

                mov         rax,[rbp+16]                ; get the word to print (8-byte filled)
                and         rax,qword 0xff              ; get the lower byte from the word
                call        TextOutputHex               ; print the byte

                pop         rbx                         ; restore rbx
                pop         rbp                         ; and caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextPutString(char *str) -- put a null-terminated string of characters onto the screen
;----------------------------------------------------------------------------------------------

                global      TextPutString

TextPutString:
                push        rbp                         ; create frame
                mov         rbp,rsp
                push        rbx                         ; save rbx, since we will modify
                push        rsi                         ; save rsi since we will modify
                sub         rsp,8                       ; make room on the stack for a parm

                mov         rsi,[rbp+16]                ; get the address of the string
.loop:
                xor         rax,rax                     ; clear the rax reg
                mov         al,byte[rsi]                ; get the next byte to write
                cmp         al,0                        ; are we at null?
                je          .out                        ; if so, exit

                mov         [rsp],rax                   ; put the 8-byte aligned parameter
                call        TextPutChar                 ; put the character on the screen
                inc         rsi                         ; move to the next character
                jmp         .loop

.out:
                add         rsp,8                       ; remove the working parameter
                pop         rsi                         ; restore rsi
                pop         rbx                         ; restore rbx
                pop         rbp                         ; and caller's frame
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
                push        rbp                         ; create frame
                mov         rbp,rsp
                push        rbx                         ; save rbx, since we will modify
                push        rcx                         ; save rcx since we will modify
                push        rdx                         ; save rdx since we will modify
                push        rsi                         ; save rsi since we will modify

                mov         rsi,qword textHex           ; get the address of the char array
                xor         rdx,rdx                     ; clear out rdx
                mov         dl,al                       ; get the byte
                shr         dl,4                        ; we want the upper 4 bits of the byte

                xor         rcx,rcx                     ; clear rcx
                add         rsi,rdx                     ; move to the offset
                mov         cl,byte [rsi]               ; get the hex digit

                push        rax                         ; we need to keep this value
                push        rcx                         ; push it on the stack
                call        TextPutChar                 ; and display it
                add         rsp,8                       ; clean up the stack
                pop         rax                         ; now restore this value

                mov         rsi,qword textHex           ; get the address of the char array
                xor         rdx,rdx                     ; clear out rdx
                and         rax,qword 0x0f              ; we want the lower 4 bits of the byte

                xor         rcx,rcx                     ; clear rcx
                add         rsi,rax                     ; move to the offset
                mov         cl,byte [rsi]               ; get the hex digit

                push        rcx                         ; push it on the stack
                call        TextPutChar                 ; and display it
                add         rsp,8                       ; clean up the stack

                pop         rsi                         ; restore rbx
                pop         rdx                         ; restore rbx
                pop         rcx                         ; restore rbx
                pop         rbx                         ; restore rbx
                pop         rbp                         ; and caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextScrollUp(void) -- This function will scroll the screen.  For now, I am assuming that
;                            I will no l onger maintain a status bar at the bottom of the
;                            screen.  If I choose to add it later, this function will need to
;                            be modified to account for it.
;----------------------------------------------------------------------------------------------

TextScrollUp:
                push        rbp                         ; create frame
                mov         rbp,rsp
                push        rbx                         ; save rbx, since we will modify
                push        rcx                         ; save rcx, since we will modify
                push        rsi                         ; save rsi since will will modify
                push        rdi                         ; save rdi, since we will modify
                pushfq                                  ; save the flags; no interrupting pls
                cli                                     ; no interrupts

                xor         rax,rax                     ; clear rax
                xor         rdi,rdi                     ; clear rdi
                mov         rbx,qword textBuf           ; get the address of the buffer var
                mov         edi,dword [rbx]             ; now get the buffer address

                xor         rcx,rcx                     ; clear rcx
                mov         rbx,qword textMaxCol        ; get the address for the max col #
                mov         cl,byte [rbx]               ; get the max column number
                inc         cl                          ; add 1 to it to get the number of cols
                mov         ah,cl                       ; save this value for later
                shl         rcx,1                       ; multiply by 2 to get words
                mov         rdx,rcx                     ; save this value to clear the blank line
                mov         rsi,rcx                     ; move it to the rsi reg as well
                add         rsi,rdi                     ; now get the source to cpy; 1 row down

                mov         rbx,qword textMaxRow        ; get the address of the max row #
                mov         al,byte [rbx]               ; and get the number of rows

                mul         ah                          ; mult by ah, results in ax
                mov         rcx,rax                     ; set the counter

                rep         movsw                       ; move the data

                mov         rbx,qword textAttr          ; get the address of the attr var
                mov         ah,byte[rbx]                ; and load its contents into ah
                mov         al,0x20                     ; and the low byte is " "
                mov         rcx,rdx                     ; restore the column count

                rep         stosw                       ; clear the last line

                popfq                                   ; restore the IF
                pop         rdi                         ; restore rbx
                pop         rsi                         ; restore rsi
                pop         rcx                         ; restore rbx
                pop         rbx                         ; restore rbx
                pop         rbp                         ; and caller's frame
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
                push        rbp                         ; create a frame
                mov         rbp,rsp
                push        rbx                         ; save rbx since we will trash it
                push        rcx                         ; save rcx since we will trash it
                push        rdx                         ; save rdx since we will trash it

;----------------------------------------------------------------------------------------------
; Calculate the proper offset
;----------------------------------------------------------------------------------------------

                xor         rax,rax                     ; clear rax for consistency
                mov         rbx,qword textRow           ; get the address of the textRow var
                mov         al,byte [rbx]               ; and load the value into al

                mov         rbx,qword textMaxCol        ; get address of the max col #
                mov         ah,byte [rbx]               ; and load the value into ah
                inc         ah                          ; reset this to be the # cols

                mul         ah                          ; multiply; result in ax

                xor         rcx,rcx                     ; clear rcx for consistency
                mov         rbx,qword textCol           ; get the address of the textCol var
                mov         cl,byte [rbx]               ; and load the value into cl
                add         ax,cx                       ; add to ax (ch is clear); ax holds off

                mov         bl,ah                       ; save the MSB in bl
                mov         cl,al                       ; save the LSB in cl

;----------------------------------------------------------------------------------------------
; Tell the controller where to position the cursor
;----------------------------------------------------------------------------------------------

                mov         dx,0x3d4                    ; set the IO control port
                mov         al,0x0e                     ; we want the MSB of cursor pos
                out         dx,al                       ; tell the port what is coming next

                inc         dx                          ; move the the data port
                mov         al,bl                       ; get our MSB
                out         dx,al                       ; and write it to the data port

                dec         dx                          ; go back to the control port
                mov         al,0x0f                     ; we want the LSB of cursor pos
                out         dx,al                       ; tell the port what is coming next

                inc         dx                          ; move back to the data port
                mov         al,cl                       ; getour LSB
                out         dx,al                       ; and write it to the data port

                pop         rdx                         ; restore rdx
                pop         rcx                         ; restore rcx
                pop         rbx                         ; restore rbx
                pop         rbp                         ; and rbp
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextSetBlockCursor(void) -- This function will change the cursor to be a block-style
;                                  cursor.
;----------------------------------------------------------------------------------------------
                global      TextSetBlockCursor

TextSetBlockCursor:
                push        rbp                         ; create a frame
                mov         rbp,rsp
                push        rbx                         ; save rbx since we will trash it
                push        rdx                         ; save rdx since we will modify

                mov         dx,0x3d4                    ; set the 6845 control reg
                mov         al,0x0a                     ; set the cursor start register
                out         dx,al                       ; send the byte fo the 6845

                inc         dx                          ; set the 6845 data register
                xor         rax,rax                     ; we want to start on scan line 0
                out         dx,al                       ; send the byte to the 6845

                mov         dx,0x3d4                    ; again, set 6845 control reg
                mov         al,0x09                     ; scan line register
                in          al,dx                       ; get the byte

                and         al,0x1f                     ; mask out the scan line
                push        rax                         ; save the value -- we will overwrite

                mov         dx,0x3d4                    ; set the 6845 control reg
                mov         al,0x0b                     ; cursor end register
                out         dx,al                       ; send the byte

                inc         dx                          ; move to 6845 data reg
                pop         rax                         ; get our value back
                add         eax,4                       ; add 4 additional scan lines
                out         dx,al                       ; set the bottom scan line

                pop         rdx                         ; restore rbx
                pop         rbx                         ; restore rbx
                pop         rbp                         ; and rbp
                ret

;==============================================================================================
