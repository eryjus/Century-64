;==============================================================================================
;
; kheap.s
;
; This file contains the functions and structures needed to manage a heap of shared memory
; specifically for the kernel processes.
;
; The basis for the design is lifted from Century32 (a 32-bit Hobby OS) and recoded from the
; ground up in 64-bit assembly.
;
; There are several structures that are used and maintained with the heap management.  The
; heap structure itself is nothing more than a doubly linked list of free blocks of memory.
; This linked list is also ordered based on the size of the free block of memory.  Pointers
; are setup in the heap structure to point to blocks of certain sizes in an attempt to speed
; up the allocation and deallocation process.  These pointers are at:
; * the beginning of the heap (of course)
; * >= 512 bytes
; * >= 1K bytes
; * >= 4K bytes
; * >= 16K bytes
;
; When a block of memory is requested, the size if first increased to cover the size of the
; header and footer as well as adjusted up to the allocation alignment.  So, if 1 byte is
; requested (unlikely, but great for illustration purposes), the size is increased by
; the size of the header (KHeapHdr_size), the size of the footer (KHeapFtr_size), and then
; aligned to the next 8 byte boundary up.  Note that care has been taken to make sure that
; the size of the KHeapHdr and KHeapFtr structures are 8-byte aligned as well.  With the
; header at 24 bytes and the footer at 16 bytes (40 bytes total) the request will actually
; allocate 48 bytes (24 header, 1 byte requested, 7 bytes alignment, 16 bytes footer).
;
; In addition, when the OrderedList is searched for the "best fit" (that is the class of
; algorithm used here), if the adjusted request is >= 16K, then the search starts at the
; 16K pointer; >= 4K but < 16K, then the search starts at the 4K pointer; >= 1K but < 4K,
; then the search starts at the 1K pointer; >= 512 bytes but < 1K, then the search starts
; at the 512 bytes pointer; and, all other searches < 512 bytes are stated at the beginning.
;
; Note that if there are no memory blocks < 512 bytes, but blocks >= 512 bytes, then the
; beginning of the OrderedList will point to the first block no matter the size.  The
; rationale for this is simple: a larger block can always be split to fulfill a request.
;
; On the other hand, if there are no blocks >= 16K bytes is size, then the >= 16K pointer
; will be NULL.  Again, the rationale is simple: we cannot add up blocks to make a 16K
; block, so other measures need to be taken (create more heap memory or return failure).
;
; ** NOTE **:
; An important assumption in this implementation is as follows: No requests to the kernel heap
; manager will need to be page aligned.  All requests that need to be page aligned will go
; through the Virtual Memory Manager and will be whole pages.
;
; The following functions are published in this source:
;	qword kmalloc(qword size);
;	void kfree(qword block);
;	void HeapInit(void);
;
; The following functions are internal to the source file:
;	void AddToList(qword Entry);
;	qword FindHole(qword AdjustedSize);
;	qword MergeLeft(qword blockHdr);
;	qword MergeRight(qword blockHdr);
;	qword NewListEntry(qword HdrAddr, qword AddIt);
;	void ReleaseEntry(qword Entry);
;	void RemoveFromList(qword Entry);
;   qword SplitBlock(qword Entry, qword Size);
;	void kHeapError(qword hdr, qword msg);
;
;    Date     Tracker  Pgmr  Description
; ----------  -------  ----  ------------------------------------------------------------------
; 2014/10/21  Initial  ADCL  Initial version
;
;==============================================================================================

%define		__KHEAP_S__
%include	'private.inc'

;==============================================================================================
; In this first section (before we get into any real data or code), we will define some
; constants and suce to make out coding easier.
;==============================================================================================

ALLOC_MULT		equ		8
ALLOC_MIN_BLK	equ		64
ALLOC_MIN		equ		(KHeapHdr_size+KHeapFtr_size+ALLOC_MIN_BLK+ALLOC_MULT)&~(ALLOC_MULT-1)

KHEAP_MAGIC		equ		0xbab6badc
FIXED_ORD_LIST	equ		1024			; we will initially set aside this many Ordered List
										; entries for use before we get our Heap Manager
										; fully operational
HEAP_START		equ		0xffff800000000000	; this is the starting point for the kernel heap

HEAP_PTR1		equ		512				; anything >= 512 bytes
HEAP_PTR2		equ		1024			; anything >= 1K bytes
HEAP_PTR3		equ		4*1024			; anything >= 4K bytes
HEAP_PTR4		equ		16*1024			; anything >= 16K bytes

;----------------------------------------------------------------------------------------------
; This structure is the heap manager structure, and will be used thoughout this source file.
;
; Note that this is my first time with a struc in NASM, so I might abandon this and go with
; some other form of coding.  It all depends on how well I can adapt to the construct.  For an
; example of something that did not work, compare my coding to the ABI standard --- couldn't
; remember what was preserved and what was trashed!
;----------------------------------------------------------------------------------------------

struc KHeap
	.heapBegin	resq	1				; the start of the ordered list -- theoretically 1 byte
	.heap512	resq	1				; the start of blocks >= 512 bytes
	.heap1K		resq	1				; the start of blocks >= 1K bytes
	.heap4K		resq	1				; the start of blocks >= 4K bytes
	.heap16K	resq	1				; the start of blocks >= 16K bytes
	.strAddr	resq	1				; the start address of the heap memory
	.endAddr	resq	1				; the end address of the heap memory
	.maxAddr	resq	1				; the maximum address of the possible heap memory
endstruc

;----------------------------------------------------------------------------------------------
; This structure is a doubly linked list of ordered free memory blocks
;----------------------------------------------------------------------------------------------

struc OrderedList
	.block		resq	1				; this is the address of a block of memory
	.size		resq	1				; this is the number of bytes of memory
	.prev		resq	1				; the address of the previous OrderedList entry
	.next		resq	1				; the address of the next OrderedList entry
endstruc

;----------------------------------------------------------------------------------------------
; This structure is the heap block header, which will appear before any allocated memory block
; and in all free memory blocks.
;----------------------------------------------------------------------------------------------

struc KHeapHdr
	.magic		resd	1				; this is the location of the magic number
	.hole		resd	1				; this is a boolean - is hole?
	.entry		resq	1				; this is the address of the ordered list entry, which
										; is only used if the block is a hole
	.size		resq	1				; this is the size of the block, incl hdr and ftr
endstruc

;----------------------------------------------------------------------------------------------
; This structure is the heap block footer.  At first I did not think I needed one of these, but
; if I am going to be able to find the previuos block header (i.e. MergeLeft()), then I need
; some way to calculate it based on data right before this header.  Therefore, I need the
; footer.
;----------------------------------------------------------------------------------------------

struc KHeapFtr
	.magic		resd	1				; this is the magic number
	.fill		resd	1				; this is unused, but to keep the structure aligned
	.hdr		resq	1				; pointer back to the header
endstruc


;==============================================================================================
; This is the .bss section.  It contains uninitialized data.
;==============================================================================================

				section		.bss

kHeap:			resb		KHeap_size
.end
OrdList:		resb		OrderedList_size * FIXED_ORD_LIST
.end:

;==============================================================================================
; This is the read only data (.rodata) and will be included in the .text section at link
;==============================================================================================

				section		.rodata

NoEntriesLeft	db			'There are no OrderedList entries available in the table.',13
				db			' ** KILLING THE KERNEL **',13,0




kHeapErr1		db			'                               Kernel Heap Error',13,0
kHeapTxt		db			' kHeap      ',0
HdrTxt			db			'       Header   ',0
hBeginTxt		db			13,' .heapBegin ',0
hdrMagic		db			'       .magic   ',0
h512Txt			db			13,' .heap512   ',0
hdrHole			db			'       .hole    ',0
h1kTxt			db			13,' .heap1K    ',0
hdrEntry		db			'       .entry   ',0
h4kTxt			db			13,' .heap4K    ',0
hdrSize			db			'       .size    ',0
h16kTxt			db			13,' .heap16K   ',0
hStrTxt			db			13,' .strAddr   ',0
FtrTxt			db			'       Footer   ',0
hEndTxt			db			13,' .endAddr   ',0
ftrFill			db			'       .fill    ',0
hMaxTxt			db			13,' .maxAddr   ',0
ftrHdr			db			13,'                                        .hdr     ',0
OLHdg			db			13,13,' OrderedList Bounds                     Entry    ',0
OLStart			db			13,' .start     ',0
EntBlock		db			'      .block    ',0
OLEnd           db          13,' .end       ',0
EntSize         db          '      .size     ',0
EntPrev			db			13,'                                       .prev     ',0
EntNext			db			13,'                                       .next     ',0

freeNULL		db			'                    In kfree(), Trying to free a NULL pointer',0
freeAlign		db			'                  In kfree(), Trying to free an unaligned block',0
freeHdrRange	db			'                In kfree(), Header address not in heap address range',0
freeFtrRange	db			'                In kfree(), Footer address not in heap address range',0
freeHdrMagic	db			'                   In kfree(), Header magic number is not valid',0
freeFtrMagic	db			'                   In kfree(), Footer magic number is not valid',0
freeHdrFtr		db			'               In kfree(), Header address is after the footer address',0
freeHole		db			'                      In kfree(), Freed memory is not a hole',0
freeHdr			db			'              In kfree(), Pointer in footer does not match header addr',0
freeEntry		db			'                      In kfree(), Entry in Header is not NULL',0

add2ListNULL	db			'                       In AddToList(), Entry pointer is NULL',0
add2ListBadEnt	db			'                In AddToList(), Entry address is not in table bounds',0
add2ListBadPtr	db			'                    In AddToList(), Entry is already in the list',0

;==============================================================================================
; This is the code section of the source file.  It will be part of the kernel.
;==============================================================================================

				section		.text
				bits		64

;----------------------------------------------------------------------------------------------
; qword kmalloc(qword size) -- This function will allocate a block of memory from the heap
;                              containing at least the requested size.  A special case
;                              requirement for UDI that will be handled here is that if a
;                              request of size 0 is made, the function must return NULL.
;                              All requests should be in multiples of ALLOC_MULT, and if a
;                              request is not of that multiple, it will be increased to a
;                              multiple of ALLOC_MULT.
;
; In addition, this is a non-blocking memory request.  A request is either granted immediately
; or the function returns will NULL as the result.  It will not wait for memory to be kfreed.
; No provision is made to increate kHeap.endAddr closer to kHeap.maxAddr.  As a result, there
; is a very real possibiltiy that we will run out of kernel heap memory.
;
; Finally, though noted elsewhere, it should also be noted here that the OrderedList structures
; are limited and need to be eliminated.  This task is saved for a future enhancement to the
; kernel heap manager.
;----------------------------------------------------------------------------------------------

				global		kmalloc

kmalloc:
				push		rbp						; save the caller's frame
				mov.q		rbp,rsp					; create our own frame
				push		rbx						; save rbx -- our entry
				push		rcx						; save rcx -- number of bytes requested
				push		rsi						; save rsi -- header pointer
				push		r14						; save r14 -- footer pointer
				pushfq								; save the flags

;----------------------------------------------------------------------------------------------
; initialize and perform some sanity checking
;----------------------------------------------------------------------------------------------

				cli									; no interrupts -- add spinlock in future
				xor.q		rax,rax					; assume we will return 0

				mov.q		rcx,[rbp+16]			; get the number of bytes requested
				cmp.q		rcx,0					; special case: requested 0?
				je			.out					; exit; NULL return value already set

				cmp.q		rcx,ALLOC_MIN_BLK		; are we allocing the minimum size?
				jae			.chkMult				; yes, proceed to the next check

				mov.q		rcx,ALLOC_MIN_BLK		; no, so allocate the minimum
				jmp			.goodSize				; we know this is already multiple aligned

.chkMult:		test.q		rcx,ALLOC_MULT-1		; are we allocing a multiple of ALLOC_MULT
				jz			.goodSize				; if we are good, skip realignment

				add.q		rcx,ALLOC_MULT			; increase the size 1 multiple
				and.q		rcx,~(ALLOC_MULT-1)		; and truncate its lower bits

;----------------------------------------------------------------------------------------------
; here we are guaranteed to have a ligit request that is a proper allocation multiple.  Now
; add in the size of the header and footer.
;----------------------------------------------------------------------------------------------

.goodSize:		add.q		rcx,(KHeapHdr_size+KHeapFtr_size)	; add hdr&ftr sizes to request

;----------------------------------------------------------------------------------------------
; now, let's try to find a hole the proper size
;----------------------------------------------------------------------------------------------

				push		rcx						; push the size as parm
				call		FindHole				; see if we can find a hole the right size
				add.q		rsp,8					; clean up the stack

				cmp.q	 	rax,0					; did we get something?
				je			.out					; if NULL, we did not; exit returning NULL

;----------------------------------------------------------------------------------------------
; we have a block that is at least big enough for our request, do we need to split it?
;----------------------------------------------------------------------------------------------

				mov.q		rbx,rax					; save our entry; rax will be used for calc
				mov.q		rax,rcx					; get our adjusted size
				mov.q		rsi,[rbx+OrderedList.block]	; get the block header address
				sub.q		rax,[rbx+OrderedList.size]	; determine the difference in sizes
				cmp.q		rax,ALLOC_MIN_BLK		; is the leftover size enough to split blk?
				jbe			.noSplit				; if small enough, we will not split it

;----------------------------------------------------------------------------------------------
; At this point, we have a block that needs to be split into two blocks
;----------------------------------------------------------------------------------------------

.Split:
				push		rcx						; we need our adjusted size as parm
				push		rbx						; we need our Entry as parm
				call		SplitBlock				; split the block
				add.q		rsp,16					; clean up the stack
				jmp			.polish					; go adjust the pointer and return

;----------------------------------------------------------------------------------------------
; We now have a properly sized block; need some housekeeping and return
;----------------------------------------------------------------------------------------------

.noSplit:
				mov.q		r14,rsi					; start calcing the footer address
				add.q		r14,[rsi+KHeapHdr.size]	; move to the end of the block
				sub.q		r14,KHeapFtr_size		; back out the footer to get address

				push		rbx						; need entry address
				call		ReleaseEntry			; release the entry from the list
				add.q		rsp,8					; clean up the stack

				mov.d		[rsi+KHeapHdr.hole],0	; this is not a hole anymore

;----------------------------------------------------------------------------------------------
; rax now holds the proerly sized block; polish up the pointer and return
;----------------------------------------------------------------------------------------------

.polish:
				add.q		rax,KHeapHdr_size		; adjust past the header

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
				popfq								; restore the flags & interrupts
				pop			r14						; restore r14
				pop			rsi						; restore rsi
				pop			rcx						; restore rcx
				pop			rbx						; restore rbx
				pop			rbp						; restore caller's frame
				ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void kfree(qword block) -- free a block of memory back to the kernel heap.
;
; There are a lot of things that can go wrong when trying to free memory, so there are lots of
; sanity checks that need to pass before an attempt is made to actually free the memory.  Since
; this is kernel heap, any sanity check that fails will throw a kHeapError.  The justification
; for this is simple: we are in control and should know what we are doing with the heap.
;
; The sanity checks are these:
; 1.  the block of memory is not NULL
; 2.  is the block properly aligned?
; 3.  the block of memory (at header) is >= kHeap.strAddr && < kHeap.endAddr
; 4.  the block has a valid header (checking magic number)
; 5.  the footer addr is > header addr
; 6.  the end of the footer is <= kHeap.endAddr && > kHeap.strAddr
; 7.  we can find a footer with a proper magic number
; 8.  the hole is 0
; 9.  the kHeapFtr.hdr points back to the header
; 10.  the kHeapHdr.entry is NULL
;----------------------------------------------------------------------------------------------

				global		kfree

kfree:
				push		rbp						; save caller's frame
				mov.q		rbp,rsp					; create our own frame
				push		rbx						; save rbx -- the pointer to the block
				push		rsi						; save rsi -- the pointer to the header
				push		r14						; save r14 -- the pointer to the footer
				pushfq								; save the flags
				cli									; and no interrupts please

;----------------------------------------------------------------------------------------------
; start with the sanity checks -- the first one is that the block is not NULL
;----------------------------------------------------------------------------------------------

.chk1:			mov.q		rbx,[rbp+16]			; get the memory parameter
				cmp.q		rbx,0					; is the address NULL?
				jne			.chk2					; if not, we can go on

				mov.q		rax,freeNULL			; get the address of the error message
				push		rax						; push it on the stack
				push		rbx						; push the address (which is NULL)
				call		kHeapError				; generate the error screen -- does not ret

;----------------------------------------------------------------------------------------------
; sanity check 2 -- is the block properly aligned?
;----------------------------------------------------------------------------------------------

.chk2:			test.q		 rbx,ALLOC_MULT-1		; are the low bits set?
				jz			.chk3					; if not, we can go on

				mov.q		rax,freeAlign			; get the address of the error message
				push		rax						; push it on the stack
				push		rbx						; push the address (which is NULL)
				call		kHeapError				; generate the error screen -- does not ret

;----------------------------------------------------------------------------------------------
; sanity check 3 -- is the header in range?
;----------------------------------------------------------------------------------------------

.chk3:			mov.q		rsi,rbx					; get the header start address
				sub.q		rsi,KHeapHdr_size		; and offset it back to start of hdr addr

				mov.q 		rax,kHeap				; get the heap structure address
				mov.q		rax,[rax+KHeap.strAddr]	; and offset it to the strAddr member
				cmp.q		rsi,rax					; is the address after the start?
				jb			.chk3Err				; if less, we have an error

				mov.q 		rax,kHeap				; get the heap structure address
				mov.q		rax,[rax+KHeap.endAddr]	; and offset it to the endAddr member
				cmp.q		rsi,rax					; is the address before the end?
				jb			.chk4					; if below, we can continue

.chk3Err:		mov.q		rax,freeHdrRange		; get the address of the error message
				push		rax						; push it on the stack
				push		rbx						; push the address of the hdr
				call		kHeapError				; generate the error screen -- does not ret

;----------------------------------------------------------------------------------------------
; sanity check 4 -- header magic number good?
;----------------------------------------------------------------------------------------------

.chk4:			mov.q		rax,KHEAP_MAGIC			; get the magic number
				cmp.q		rax,[rsi+KHeapHdr.magic]	; is the magic number good?
				je			.chk5					; if equal, we can continue

				mov.q		rax,freeHdrMagic		; get the address of the error message
				push		rax						; push it on the stack
				push		rbx						; push the address (which is NULL)
				call		kHeapError				; generate the error screen -- does not ret

;----------------------------------------------------------------------------------------------
; sanity check 5 -- is footer after header?
;----------------------------------------------------------------------------------------------

.chk5:			mov.q		r14,rsi					; start to calc the footer address
				add.q		r14,[rsi+KHeapHdr.size]	; move the the end of the block
				sub.q		r14,KHeapFtr_size		; and adjust back for the footer addr

				cmp.q		r14,rsi					; compare the 2 addresses
				ja			.chk6					; if footer is after header, we continue

				mov.q		rax,freeHdrFtr			; get the address of the error message
				push		rax						; push it on the stack
				push		rbx						; push the address (which is NULL)
				call		kHeapError				; generate the error screen -- does not ret

;----------------------------------------------------------------------------------------------
; sanity check 6 -- is the footer in range?
;----------------------------------------------------------------------------------------------

.chk6:			mov.q 		rax,kHeap				; get the heap structure address
				mov.q		rax,[rax+KHeap.strAddr]	; and offset it to the strAddr member
				cmp.q		r14,rax					; is the address after the start?
				jb			.chk6Err				; if less, we have an error

				mov.q 		rax,kHeap				; get the heap structure address
				mov.q		rax,[rax+KHeap.endAddr]	; and offset it to the endAddr member
				cmp.q		r14,rax					; is the address before the end?
				jb			.chk7					; if below, we can continue

.chk6Err:		mov.q		rax,freeFtrRange		; get the address of the error message
				push		rax						; push it on the stack
				push		rbx						; push the address of the hdr
				call		kHeapError				; generate the error screen -- does not ret

;----------------------------------------------------------------------------------------------
; sanity check 7 -- footer has magic number?
;----------------------------------------------------------------------------------------------

.chk7:			mov.q		rax,KHEAP_MAGIC			; get the magic number
				cmp.q		rax,[r14+KHeapFtr.magic]	; is the magic number good?
				je			.chk8					; if equal, we can continue

				mov.q		rax,freeFtrMagic		; get the address of the error message
				push		rax						; push it on the stack
				push		rbx						; push the address (which is NULL)
				call		kHeapError				; generate the error screen -- does not ret

;----------------------------------------------------------------------------------------------
; sanity check 8 -- is the hole 0?
;----------------------------------------------------------------------------------------------

.chk8:			xor.q		rax,rax					; clear rax
				mov.d		eax,[rsi+KHeapHdr.hole]	; get the hole flag
				cmp.q		rax,0					; is the falg 0
				je			.chk9					; if so, we can continue

				mov.q		rax,freeHole			; get the address of the error message
				push		rax						; push it on the stack
				push		rbx						; push the address (which is NULL)
				call		kHeapError				; generate the error screen -- does not ret

;----------------------------------------------------------------------------------------------
; sanity check 9 -- footer header pointer match header address?
;----------------------------------------------------------------------------------------------

.chk9:			mov.q		rax,[r14+KHeapFtr.hdr]	; get the hdr address
				cmp.q		rsi,rax					; are they the same?
				je			.chk10					; if they are, go to the next check

				mov.q		rax,freeHdr				; get the address of the error message
				push		rax						; push it on the stack
				push		rbx						; push the address (which is NULL)
				call		kHeapError				; generate the error screen -- does not ret

;----------------------------------------------------------------------------------------------
; sanity check 10 -- entry is NULL
;----------------------------------------------------------------------------------------------

.chk10:			mov.q		rax,[rsi+KHeapHdr.entry]	; get the entry address
				cmp.q		rax,0					; is the value 0
				je			.goodMem				; if 0, we can continue

				mov.q		rax,freeEntry			; get the address of the error message
				push		rax						; push it on the stack
				push		rbx						; push the address (which is NULL)
				call		kHeapError				; generate the error screen -- does not ret

;----------------------------------------------------------------------------------------------
; At this point, we have a good block of memory to free.  Now, let's go about freeing it back
; to the kernel heap.
;----------------------------------------------------------------------------------------------

.goodMem:		push		rsi						; push the header on the stack
				call		MergeRight				; merge it with the right block, if free
				call		MergeLeft				; and merge it with the left block if free
				add.q		rsp,8					; clean up the stack

;----------------------------------------------------------------------------------------------
; rax, if <> 0, contains the address of the OrderedList entry.  if == 0 we will need the
; address from the current header.
;----------------------------------------------------------------------------------------------

				cmp.q		rax,0					; is the entry 0?
				je			.getEntry				; if so, go get an entry address

				mov.q		rsi,[rax+OrderedList.block]	; set the header address
				jmp			.addToList				; and go add it to the list

.getEntry:		mov.q		rax,[rsi+KHeapHdr.entry]	; set the entry address

;----------------------------------------------------------------------------------------------
; at this point, we have a good block, possibly bigger.  If rax is 0, then we need to create
; a new list entry for the block; if eax <> 0 then we just need to re-insert the entry.
;----------------------------------------------------------------------------------------------

.addToList:		mov.d		[rsi+KHeapHdr.hole],1	; make this block a hole

				cmp.q		rax,0					; is the entry address 0?
				je			.newEntry				; if 0, then we need a new entry

				push		rax						; push the entry address onto the stack
				call		AddToList				; and add it to the list
				add.q		rsp,8					; clean up the stack
				jmp			.out

.newEntry:		push		rsi						; push the header address onto the stack
				call		NewListEntry			; and add it to the list
				add.q		rsp,8					; clean up the stack

;----------------------------------------------------------------------------------------------
; clean  up and exit
;----------------------------------------------------------------------------------------------

.out:			popfq								; restore flags
				pop			r14						; restore r14
				pop			rsi						; restore rsi
				pop			rbx						; restore rbx
				pop			rbp						; restore caller's frame
				ret


;==============================================================================================

;----------------------------------------------------------------------------------------------
; void HeapInit(void) -- Initialize the heap structures
;----------------------------------------------------------------------------------------------

				global		HeapInit

HeapInit:		push		rbp						; save caller's frame
				mov.q		rbp,rsp					; create our own frame
				push		rcx						; save rcx -- used for block size
				push		rsi						; save rsi -- used for header address
				push		r14						; save r14 -- used for footer address

				mov.q		rax,kHeap				; get the heap struct address
				lea.q		rax,[rax+KHeap.strAddr]	; get the address of the start addr mbr
				mov.q		rcx,bssEnd				; get the ending address
				mov.q		[rax],rcx			; the starting heap address

				mov.q		rax,kHeap				; get the heap struct address
				lea.q		rax,[rax+KHeap.endAddr]	; get the address of the end addr mbr
				add.q		rcx,0x100000			; set up for 1 MB heap
				and.q		rcx,0xfffffffffff00000	; align back to under 1MB
				mov.q		[rax],rcx				; store the ending address

				mov.q		rax,kHeap				; get the heap struct address
				lea.q		rax,[rax+KHeap.maxAddr]	; get the address of the max addr mbr
				mov.q		[rax],0xffffffffcfffffff	; the theoretical max of heap

				mov.q		rax,kHeap				; get the heap struct address
				mov.q		rcx,[rax+KHeap.endAddr]	; get the heap ending address
				sub.q		rcx,[rax+KHeap.strAddr]	; this is the size of the block

				mov.q		r14,[rax+KHeap.endAddr]	; get the footer address (calc)
				sub.q		r14,KHeapFtr_size		; r14 now holds the footer address

				mov.q		rsi,[rax+KHeap.strAddr]	; get the address of the hdr

				mov.d		[rsi+KHeapHdr.magic],KHEAP_MAGIC	; set the magic number
				mov.d		[rsi+KHeapHdr.hole],0	; pretend this is allocated
				mov.q		[rsi+KHeapHdr.entry],0	; entry is 0
				mov.q		[rsi+KHeapHdr.size],rcx	; set the size

				mov.d		[r14+KHeapFtr.magic],KHEAP_MAGIC	; set the magic number
				mov.d		[r14+KHeapFtr.fill],0	; set the fill value
				mov.q		[r14+KHeapFtr.hdr],rsi	; set the header pointer

				mov.q		rbx,OrdList				; get the orderedList array
				xor.q		rcx,rcx					; start counting at 0

.loop:			cmp.q		rcx,FIXED_ORD_LIST		; have we init'd all of them?
				jae			.free					; if so, exit the loop

				mov.q		[rbx+OrderedList.block],-1	; set the block to -1 to show avail
				inc			rcx						; increment our counter
				add.q		rbx,OrderedList_size	; move to the next element

				jmp			.loop					; iterate

.free:			add.q		rsi,KHeapHdr_size		; adjust for the header
				push		rsi						; push the block address onto stack
				call		kfree					; 'trick' the system to free the block
				add.q		rsp,8					; clean up the stack

				pop			r14						; restore r14
				pop			rsi						; restore rsi
				pop			rcx						; restore rcx
				pop			rbp						; restore caller's frame
				ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void AddToList(qword EntryAddr) -- Adds an entry (which is already setup) to the ordered list
;                                    of free blocks.  This is a quite complicated process
;                                    (based on the other functions written to date, so the
;                                    process is outlined here first.
;
; First perform sone sanity checks:
; 1.  EntryAddr cannot be null; if it is, kill the kernel
; 2.  Bounds check EntryAddr in the table; if it is not in the table range, kill the kernel
; 3.  Check that the prev and next members of the OrderedList entry are null; if they are not,
;     kill the kernel
; The above checks are in place to prevent the kernel from working with invalid data.  Later,
; this will need to be changed to throw some kind of fault.
;
; We need to check the heap pointers to make sure they are not empty.. If they are handle it
; and exit.  This is a special case we need to be aware of.
;
; Next, we need to figure out from which heap pointer we will start searching from.  This is
; done by determining the size of the block and comparing it against our fixed pointer sizes.
; The result should tell us from where to start looking for the proper place to insert the
; entry.
;----------------------------------------------------------------------------------------------

;==============================================================================================

AddToList:
				push		rbp						; save the claler's stack frame
				mov.q		rbp,rsp					; create a new stack frame
				push		rbx						; save rbx
				push		rcx						; save rcx
				push		rsi						; save rsi
				push		rdi						; save rdi

				xor.q		rdi,rdi					; make sure rdi is 0

;----------------------------------------------------------------------------------------------
; Complete sanity check #1: make sure EntryAddr is not null
;----------------------------------------------------------------------------------------------

				mov.q		rax,[rbp+16]			; get the addr
				cmp.q		rax,0					; check if NULL
				je			.IsNull					; if so, we will report the error

;----------------------------------------------------------------------------------------------
; Complete sanity check #2: bounds check the array
;----------------------------------------------------------------------------------------------

				mov.q		rbx,OrdList				; get the address of the OrderedList
				cmp.q		rax,rbx					; compare against the start of the array
				jb			.BadAddr				; we have a bad address; report it

				mov.q		rbx,OrdList.end			; get the address of the end of the list
				cmp.q		rax,rbx					; compare against the end of the array
				jae			.BadAddr				; we have a bad address; report it

;----------------------------------------------------------------------------------------------
; Complete sanity check #3: make sure the Entry is not already "inserted"
;----------------------------------------------------------------------------------------------

				mov.q		rbx,rax					; move the address into the working reg
				mov.q		rax,[rbx+OrderedList.prev]	; get the prev field
				cmp.q		rax,0					; is the addr NULL
				jne			.BadPtr					; if not, report the error

				mov.q		rax,[rbx+OrderedList.next]	; get the next field
				cmp.q		rax,0					; if the addr NULL
				jne			.BadPtr					; if not, report the error

;----------------------------------------------------------------------------------------------
; Now, we get the size of the block.  We will assume we need to start at th beginning
;----------------------------------------------------------------------------------------------

				mov.q		rcx,[rbx+OrderedList.size]	; get the size
				mov.q		rax,kHeap					; get the address of the ptr
				mov.q		rsi,[rax+KHeap.heapBegin]	; get the pointer

;----------------------------------------------------------------------------------------------
; Check if the ordered list is empty -- this is a special case we need to handle
;----------------------------------------------------------------------------------------------

				cmp.q		rsi,0					; if this is empty, we have no list
				jne			.chkSize				; we have something, so continue

;----------------------------------------------------------------------------------------------
; We know the ordered list is empty, just make it right and leave; nothing else to do
;----------------------------------------------------------------------------------------------

				mov.q		rsi,kHeap				; get the address of the structure
				mov.q		[rsi+KHeap.heapBegin],rbx	; save the entry at the start

				cmp.q		rcx,HEAP_PTR1			; compare to 512 bytes
				jb			.out					; if not that big, exit
				mov.q		[rsi+KHeap.heap512],rbx	; save the entry for >= 512 bytes

				cmp.q		rcx,HEAP_PTR2			; compare to 1K bytes
				jb			.out					; if not that big exit
				mov.q		[rsi+KHeap.heap1K],rbx	; save the entry for >= 1K bytes

				cmp.q		rcx,HEAP_PTR3			; compare to 4K bytes
				jb			.out					; if not that big exit
				mov.q		[rsi+KHeap.heap4K],rbx	; save the entry for >= 4K bytes

				cmp.q		rcx,HEAP_PTR4			; compare to 16K bytes
				jb			.out					; if not that big exit
				mov.q		[rsi+KHeap.heap16K],rbx	; save that entry for >= 16K bytes

				jmp			.out					; go ahead and exit

;----------------------------------------------------------------------------------------------
; Check if we are looking for something >= 512 bytes; if so, adjust the pointer accordingly
;----------------------------------------------------------------------------------------------

.chkSize:
				cmp.q		rcx,HEAP_PTR1				; compare to 512
				jb			.search						; if less go do the search
				mov.q		rsi,[rax+KHeap.heap512]		; get the pointer

				cmp.q		rcx,HEAP_PTR2				; compare to 1K
				jb			.search						; if less go do the search
				mov.q		rsi,[rax+KHeap.heap1K]		; get the pointer

				cmp.q		rcx,HEAP_PTR3				; compare to 4K
				jb			.search						; if less go do the search
				mov.q		rsi,[rax+KHeap.heap4K]		; get the pointer

				cmp.q		rcx,HEAP_PTR4				; compare to 16K
				jb			.search						; if less go do the search
				mov.q		rsi,[rax+KHeap.heap16K]		; get the pointer

;----------------------------------------------------------------------------------------------
; At this point, we can do an exhaustive search until we find a block bigger than or equal to
; the size we want.  rsi contains the OrderedList address we are working with.
;----------------------------------------------------------------------------------------------

.search:
				cmp.q		rsi,0						; reached end of list?
				je			.addEnd						; handle the special case to add to end

				mov.q		rdi,rsi						; save value, we will use later
				cmp.q		[rsi+OrderedList.size],rcx	; compare the sizes
				jae			.foundLoc					; if >=, we found where to put block

				mov.q		rsi,[rsi+OrderedList.next]	; get the next address
				jmp			.search						; continue to search

;----------------------------------------------------------------------------------------------
; This is a special case where we will add the block to the end of the OrderedList
;----------------------------------------------------------------------------------------------

.addEnd:
				cmp.q		rdi,0						; have we assigned a value?
				je			.addEnd2					; if not, jump over next stmt

				mov.q		[rdi+OrderedList.next],rbx	; store the entry at the end

.addEnd2:
				mov.q		[rbx+OrderedList.prev],rdi	; might be NULL
				mov.q		[rbx+OrderedList.next],0	; Set to NULL; it is the end

				jmp			.fixupNull					; go to fixup the heap ptrs

;----------------------------------------------------------------------------------------------
; Found the location, insert before rsi entry; rsi is guaranteed <> NULL
;----------------------------------------------------------------------------------------------

.foundLoc:
				mov.q		[rbx+OrderedList.next],rsi	; the next entry is the entry we found
				mov.q		rax,[rsi+OrderedList.prev]	; get the previous ptr (might be NULL)
				mov.q		[rbx+OrderedList.prev],rax	; and set the prev entry equal to this

				mov.q		rax,[rbx+OrderedList.prev]	; get the address of prev
				cmp.q		rax,0						; compare to 0
				je			.foundLoc2					; if NULL, skip next part

				lea.q		rax,[rax+OrderedList.next]	; get the prev entry next addr
				mov.q		[rax],rbx					; now set the address to be our entry

.foundLoc2:
				mov.q		rax,[rbx+OrderedList.next]	; get the address of prev
				cmp.q		rax,0						; compare to 0
				je			.fixupNull					; if NULL, skip next part

				lea.q		rax,[rax+OrderedList.prev]	; get the prev entry next addr
				mov.q		[rax],rbx					; now set the address to be our entry

;----------------------------------------------------------------------------------------------
; The last step is to make sure the optimized pointers are pointing properly.  Start by making
; sure that any null pointer is really supposed to be null.
;----------------------------------------------------------------------------------------------

.fixupNull:
				mov.q		rsi,kHeap					; get the address of the structure

				cmp.q		[rsi+KHeap.heap512],0		; compare to NULL
				jne			.fixupNull2					; if not NULL, go to the next check

				cmp.q		rcx,HEAP_PTR1				; Compare to 512
				jb			.fixupNull2					; if not >= 512, jump to next check

				mov.q		[rsi+KHeap.heap512],rbx		; set the 512 byte pointer

.fixupNull2:
				cmp.q		[rsi+KHeap.heap1K],0		; compare to NULL
				jne			.fixupNull3					; if not NULL, go to the next check

				cmp.q		rcx,HEAP_PTR2				; Compare to 1K bytes
				jb			.fixupNull3					; if not >= 1K bytes, jump to next check

				mov.q		[rsi+KHeap.heap1K],rbx		; set the 1K byte pointer

.fixupNull3:
				cmp.q		[rsi+KHeap.heap4K],0		; compare to NULL
				jne			.fixupNull4					; if not NULL, go to the next check

				cmp.q		rcx,HEAP_PTR3				; Compare to 4K bytes
				jb			.fixupNull4					; if not >= 4K bytes, jump to next chk

				mov.q		[rsi+KHeap.heap4K],rbx		; set the 4K byte pointer

.fixupNull4:
				cmp.q		[rsi+KHeap.heap16K],0		; compare to NULL
				jne			.fixup512					; if not NULL, go to the next check

				cmp.q		rcx,HEAP_PTR4				; Compare to 16K bytes
				jb			.fixup512					; if not >= 16K bytes, jump to next chk

				mov.q		[rsi+KHeap.heap16K],rbx		; set the 16K byte pointer

;----------------------------------------------------------------------------------------------
; Check the 512 byte pointer points to the first block that is >= 512 bytes.
;----------------------------------------------------------------------------------------------

.fixup512:
				mov.q		rax,[rsi+KHeap.heap512]		; get the addr of the pointer
				cmp.q		rax,0						; is the addr NULL?
				je			.fixup1K					; if null, we are done

				mov.q		rax,[rax+OrderedList.prev]	; get the previuos addr
				mov.q		rcx,rax						; save this in case we use it later
				cmp.q		rax,0						; is the addr NULL?
				je			.fixup1K					; if null, we are done

				mov.q		rax,[rax+OrderedList.size]	; get the size of the block
				cmp.q		rax,HEAP_PTR1				; is the size >= 512
				jb			.fixup1K					; if not >= 512, we are done

				mov.q		rbx,kHeap					; get the heap struct addr
				lea.q		rbx,[rbx+KHeap.heap512]		; get the address of the var
				mov.q		[rbx],rcx					; set the new pointer

;----------------------------------------------------------------------------------------------
; Check the 1K byte pointer points to the first block that is >= 1K bytes.
;----------------------------------------------------------------------------------------------

.fixup1K:
				mov.q		rax,[rsi+KHeap.heap1K]		; get the addr of the pointer
				cmp.q		rax,0						; is the addr NULL?
				je			.fixup4K					; if null, we are done

				mov.q		rax,[rax+OrderedList.prev]	; get the previuos addr
				mov.q		rcx,rax						; save this in case we use it later
				cmp.q		rax,0						; is the addr NULL?
				je			.fixup4K					; if null, we are done

				mov.q		rax,[rax+OrderedList.size]	; get the size of the block
				cmp.q		rax,HEAP_PTR2				; is the size >= 1K
				jb			.fixup4K					; if not >= 1K, we are done

				mov.q		rbx,kHeap					; get the heap struct addr
				lea.q		rbx,[rbx+KHeap.heap1K]		; get the address of the var
				mov.q		[rbx],rcx					; set the new pointer

;----------------------------------------------------------------------------------------------
; Check the 4K byte pointer points to the first block that is >= 4K bytes.
;----------------------------------------------------------------------------------------------

.fixup4K:
				mov.q		rax,[rsi+KHeap.heap4K]		; get the addr of the pointer
				cmp.q		rax,0						; is the addr NULL?
				je			.fixup16K					; if null, we are done

				mov.q		rax,[rax+OrderedList.prev]	; get the previuos addr
				mov.q		rcx,rax						; save this in case we use it later
				cmp.q		rax,0						; is the addr NULL?
				je			.fixup16K					; if null, we are done

				mov.q		rax,[rax+OrderedList.size]	; get the size of the block
				cmp.q		rax,HEAP_PTR3				; is the size >= 4K
				jb			.fixup16K					; if not >= 4K, we are done

				mov.q		rbx,kHeap					; get the heap struct addr
				lea.q		rbx,[rbx+KHeap.heap4K]		; get the address of the var
				mov.q		[rbx],rcx					; set the new pointer


;----------------------------------------------------------------------------------------------
; Check the 16K byte pointer points to the first block that is >= 16K bytes.
;----------------------------------------------------------------------------------------------

.fixup16K:
				mov.q		rax,[rsi+KHeap.heap16K]		; get the addr of the pointer
				cmp.q		rax,0						; is the addr NULL?
				je			.out						; if null, we are done

				mov.q		rax,[rax+OrderedList.prev]	; get the previuos addr
				mov.q		rcx,rax						; save this in case we use it later
				cmp.q		rax,0						; is the addr NULL?
				je			.out						; if null, we are done

				mov.q		rax,[rax+OrderedList.size]	; get the size of the block
				cmp.q		rax,HEAP_PTR4				; is the size >= 16K
				jb			.out						; if not >= 16K, we are done

				mov.q		rbx,kHeap					; get the heap struct addr
				lea.q		rbx,[rbx+KHeap.heap16K]		; get the address of the var
				mov.q		[rbx],rcx					; set the new pointer

				jmp			.out						; go clean up and exit

;----------------------------------------------------------------------------------------------
; We have a null entry.  Since this should never happen if our code is good, report it and die
;----------------------------------------------------------------------------------------------

.IsNull:
				mov.q		rax,add2ListNULL		; get the address of the error message
				push		rax						; and push it on the stack
				push		0						; push a NULL hdr address on the stack
				call		kHeapError				; report the error -- will not return

;----------------------------------------------------------------------------------------------
; We have a bad address.  Since this should never happen if our code is good, report it and die
;----------------------------------------------------------------------------------------------

.BadAddr:
				mov.q		rax,add2ListBadEnt		; get the address of the error message
				push		rax						; and push it on the stack
				push		0						; push a NULL hdr address on the stack
				call		kHeapError				; report the error -- will not return

;----------------------------------------------------------------------------------------------
; We have a bad pointer.  Since this should never happen if our code is good, report it and die
;----------------------------------------------------------------------------------------------

.BadPtr:
				mov.q		rax,add2ListBadPtr		; get the address of the error message
				push		rax						; and push it on the stack
				push		0						; push a NULL hdr address on the stack
				call		kHeapError				; report the error -- will not return


;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
				pop			rdi						; restore rdi
				pop			rsi						; restore rsi
				pop			rcx						; restore rcx
				pop			rbx						; restore rbx
				pop			rbp						; restore the callier's stack frame
				ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword FindHole(qword AdjustedSize) -- This function will find the first entry in the ordered
;                                       list that is at least AdjustedSize bytes long.  The
;                                       AdjustedSize already includes the KHeapHdr size and
;                                       the KHeapFtr size.  The Adjsuted size also accounts for
;                                       any adjustment needed to meet the minumum allocation
;                                       size.  The Adjusted size is also already adjusted to
;                                       the allocation multiple.  In short, the AdjustedSize is
;                                       the real size of the block we need to find.
;
; Note that this function does not remove the entry from the list, it just locates one.
;----------------------------------------------------------------------------------------------

FindHole:
				push			rbp					; save the caller's frame
				mov.q			rbp,rsp				; create a frame
				push			rbx					; we will use rbx for our pointers
				push			rcx					; we will use rcx for our pointers
				push			rsi					; we will use rsi for our pointers

				mov.q			rsi,kHeap			; get the heap address
				mov.q			rbx,[rsi+KHeap.heapBegin]	; get the starting address

				mov.q			rcx,[rbp+16]		; get the size to find

				cmp.q			rcx,HEAP_PTR1		; compare to the first pointer size
				jb				.loop				; if < 512, we found our pointer
				mov.q			rbx,[rsi+KHeap.heap512]	; we can jump ahead on our searches

				cmp.q			rcx,HEAP_PTR2		; compare to pointer 2 size
				jb				.loop				; if < 1024, we found our pointer
				mov.q			rbx,[rsi+KHeap.heap1K]	; we can jump ahead on our searches

				cmp.q			rcx,HEAP_PTR3		; compare to pointer 3 size
				jb				.loop				; if < 4K, we found our pointer
				mov.q			rbx,[rsi+KHeap.heap4K]	; we can jump ahead on our searches

				cmp.q			rcx,HEAP_PTR4		; compare to pointer 4 size
				jb				.loop				; if < 16K, we found our pointer
				mov.q			rbx,[rsi+KHeap.heap16K]	; we can jump ahead on our searches

;----------------------------------------------------------------------------------------------
; at this point, rbx contains the address that is closest (without going over) from which we
; will start searching.  Start searching.
;----------------------------------------------------------------------------------------------

.loop:
				cmp.q			rbx,0				; so, is the address NULL?
				je				.noMem				; if NULL, we jump to return NULL

				cmp.q			rcx,[rbx+OrderedList.size]	; compare our sizes
				jae				.foundMem			; if >=, we found our block

;----------------------------------------------------------------------------------------------
; Not the right block, look at the next one
;----------------------------------------------------------------------------------------------

				mov.q			rbx,[rbx+OrderedList.next]	; get next addr
				jmp				.loop

;----------------------------------------------------------------------------------------------
; We found the right block, return it
;----------------------------------------------------------------------------------------------

.foundMem:
				mov.q			rax,rbx				; set the return value
				jmp				.out				; go exit

;----------------------------------------------------------------------------------------------
; No memory found that matches the request
;----------------------------------------------------------------------------------------------

.noMem:
				xor.q			rax,rax				; set the return value to NULL

;----------------------------------------------------------------------------------------------
; Clean up and exit
;----------------------------------------------------------------------------------------------

.out:
				pop				rsi					; restore rsi
				pop				rcx					; restore rcx
				pop				rbx					; restore rbx
				pop				rbp					; restore caller's frame
				ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword MergeLeft(qword blockHdr) -- Merge the freed block with the block to the left; the
;                                    block to the left is not known to be free, so we will
;                                    check that before we combine them into 1 single large
;                                    block.  This function returns the new OrderedList entry.
;----------------------------------------------------------------------------------------------

MergeLeft:
				push		rbp					; save the caller's frame
				mov.q		rbp,rsp				; create our own frame
				push		rsi					; save rsi
				push		rdi					; save rdi
				push		r14					; save r14
				push		r15					; save r15

;----------------------------------------------------------------------------------------------
; first thing to do is to set up our registers.  rsi will be the address of the left header;
; r14 the address of the left footer; rdi the address of the right header; r15 the address of
; the right footer.  These can all be determined from the address of the block header passed
; as the parameter.  Recall that the left footer is immediately before the header we are
; considering.
;----------------------------------------------------------------------------------------------

				mov.q		rdi,[rbp+16]		; get the right block header -- param

				mov.q		r15,rdi				; start to calc the right footer
				add.q		r15,[rdi+KHeapHdr.size]	; add the size
				sub.q		r15,KHeapFtr_size	; back out the footer size for struct start

				mov.q		r14,rdi				; start to calc the left footer
				sub.q		r14,KHeapFtr_size	; back up to start of footer

				mov.q		rsi,[r14+KHeapFtr.hdr]	; calc the left hdr address

;----------------------------------------------------------------------------------------------
; now that our registers are setup, make sure we have a hole to the left
;----------------------------------------------------------------------------------------------

				mov.d		eax,[rsi+KHeapHdr.hole]	; get the hole value
				cmp.d		eax,0				; do we have a hole?
				je			.haveHole			; we do, so go on

				xor.q		rax,rax				; clear rax
				jmp			.out				; and exit

;----------------------------------------------------------------------------------------------
; now that we have our registers setup, we only need to keep rsi (left side header) and r15
; (right side footer).  These will be the header/footer of our new bigger block.  The header
; and footer at rdi and r14 will be abandonned with their contents as-is.  No clean up will be
; done.  We will rebuild the header/footer to be sure.
;
; before we do, we need to remove the entry for the other hole.
;----------------------------------------------------------------------------------------------

.haveHole:		mov.q		rax,[rsi+KHeapHdr.entry]	; get the left side entry
				push		rax					; push as parm
				call		ReleaseEntry		; remove it from the list
				add.q		rsp,8				; clean up the stack

;----------------------------------------------------------------------------------------------
; polish up the left header
;----------------------------------------------------------------------------------------------

				mov.q		rax,[rdi+KHeapHdr.size]	; get the right side size
				add.q		[rsi+KHeapHdr.size],rax	; the new and improved size
				mov.d		[rsi+KHeapHdr.magic],KHEAP_MAGIC	; store the magic number
				mov.d		[rsi+KHeapHdr.hole],1		; this is a hole
				mov.q		[rsi+KHeapHdr.entry],0	; no entry for this hole

;----------------------------------------------------------------------------------------------
; polish up the right footer
;----------------------------------------------------------------------------------------------

				mov.d		[r15+KHeapFtr.magic],KHEAP_MAGIC	; set the magic number
				mov.d		[r15+KHeapFtr.fill],0		; not needed, but good idea
				mov.q		[r15+KHeapFtr.hdr],rdi	; set the header pointer

;----------------------------------------------------------------------------------------------
; finally create an OrderedList entry for the block
;----------------------------------------------------------------------------------------------

				push		0					; we do not want to add it; might MergeRight
				push		rsi					; push the header address
				call		NewListEntry		; create the entry; ret val in rax after call
				add.q		rsp,16				; clean up stack

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:			pop			r15					; restore r15
				pop			r14					; restore r14
				pop			rdi					; restore rdi
				pop			rsi					; restore rsi
				pop			rbp					; restore caller's frame
				ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword MergeRight(qword blockHdr) -- Merge the freed block with the block to the right; the
;                                     block to the right is already known to be free as well,
;                                     do we want to combine them into 1 single large block.
;                                     This function returns the new OrderedList entry.
;----------------------------------------------------------------------------------------------

MergeRight:
				push		rbp					; save the caller's frame
				mov.q		rbp,rsp				; create our own frame
				push		rsi					; save rsi
				push		rdi					; save rdi
				push		r14					; save r14
				push		r15					; save r15

;----------------------------------------------------------------------------------------------
; first thing to do is to set up our registers.  rsi will be the address of the left header;
; r14 the address of the left footer; rdi the address of the right header; r15 the address of
; the right footer.  These can all be determined from the address of the block header passed
; as the parameter.  Recall that the left footer is immediately before the header we are
; considering.
;----------------------------------------------------------------------------------------------

				mov.q		rsi,[rbp+16]		; get the left block header -- param

				mov.q		r14,rsi				; start to calc the left footer
				add.q		r14,[rsi+KHeapHdr.size]	; add the size
				sub.q		r14,KHeapFtr_size	; back out the footer size for struct start

				mov.q		rdi,r14				; start to cal calc the right hdr address
				add.q		rdi,KHeapFtr_size	; move to the next hdr

				mov.q		r15,rdi				; start to calc the right footer
				add.q		r15,[rdi+KHeapHdr.size]	; add the size
				sub.q		r15,KHeapFtr_size	; back out the footer size for struct start

;----------------------------------------------------------------------------------------------
; now that our registers are setup, make sure we have a hole to the right
;----------------------------------------------------------------------------------------------

				mov.d		eax,[rdi+KHeapHdr.hole]	; get the hole value
				cmp.d		eax,0				; do we have a hole?
				je			.haveHole			; we do, so go on

				xor.q		rax,rax				; clear rax
				jmp			.out				; and exit

;----------------------------------------------------------------------------------------------
; now that we have our registers setup, we only need to keep rsi (left side header) and r15
; (right side footer).  These will be the header/footer of our new bigger block.  The header
; and footer at rdi and r14 will be abandonned with their contents as-is.  No clean up will be
; done.  We will rebuild the header/footer to be sure.
;
; before we do, we need to remove the entry for the other hole.
;----------------------------------------------------------------------------------------------

.haveHole:		mov.q		rax,[rdi+KHeapHdr.entry]	; get the right side entry
				push		rax					; push as parm
				call		ReleaseEntry		; remove it from the list
				add.q		rsp,8				; clean up the stack

;----------------------------------------------------------------------------------------------
; polish up the left header
;----------------------------------------------------------------------------------------------

				mov.q		rax,[rdi+KHeapHdr.size]	; get the right side size
				add.q		[rsi+KHeapHdr.size],rax	; the new and improved size
				mov.d		[rsi+KHeapHdr.magic],KHEAP_MAGIC	; store the magic number
				mov.d		[rsi+KHeapHdr.hole],1	; this is a hole
				mov.q		[rsi+KHeapHdr.entry],0	; no entry for this hole

;----------------------------------------------------------------------------------------------
; polish up the right footer
;----------------------------------------------------------------------------------------------

				mov.d		[r15+KHeapFtr.magic],KHEAP_MAGIC	; set the magic number
				mov.d		[r15+KHeapFtr.fill],0	; not needed, but good idea
				mov.q		[r15+KHeapFtr.hdr],rdi	; set the header pointer

;----------------------------------------------------------------------------------------------
; finally create an OrderedList entry for the block
;----------------------------------------------------------------------------------------------

				push		0				; we do not want to add it; might MergeRight
				push		rsi					; push the header address
				call		NewListEntry		; create the entry; ret val in rax after call
				add.q		rsp,16				; clean up stack

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:			pop			r15					; restore r15
				pop			r14					; restore r14
				pop			rdi					; restore rdi
				pop			rsi					; restore rsi
				pop			rbp					; restore caller's frame
				ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword NewListEntry(qword HdrAddr, qword AddIt) -- This function will create a new OrderedList
;                                                   entry in the table, properly intitializing
;                                                   the OrderedList structure values from
;                                                   the HdrAddr parameter.
;----------------------------------------------------------------------------------------------

NewListEntry:
				push		rbp						; save the caller's frame
				mov			rbp,rsp					; and create a new frame
				push		rbx						; save rbx -- used as address base
				push		rcx						; save rcx -- used as counter
				push		r15						; save r15 -- used for temp return value

				xor			r15,r15					; clear out r15; assume returning 0 (error)

;----------------------------------------------------------------------------------------------
; We are going to iterate through all the Ordered List entries to find one that has not been
; used.  If we get to the end, we know we don't have one available and we need to stop the
; kernel, reporting the error.
;
; Initialization -- counter = 0; set start of table (OrdList[0])
;----------------------------------------------------------------------------------------------

				xor			rcx,rcx					; clear out rcx -- used as counter
				mov			rbx,qword OrdList		; get table address

;----------------------------------------------------------------------------------------------
; Top fo the loop: determine if we are done looping
;----------------------------------------------------------------------------------------------

.loop:			cmp			rcx,qword FIXED_ORD_LIST	; compare against the size
				jae			.loopout				; if we are done, exit

;----------------------------------------------------------------------------------------------
; Now for the body of the loop: first check for the block value (is -1 if not used)
;----------------------------------------------------------------------------------------------

				mov			rax,[rbx+OrderedList.block]	; get the block value
				cmp			rax,-1					; check the value; -1 is unused
				jne			.iter					; if used (block <> -1) iterate

;----------------------------------------------------------------------------------------------
; We found a block we can use, so set it up and return
;----------------------------------------------------------------------------------------------

				mov			r15,rbx					; setup the return value in temp reg

				mov			rax,[rbp+16]			; get the block hdr address
				mov			[rbx+OrderedList.block],rax	; and set it in the orderedList

				mov			rcx,[rax+KHeapHdr.size]	; get the size from the header
				mov			[rbx+OrderedList.size],rcx	; and store it in the orderedList

				xor			rcx,rcx					; clear rcx
				mov			[rbx+OrderedList.prev],rcx	; set prev to null
				mov			[rbx+OrderedList.next],rcx	; and next to null as well

				lea			rbx,[rax+KHeapHdr.entry]	; get the address of the entry
				mov			[rbx],r15				; set the entry pointer to the temp ret val

;----------------------------------------------------------------------------------------------
; Check if we need to add the list entry to the free nodes list
;----------------------------------------------------------------------------------------------

				mov			rax,[rbp+24]			; get the "add" parm
				cmp			rax,0					; is it false?
				je			.out					; if false, we don't need to add it

				push		r15						; push the parm on the stack
				call		AddToList				; add it to the list
				add			rsp,8					; clean up the stack

				jmp			.out					; and exit

;----------------------------------------------------------------------------------------------
; Now iterate the loop -- increment counter and move to the next table entry
;----------------------------------------------------------------------------------------------

.iter:
				inc			rcx						; add 1 to the counter
				add			rbx,qword OrderedList_size	; and move to the next entry

				jmp			.loop					; go back and loop again

;----------------------------------------------------------------------------------------------
; We have run out of blocks...  we need to report the problem and stop processing
;----------------------------------------------------------------------------------------------

.loopout:
				push		qword 0x0c				; we want red on black
				call		TextSetAttr				; Set the attribute

				mov			rbx,qword NoEntriesLeft	; get the address of the error message
				mov			[rsp],rbx				; and set it on the stack
				call		TextPutString			; output the message
				add			rsp,8					; clean up, even tho we will stop here

.die:			cli									; no interrupts
				hlt									; stop the processor
				jmp			.die					; loop just in case

;----------------------------------------------------------------------------------------------
; Clean up and exit
;----------------------------------------------------------------------------------------------

.out:
				mov			rax,r15					; get the return value
				pop			r15						; restore r15
				pop			rcx						; restore rcx
				pop			rbx						; restore rbx
				pop			rbp						; restore caller's frame
				ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void ReleaseEntry(qword Entry) -- Release an Entry from the free nodes list.  Typically, this
;                                   will happen for 1 of 2 reasons:
;
; 1) The hole will be allocated in its entirety
; 2) Two holes are combined into 1 larger hole and one of the 2 entries will not be needed.
;----------------------------------------------------------------------------------------------

ReleaseEntry:
				push		rbp						; push caller's frame
				mov			rbp,rsp					; create our own frame
				push		rbx						; save rbx - will use
				push		rsi						; save rsi -- will use

				mov			rbx,[rbp+16]			; get entry address
				cmp			rbx,qword 0				; is it NULL?
				je			.out					; if so, exit

;----------------------------------------------------------------------------------------------
; check to make sure that the entry has been removed
;----------------------------------------------------------------------------------------------

				cmp			qword [rbx+OrderedList.prev],0	; is prev 0?
				jne			.remove					; if not null, remove

				cmp			qword [rbx+OrderedList.next],0	; is next 0?
				jne			.remove					; if not null, remove

				jmp			.clear					; no need to remove, clear entry

;----------------------------------------------------------------------------------------------
; check to make sure that the entry has been removed
;----------------------------------------------------------------------------------------------

.remove:
				push		rbx						; push the entry address
				call		RemoveFromList			; go remove it
				add			rsp,8					; clean up stack

;----------------------------------------------------------------------------------------------
; clear the entry data elemenets
;----------------------------------------------------------------------------------------------

.clear:
				mov			rsi,qword [rbx+OrderedList.block]	; get the block address
				lea			rax,[rsi+KHeapHdr.entry]	; get the hdr ptr to entry (addr)
				mov			qword [rax],0			; clear the entry

				mov			qword [rbx+OrderedList.block],-1	; clear the block pointer
				mov			qword [rbx+OrderedList.prev],0	; clear prev pointer
				mov			qword [rbx+OrderedList.next],0	; clear next pointer

.out:
				pop			rsi						; restore rsi
				pop			rbx						; restore rbx
				pop			rbp						; restore caller's frame
				ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void RemoveFromList(qword Entry) -- Remove an entry pointed to by the value in Entry from the
;                                     heap ordered list.  This function will also maintain all
;                                     the pointers in the heap structure.  This function does
;                                     not return the entry; the calling function is to know
;                                     what entry it is operating with.
;----------------------------------------------------------------------------------------------

RemoveFromList:
				push		rbp						; push caller's frame
				mov			rbp,rsp					; create our own frame
				push		rbx						; save rbx - will use
				push		rcx						; save rcx
				push		rsi						; save rsi - we will use

				mov			rbx,qword [rbp+16]		; get the entry address
				cmp			rbx,qword 0				; is hte address null?
				je			.out					; if so, exit

;----------------------------------------------------------------------------------------------
; handle a few special cases: check the beginning pointer to see if they are the same
;----------------------------------------------------------------------------------------------

				mov			rsi,qword kHeap			; get the heap address
				mov			rax,qword [rsi+KHeap.heapBegin]	; get the pointer
				cmp			rax,rbx					; are they the same
				jne			.chk512					; if not, skip and jump to next check

				mov			rcx,qword [rax+OrderedList.next]	; get the address of 'next' fld
				mov			qword [rax],rcx			; move the pointer

;----------------------------------------------------------------------------------------------
; handle a few special cases: check the 512 byte pointer to see if they are the same
;----------------------------------------------------------------------------------------------

.chk512:
				mov			rsi,qword kHeap			; get the heap address
				mov			rax,qword [rsi+KHeap.heap512]	; get the pointer
				cmp			rax,rbx					; are they the same
				jne			.chk1K					; if not, skip and jump to next check

				mov			rcx,qword [rax+OrderedList.next]	; get the address of 'next' fld
				mov			qword [rax],rcx			; move the pointer

;----------------------------------------------------------------------------------------------
; handle a few special cases: check the 1K byte pointer to see if they are the same
;----------------------------------------------------------------------------------------------

.chk1K:
				mov			rsi,qword kHeap			; get the heap address
				mov			rax,qword [rsi+KHeap.heap1K]	; get the pointer
				cmp			rax,rbx					; are they the same
				jne			.chk4K					; if not, skip and jump to next check

				mov			rcx,qword [rax+OrderedList.next]	; get the address of 'next' fld
				mov			qword [rax],rcx			; move the pointer

;----------------------------------------------------------------------------------------------
; handle a few special cases: check the 4K byte pointer to see if they are the same
;----------------------------------------------------------------------------------------------

.chk4K:
				mov			rsi,qword kHeap			; get the heap address
				mov			rax,qword [rsi+KHeap.heap4K]	; get the pointer
				cmp			rax,rbx					; are they the same
				jne			.chk16K					; if not, skip and jump to next check

				mov			rcx,qword [rax+OrderedList.next]	; get the address of 'next' fld
				mov			qword [rax],rcx			; move the pointer

;----------------------------------------------------------------------------------------------
; handle a few special cases: check the 1K byte pointer to see if they are the same
;----------------------------------------------------------------------------------------------

.chk16K:
				mov			rsi,qword kHeap			; get the heap address
				mov			rax,qword [rsi+KHeap.heap16K]	; get the pointer
				cmp			rax,rbx					; are they the same
				jne			.remove					; if not, skip and jump to next check

				mov			rcx,qword [rax+OrderedList.next]	; get the address of 'next' fld
				mov			qword [rax],rcx			; move the pointer

;----------------------------------------------------------------------------------------------
; The special cases handled, remove the entry from the ordered list
;----------------------------------------------------------------------------------------------

.remove:
				mov			rsi,qword [rbx+OrderedList.next]	; get next address
				cmp			rsi,qword 0				; is the next addr 0?
				je			.remove2				; if so, skip this part

				lea			rcx,[rsi+OrderedList.prev]	; get addr of next-prev fld
				mov			rsi,qword [rbx+OrderedList.prev]	; get prev addr
				mov			qword [rcx],rsi			; set next->prev = prev

.remove2:
				mov			rsi,qword [rbx+OrderedList.prev]	; get prev address
				cmp			rsi,qword 0				; is the prev addr 0?
				je			.clean					; if so, skip this part

				lea			rcx,[rsi+OrderedList.next]	; get addr of prev-next fld
				mov			rsi,qword [rbx+OrderedList.next]	; get next addr
				mov			qword [rcx],rsi			; set prev->next = next

;----------------------------------------------------------------------------------------------
; Entry has been removed from the list; clean up its pointers
;----------------------------------------------------------------------------------------------

.clean:
				mov			qword [rbx+OrderedList.prev],0	; set address to 0
				mov			qword [rbx+OrderedList.next],0	; set address to 0

.out:
				pop			rsi						; restore rsi
				pop			rcx						; restore rcx
				pop			rbx						; restore rbx
				pop			rbp						; restore caller's frame
				ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword SplitBlock(qword Entry, qword Size) -- Split a block of memory into 2 smaller blocks.
;                                              These 2 smaller blocks will be:
;                                              1) the block that will be allocated
;                                              2) the remaining memory hole that will be put
;                                              back into the ordered list.
;
; This function returns the header for the block to allocate.  Entry is no longer valid after
; executing this function.
;----------------------------------------------------------------------------------------------

SplitBlock:
				push		rbp						; save the caller's frame
				mov			rbp,rsp					; create our frame
				push		rbx						; save rbx -- will modify
				push		rcx						; save rcx -- will modify
				push		rsi						; save rsi -- will modify
				push		rdi						; save rdi -- will modify
				push		r14						; save r14 -- will modify
				push		r15						; save r15 -- will modify

				mov			rbx,[rbp+16]			; get the Entry address
				mov			rcx,[rbp+24]			; get the new size

;----------------------------------------------------------------------------------------------
; First we need to setup our pointers for the first and second blocks of memory
;----------------------------------------------------------------------------------------------

				mov			rsi,qword [rbx+OrderedList.block]	; get the hdr address
				mov			rdi,rsi					; prepare the second hdr address
				add			rdi,rcx					; and move it to the new location

;----------------------------------------------------------------------------------------------
; now we can remove and invalidate the entry strucure -- no longer valid for use after this
;----------------------------------------------------------------------------------------------

				push		rbx						; pass the entry
				call		ReleaseEntry			; call the function
				add			rsp,8					; clean up the stack

;----------------------------------------------------------------------------------------------
; OK, now rsi is the pointer to the left side header; rdi is the right side header.  At this
; point we need to calcualte the location of the footers.  The left side footer is actually
; immediately before the right side header.  The right side footer is pointed to by the current
; left side header.  r14 will point to the left side footer; r15 will point to the right side
; footer.
;----------------------------------------------------------------------------------------------

				mov			r14,rdi					; start with the right side header
				sub			r14,qword KHeapFtr_size	; back up to the footer location

				mov			r15,rsi					; start with the left side header
				add			r15,qword [rsi+KHeapHdr.size]	; move to the next header
				sub			r15,qword KHeapFtr_size	; back up to the footer location

;----------------------------------------------------------------------------------------------
; Now we need to rebuild the 2 headers and 2 footers.  Start with the left-side header.  This
; is the block we will allocate, so it will not be a hole.
;----------------------------------------------------------------------------------------------

				mov			dword [rsi+KHeapHdr.magic],KHEAP_MAGIC	; set the magic number
				mov			dword [rsi+KHeapHdr.hole],0		; it is not a hole
				mov			qword [rsi+KHeapHdr.entry],0	; set the entry to be 0
				mov			qword [rsi+KHeapHdr.size],rcx	; this is the size we requested

;----------------------------------------------------------------------------------------------
; now we doctor up the left side footer
;----------------------------------------------------------------------------------------------

				mov			dword [r14+KHeapFtr.magic],KHEAP_MAGIC	; set the magic number
				mov			dword [r14+KHeapFtr.fill],0		; not needed, but good idea
				mov			qword [r14+KHeapFtr.hdr],rsi	; set the header pointer

;----------------------------------------------------------------------------------------------
; now we clean up the right side header, just like above (well, almost)
;----------------------------------------------------------------------------------------------

				mov			dword [rdi+KHeapHdr.magic],KHEAP_MAGIC	; set the magic number
				mov			dword [rdi+KHeapHdr.hole],1		; it is a hole
				mov			qword [rdi+KHeapHdr.entry],0	; set the entry to be 0
				mov			qword [rdi+KHeapHdr.size],r15	; calc this val; start with footer
				add			qword [rdi+KHeapHdr.size],KHeapFtr_size		; move past footer
				sub			qword [rdi+KHeapHdr.size],rdi	; sub hdr locn; what's left is size

;----------------------------------------------------------------------------------------------
; finally we clean up the right side footer
;----------------------------------------------------------------------------------------------

				mov			dword [r15+KHeapFtr.magic],KHEAP_MAGIC	; set the magic number
				mov			dword [r15+KHeapFtr.fill],0		; not needed, but good idea
				mov			qword [r15+KHeapFtr.hdr],rdi	; set the header pointer

;----------------------------------------------------------------------------------------------
; with our data set properly, we can add the right side back to the free OrderedList
;----------------------------------------------------------------------------------------------

				push		qword 1					; we will add to free nodes list
				push		rdi						; push the hdr addr
				call		NewListEntry			; call the function
				add			rsp,16					; clean up the stack

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

				mov			rax,rsi					; return the hdr address

.out:
				pop			r15						; restore r15
				pop			r14						; restore r14
				pop			rdi						; restore rdi
				pop			rsi						; restore rsi
				pop			rcx						; restore rcx
				pop			rbx						; restore rbx
				pop			rbp						; restore caller's frame
				ret

;==============================================================================================
;==============================================================================================
;==============================================================================================
;==============================================================================================
;==============================================================================================
;==============================================================================================
;==============================================================================================


;----------------------------------------------------------------------------------------------
; void kHeapError(qword hdr, qword msg) -- this function is called in the event of a kernel
;                                          heap error.  It will not return.  It will dump some
;                                          of the critical related heap structures and will
;                                          die a miserable death.
;----------------------------------------------------------------------------------------------

				global		kHeapError

kHeapError:
				cli							; immediately clear interrupts -- we will never ret
				push		rbp				; save caller's frame -- might want to unwind stack
				mov			rbp,rsp			; create our own frame; we dont ret -- save no regs
				sub			rsp,64			; make room for 8 parameters for function calls

				mov qword 	[rsp],0x0c		; set the color: white on red
				call		TextSetAttr		; set the attribute color
				call		TextClear		; clear the screen to a red color

				xor			r15,r15			; clear r15 since it might not get set later

;----------------------------------------------------------------------------------------------
; line 1 -- Screen header so you know what kind of error it is
;----------------------------------------------------------------------------------------------

.line01:		mov	qword	rax,kHeapErr1	; get the header text for the screen
				mov			[rsp],rax		; set the parameter
				call		TextPutString	; and write it to the screen

;----------------------------------------------------------------------------------------------
; lines 2 & 3 -- Error message so you know why you are seeing this screen (plus a blank line)
;----------------------------------------------------------------------------------------------

.line02:		mov qword 	[rsp],0x07		; set the color: grey on red
				call		TextSetAttr		; and set the attribute

				mov qword	rax,[rbp+24]	; get the error message
				mov			[rsp],rax		; store it as a parm
				call		TextPutString	; and write it to the screen

				mov qword	[rsp],13		; we want to put a linefeed on the screen
				call		TextPutChar		; go ahead and write it
				call		TextPutChar		; and again to create a blank line

;----------------------------------------------------------------------------------------------
; line 4 -- the heap structure heading and the block header heading and addresses
;----------------------------------------------------------------------------------------------

.line04:		mov qword	rax,kHeapTxt	; get the address of the kHeap text
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				mov qword	rbx,kHeap		; get the address of the kHeap Struct
				mov			[rsp],rbx		; and set the parameter
				call		TextPutHexQWord	; and write it to the screen

				mov qword	rax,HdrTxt		; get the address of the Header text
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				mov qword	rsi,[rbp+16]	; get the address of the kHeap Struct
				mov			[rsp],rsi		; and set the parameter
				call		TextPutHexQWord	; and write it to the screen
				mov			rcx,rsi			; save this address for comparison later

;----------------------------------------------------------------------------------------------
; line 5 -- heapBegin member and block header magic number
;----------------------------------------------------------------------------------------------

.line05:		mov qword	rax,hBeginTxt	; get the address of the .heapBegin txt
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				mov qword	rax,[rbx+KHeap.heapBegin]	; get addr in var kHeap.heapBegin
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexQWord	; and write it to the screen

				mov qword	rax,hdrMagic	; get the address of the .heapBegin txt
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				cmp			rcx,0			; do we have a null address?
				je			.line06			; if so, skip the next part

				xor			rax,rax			; clear rax
				mov dword	eax,[rsi+KHeapHdr.magic]	; get addr in var kHeapHdr.magic
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexDWord	; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 6 -- heap512 member and block header hole flag
;----------------------------------------------------------------------------------------------

.line06:		mov qword	rax,h512Txt		; get the address of the .heap512 txt
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				mov qword	rax,[rbx+KHeap.heap512]	; get addr in var kHeap.heap512
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexQWord	; and write it to the screen

				mov qword	rax,hdrHole		; get the address of the .hole txt
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				cmp			rcx,0			; do we have a null address?
				je			.line07			; if so, skip the next part

				xor			rax,rax			; clear rax
				mov dword	eax,[rsi+KHeapHdr.hole]	; get addr in var kHeapHdr.hole
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexDWord	; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 7 -- heap1K member and block header Entry address
;----------------------------------------------------------------------------------------------

.line07:		mov qword	rax,h1kTxt		; get the address of the .heap1K txt
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				mov qword	rax,[rbx+KHeap.heap1K]	; get addr in var kHeap.heap1K
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexQWord	; and write it to the screen

				mov qword	rax,hdrEntry	; get the address of the .heapEntry txt
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				cmp			rcx,0			; do we have a null address?
				je			.line08			; if so, skip the next part

				mov qword	rax,[rsi+KHeapHdr.entry]	; get addr in var kHeapHdr.entry
				mov			[rsp],rax		; and set the parameter
				mov			r15,rax			; save the entry address for later
				call		TextPutHexQWord	; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 8 -- heap4K member and block Header size
;----------------------------------------------------------------------------------------------

.line08:		mov qword	rax,h4kTxt		; get the address of the .heap4K txt
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				mov qword	rax,[rbx+KHeap.heap4K]	; get addr in var kHeap.heap4K
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexQWord	; and write it to the screen

				mov qword	rax,hdrSize		; get the address of the .szie txt
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				cmp			rcx,0			; do we have a null address?
				je			.line09			; if so, skip the next part

				mov qword	rax,[rsi+KHeapHdr.size]	; get addr in var kHeapHdr.size
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexQWord	; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 9 -- heap16K member (and a blank line between header & footer)
;----------------------------------------------------------------------------------------------

.line09:		mov qword	rax,h16kTxt		; get the address of the .heap16K txt
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				mov qword	rax,[rbx+KHeap.heap16K]	; get addr in var kHeap.heap16K
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexQWord	; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 10 -- heap start address and the block booter heading and address
;----------------------------------------------------------------------------------------------

.line10:		mov qword	rax,hStrTxt		; get the address of the .strAddr txt
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				mov qword	rax,[rbx+KHeap.strAddr]	; get addr in var kHeap.strAddr
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexQWord	; and write it to the screen

				mov qword	rax,FtrTxt		; get the address of the Footer txt
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				cmp			rcx,0			; do we have a null address?
				je			.line11			; if so, skip the next part

				add	qword	rsi,[rsi+KHeapHdr.size]	; move the hdr pointer
				sub	qword	rsi,KHeapFtr_size	; back out the size of the footer
				mov			[rsp],rsi		; and set the parameter
				mov			rcx,rsi			; save this address for later
				call		TextPutHexQWord	; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 11 -- heap current ending address and the block footer magic number
;----------------------------------------------------------------------------------------------

.line11:		mov qword	rax,hEndTxt		; get the address of the .endAddr txt
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				mov qword	rax,[rbx+KHeap.endAddr]	; get addr in var kHeap.endAddr
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexQWord	; and write it to the screen

				mov qword	rax,hdrMagic	; we can reuse this text
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				cmp			rcx,0			; do we have a null address?
				je			.line12			; if so, skip the next part

				xor			rax,rax			; clear out high rax bits
				mov	dword	eax,[rsi+KHeapFtr.magic]	; move the hdr pointer
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexDWord	; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 12 -- heap theoretical max address and the block footer fill dword (s/b 0)
;----------------------------------------------------------------------------------------------

.line12:		mov qword	rax,hMaxTxt		; get the address of the .maxAddr txt
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				mov qword	rax,[rbx+KHeap.maxAddr]	; get addr in var kHeap.maxAddr
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexQWord	; and write it to the screen

				mov qword	rax,ftrFill		; get the address of .fill text
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				cmp			rcx,0			; do we have a null address?
				je			.line13			; if so, skip the next part

				xor			rax,rax			; clear out high rax bits
				mov	dword	eax,[rsi+KHeapFtr.fill]	; move the pointer
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexDWord	; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 13 -- space between the heap structure and OrderedList limits & the block ftr hdr addr
;----------------------------------------------------------------------------------------------

.line13:		mov qword	rax,ftrHdr		; get the address of .fill text
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				cmp			rcx,0			; do we have a null address?
				je			.line15			; if so, skip the next part

				mov	qword	rax,[rsi+KHeapFtr.hdr]	; move the pointer
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexQWord	; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 14 & 15 -- 14 is blank; 15 has the OrderedList limits & Entry Headings (and addr)
;----------------------------------------------------------------------------------------------

.line15:		mov qword	rax,OLHdg		; get the address of the OrderedList heading
				mov			[rsp],rax		; and set it as a parameter
				call		TextPutString	; and write it to the screen

				mov			[rsp],r15		; Set the parm from saved entry address
				call		TextPutHexQWord	; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 16 -- OrderedList Array start address and block address
;----------------------------------------------------------------------------------------------

.line16:		mov qword	rax,OLStart		; get the address of the .start text
				mov			[rsp],rax		; set it as a parameter
				call		TextPutString	; and write it to the screen

				mov qword	rax,OrdList		; get addr of the OrderedList Array
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexQWord	; and write it to the screen

				mov qword	rax,EntBlock	; get the address of .block text
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				cmp			r15,0			; do we have a null address?
				je			.line17			; if so, skip the next part

				mov	qword	rax,[r15+OrderedList.block]	; move the pointer
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexQWord	; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 17 -- Ordered List ending address and block size
;----------------------------------------------------------------------------------------------

.line17:		mov qword	rax,OLEnd		; get the address of the .end text
				mov			[rsp],rax		; set it as a parameter
				call		TextPutString	; and write it to the screen

				mov qword	rax,OrdList.end	; get addr of the OrderedList Array
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexQWord	; and write it to the screen

				mov qword	rax,EntSize		; get the address of .block text
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				cmp			r15,0			; do we have a null address?
				je			.line18			; if so, skip the next part

				mov	qword	rax,[r15+OrderedList.size]	; move the pointer
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexQWord	; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 18 -- The Entry previous address
;----------------------------------------------------------------------------------------------

.line18:		mov qword	rax,EntPrev		; get the address of .fill text
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				cmp			r15,0			; do we have a null address?
				je			.line19			; if so, skip the next part

				mov	qword	rax,[r15+OrderedList.prev]	; move the pointer
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexQWord	; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 19 -- The Entry next address
;----------------------------------------------------------------------------------------------

.line19:		mov qword	rax,EntNext		; get the address of .fill text
				mov			[rsp],rax		; and set the parameter
				call		TextPutString	; and write it to the screen

				cmp			r15,0			; do we have a null address?
				je			.hlt			; if so, skip the next part

				mov	qword	rax,[r15+OrderedList.next]	; move the pointer
				mov			[rsp],rax		; and set the parameter
				call		TextPutHexQWord	; and write it to the screen

;----------------------------------------------------------------------------------------------
; here is where we halt; interrupts already disabled
;----------------------------------------------------------------------------------------------

				mov.q		[rsp],13		; set up for printing new lines
				call		TextPutChar		; and write it to the screen
				call		TextPutChar		; and write it to the screen
				call		TextPutChar		; and write it to the screen

.hlt:			jmp			.hlt			; here we die
