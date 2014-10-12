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
; the .bss section here contains the memory reservation for the page allocation bitmap
;==============================================================================================

				section		.bss
				align		0x1000

PMMQWORDS		equ			16384					; that's 128K

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
; void PMMSetBitFree(uint64 addr) -- Mark a page as free by setting its flag to be a '1'
;----------------------------------------------------------------------------------------------

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
; void PMMSetBitUsed(uint64 addr) -- Mark a page as used by setting its flag to be a '0'
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
				push		r15					; assume we will modify rbx

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
				mov			r15,rdi				; save this value
				call		PMMSetBitFree		; call the function

				add			rdi,0x1000			; move to the next page
				sub			rcx,1				; next iteration
				cmp			rcx,0				; are we done?
				je			.out				; if so, leave the loop

				jmp			.adjusted

.out:
				pop			r15					; restore the fields
				pop			rdi					; restore the fields
				pop			rcx					; restore the fields
				pop			rbx					; restore the fields
				pop			rbp
				ret

;==============================================================================================

				global		PMMMarkBlockUsed

PMMMarkBlockUsed:
				push		rbp					; create a new stack frame
				mov			rbp,rsp
				push		rbx					; assume we will modify rbx
				push		rcx					; assume we will modify rbx
				push		rdi					; assume we will modify rbx
				push		r15					; assume we will modify rbx

				mov			rax,qword [rbp+16]	; get the start parm
				mov			rdi,rax				; and store it in rdi

				mov			rcx,qword [rbp+24]	; get the size
				shr			rcx,12				; shift this down to be a count -- will
												; truncate a partial page at the end

				test		rcx,qword 0x0000000000000fff ; check for partial page at start
				jz			.adjusted			; skip the adjustments

				and			rcx,qword 0xfffffffffffff000	; Align to page
				add			rcx,0x1000			; step it up to fill last page

.adjusted:
				and			rdi,qword 0xfffffffffffff000	; truncate to a page boundary

				mov			r15,rdi				; save this value
				call		PMMSetBitUsed		; call the function

				add			rdi,0x1000			; move to the next page
				sub			rcx,1				; next iteration
				cmp			rcx,0				; are we done?
				je			.out				; if so, leave the loop

				jmp			.adjusted

.out:
				pop			r15					; restore the fields
				pop			rdi					; restore the fields
				pop			rcx					; restore the fields
				pop			rbx					; restore the fields
				pop			rbp
				ret

;==============================================================================================

				section		.data

logging			db			'    Logging page ',0
asFree			db			' as free.',13,0
