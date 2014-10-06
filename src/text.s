;==============================================================================================
;
; text.s
;
; This file contains the functions required to manipulate the text screen after entering 64-bit
; long mode.  These functions are expected to be called when interrupts are enabled.
;
; The functions provided in this file are:
;   void TextClear(void);
;	void TextSetAttr(unsigned char attr);
;
; Internal functions:
;   void TextScrollUp(void);
;	void TextSetCursor(void);
;
;    Date     Tracker  Pgmr  Description
; ----------  -------  ----  ------------------------------------------------------------------
; 2014/10/05  Initial  ADCL  Initial coding
;
;==============================================================================================


;==============================================================================================
; The .data segment will hold all data related to the kernel
;==============================================================================================

			section		.data

textRow		db			0
textCol		db			0
textBuf		dd			0xb8000
textAttr	db			0x0f
textNumRows	db			25
textNumCols	db			80


;==============================================================================================
; The .text section is the 64-bit kernel proper
;==============================================================================================

			section		.text
			bits		64

;----------------------------------------------------------------------------------------------
; void TextClear(void) -- clear the screen using the current textAttr in the current textBuf
;                         with textNumRows and textNumCols.  Reset the textRow and textCol
;                         back to 0,0 and finally move the cursor.
;----------------------------------------------------------------------------------------------

			global		TextClear

TextClear:
			push		rbp								; create a frame
			mov			rbp,rsp
			push		rbx								; we will modify rbx

;----------------------------------------------------------------------------------------------
; First clear the screen
;----------------------------------------------------------------------------------------------

			mov			rbx,qword textBuf				; get the address of the buffer var
			xor			rdi,rdi							; clear rdi for safety
			mov			edi,dword [rbx]					; and load its contents into rdi

			mov			rbx,qword textNumRows			; get the address of the #rows var
			mov			al,byte [rbx]					; and load its contents into al

			mov			rbx,qword textNumCols			; get the address of the #cols var
			mov			ah,byte [rbx]					; and load its contents into ah

			mul			ah								; mul rows by cols -- result in ax

			xor			rcx,rcx							; now load rcx with the number of words
			mov			cx,ax							; cx is the result we want

			mov			rbx,qword textAttr				; get the address of the attr var
			mov			ah,byte[rbx]					; and load its contents into ah
			mov			al,0x20							; and the low byte is " "

;----------------------------------------------------------------------------------------------
; Make sure something else does not try to move the cursor on us while we are positioning it
;----------------------------------------------------------------------------------------------

			pushfq										; save the flags
			cli											; no interrupts, please

;----------------------------------------------------------------------------------------------
; Now, reset the internal cursor position (textRow and textCol)
;----------------------------------------------------------------------------------------------

			mov			rbx,qword textRow				; get the address of the current Row
			mov			[rbx],byte 0					; and set it to 0

			mov			rbx,qword textCol				; get the address of the current Col
			mov			[rbx],byte 0					; and set it to 0

			cld											; make sure we increment
			rep			stosw							; now, clear the screen

;----------------------------------------------------------------------------------------------
; Position the cursor on the screen
;----------------------------------------------------------------------------------------------

			call		TextSetCursor					; position the cursor

			popfq										; restore the IF
			pop			rbx								; restore rbx
			pop			rbp								; restore caller's frame
			ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextSetAttr(unsigned char attr) -- This function will set the attribute to be used for
;                                         all subsequent characters (until it is changed
;                                         again)
;----------------------------------------------------------------------------------------------

			global		TextSetAttr

TextSetAttr:
			push		rbp								; create frame
			mov			rbp,rsp
			push		rbx								; save rbx, since we will modify

			mov			rax,qword [rbp+16]					; get the new attr (8-byte aligned)
			mov			rbx,qword textAttr				; get the address of the var
			mov			[rbx],al						; and set the new value

			pop			rbx								; restore rbx
			pop			rbp								; and caller's frame
			ret


;==============================================================================================

;----------------------------------------------------------------------------------------------
; void TextScrollUp(void) -- This function will scroll the screen.  For now, I am assuming that
;                            I will no l onger maintain a status bar at the bottom of the
;                            screen.  If I choose to add it later, this function will need to
;                            be modified to account for it.
;----------------------------------------------------------------------------------------------

TextScrollUp:
			push		rbp								; create frame
			mov			rbp,rsp
			push		rbx								; save rbx, since we will modify
			pushfq										; save the flags; no interrupting pls
			cli											; no interrupts

			xor			rdi,rdi							; clear rdi
			mov			rbx,qword textBuf				; get the address of the buffer var
			mov			edi,dword [rbx]					; now get the buffer address

			xor			rcx,rcx							; clear rcx
			mov			rbx,qword textNumCols			; get the address for the # cols var
			mov			cl,byte [rbx]					; get the number of columns
			mov			rdx,rcx							; we will want this again later
			mov			rsi,rcx							; move it to the rsi reg as well
			shl			rsi,1							; multiply by 2
			add			rsi,rdi							; now get the source to cpy; 1 row down

			xor			eax,eax							; clear eax
			mov			rbx,qword textNumRows			; get the address of the # rows var
			mov			al,byte [rbx]					; and get the number of rows

			mul			al								; results in ax
			mov			rcx,rax							; set the counter

			cld											; make sure we increment
			rep			movsw							; move the data

			mov			rbx,qword textAttr				; get the address of the attr var
			mov			ah,byte[rbx]					; and load its contents into ah
			mov			al,0x20							; and the low byte is " "
			mov			rcx,rdx							; restore the column count

			rep			stosw							; clear the last line

			popfq										; restore the IF
			pop			rbx								; restore rbx
			pop			rbp								; and caller's frame
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
			push		rbp								; create a frame
			mov			rbp,rsp
			push		rbx								; save rbx since we will trash it

;----------------------------------------------------------------------------------------------
; Calculate the proper offset
;----------------------------------------------------------------------------------------------

			xor			rax,rax							; clear rax for consistency
			mov			rbx,qword textRow				; get the address of the textRow var
			mov			al,byte [rbx]					; and load the value into al

			mov			rbx,qword textNumCols			; get address of the textNumCols var
			mov			ah,byte [rbx]					; and load the value into ah

			mul			ah								; multiply; result in ax

			xor			rcx,rcx							; clear rcx for consistency
			mov			rbx,qword textCol				; get the address of the textCol var
			mov			cl,byte [rbx]					; and load the value into cl
			add			ax,cx							; add to ax (ch is clear); ax holds off

			mov			bl,ah							; save the MSB in bl
			mov			cl,al							; save the LSB in cl

;----------------------------------------------------------------------------------------------
; Tell the controller where to position the cursor
;----------------------------------------------------------------------------------------------

			mov			dx,0x3d4						; set the IO control port
			mov			al,0x0e							; we want the MSB of cursor pos
			out			dx,al							; tell the port what is coming next

			inc			dx								; move the the data port
			mov			al,bl							; get our MSB
			out			dx,al							; and write it to the data port

			dec			dx								; go back to the control port
			mov			al,0x0f							; we want the LSB of cursor pos
			out			dx,al							; tell the port what is coming next

			inc			dx								; move back to the data port
			mov			al,cl							; getour LSB
			out			dx,al							; and write it to the data port

			pop			rbx								; restore rbx
			pop			rbp								; and rbp
			ret

;----------------------------------------------------------------------------------------------
