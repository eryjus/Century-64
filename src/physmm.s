;==============================================================================================
;
; physmm.s
;
; This file contains the functions and data that will be used to manage the physical memory
; layer of this kernel
;
; After a number of days of internal debate, I have settled on a bitmap for my memory manager
; implementation.  I will implement this bitmap with 1 slight modification: I will maintain a
; pointer in the bitmap where the last block was found to be available and start subsequent
; searches there.  From an allocation perspective, the logic is simple: we cannot assume that
; memory ever gets freed, so why go back and start looking for free memory when we have
; already determined that there is none.  If we reach the end of memory, we will loop and
; look again from the beginning.
;
; I settled on this model because of the memory requirements.  While speed is an issue, I
; also need to consider how to handle the structures since this is all (so far) written in
; assembly.  At the point I am setting this up, I have no kernel heap manager, so allocating
; and deallocating is a bit of a mess (unless I want to statically allocate an array and
; maintain a flag available/used).  In addition, looking at pairs (block#,#blocks) of free
; memory looks great to start with.  However, if memory becomed heavily fragmented, then the
; result is quite a lot of overhead (odd blocks free for 4GB results in paris: (1,1), (3,1),
; (5,1), etc; 512K pairs; 8 bytes per pair = 4MB structures worst case and twice that for 16
; byte pairs).  The bitmap is static at 128K.  The static nature of the structure appealed to
; me greatly.
;
; I have not yet determined that I need to allow for "configuous" memory to be allocated.  So,
; I'm going to skip this for now and come back to it if I deem it necessary.  For the moment,
; any contiguous memory is allocated at compile time.
;
; The bitmap will be 16384 qwords (128K) and each bit (1 Mbit total) will represent a 4K page.
; This then allows the bitmap to represent 4GB of memory.  A bit will be set to 0 if a page is
; used and 1 is a page is available.  This scheme allows a quick qword to be compared to 0
; and if the result is true, then we move on the investigate the next 64-bits.  If the result
; is not true, then we know we have a free page in there and we will dig into it to determine
; which page is available.
;
; The following functions are published in this file:
;	void PMMInit(void);
;	void PMMMarkBlockFree(qword strart, qword length);
;	void PMMMarkBlockUsed(qword strart, qword length);
;	qword PMMAllocLowerMem(void);
;	qword PMMAllocUpperMem(void);
;	qword PMMAlloc32bitMem(void);
;	qword PMMAllocMem(void);
;	void PMMFreeMem(qword frame);
;
; The following functions are internal functions:
;	void PMMSetBitFree(qword addr);
;	void PMMSetBitUsed(qword addr);
;
;    Date     Tracker  Pgmr  Description
; ----------  ------   ----  ------------------------------------------------------------------
; 2014/10/10  Initial  ADCL  Initial code
; 2014/10/12  #169     ADCL  For me, the ABI standard is causing me issues. For whatever reason,
;                            I am having trouble keeping track of "registers I want to save as
;                            the caller" rather than "saving all registers I will modify as the
;                            callee". I will adopt the latter standard so that debugging will
;                            be easier to manage, with the exception of rax.  DF in rFLAGS will
;                            be maintained as clear.
;                            At the same time reformat for spacing
;
;==============================================================================================

%define			__PHYSMM_S__
%include		'private.inc'


;==============================================================================================
; the .data segment has the data members that will be used for allocations
;==============================================================================================

				section		.data
				align		8

pmmLoIndex		dq			0
pmmHiIndex		dq			PMMLOQWORDS
pmm32Index		dq			PMMLOQWORDS

;==============================================================================================
; the .bss section here contains the memory reservation for the page allocation bitmap
;==============================================================================================

				section		.bss
				align		0x1000

PMMQWORDS		equ			16384					; that's 128K
PMMLOQWORDS		equ			4						; that's up to 1M for allocating low-memory
PMM32BIT		equ			(1024*1024)/64			; that's 4GB memory

PMMBitMap: 		resq		PMMQWORDS


;==============================================================================================
; this .text section contains the code to implement the Physical Memory Management layer
;==============================================================================================

				section		.text
				bits		64

;----------------------------------------------------------------------------------------------
; void PMMInit(void) -- Initialize the bitmap structure; at first, all memory is "used"; we
;                       will come back and set the "free" bits before we give control over to
;                       the memory manager.
;----------------------------------------------------------------------------------------------

				global		PMMInit

PMMInit:
				push		rbp					; create a new stack frame
				mov			rbp,rsp
				push		rbx					; assume we will modify rbx
				push		rcx					; assume we will modify rcx
				push		rdi					; assume we will modify rdi

				mov			rcx,qword PMMQWORDS	; set the number of qwords to init
				xor			rax,rax				; make rax 0
				mov			rdi,qword PMMBitMap	; get the bitmap
				cld								; make sure we increment
				rep			stosq				; initialize the bitmap

				pop			rdi					; restore the fields
				pop			rcx					; restore the fields
				pop			rbx					; restore the fields
				pop			rbp
				ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void PMMSetBitFree(qword addr) -- Mark a page as free by setting its flag to be a '1'
; void PMMFreeMem(qword frame) -- Free a memory frame back to the pool.  These functions do
;                                 the same thing (the only possible difference might be
;                                 clearing the page before releasing the frame.
;----------------------------------------------------------------------------------------------

PMMFreeMem:
PMMSetBitFree:
				push		rbp					; create a new stack frame
				mov			rbp,rsp
				push		rbx					; assume we will modify rbx
				push		rcx					; assume we will modify rcx
				push		rdx					; assume we will modify rdx
				push		rsi					; assume we will modify rsi
				pushfq							; we will save flags
				cli								; because we don't want to be interrupted

				mov			rax,qword [rbp+16]
				shr			rax,12				; divide by 4K to get page #

				mov			rcx,rax				; we will need to get the bit number
				and			rcx,qword 0x000000000000003f	; mask out the bit number

				mov			rbx,rax				; we need to get the qword #
				shr			rbx,6				; divide by 64 to get qword number
				shl			rbx,3				; multiply by 8 to get a byte count

				xor			rdx,rdx				; clear rdx
				add			rdx,1				; make rdx 1
				shl			rdx,cl				; rdx now holds the bit mask we want to check

				mov			rsi,qword PMMBitMap	; get the table address
				add			rsi,rbx				; rsi now holds the address of the qword
				mov			rax,qword [rsi]		; get the qword
				or			rax,rdx				; set the bit
				mov			qword [rsi],rax		; store the word again

				popfq							; restore the flags
				pop			rsi					; restore the fields
				pop			rdx					; restore the fields
				pop			rcx					; restore the fields
				pop			rbx					; restore the fields
				pop			rbp
				ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void PMMSetBitUsed(qword addr) -- Mark a page as used by setting its flag to be a '0'
;----------------------------------------------------------------------------------------------

PMMSetBitUsed:
				push		rbp					; create a new stack frame
				mov			rbp,rsp
				push		rbx					; assume we will modify rbx
				push		rcx					; assume we will modify rcx
				push		rdx					; assume we will modify rdx
				push		rsi					; assume we will modify rsi
				pushfq							; we will save flags
				cli								; because we don't want to be interrupted

				mov			rax,qword [rbp+16]
				shr			rax,12				; divide by 4K to get page #

				mov			rcx,rax				; we will need to get the bit number
				and			rcx,qword 0x000000000000003f	; mask out the bit number

				mov			rbx,rax				; we need to get the qword #
				shr			rbx,6				; divide by 64 to get qword number
				shl			rbx,3				; multiply by 8 to get a byte count

				xor			rdx,rdx				; clear rdx
				add			rdx,1				; make rdx 1
				shl			rdx,cl				; rdx now holds the bit mask we want to check
				not			rdx					; flip the bits

				mov			rsi,qword PMMBitMap	; get the table address
				add			rsi,rbx				; rsi now holds the address of the qword
				mov			rax,qword [rsi]		; get the qword
				and			rax,rdx				; clear the bit
				mov			qword [rsi],rax		; store the word again

				popfq							; restore the flags
				pop			rsi					; restore the fields
				pop			rdx					; restore the fields
				pop			rcx					; restore the fields
				pop			rbx					; restore the fields
				pop			rbp
				ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void PMMMarkBlockFree(qword strart, qword length) -- Mark a block of pages free, adjusting
;                                                      properly for the start to break on page
;                                                      boundaries, and adjusting the length
;                                                      to break on boundaries as well.  If a
;                                                      page is partially free and partially
;                                                      used, then consider the whole page used.
;----------------------------------------------------------------------------------------------

				global		PMMMarkBlockFree

PMMMarkBlockFree:
				push		rbp					; create a new stack frame
				mov			rbp,rsp
				push		rbx					; assume we will modify rbx
				push		rcx					; assume we will modify rbx
				push		rdi					; assume we will modify rbx

				mov			rax,qword [rbp+16]	; get the start parm
				mov			rdi,rax				; and store it in rdi

				mov			rcx,qword [rbp+24]	; get the size
				shr			rcx,12				; shift this down to be a count -- will
												; truncate a partial page at the end

				and			rax,qword 0x0000000000000fff ; check for partial page at start
				cmp			rax,0				; are we 0?
				je			.adjusted			; skip the adjustments

				and			rdi,qword 0xfffffffffffff000	; truncate to a page boundary
				add			rdi,qword 0x0000000000001000	; and move to the next page

.adjusted:
				push		rdi					; push this value for the function
				call		PMMSetBitFree		; call the function
				add			rsp,8				; clean up the stack

				add			rdi,0x1000			; move to the next page
				sub			rcx,1				; next iteration
				cmp			rcx,0				; are we done?
				je			.out				; if so, leave the loop

				jmp			.adjusted

.out:
				pop			rdi					; restore the fields
				pop			rcx					; restore the fields
				pop			rbx					; restore the fields
				pop			rbp
				ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void PMMMarkBlockUsed(qword strart, qword length) -- Mark a block of pages used, adjusting
;                                                      properly for the start to break on page
;                                                      boundaries, and adjusting the length
;                                                      to break on boundaries as well.  If a
;                                                      page is partially free and partially
;                                                      used, then consider the whole page used.
;----------------------------------------------------------------------------------------------

				global		PMMMarkBlockUsed

PMMMarkBlockUsed:
				push		rbp					; create a new stack frame
				mov			rbp,rsp
				push		rbx					; assume we will modify rbx
				push		rcx					; assume we will modify rbx
				push		rdi					; assume we will modify rbx

				mov			rax,qword [rbp+16]	; get the start parm
				mov			rdi,rax				; and store it in rdi

				mov			rcx,qword [rbp+24]	; get the size
				shr			rcx,12				; shift this down to be a count -- will
												; truncate a partial page at the end

				test		rcx,qword 0x0000000000000fff ; check for partial page at end
				jz			.adjusted			; skip the adjustments

				and			rcx,qword 0xfffffffffffff000	; Align to page
				add			rcx,0x1000			; step it up to fill last page

.adjusted:
				and			rdi,qword 0xfffffffffffff000	; truncate to a page boundary

				push		rdi					; save this value
				call		PMMSetBitUsed		; call the function
				add			rsp,8				; clean up the stack

				add			rdi,0x1000			; move to the next page
				sub			rcx,1				; next iteration
				cmp			rcx,0				; are we done?
				je			.out				; if so, leave the loop

				jmp			.adjusted

.out:
				pop			rdi					; restore the fields
				pop			rcx					; restore the fields
				pop			rbx					; restore the fields
				pop			rbp
				ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword PMMAllocLowerMem(void) -- Allocate a frame in the lower memory section (up to 1MB).
;                                 If the allocation fails, return -1 for the frame
;----------------------------------------------------------------------------------------------

				global		PMMAllocLowerMem

PMMAllocLowerMem:
				push		rbp					; create a new stack frame
				mov			rbp,rsp
				push		rbx					; we will modify rbx
				push		rcx					; we will modify rcx
				push		rdx					; we will modify rdx
				push		rsi					; save rsi
				push		r13					; save r13
				push		r14					; save r14
				push		r15					; we will modify r15
				pushfq
				cli								; please don't interrupt me!

				mov			rbx,qword pmmLoIndex; get the address of the var
				mov			r13,rbx				; save the address of the var
				mov			r15,[rbx]			; get the starting value
				mov			r14,r15				; we also need a working value

				mov			rbx,qword PMMBitMap	; get the bitmap address

.loop:
				mov			rax,r14				; get the working value
				shl			rax,8				; convert the value to qwords

				mov			rcx,[rbx+rax]		; get the bitmap qword
				cmp			rcx,0				; is the memory fully booked?
				jne			AllocCommonEnd.found; if some space, go get it

				inc			r14					; continue our search
				cmp			r14,qword PMMLOQWORDS	; are we at the end of the list?
				jb			.chkDone			; if not at last byte, go chk is checked all

				xor			r14,r14				; start over at byte 0

.chkDone:
				cmp			r14,r15				; check if we have fully looped
				jne			.loop				; if not, go check again

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword PMMAllocUpperMem(void) -- Allocate a frame in the upper memory section (> 1MB).
;                                 If the allocation fails, return -1 for the frame
;----------------------------------------------------------------------------------------------

				global		PMMAllocUpperMem

PMMAllocUpperMem:
				push		rbp					; create a new stack frame
				mov			rbp,rsp
				push		rbx					; we will modify rbx
				push		rcx					; we will modify rcx
				push		rdx					; we will modify rdx
				push		rsi					; save rsi
				push		r13					; save r13
				push		r14					; save r14
				push		r15					; we will modify r15
				pushfq
				cli								; please don't interrupt me!

				mov			rbx,qword pmmHiIndex; get the address of the var
				mov			r13,rbx				; save the address of the var
				mov			r15,[rbx]			; get the starting value
				mov			r14,r15				; we also need a working value

				mov			rbx,qword PMMBitMap	; get the bitmap address

.loop:
				mov			rax,r14				; get the working value
				shl			rax,8				; convert the value to qwords

				mov			rcx,[rbx+rax]		; get the bitmap qword
				cmp			rcx,0				; is the memory fully booked?
				jne			AllocCommonEnd.found; if some space, go get it

				inc			r14					; continue our search
				cmp			r14,qword PMMQWORDS	; are we at the end of the list?
				jb			.chkDone			; if not at last byte, go chk is checked all

				mov			r14,qword PMMLOQWORDS	; start over at 1MB

.chkDone:
				cmp			r14,r15				; check if we have fully looped
				jne			.loop				; if not, go check again

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword PMMAlloc32bitMem(void) -- Allocate a frame in 32-bit accessible (<4GB) memory
;----------------------------------------------------------------------------------------------

				global		PMMAllocUpperMem

PMMAlloc32bitMem:
				push		rbp					; create a new stack frame
				mov			rbp,rsp
				push		rbx					; we will modify rbx
				push		rcx					; we will modify rcx
				push		rdx					; we will modify rdx
				push		rsi					; save rsi
				push		r13					; save r13
				push		r14					; save r14
				push		r15					; we will modify r15
				pushfq
				cli								; please don't interrupt me!

				mov			rbx,qword pmm32Index; get the address of the var
				mov			r13,rbx				; save the address of the var
				mov			r15,[rbx]			; get the starting value
				mov			r14,r15				; we also need a working value

				mov			rbx,qword PMMBitMap	; get the bitmap address

.loop:
				mov			rax,r14				; get the working value
				shl			rax,8				; convert the value to qwords

				mov			rcx,[rbx+rax]		; get the bitmap qword
				cmp			rcx,0				; is the memory fully booked?
				jne			AllocCommonEnd.found; if some space, go get it

				inc			r14					; continue our search
				cmp			r14,qword PMM32BIT	; are we at the end of the list?
				jb			.chkDone			; if not at last byte, go chk is checked all

				mov			r14,qword PMMLOQWORDS	; start over at 1MB

.chkDone:
				cmp			r14,r15				; check if we have fully looped
				jne			.loop				; if not, go check again

;==============================================================================================

;----------------------------------------------------------------------------------------------
; AllocCommonEnd -- This is a label for a function in process.  It will be a common ending to
;                   both the PMMAllocUpperMem and PMMAllocLowerMem functions to reduce code
;                   duplicaiton.
;----------------------------------------------------------------------------------------------

AllocCommonEnd:
.noneFound:											; if we reach this point, no mem is available
				mov			rax,qword 0xffffffffffffffff	; set the return to -1
				jmp			AllocCommonEnd.out

;----------------------------------------------------------------------------------------------
; let's make sure we know what we know:
;  * rbx holds the address of the PMMBitMap
;  * rcx holds the bitmap we found to have a free frame
;  * r14 holds the qword offset for the bitmap; this becomes the bits 63-18 of the frame
;
; we need to determine the free block bit which will become bits 17-12 of the frame; and
; remember that since we are 4K frame aligned, bits 11-0 will be 0.
;----------------------------------------------------------------------------------------------

.found:											; if we get here, we found a frame to use
				mov			rbx,r13				; get the address of the var to store index
				mov			qword [rbx],r14		; store the index

				mov			rax,rcx				; move the bitmap to rax
				xor			rcx,rcx				; start at the lowest mem bit

.loop2:
				mov			rdx,1				; set a bit to check
				shl			rdx,cl				; shift the bit to the proper location
				test		rax,rdx				; check the bit
				jnz			.bitFound			; we founf the proper bit; exit loop

				add			rcx,1				; move to the next bit
				cmp			rcx,64				; have we checked them all?
				jae			.noneFound			; if we exhaust our options, exit with -1

				jmp			.loop2				; loop some more

.bitFound:
;----------------------------------------------------------------------------------------------
; now, we know the following:
;   * rbx holds the address of the PMMBitMap
;   * rax holds the bitmap we found to have a free frame (which we don't need anymore)
;   * r14 holds the qword offset for the bitmap; this becomes the bits 63-18 of the frame
;   * rcx holds the bit number for the addr; this becomes bits 17-12 of the frame
;
; now we just need to assemble the final address, and mark the bit as used
;----------------------------------------------------------------------------------------------

				shl			r14,6				; assemble in r14; make room for the bit#
				or			r14,rcx				; mask in the bit number
				shl			r14,12				; now we have the proper address in r14

				push		r14					; push it on the stack for a parm
				call		PMMSetBitUsed		; set the bit as used
				pop			rax					; set the return value as well

.out:
				popfq
				pop			r15					; restore r15
				pop			r14					; restore r14
				pop			r13					; restore r13
				pop			rsi					; restore rsi
				pop			rdx					; restore rdx
				pop			rcx					; restore rcx
				pop			rbx					; restore rbx
				pop			rbp
				ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword PMMAllocMem(void) -- Allocate memory.  This function will first look for memory in
;                            the upper memory section.  If that fails, then it will look for
;                            memory in the lower memory section.  If the allocation fails,
;                            return -1 for the frame
;----------------------------------------------------------------------------------------------

				global		PMMAllocMem

PMMAllocMem:
				push		rbp					; create a new stack frame
				mov			rbp,rsp

				call		PMMAllocUpperMem	; try to get a page of upper memory
				cmp			rax,qword 0xffffffffffffffff	; did we get a frame?
				jne			.out				; we got a frame, exit

				call		PMMAllocLowerMem	; try to get a page of lower memory
												; the return value falls through
.out:
				pop			rbp
				ret

;==============================================================================================

				global		PMMPrintMap

PMMPrintMap:
				push		rbp
				mov			rbp,rsp
				push		rbx
				push		rcx
				push		rdx
				push		rsi

				call		TextClear

				mov			rsi,qword PMMBitMap
				mov			rcx,(80*25)-1

.loop:
				xor			rbx,rbx
				xor			rax,rax
				xor			rdx,rdx

				mov			rax,qword [rsi]

.chk:
				cmp			rax,qword 0
				je			.zero

				mov			rbx,qword 0xffffffffffffffff
				cmp			rax,rbx
				je			.one

				push		qword '-'
				jmp			.put

.zero:
				push		qword '0'
				jmp			.put

.one:
				push		qword '1'

.put:
				call		TextPutChar
				add			rsp,8

				dec			rcx
				add			rsi,8
				cmp			rcx,0
				jne			.loop

				pop			rsi
				pop			rdx
				pop			rcx
				pop			rbx
				pop			rbp
				ret
