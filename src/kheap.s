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
; Free blocks are maintained in the heap structure as an ordered list by size, from smallest
; to biggest.  In addition, when the ordered list is searched for the "best fit" (that is the
; class of algorithm used here), if the adjusted request is >= 16K, then the search starts at
; the 16K pointer; >= 4K but < 16K, then the search starts at the 4K pointer; >= 1K but < 4K,
; then the search starts at the 1K pointer; >= 512 bytes but < 1K, then the search starts
; at the 512 bytes pointer; and, all other searches < 512 bytes are stated at the beginning.
;
; Note that if there are no memory blocks < 512 bytes, but blocks >= 512 bytes, then the
; beginning of the ordered list will point to the first block no matter the size.  The
; rationale for this is simple: a larger block can always be split to fulfill a request.
;
; On the other hand, if there are no blocks >= 16K bytes is size, then the >= 16K pointer
; will be NULL.  Again, the rationale is simple: we cannot add up blocks to make a 16K
; block, so other measures need to be taken (create more heap memory or return failure).
;
; Finally, the dedicated ordered list array is going to be eliminated in this
; implementation.  Instead it will be included as part of the header structure.  This change
; will allow for more than a fixed number of free blocks.  This should also simplify the
; implementation as well.
;
; Programming note:
; The following registers are standardized for the following uses throughout this file:
;  - rsi -- a left side block header, or single header when only dealing with 1 header
;  - r14 -- a left side block footer, of single footer when only dealing with 1 footer
;  - rdi -- a right side block header
;  - r15 -- a right side block footer
;  - r9 -- in the event we are dealing with 3 headers, this is the middle one
;  - rbx -- the address of the kHeap structure
;  - rcx -- the number of bytes we are working with
;  - rax -- a scratch work register and return value
;
; ** NOTE **:
; An important assumption in this implementation is as follows: No requests to the kernel heap
; manager will need to be page aligned.  All requests that need to be page aligned will go
; through the Virtual Memory Manager and therefore the physical memory manager and will be
; whole pages.
;
; The following functions are published in this source:
;   qword kmalloc(qword size);
;   void kfree(qword block);
;   void HeapInit(void);
;
; The following functions are internal to the source file:
;   void AddToList(qword blockHdr);
;   qword FindHole(qword AdjustedSize);
;   qword MergeLeft(qword blockHdr);
;   qword MergeRight(qword blockHdr);
;   void RemoveFromList(qword blockHdr);
;   qword SplitBlock(qword blockHdr, qword Size);
;
; The following function is an error reporting function from which there is no return:
;   void kHeapError(qword hdr, qword msg);
;
;    Date     Tracker  Pgmr  Description
; ----------  -------  ----  ------------------------------------------------------------------
; 2014/10/21  Initial  ADCL  Initial version
; 2014/11/11   #188    ADCL  OK, I'm taking this on now.  There will be a significant amount
;                            of rewriting with this change and better to get it in before
;                            is do a  significant amount of debugging -- only to have to
;                            uproot all this good code.
; 2014/11/13  CleanUp  ADCL  Clean up some of the comments post-commit.  Made a change to my
;                            editor to save spaces instead of tabs.  Some changes made to
;                            accomodate already written code.
;
;==============================================================================================

%define     __KHEAP_S__
%include    'private.inc'

;==============================================================================================
; In this first section (before we get into any real data or code), we will define some
; constants and suce to make out coding easier.
;==============================================================================================

ALLOC_MULT      equ     8
ALLOC_MIN_BLK   equ     64
ALLOC_MIN       equ     (KHeapHdr_size+KHeapFtr_size+ALLOC_MIN_BLK+ALLOC_MULT)&~(ALLOC_MULT-1)

KHEAP_MAGIC     equ     0xbab6badc

HEAP_START      equ     0xffffa00000000000  ; this is the starting point for the kernel heap
HEAP_END        equ     0xffffafffffffffff  ; this is the ending point for the kernel heap
HEAP_SIZE       equ     0x100000            ; the initial kernel heap mapped size (may expand)

HEAP_PTR1       equ     512             ; anything >= 512 bytes
HEAP_PTR2       equ     1024            ; anything >= 1K bytes
HEAP_PTR3       equ     4*1024          ; anything >= 4K bytes
HEAP_PTR4       equ     16*1024         ; anything >= 16K bytes

;----------------------------------------------------------------------------------------------
; This structure is the heap manager structure, and will be used thoughout this source file.
;
; Note that this is my first time with a struc in NASM, so I might abandon this and go with
; some other form of coding.  It all depends on how well I can adapt to the construct.  For an
; example of something that did not work, compare my coding to the ABI standard --- couldn't
; remember what was preserved and what was trashed!
;----------------------------------------------------------------------------------------------

struc KHeap
    .heapBegin  resq    1               ; the start of the ordered list -- theoretically 1 byte
    .heap512    resq    1               ; the start of blocks >= 512 bytes
    .heap1K     resq    1               ; the start of blocks >= 1K bytes
    .heap4K     resq    1               ; the start of blocks >= 4K bytes
    .heap16K    resq    1               ; the start of blocks >= 16K bytes
    .strAddr    resq    1               ; the start address of the heap memory
    .endAddr    resq    1               ; the end address of the heap memory
    .maxAddr    resq    1               ; the maximum address of the possible heap memory
endstruc

;----------------------------------------------------------------------------------------------
; This structure is the heap block header, which will appear before any allocated memory block
; and in all free memory blocks.
;----------------------------------------------------------------------------------------------

struc KHeapHdr
    .magic      resd    1               ; this is the location of the magic number
    .hole       resd    1               ; this is a boolean - is hole?
    .size       resq    1               ; this is the size of the block, incl hdr and ftr
    .prev       resq    1               ; the addr of the prev free entry in the ordered list
    .next       resq    1               ; the addr of the next free entry in the ordered list
endstruc

;----------------------------------------------------------------------------------------------
; This structure is the heap block footer.  At first I did not think I needed one of these, but
; if I am going to be able to find the previuos block header (i.e. MergeLeft()), then I need
; some way to calculate it based on data right before this header.  Therefore, I need the
; footer.
;----------------------------------------------------------------------------------------------

struc KHeapFtr
    .magic      resd    1               ; this is the magic number
    .fill       resd    1               ; this is unused, but to keep the structure aligned
    .hdr        resq    1               ; pointer back to the header
endstruc


;==============================================================================================
; This is the .bss section.  It contains uninitialized data.
;==============================================================================================

                section     .bss

kHeap:          resb        KHeap_size
.end:

;==============================================================================================
; This is the read only data (.rodata) and will be included in the .text section at link
;==============================================================================================

                section     .rodata

kHeapErr1       db          '                               Kernel Heap Error',13,0

kHeapTxt        db          ' kHeap      ',0
hBeginTxt       db          13,' .heapBegin ',0
h512Txt         db          13,' .heap512   ',0
h1kTxt          db          13,' .heap1K    ',0
h4kTxt          db          13,' .heap4K    ',0
h16kTxt         db          13,' .heap16K   ',0
hStrTxt         db          13,' .strAddr   ',0
hEndTxt         db          13,' .endAddr   ',0
hMaxTxt         db          13,' .maxAddr   ',0

HdrTxt          db          '       Header   ',0
hdrMagic        db          '       .magic   ',0
hdrHole         db          '       .hole    ',0
hdrEntry        db          '       .entry   ',0
hdrSize         db          '       .size    ',0
hdrPrev         db          '       .prev    ',0
hdrNext         db          '       .next    ',0

FtrTxt          db          '       Footer   ',0
ftrFill         db          13,'                                        .fill    ',0
ftrHdr          db          13,'                                        .hdr     ',0

freeNULL        db          '                    In kfree(), Trying to free a NULL pointer',0
freeAlign       db          '                  In kfree(), Trying to free an unaligned block',0
freeHdrRange    db          '                In kfree(), Header address not in heap address range',0
freeFtrRange    db          '                In kfree(), Footer address not in heap address range',0
freeHdrMagic    db          '                   In kfree(), Header magic number is not valid',0
freeFtrMagic    db          '                   In kfree(), Footer magic number is not valid',0
freeHdrFtr      db          '               In kfree(), Header address is after the footer address',0
freeHole        db          '                      In kfree(), Freed memory is not a hole',0
freeHdr         db          '              In kfree(), Pointer in footer does not match header addr',0
freeEntry       db          '                      In kfree(), Entry in Header is not NULL',0

add2ListNULL    db          '                       In AddToList(), Header pointer is NULL',0
add2ListBadEnt  db          '                In AddToList(), Header address is not in table bounds',0
add2ListBadPtr  db          '                    In AddToList(), Header is already in the list',0

mlHdrNULL       db          '                      In MergeLeft(), Header parameter is NULL',0
mlRHdrBounds    db          '              In MergeLeft(), Right header address not in heap bounds',0
mlRHdrMagic     db          '                 In MergeLeft(), Right header magic number invalid',0
mlRFtrBounds    db          '              In MergeLeft(), Right footer address not in heap bounds',0
mlRFtrMagic     db          '                 In MergeLeft(), Right footer magic number invalid',0
mlLFtrMagic     db          '                 In MergeLeft(), Left footer magic number invalid',0
mlLHdrBounds    db          '              In MergeLeft(), Left header address not in heap bounds',0
mlLHdrMagic     db          '                 In MergeLeft(), Left header magic number invalid',0

mrHdrNULL       db          '                      In MergeRight(), Header parameter is NULL',0
mrRHdrBounds    db          '              In MergeRight(), Right header address not in heap bounds',0
mrRHdrMagic     db          '                 In MergeRight(), Right header magic number invalid',0
mrRFtrBounds    db          '              In MergeRight(), Right footer address not in heap bounds',0
mrRFtrMagic     db          '                 In MergeRight(), Right footer magic number invalid',0
mrLFtrMagic     db          '                 In MergeRight(), Left footer magic number invalid',0
mrLFtrBounds    db          '              In MergeRight(), Left header address not in heap bounds',0
mrLHdrMagic     db          '                 In MergeRight(), Left header magic number invalid',0

;==============================================================================================
; This is the code section of the source file.  It will be part of the kernel.
;==============================================================================================

                section     .text
                bits        64

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
;----------------------------------------------------------------------------------------------

                global      kmalloc

kmalloc:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rcx                     ; save rcx -- number of bytes requested
                push        rsi                     ; save rsi -- header pointer
                push        r14                     ; save r14 -- footer pointer
                pushfq                              ; save the flags

;----------------------------------------------------------------------------------------------
; initialize and perform some sanity checking
;----------------------------------------------------------------------------------------------

                cli                                 ; no interrupts -- add spinlock in future
                xor.q       rax,rax                 ; assume we will return 0

                mov.q       rcx,[rbp+16]            ; get the number of bytes requested
                cmp.q       rcx,0                   ; special case: requested 0?
                je          .out                    ; exit; NULL return value already set

                cmp.q       rcx,ALLOC_MIN_BLK       ; are we allocing the minimum size?
                jae         .chkMult                ; yes, proceed to the next check

                mov.q       rcx,ALLOC_MIN_BLK       ; no, so allocate the minimum
                jmp         .goodSize               ; we know this is already multiple aligned

.chkMult:       test.q      rcx,ALLOC_MULT-1        ; are we allocing a multiple of ALLOC_MULT
                jz          .goodSize               ; if we are good, skip realignment

                add.q       rcx,ALLOC_MULT          ; increase the size 1 multiple
                and.q       rcx,~(ALLOC_MULT-1)     ; and truncate its lower bits

;----------------------------------------------------------------------------------------------
; here we are guaranteed to have a ligit request that is a proper allocation multiple.  Now
; add in the size of the header and footer.
;----------------------------------------------------------------------------------------------

.goodSize:      add.q       rcx,(KHeapHdr_size+KHeapFtr_size)   ; add hdr&ftr sizes to request

;----------------------------------------------------------------------------------------------
; now, let's try to find a hole the proper size
;----------------------------------------------------------------------------------------------

                push        rcx                     ; push the size as parm
                call        FindHole                ; see if we can find a hole the right size
                add.q       rsp,8                   ; clean up the stack

                cmp.q       rax,0                   ; did we get something?
                je          .out                    ; if NULL, we did not; exit returning NULL

;----------------------------------------------------------------------------------------------
; we have a block that is at least big enough for our request, do we need to split it?
;----------------------------------------------------------------------------------------------

                mov.q       rsi,rax                 ; save our header; rax will be used for calc
                mov.q       rax,rcx                 ; get our adjusted size
                sub.q       rax,[rbx+KHeapHdr.size] ; determine the difference in sizes
                cmp.q       rax,ALLOC_MIN_BLK       ; is the leftover size enough to split blk?
                jbe         .noSplit                ; if small enough, we will not split it

;----------------------------------------------------------------------------------------------
; At this point, we have a block that needs to be split into two blocks
;----------------------------------------------------------------------------------------------

.Split:
                push        rcx                     ; we need our adjusted size as parm
                push        rsi                     ; we need our Header as parm
                call        SplitBlock              ; split the block and put free part on block
                add.q       rsp,16                  ; clean up the stack

                mov.q       rsi,rax                 ; refresh the pointer to the header
                jmp         .polish                 ; go adjust the pointer and return

;----------------------------------------------------------------------------------------------
; We now have a properly sized block; need some housekeeping and return
;----------------------------------------------------------------------------------------------

.noSplit:
                mov.q       r14,rsi                 ; start calcing the footer address
                add.q       r14,[rsi+KHeapHdr.size] ; move to the end of the block
                sub.q       r14,KHeapFtr_size       ; back out the footer to get address

                push        rsi                     ; need entry address
                call        RemoveFromList          ; remove the block from the list
                add.q       rsp,8                   ; clean up the stack

                mov.d       [rsi+KHeapHdr.hole],0   ; this is not a hole anymore

;----------------------------------------------------------------------------------------------
; rax now holds the proerly sized block; polish up the pointer and return
;----------------------------------------------------------------------------------------------

.polish:
                mov.q       rax,rsi                 ; get the header address
                add.q       rax,KHeapHdr_size       ; adjust past the header

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:           popfq                               ; restore the flags & interrupts
                pop         r14                     ; restore r14
                pop         rsi                     ; restore rsi
                pop         rcx                     ; restore rcx
                pop         rbp                     ; restore caller's frame
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
;----------------------------------------------------------------------------------------------

                global      kfree

kfree:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx -- the pointer to the block
                push        rsi                     ; save rsi -- the pointer to the header
                push        r14                     ; save r14 -- the pointer to the footer
                pushfq                              ; save the flags
                cli                                 ; and no interrupts please

;----------------------------------------------------------------------------------------------
; start with the sanity checks -- the first one is that the block is not NULL
;----------------------------------------------------------------------------------------------

.chk1:          mov.q       rsi,[rbp+16]            ; get the memory parameter
                cmp.q       rsi,0                   ; is the address NULL?
                jne         .chk2                   ; if not, we can go on

                mov.q       rax,freeNULL            ; get the address of the error message
                push        rax                     ; push it on the stack
                push        0                       ; push the address (which is NULL)
                call        kHeapError              ; generate the error screen -- does not ret

;----------------------------------------------------------------------------------------------
; sanity check 2 -- is the block properly aligned?
;----------------------------------------------------------------------------------------------

.chk2:          test.q       rsi,ALLOC_MULT-1       ; are the low bits set?
                jz          .chk3                   ; if not, we can go on

                mov.q       rax,freeAlign           ; get the address of the error message
                push        rax                     ; push it on the stack
                push        0                       ; push the address (which is NULL)
                call        kHeapError              ; generate the error screen -- does not ret

;----------------------------------------------------------------------------------------------
; sanity check 3 -- is the header in range?
;----------------------------------------------------------------------------------------------

.chk3:          sub.q       rsi,KHeapHdr_size       ; and offset it back to start of hdr addr

                mov.q       rbx,kHeap               ; get the heap structure address
                mov.q       rax,[rbx+KHeap.strAddr] ; and offset it to the strAddr member
                cmp.q       rsi,rax                 ; is the address after the start?
                jb          .chk3Err                ; if less, we have an error

                mov.q       rax,kHeap               ; get the heap structure address
                mov.q       rax,[rbx+KHeap.endAddr] ; and offset it to the endAddr member
                cmp.q       rsi,rax                 ; is the address before the end?
                jb          .chk4                   ; if below, we can continue

.chk3Err:       mov.q       rax,freeHdrRange        ; get the address of the error message
                push        rax                     ; push it on the stack
                push        rsi                     ; push the address of the hdr
                call        kHeapError              ; generate the error screen -- does not ret

;----------------------------------------------------------------------------------------------
; sanity check 4 -- header magic number good?
;----------------------------------------------------------------------------------------------

.chk4:          mov.q       rax,KHEAP_MAGIC         ; get the magic number
                cmp.q       rax,[rsi+KHeapHdr.magic]    ; is the magic number good?
                je          .chk5                   ; if equal, we can continue

                mov.q       rax,freeHdrMagic        ; get the address of the error message
                push        rax                     ; push it on the stack
                push        rsi                     ; push the address
                call        kHeapError              ; generate the error screen -- does not ret

;----------------------------------------------------------------------------------------------
; sanity check 5 -- is footer after header?
;----------------------------------------------------------------------------------------------

.chk5:          mov.q       r14,rsi                 ; start to calc the footer address
                add.q       r14,[rsi+KHeapHdr.size] ; move the the end of the block
                sub.q       r14,KHeapFtr_size       ; and adjust back for the footer addr

                cmp.q       r14,rsi                 ; compare the 2 addresses
                ja          .chk6                   ; if footer is after header, we continue

                mov.q       rax,freeHdrFtr          ; get the address of the error message
                push        rax                     ; push it on the stack
                push        rsi                     ; push the address
                call        kHeapError              ; generate the error screen -- does not ret

;----------------------------------------------------------------------------------------------
; sanity check 6 -- is the footer in range?
;----------------------------------------------------------------------------------------------

.chk6:          mov.q       rax,[rbx+KHeap.strAddr] ; and offset it to the strAddr member
                cmp.q       r14,rax                 ; is the address after the start?
                jb          .chk6Err                ; if less, we have an error

                mov.q       rax,[rbx+KHeap.endAddr] ; and offset it to the endAddr member
                cmp.q       r14,rax                 ; is the address before the end?
                jb          .chk7                   ; if below, we can continue

.chk6Err:       mov.q       rax,freeFtrRange        ; get the address of the error message
                push        rax                     ; push it on the stack
                push        rsi                     ; push the address of the hdr
                call        kHeapError              ; generate the error screen -- does not ret

;----------------------------------------------------------------------------------------------
; sanity check 7 -- footer has magic number?
;----------------------------------------------------------------------------------------------

.chk7:          mov.q       rax,KHEAP_MAGIC         ; get the magic number
                cmp.q       rax,[r14+KHeapFtr.magic]    ; is the magic number good?
                je          .chk8                   ; if equal, we can continue

                mov.q       rax,freeFtrMagic        ; get the address of the error message
                push        rax                     ; push it on the stack
                push        rsi                     ; push the address
                call        kHeapError              ; generate the error screen -- does not ret

;----------------------------------------------------------------------------------------------
; sanity check 8 -- is the hole 0?
;----------------------------------------------------------------------------------------------

.chk8:          mov.d       eax,[rsi+KHeapHdr.hole] ; get the hole flag
                cmp.d       eax,0                   ; is the falg 0
                je          .chk9                   ; if so, we can continue

                mov.q       rax,freeHole            ; get the address of the error message
                push        rax                     ; push it on the stack
                push        rsi                     ; push the address
                call        kHeapError              ; generate the error screen -- does not ret

;----------------------------------------------------------------------------------------------
; sanity check 9 -- footer header pointer match header address?
;----------------------------------------------------------------------------------------------

.chk9:          mov.q       rax,[r14+KHeapFtr.hdr]  ; get the hdr address
                cmp.q       rsi,rax                 ; are they the same?
                je          .goodMem                    ; if they are, go to the next check

                mov.q       rax,freeHdr             ; get the address of the error message
                push        rax                     ; push it on the stack
                push        rsi                     ; push the address
                call        kHeapError              ; generate the error screen -- does not ret

;----------------------------------------------------------------------------------------------
; At this point, we have a good block of memory to free.  Now, let's go about freeing it back
; to the kernel heap.
;----------------------------------------------------------------------------------------------

.goodMem:       push        rsi                     ; push the header on the stack
                call        MergeRight              ; merge it with the right block, if free
                call        MergeLeft               ; and merge it with the left block if free
                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; OK, so MergeRight was called first specifically because whether or not the block to the right
; is a hole, the left side block has the same address no matter what.  MergeLeft, however, is
; not the same situation.  In the event that MergeLeft is able to merge the block to the left,
; rax will hold the address of the new left block.  If MergeLeft is not able to merge with the
; block to the left, then rax will hold the block value we passed in.
;
; In all cases, rax will hold the address of the new and improved block (MergedRight and/or
; MergedLeft, or not...).
;----------------------------------------------------------------------------------------------

                mov.q       rsi,rax                 ; get the address of the new block

;----------------------------------------------------------------------------------------------
; at this point, we have a good block, possibly bigger.  If rax is 0, then we need to create
; a new list entry for the block; if eax <> 0 then we just need to re-insert the entry.
;----------------------------------------------------------------------------------------------

.addToList:     mov.d       [rsi+KHeapHdr.hole],1   ; make this block a hole

                push        rsi                     ; push the entry address onto the stack
                call        AddToList               ; and add it to the list
                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; clean  up and exit
;----------------------------------------------------------------------------------------------

.out:           popfq                               ; restore flags
                pop         r14                     ; restore r14
                pop         rsi                     ; restore rsi
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret


;==============================================================================================

;----------------------------------------------------------------------------------------------
; void HeapInit(void) -- Initialize the heap structures
;----------------------------------------------------------------------------------------------

                global      HeapInit

HeapInit:       push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx -- used for heap address
                push        rcx                     ; save rcx -- used for block size
                push        rsi                     ; save rsi -- used for header address
                push        r14                     ; save r14 -- used for footer address

;----------------------------------------------------------------------------------------------
; First, set up the heap structure with our initial values
;----------------------------------------------------------------------------------------------

                mov.q       rbx,kHeap               ; get the heap struct address

                mov.q       rcx,HEAP_START          ; get the ending address
                mov.q       [rbx+KHeap.strAddr],rcx ; the starting heap address

                add.q       rcx,HEAP_SIZE           ; set up for 1 MB heap
                mov.q       [rbx+KHeap.endAddr],rcx ; store the ending address

                mov.q       rax,HEAP_END            ; the theoretical max of heap
                mov.q       [rbx+KHeap.maxAddr],rax ; stored in the proper location

                mov.q       rcx,[rbx+KHeap.endAddr] ; get the heap ending address
                sub.q       rcx,[rbx+KHeap.strAddr] ; this is the size of the block

;----------------------------------------------------------------------------------------------
; we need to map (and allocate) our heap memory from the VMM
;----------------------------------------------------------------------------------------------

                mov.q       rax,HEAP_SIZE           ; get the initial size
                shr.q       rax,12                  ; convert it to the number of pages
                push        rax                     ; save it as a parm

                mov.q       rax,HEAP_START          ; get the starting address of the heap
                push        rax                     ; save it as a parm

                call        VMMAlloc                ; go allocate and map the memory
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; Now, set up our heap header and heap footer pointers
;----------------------------------------------------------------------------------------------

                mov.q       r14,[rbx+KHeap.endAddr] ; get the footer address (calc)
                sub.q       r14,KHeapFtr_size       ; r14 now holds the footer address

                mov.q       rsi,[rbx+KHeap.strAddr] ; get the address of the hdr

;----------------------------------------------------------------------------------------------
; fill in our heap header information
;----------------------------------------------------------------------------------------------

                mov.d       [rsi+KHeapHdr.magic],KHEAP_MAGIC    ; set the magic number
                mov.d       [rsi+KHeapHdr.hole],0   ; pretend this is allocated
                mov.q       [rsi+KHeapHdr.size],rcx ; set the size
                mov.q       [rsi+KHeapHdr.prev],0   ; set the prev ordered list entry
                mov.q       [rsi+KHeapHdr.next],0   ; set the next ordered list entry

;----------------------------------------------------------------------------------------------
; fill in our heap footer information
;----------------------------------------------------------------------------------------------

                mov.d       [r14+KHeapFtr.magic],KHEAP_MAGIC    ; set the magic number
                mov.d       [r14+KHeapFtr.fill],0   ; set the fill value
                mov.q       [r14+KHeapFtr.hdr],rsi  ; set the header pointer

;----------------------------------------------------------------------------------------------
; now, add the block as a free block
;----------------------------------------------------------------------------------------------

                add.q       rsi,KHeapHdr_size       ; adjust for the header
                push        rsi                     ; push the block address onto stack
                call        kfree                   ; 'trick' the system to free the block
                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; finally, clean up and exit
;----------------------------------------------------------------------------------------------

                pop         r14                     ; restore r14
                pop         rsi                     ; restore rsi
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void AddToList(qword blockHdr) -- Adds an entry (which is already setup) to the ordered list
;                                   of free blocks.  This is a quite complicated process
;                                   (based on the other functions written to date, so the
;                                   process is outlined here first.
;
; First perform sone sanity checks:
; 1.  block cannot be null; if it is, kill the kernel
; 2.  Bounds check blockHdr in the heap; if it is not in the heap range, kill the kernel
; 3.  Check that the prev and next members of the are null; if they are not, kill the kernel
;
; The above checks are in place to prevent the kernel from working with invalid data.  Later,
; this will need to be changed to throw some kind of fault.
;
; We need to check the heap pointers to make sure they are not empty.  If they are handle it
; and exit.  This is a special case we need to be aware of.
;
; Next, we need to figure out from which heap pointer we will start searching from.  This is
; done by determining the size of the block and comparing it against our fixed pointer sizes.
; The result should tell us from where to start looking for the proper place to insert the
; entry.
;----------------------------------------------------------------------------------------------

;==============================================================================================

AddToList:
                push        rbp                     ; save the caller's stack frame
                mov.q       rbp,rsp                 ; create a new stack frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rsi                     ; save rsi
                push        rdi                     ; save rdi
                push        r9                      ; save r9

;----------------------------------------------------------------------------------------------
; Complete sanity check #1: make sure blockHdr is not null
;----------------------------------------------------------------------------------------------

                mov.q       r9,[rbp+16]             ; get the addr
                cmp.q       r9,0                    ; check if NULL
                je          .IsNull                 ; if so, we will report the error

;----------------------------------------------------------------------------------------------
; Complete sanity check #2: bounds check the heap
;----------------------------------------------------------------------------------------------

                mov.q       rbx,kHeap               ; get the address of the heap struct
                cmp.q       r9,[rbx+KHeap.strAddr]  ; compare against the start of the heap
                jb          .BadAddr                ; we have a bad address; report it

                cmp.q       rax,[rbx+KHeap.endAddr] ; compare against the end of the heap
                jae         .BadAddr                ; we have a bad address; report it

;----------------------------------------------------------------------------------------------
; Complete sanity check #3: make sure the block is not already "inserted"
;----------------------------------------------------------------------------------------------

                cmp.q       [r9+KHeapHdr.prev],0    ; is the addr NULL
                jne         .BadPtr                 ; if not, report the error

                cmp.q       [r9+KHeapHdr.next],0    ; if the addr NULL
                jne         .BadPtr                 ; if not, report the error

;----------------------------------------------------------------------------------------------
; Now, we get the size of the block.  We will assume we need to start at th beginning
;----------------------------------------------------------------------------------------------

                mov.q       rcx,[r9+KHeapHdr.size]  ; get the size
                mov.q       rax,[rbx+KHeap.heapBegin]   ; get the pointer

;----------------------------------------------------------------------------------------------
; Check if the ordered list is empty -- this is a special case we need to handle
;----------------------------------------------------------------------------------------------

                cmp.q       rax,0                   ; if this is empty, we have no list
                jne         .chkSize                ; we have something, so continue

;----------------------------------------------------------------------------------------------
; We know the ordered list is empty, just make it right and leave; nothing else to do
;----------------------------------------------------------------------------------------------

                mov.q       [rbx+KHeap.heapBegin],r9    ; save the entry at the start

                cmp.q       rcx,HEAP_PTR1           ; compare to 512 bytes
                jb          .out                    ; if not that big, exit
                mov.q       [rbx+KHeap.heap512],r9  ; save the entry for >= 512 bytes

                cmp.q       rcx,HEAP_PTR2           ; compare to 1K bytes
                jb          .out                    ; if not that big exit
                mov.q       [rbx+KHeap.heap1K],r9   ; save the entry for >= 1K bytes

                cmp.q       rcx,HEAP_PTR3           ; compare to 4K bytes
                jb          .out                    ; if not that big exit
                mov.q       [rbx+KHeap.heap4K],r9   ; save the entry for >= 4K bytes

                cmp.q       rcx,HEAP_PTR4           ; compare to 16K bytes
                jb          .out                    ; if not that big exit
                mov.q       [rbx+KHeap.heap16K],r9  ; save that entry for >= 16K bytes

                jmp         .out                    ; go ahead and exit

;----------------------------------------------------------------------------------------------
; Check if we are looking for something >= 512 bytes; if so, adjust the pointer accordingly
;----------------------------------------------------------------------------------------------

.chkSize:
                cmp.q       rcx,HEAP_PTR1               ; compare to 512
                jb          .search                     ; if less go do the search
                mov.q       rax,[rbx+KHeap.heap512]     ; get the pointer

                cmp.q       rcx,HEAP_PTR2               ; compare to 1K
                jb          .search                     ; if less go do the search
                mov.q       rax,[rbx+KHeap.heap1K]      ; get the pointer

                cmp.q       rcx,HEAP_PTR3               ; compare to 4K
                jb          .search                     ; if less go do the search
                mov.q       rax,[rbx+KHeap.heap4K]      ; get the pointer

                cmp.q       rcx,HEAP_PTR4               ; compare to 16K
                jb          .search                     ; if less go do the search
                mov.q       rax,[rbx+KHeap.heap16K]     ; get the pointer

;----------------------------------------------------------------------------------------------
; At this point, we can do an exhaustive search until we find a block bigger than or equal to
; the size we want.  rax contains the ordered list address we are working with.
;----------------------------------------------------------------------------------------------

.search:
                cmp.q       rax,0                       ; reached end of list?
                je          .addEnd                     ; handle the special case to add to end

                cmp.q       [rax+KHeapHdr.size],rcx     ; compare the sizes
                jae         .foundLoc                   ; if >=, we found where to put block

                mov.q       rax,[rax+KHeapHdr.next]     ; get the next address
                jmp         .search                     ; continue to search

;----------------------------------------------------------------------------------------------
; This is a special case where we will add the block to the end of the ordered list
;----------------------------------------------------------------------------------------------

.addEnd:
                cmp.q       rax,0                       ; have we assigned a value?
                je          .addEnd2                    ; if not, jump over next stmt

                mov.q       [rax+KHeapHdr.next],r9      ; store the entry at the end

.addEnd2:
                mov.q       [r9+KHeapHdr.prev],rax      ; might be NULL
                mov.q       [r9+KHeapHdr.next],0        ; Set to NULL; it is the end

                jmp         .fixupNull                  ; go to fixup the heap ptrs

;----------------------------------------------------------------------------------------------
; Found the location, insert before rax entry; rax is guaranteed <> NULL
;
; The point of this section of code is to insert an block Header entry (r9) in a list before
; a specified location (rax).  At the point we get here, we have the following:
;
;                                   +----------------+
;                                   | new node (r9)  |
;                                   | -------------- |
;                              0 <- | prev           |
;                                   |           next | -> 0
;                                   +----------------+
;
;       +----------------+                                       +----------------+
;       | curr prev node |                                       | ins prior(rax) |
;       | -------------- |                                       | -------------- |
; ?? <- | prev           | <------------------------------------ | prev           |
;       |           next | ------------------------------------> |           next | -> ??
;       +----------------+                                       +----------------+
;
;
; The end result of this section is to have the following:
;
;       +----------------+          +----------------+           +----------------+
;       | cur prev (rsi) |          | new node (r9)  |           | ins prior(rdi) |
;       | -------------- |          | -------------- |           | -------------- |
; ?? <- | prev           | <------- | prev           | <-------- | prev           |
;       |           next | -------> |           next | --------> |           next | -> ??
;       +----------------+          +----------------+           +----------------+
;
;
;   ** NOTE **: cur prev (rsi) node could really be null; ins prior (rdi) is guaranteed not to be
;               NULL.
;
;
; So, with all that said, start with setting up our registers to have the proper addresses.
; Since rdi and rbx are already set, rsi is the only one we are concerned with setting.
;----------------------------------------------------------------------------------------------

.foundLoc:
                mov.q       rdi,rax                     ; set the right side pointer
                mov.q       rsi,[rdi+KHeapHdr.prev]     ; rsi is curr prev (or NULL)

;----------------------------------------------------------------------------------------------
; OK, now let's set the prev and next pointers in rbx (the new node)
;----------------------------------------------------------------------------------------------

                mov.q       [r9+KHeapHdr.prev],rsi      ; rsi could still be null -- works
                mov.q       [r9+KHeapHdr.next],rdi      ; set the next pointer

;----------------------------------------------------------------------------------------------
; now, the 'ins prior' node needs a new prev pointer
;----------------------------------------------------------------------------------------------

                mov.q       [rdi+KHeapHdr.prev],r9      ; next is unchanged

;----------------------------------------------------------------------------------------------
; finally, if rsi is not NULL, it needs a new next pointer
;----------------------------------------------------------------------------------------------

                cmp.q       rsi,0                       ; check if we have a NULL
                je          .fixupNull                  ; if NULL, skip next part

                mov.q       [rsi+KHeapHdr.next],r9      ; prev is unchanged

;----------------------------------------------------------------------------------------------
; The last step is to make sure the optimized pointers are pointing properly.  Start by making
; sure that any null pointer is really supposed to be null.
;----------------------------------------------------------------------------------------------

.fixupNull:
                cmp.q       [rbx+KHeap.heapBegin],0     ; compare to NULL
                jne         .fixupNull1                 ; if not NULL, go to the next check

                mov.q       [rbx+KHeap.heapBegin],r9    ; set the beginning Heap pointer

.fixupNull1:
                cmp.q       [rbx+KHeap.heap512],0       ; compare to NULL
                jne         .fixupNull2                 ; if not NULL, go to the next check

                cmp.q       rcx,HEAP_PTR1               ; Compare to 512
                jb          .fixupNull2                 ; if not >= 512, jump to next check

                mov.q       [rbx+KHeap.heap512],r9      ; set the 512 byte pointer

.fixupNull2:
                cmp.q       [rbx+KHeap.heap1K],0        ; compare to NULL
                jne         .fixupNull3                 ; if not NULL, go to the next check

                cmp.q       rcx,HEAP_PTR2               ; Compare to 1K bytes
                jb          .fixupNull3                 ; if not >= 1K bytes, jump to next check

                mov.q       [rbx+KHeap.heap1K],r9       ; set the 1K byte pointer

.fixupNull3:
                cmp.q       [rbx+KHeap.heap4K],0        ; compare to NULL
                jne         .fixupNull4                 ; if not NULL, go to the next check

                cmp.q       rcx,HEAP_PTR3               ; Compare to 4K bytes
                jb          .fixupNull4                 ; if not >= 4K bytes, jump to next chk

                mov.q       [rbx+KHeap.heap4K],r9       ; set the 4K byte pointer

.fixupNull4:
                cmp.q       [rbx+KHeap.heap16K],0       ; compare to NULL
                jne         .fixupBegin                 ; if not NULL, go to the next check

                cmp.q       rcx,HEAP_PTR4               ; Compare to 16K bytes
                jb          .fixupBegin                 ; if not >= 16K bytes, jump to next chk

                mov.q       [rbx+KHeap.heap16K],r9      ; set the 16K byte pointer

;----------------------------------------------------------------------------------------------
; Check the beginning pointer points to the first block.  In fact, we could have inserted a
; block in front of the existing pointer that was the first block.  This is  done regardless of
; size.
;----------------------------------------------------------------------------------------------

.fixupBegin:    mov.q       rdi,[rbx+KHeap.heapBegin]   ; get the addr of the pointer
                cmp.q       rdi,0                       ; is the addr NULL?
                je          .fixup512                   ; if null, we are done

                mov.q       rsi,[rdi+KHeapHdr.prev]     ; get the previuos addr
                cmp.q       rsi,0                       ; is the addr NULL?
                je          .fixup512                   ; if null, we are done

                mov.q       [rbx+KHeap.heapBegin],rsi   ; set the new pointer

;----------------------------------------------------------------------------------------------
; Check the 512 byte pointer points to the first block that is >= 512 bytes.  In fact, we
; could have inserted a block in front of the existing pointer that is really >= 512 as well.
;----------------------------------------------------------------------------------------------

.fixup512:      mov.q       rdi,[rbx+KHeap.heap512]     ; get the addr of the pointer
                cmp.q       rdi,0                       ; is the addr NULL?
                je          .fixup1K                    ; if null, we are done

                mov.q       rsi,[rdi+KHeapHdr.prev]     ; get the previuos addr
                cmp.q       rsi,0                       ; is the addr NULL?
                je          .fixup1K                    ; if null, we are done

                cmp.q       [rsi+KHeapHdr.size],HEAP_PTR1   ; is the size >= 512
                jb          .fixup1K                    ; if not >= 512, we are done

                mov.q       [rbx+KHeap.heap512],rsi     ; set the new pointer

;----------------------------------------------------------------------------------------------
; Check the 1K byte pointer points to the first block that is >= 1K bytes.  In fact, we
; could have inserted a block in front of the existing pointer that is really >= 1K as well.
;----------------------------------------------------------------------------------------------

.fixup1K:       mov.q       rdi,[rbx+KHeap.heap1K]      ; get the addr of the pointer
                cmp.q       rdi,0                       ; is the addr NULL?
                je          .fixup4K                    ; if null, we are done

                mov.q       rsi,[rdi+KHeapHdr.prev]     ; get the previuos addr
                cmp.q       rsi,0                       ; is the addr NULL?
                je          .fixup4K                    ; if null, we are done

                cmp.q       [rsi+KHeapHdr.size],HEAP_PTR2   ; is the size >= 1K
                jb          .fixup4K                    ; if not >= 1K, we are done

                mov.q       [rbx+KHeap.heap1K],rsi      ; set the new pointer

;----------------------------------------------------------------------------------------------
; Check the 4K byte pointer points to the first block that is >= 4K bytes.  In fact, we
; could have inserted a block in front of the existing pointer that is really >= 4K as well.
;----------------------------------------------------------------------------------------------

.fixup4K:       mov.q       rdi,[rbx+KHeap.heap4K]      ; get the addr of the pointer
                cmp.q       rdi,0                       ; is the addr NULL?
                je          .fixup16K                   ; if null, we are done

                mov.q       rsi,[rdi+KHeapHdr.prev]     ; get the previuos addr
                cmp.q       rsi,0                       ; is the addr NULL?
                je          .fixup16K                   ; if null, we are done

                cmp.q       [rsi+KHeapHdr.size],HEAP_PTR3   ; is the size >= 4K
                jb          .fixup16K                   ; if not >= 1K, we are done

                mov.q       [rbx+KHeap.heap4K],rsi      ; set the new pointer

;----------------------------------------------------------------------------------------------
; Check the 16K byte pointer points to the first block that is >= 16K bytes.  In fact, we
; could have inserted a block in front of the existing pointer that is really >= 16K as well.
;----------------------------------------------------------------------------------------------

.fixup16K:      mov.q       rdi,[rbx+KHeap.heap16K]     ; get the addr of the pointer
                cmp.q       rdi,0                       ; is the addr NULL?
                je          .out                        ; if null, we are done

                mov.q       rsi,[rdi+KHeapHdr.prev]     ; get the previuos addr
                cmp.q       rsi,0                       ; is the addr NULL?
                je          .out                        ; if null, we are done

                cmp.q       [rsi+KHeapHdr.size],HEAP_PTR4   ; is the size >= 4K
                jb          .out                        ; if not >= 1K, we are done

                mov.q       [rbx+KHeap.heap16K],rsi     ; set the new pointer

                jmp         .out                        ; go clean up and exit

;----------------------------------------------------------------------------------------------
; We have a null entry.  Since this should never happen if our code is good, report it and die
;----------------------------------------------------------------------------------------------

.IsNull:
                mov.q       rax,add2ListNULL        ; get the address of the error message
                push        rax                     ; and push it on the stack
                push        0                       ; push a NULL hdr address on the stack
                call        kHeapError              ; report the error -- will not return

;----------------------------------------------------------------------------------------------
; We have a bad address.  Since this should never happen if our code is good, report it and die
;----------------------------------------------------------------------------------------------

.BadAddr:
                mov.q       rax,add2ListBadEnt      ; get the address of the error message
                push        rax                     ; and push it on the stack
                push        0                       ; push a NULL hdr address on the stack
                call        kHeapError              ; report the error -- will not return

;----------------------------------------------------------------------------------------------
; We have a bad pointer.  Since this should never happen if our code is good, report it and die
;----------------------------------------------------------------------------------------------

.BadPtr:
                mov.q       rax,add2ListBadPtr      ; get the address of the error message
                push        rax                     ; and push it on the stack
                push        0                       ; push a NULL hdr address on the stack
                call        kHeapError              ; report the error -- will not return


;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:           pop         r9                      ; restore r9
                pop         rdi                     ; restore rdi
                pop         rsi                     ; restore rsi
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore the callier's stack frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword FindHole(qword AdjustedSize) -- This function will find the first block in the ordered
;                                       list that is at least AdjustedSize bytes long.  The
;                                       AdjustedSize already includes the KHeapHdr size and
;                                       the KHeapFtr size.  The Adjsuted size also accounts for
;                                       any adjustment needed to meet the minumum allocation
;                                       size.  The Adjusted size is also already adjusted to
;                                       the allocation multiple.  In short, the AdjustedSize is
;                                       the real size of the block we need to find.
;
; Note that this function does not remove the block from the list, it just locates one.
;----------------------------------------------------------------------------------------------

FindHole:
                push            rbp                 ; save the caller's frame
                mov.q           rbp,rsp             ; create a frame
                push            rbx                 ; we will use rbx for our pointers
                push            rcx                 ; we will use rcx for our pointers
                push            rsi                 ; we will use rsi for our pointers

                mov.q           rbx,kHeap           ; get the heap address
                mov.q           rsi,[rbx+KHeap.heapBegin]   ; get the starting address

                mov.q           rcx,[rbp+16]        ; get the size to find

                cmp.q           rcx,HEAP_PTR1       ; compare to the first pointer size
                jb              .loop               ; if < 512, we found our pointer
                mov.q           rsi,[rbx+KHeap.heap512] ; we can jump ahead on our searches

                cmp.q           rcx,HEAP_PTR2       ; compare to pointer 2 size
                jb              .loop               ; if < 1024, we found our pointer
                mov.q           rsi,[rbx+KHeap.heap1K]  ; we can jump ahead on our searches

                cmp.q           rcx,HEAP_PTR3       ; compare to pointer 3 size
                jb              .loop               ; if < 4K, we found our pointer
                mov.q           rsi,[rbx+KHeap.heap4K]  ; we can jump ahead on our searches

                cmp.q           rcx,HEAP_PTR4       ; compare to pointer 4 size
                jb              .loop               ; if < 16K, we found our pointer
                mov.q           rsi,[rbx+KHeap.heap16K] ; we can jump ahead on our searches

;----------------------------------------------------------------------------------------------
; at this point, rbx contains the address that is closest (without going over) from which we
; will start searching.  Start searching.
;----------------------------------------------------------------------------------------------

.loop:
                cmp.q           rsi,0               ; so, is the address NULL?
                je              .noMem              ; if NULL, we jump to return NULL

                cmp.q           rcx,[rsi+KHeapHdr.size] ; compare our sizes
                jbe             .foundMem           ; if >=, we found our block

;----------------------------------------------------------------------------------------------
; Not the right block, look at the next one
;----------------------------------------------------------------------------------------------

                mov.q           rsi,[rsi+KHeapHdr.next] ; get next addr
                jmp             .loop

;----------------------------------------------------------------------------------------------
; We found the right block, return it
;----------------------------------------------------------------------------------------------

.foundMem:
                mov.q           rax,rsi             ; set the return value
                jmp             .out                ; go exit

;----------------------------------------------------------------------------------------------
; No memory found that matches the request
;----------------------------------------------------------------------------------------------

.noMem:
                xor.q           rax,rax             ; set the return value to NULL

;----------------------------------------------------------------------------------------------
; Clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                pop             rsi                 ; restore rsi
                pop             rcx                 ; restore rcx
                pop             rbx                 ; restore rbx
                pop             rbp                 ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword MergeLeft(qword blockHdr) -- Merge the freed block with the block to the left; the
;                                    block to the left is not known to be free, so we will
;                                    check that before we combine them into 1 single large
;                                    block.  This function returns the new block address.
;
; Recall, the parameter is the header for the right-side block.  The following sanity checks
; need to be executed as we go through the merge process:
; 1.  the parameter must not be NULL
; 2.  the right block header must be >= kHeap.strAddr && < kHeap.endAddr
; 3.  the right header magic number must be correct
; 4.  the right block header + size <= kHeap.endAddr
; 5.  the right block footer magic number must be correct
; 6.  the left block footer must be >= kHeap.strAddr (must check before calcing left block hdr)
; 7.  the left block footer magic number must be correct
; 8.  the left block header must be >= kHeap.strAddr
; 9.  the left block header magic number must be correct
; 10.  the left block must be a hole
;----------------------------------------------------------------------------------------------

MergeLeft:
                push        rbp                 ; save the caller's frame
                mov.q       rbp,rsp             ; create our own frame
                push        rsi                 ; save rsi
                push        rdi                 ; save rdi
                push        r14                 ; save r14
                push        r15                 ; save r15

;----------------------------------------------------------------------------------------------
; set up our registers -- first rdi is the right-side header
;----------------------------------------------------------------------------------------------

                mov.q       rdi,[rbp+16]        ; get the right block header -- param

;----------------------------------------------------------------------------------------------
; Sanity check #1 -- the parameter is not null; if so, kHeapError
;----------------------------------------------------------------------------------------------

.chk1           cmp.q       rdi,0               ; compare the hdr addr to NULL
                jne         .chk2               ; if not, move on to sanity check #2

                mov.q       rax,mlHdrNULL       ; get the address of the error message
                push        rax                 ; push the error message
                push        rdi                 ; push the hdr parameter (0)
                call        kHeapError          ; and display the error screen

;----------------------------------------------------------------------------------------------
; Sanity check #2 -- right side header is in the heap bounds; if not kHeapError
;----------------------------------------------------------------------------------------------

.chk2:          mov.q       rax,kHeap           ; get the heap address
                mov.q       rax,[rax+KHeap.strAddr] ; get the heap starting address
                cmp.q       rdi,rax             ; compare the values
                jb          .chk2Err            ; if hdr address < heap start, display error

                mov.q       rax,kHeap           ; get the heap address
                mov.q       rax,[rax+KHeap.endAddr] ; get the heap ending address
                cmp.q       rdi,rax             ; compare the values
                jae         .chk2Err            ; if hdr addr >= heap end, display error

                jmp         .chk3               ; go on to the next check

.chk2Err:       mov.q       rax,mlRHdrBounds    ; get the address of the error message
                push        rax                 ; push the error message
                push        rdi                 ; push the hdr address
                call        kHeapError          ; display the error screen

;----------------------------------------------------------------------------------------------
; Sanity check #3 -- right side header magic number; if not kHeapError
;----------------------------------------------------------------------------------------------

.chk3:          cmp.d       [rdi+KHeapHdr.magic],KHEAP_MAGIC    ; compare the magic number
                je          .rFtr               ; if equal, we have a good hdr; get ftr

                mov.q       rax,mlRHdrMagic     ; get the address of the error message
                push        rax                 ; push the error message
                push        rdi                 ; push the hdr address
                call        kHeapError

;----------------------------------------------------------------------------------------------
; Right side header is good; get the right side footer
;----------------------------------------------------------------------------------------------

.rFtr:          mov.q       r15,rdi             ; start to calc the right footer
                add.q       r15,[rdi+KHeapHdr.size] ; add the size
                sub.q       r15,KHeapFtr_size   ; back out the footer size for struct start

;----------------------------------------------------------------------------------------------
; Sanity check #4 -- right side footer is in heap bounds; if not kHeapError
;----------------------------------------------------------------------------------------------

.chk4:          mov.q       rax,kHeap           ; get the heap address
                mov.q       rax,[rax+KHeap.endAddr] ; get the heap ending address
                cmp.q       r15,rax             ; compare the values
                jae         .chk4Err            ; if ftr addr >= heap end, display error

                jmp         .chk5               ; go on to the next check

.chk4Err:       mov.q       rax,mlRFtrBounds    ; get the address of the error message
                push        rax                 ; push the error message
                push        rdi                 ; push the hdr address
                call        kHeapError          ; display the error screen

;----------------------------------------------------------------------------------------------
; Sanity check #5 -- right side footer magic number; if not, kHeapError
;----------------------------------------------------------------------------------------------

.chk5:          cmp.d       [rdi+KHeapFtr.magic],KHEAP_MAGIC    ; compare the magic number
                je          .lFtr               ; if equal, we have a good ftr; get left ftr

                mov.q       rax,mlRFtrMagic     ; get the address of the error message
                push        rax                 ; push the error message
                push        rdi                 ; push the hdr address
                call        kHeapError

;----------------------------------------------------------------------------------------------
; now, we know that the right block is correct, we move on to the left block
;----------------------------------------------------------------------------------------------

.lFtr:          mov.q       r14,rdi             ; start to calc the left footer
                sub.q       r14,KHeapFtr_size   ; back up to start of footer

;----------------------------------------------------------------------------------------------
; Sanity check #6 -- check that the left footer is in bounds; if not, return 0.  This is not an
; error since it is completely possible that the block being freed is the first block and
; therefore there is nothing to the left of it.  We will know this if the right block is in
; bounds and the left footer is out of bounds (alt, we could check that the right header addr
; = kHeap.strAddr).
;----------------------------------------------------------------------------------------------

.chk6:          mov.q       rax,kHeap           ; get the heap structure address
                mov.q       rax,[rax+KHeap.strAddr] ; get the starting address
                cmp.q       r14,rax             ; compare the 2 addresses
                ja          .chk7               ; if so, continue checking

                mov.q       rax,[rbp+16]        ; get the address to return
                jmp         .out                ; and exit

;----------------------------------------------------------------------------------------------
; Sanity check #7 -- the left footer magic number is correct; if not, kHeapError
;----------------------------------------------------------------------------------------------

.chk7:          cmp.d       [r14+KHeapFtr.magic],KHEAP_MAGIC    ; check the magic number
                je          .lHdr               ; if good, go get the left header

                mov.q       rax,mlLFtrMagic     ; get the address of the error message
                push        rax                 ; push it on the stack
                push        0                   ; we really don't have a header to dump
                call        kHeapError          ; display the error message

;----------------------------------------------------------------------------------------------
; now we can get the left header address
;----------------------------------------------------------------------------------------------

.lHdr:          mov.q       rsi,[r14+KHeapFtr.hdr]  ; calc the left hdr address

;----------------------------------------------------------------------------------------------
; Sanity check #8 -- check that the left header is in bounds; we know the left footer is, so
; if the header is not in bounds, we have a problem with the heap structures and we need to
; kHeapError
;----------------------------------------------------------------------------------------------

.chk8:          mov.q       rax,kHeap           ; get the heap structure address
                mov.q       rax,[rax+KHeap.strAddr] ; get the starting address
                cmp.q       rsi,rax             ; compare the 2 addresses
                jae         .chk9               ; if so, continue checking

                mov.q       rax,mlLHdrBounds    ; get the address of the error message
                push        rax                 ; push it on the stack
                push        rsi                 ; push the bad header on the stack
                call        kHeapError          ; display the error message

;----------------------------------------------------------------------------------------------
; Sanity check #9 -- chek the left header magic number; if not kHeapError
;----------------------------------------------------------------------------------------------

.chk9:          cmp.d       [rsi+KHeapHdr.magic],KHEAP_MAGIC    ; check the magic number
                je          .chk10              ; if good, go on to the hole

                mov.q       rax,mlLHdrMagic     ; get the address of the error message
                push        rax                 ; push it on the stack
                push        0                   ; we really don't have a header to dump
                call        kHeapError          ; display the error message

;----------------------------------------------------------------------------------------------
; now that our registers are setup, make sure we have a hole to the left; if not return 0
;----------------------------------------------------------------------------------------------

.chk10:         mov.d       eax,[rsi+KHeapHdr.hole] ; get the hole value
                cmp.d       eax,0               ; do we have a hole?
                jne         .haveHole           ; we do, so go on

                xor.q       rax,[rbp+16]        ; set the return address
                jmp         .out                ; and exit

;----------------------------------------------------------------------------------------------
; now that we have our registers setup, we only need to keep rsi (left side header) and r15
; (right side footer).  These will be the header/footer of our new bigger block.  The header
; and footer at rdi and r14 will be abandonned with their contents as-is.  No clean up will be
; done.  We will rebuild the header/footer to be sure.
;
; before we do, we need to remove the block for the other hole.
;----------------------------------------------------------------------------------------------

.haveHole:      push        rsi                 ; push as parm
                call        RemoveFromList      ; remove it from the list
                add.q       rsp,8               ; clean up the stack

;----------------------------------------------------------------------------------------------
; polish up the left header
;----------------------------------------------------------------------------------------------

                mov.q       rax,[rdi+KHeapHdr.size] ; get the right side size
                add.q       [rsi+KHeapHdr.size],rax ; the new and improved size
                mov.d       [rsi+KHeapHdr.magic],KHEAP_MAGIC    ; store the magic number
                mov.d       [rsi+KHeapHdr.hole],1   ; this is a hole
                mov.q       [rsi+KHeapHdr.prev],0   ; this block is not in the ordered list
                mov.q       [rsi+KHeapHdr.next],0   ; this block is not in the ordered list

;----------------------------------------------------------------------------------------------
; polish up the right footer
;----------------------------------------------------------------------------------------------

                mov.d       [r15+KHeapFtr.magic],KHEAP_MAGIC    ; set the magic number
                mov.d       [r15+KHeapFtr.fill],0       ; not needed, but good idea
                mov.q       [r15+KHeapFtr.hdr],rsi  ; set the header pointer

;----------------------------------------------------------------------------------------------
; For the left footer and right header, these are now part of the free block.  To avoid
; confusion when debugging, set these contents to 0.
;----------------------------------------------------------------------------------------------

                mov.q       [rdi+KHeapHdr.size],0   ; the new and improved size
                mov.d       [rdi+KHeapHdr.magic],0  ; store the magic number
                mov.d       [rdi+KHeapHdr.hole],0   ; this is a hole
                mov.q       [rdi+KHeapHdr.prev],0   ; this block is not in the ordered list
                mov.q       [rdi+KHeapHdr.next],0   ; this block is not in the ordered list
                mov.d       [r14+KHeapFtr.magic],0  ; set the magic number
                mov.d       [r14+KHeapFtr.fill],0       ; not needed, but good idea
                mov.q       [r14+KHeapFtr.hdr],0    ; set the header pointer

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

                mov.q       rax,rsi             ; set the return value

.out:           pop         r15                 ; restore r15
                pop         r14                 ; restore r14
                pop         rdi                 ; restore rdi
                pop         rsi                 ; restore rsi
                pop         rbp                 ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword MergeRight(qword blockHdr) -- Merge the freed block with the block to the right; the
;                                     block to the right is already known to be free as well,
;                                     do we want to combine them into 1 single large block.
;                                     This function returns the new block address.
;
; Recall, the parameter is the header for the left-side block.  The following sanity checks
; need to be executed as we go through the merge process:
; 1.  the parameter must not be NULL
; 2.  the left block header must be >= kHeap.strAddr && < kHeap.endAddr
; 3.  the left header magic number must be correct
; 4.  the left block header + size <= kHeap.endAddr
; 5.  the left block footer magic number must be correct
; 6.  the right block header must be < kHeap.endAddr
; 7.  the right block header magic number must be correct
; 8.  the right block footer must be < kHeap.endAddr
; 9.  the right block footer magic number must be correct
; 10.  the right block must be a hole
;----------------------------------------------------------------------------------------------

MergeRight:
                push        rbp                 ; save the caller's frame
                mov.q       rbp,rsp             ; create our own frame
                push        rsi                 ; save rsi
                push        rdi                 ; save rdi
                push        r14                 ; save r14
                push        r15                 ; save r15

;----------------------------------------------------------------------------------------------
; set up our registers -- first rsi is the left-side header
;----------------------------------------------------------------------------------------------

                mov.q       rsi,[rbp+16]        ; get the left block header -- param

;----------------------------------------------------------------------------------------------
; Sanity check #1 -- the parameter is not null; if so, kHeapError
;----------------------------------------------------------------------------------------------

.chk1           cmp.q       rsi,0               ; compare the hdr addr to NULL
                jne         .chk2               ; if not, move on to sanity check #2

                mov.q       rax,mrHdrNULL       ; get the address of the error message
                push        rax                 ; push the error message
                push        rsi                 ; push the hdr parameter (0)
                call        kHeapError          ; and display the error screen

;----------------------------------------------------------------------------------------------
; Sanity check #2 -- left side header is in the heap bounds; if not kHeapError
;----------------------------------------------------------------------------------------------

.chk2:          mov.q       rax,kHeap           ; get the heap address
                mov.q       rax,[rax+KHeap.strAddr] ; get the heap starting address
                cmp.q       rsi,rax             ; compare the values
                jb          .chk2Err            ; if hdr address < heap start, display error

                mov.q       rax,kHeap           ; get the heap address
                mov.q       rax,[rax+KHeap.endAddr] ; get the heap ending address
                cmp.q       rsi,rax             ; compare the values
                jae         .chk2Err            ; if hdr addr >= heap end, display error

                jmp         .chk3               ; go on to the next check

.chk2Err:       mov.q       rax,mrRHdrBounds    ; get the address of the error message
                push        rax                 ; push the error message
                push        rsi                 ; push the hdr address
                call        kHeapError          ; display the error screen

;----------------------------------------------------------------------------------------------
; Sanity check #3 -- left side header magic number; if not kHeapError
;----------------------------------------------------------------------------------------------

.chk3:          cmp.d       [rsi+KHeapHdr.magic],KHEAP_MAGIC    ; compare the magic number
                je          .lFtr               ; if equal, we have a good hdr; get ftr

                mov.q       rax,mlRHdrMagic     ; get the address of the error message
                push        rax                 ; push the error message
                push        rsi                 ; push the hdr address
                call        kHeapError

;----------------------------------------------------------------------------------------------
; Left side header is good; get the left side footer
;----------------------------------------------------------------------------------------------

.lFtr:          mov.q       r14,rsi             ; start to calc the left footer
                add.q       r14,[rsi+KHeapHdr.size] ; add the size
                sub.q       r14,KHeapFtr_size   ; back out the footer size for struct start

;----------------------------------------------------------------------------------------------
; Sanity check #4 -- left side footer is in heap bounds; if not kHeapError
;----------------------------------------------------------------------------------------------

.chk4:          mov.q       rax,kHeap           ; get the heap address
                mov.q       rax,[rax+KHeap.endAddr] ; get the heap ending address
                cmp.q       r14,rax             ; compare the values
                jae         .chk4Err            ; if ftr addr >= heap end, display error

                jmp         .chk5               ; go on to the next check

.chk4Err:       mov.q       rax,mrLFtrBounds    ; get the address of the error message
                push        rax                 ; push the error message
                push        rsi                 ; push the hdr address
                call        kHeapError          ; display the error screen

;----------------------------------------------------------------------------------------------
; Sanity check #5 -- left side footer magic number; if not, kHeapError
;----------------------------------------------------------------------------------------------

.chk5:          cmp.d       [rsi+KHeapFtr.magic],KHEAP_MAGIC    ; compare the magic number
                je          .rHdr               ; if equal, we have a good ftr; get left ftr

                mov.q       rax,mrLFtrMagic     ; get the address of the error message
                push        rax                 ; push the error message
                push        rdi                 ; push the hdr address
                call        kHeapError

;----------------------------------------------------------------------------------------------
; now, we know that the left block is correct, we move on to the right block
;----------------------------------------------------------------------------------------------

.rHdr:          mov.q       rdi,r14             ; start to cal calc the right hdr address
                add.q       rdi,KHeapFtr_size   ; move to the next hdr

;----------------------------------------------------------------------------------------------
; Sanity check #6 -- check that the right header is in bounds; if not, return 0.  This is not
; an error since it is completely possible that the block being freed is the last block and
; therefore there is nothing to the right of it.  We will know this if the left block is in
; bounds and the right header is out of bounds
;----------------------------------------------------------------------------------------------

.chk6:          mov.q       rax,kHeap           ; get the heap structure address
                mov.q       rax,[rax+KHeap.endAddr] ; get the ending address
                cmp.q       rdi,rax             ; compare the 2 addresses
                jb          .chk7               ; if so, continue checking

                xor.q       rax,[rbp+16]        ; set the return address
                jmp         .out                ; and exit

;----------------------------------------------------------------------------------------------
; Sanity check #7 -- the right header magic number is correct; if not, kHeapError
;----------------------------------------------------------------------------------------------

.chk7:          cmp.d       [rdi+KHeapHdr.magic],KHEAP_MAGIC    ; check the magic number
                je          .rFtr               ; if good, go get the left header

                mov.q       rax,mrRHdrMagic     ; get the address of the error message
                push        rax                 ; push it on the stack
                push        0                   ; we really don't have a header to dump
                call        kHeapError          ; display the error message

;----------------------------------------------------------------------------------------------
; Now calculate the right footer
;----------------------------------------------------------------------------------------------

.rFtr:          mov.q       r15,rdi             ; start to calc the right footer
                add.q       r15,[rdi+KHeapHdr.size] ; add the size
                sub.q       r15,KHeapFtr_size   ; back out the footer size for struct start

;----------------------------------------------------------------------------------------------
; Sanity check #8 -- check that the right footer is in bounds; we know the right header is, so
; if the footer is not in bounds, we have a problem with the heap structures and we need to
; kHeapError
;----------------------------------------------------------------------------------------------

.chk8:          mov.q       rax,kHeap           ; get the heap structure address
                mov.q       rax,[rax+KHeap.endAddr] ; get the starting address
                cmp.q       r15,rax             ; compare the 2 addresses
                jb          .chk9               ; if so, continue checking

                mov.q       rax,mrRFtrBounds    ; get the address of the error message
                push        rax                 ; push it on the stack
                push        rdi                 ; push the bad header on the stack
                call        kHeapError          ; display the error message

;----------------------------------------------------------------------------------------------
; Sanity check #9 -- chek the right footer magic number; if not kHeapError
;----------------------------------------------------------------------------------------------

.chk9:          cmp.d       [r15+KHeapFtr.magic],KHEAP_MAGIC    ; check the magic number
                je          .chk10              ; if good, go on to the hole

                mov.q       rax,mrRFtrMagic     ; get the address of the error message
                push        rax                 ; push it on the stack
                push        0                   ; we really don't have a header to dump
                call        kHeapError          ; display the error message

;----------------------------------------------------------------------------------------------
; now that our registers are setup, make sure we have a hole to the right
;----------------------------------------------------------------------------------------------

.chk10:         mov.d       eax,[rdi+KHeapHdr.hole] ; get the hole value
                cmp.d       eax,0               ; do we have a hole?
                jne         .haveHole           ; we do, so go on

                mov.q       rax,[rbp+16]        ; set the return value
                jmp         .out                ; and exit

;----------------------------------------------------------------------------------------------
; now that we have our registers setup, we only need to keep rsi (left side header) and r15
; (right side footer).  These will be the header/footer of our new bigger block.  The header
; and footer at rdi and r14 will be abandonned with their contents as-is.  No clean up will be
; done.  We will rebuild the header/footer to be sure.
;
; before we do, we need to remove the block for the other hole.
;----------------------------------------------------------------------------------------------

.haveHole:      push        rdi                 ; push as parm
                call        RemoveFromList      ; remove it from the list
                add.q       rsp,8               ; clean up the stack

;----------------------------------------------------------------------------------------------
; polish up the left header
;----------------------------------------------------------------------------------------------

                mov.q       rax,[rdi+KHeapHdr.size] ; get the right side size
                add.q       [rsi+KHeapHdr.size],rax ; the new and improved size
                mov.d       [rsi+KHeapHdr.magic],KHEAP_MAGIC    ; store the magic number
                mov.d       [rsi+KHeapHdr.hole],1   ; this is a hole
                mov.q       [rsi+KHeapHdr.prev],0   ; this block is not in the ordered list
                mov.q       [rsi+KHeapHdr.next],0   ; this block is not in the ordered list

;----------------------------------------------------------------------------------------------
; polish up the right footer
;----------------------------------------------------------------------------------------------

                mov.d       [r15+KHeapFtr.magic],KHEAP_MAGIC    ; set the magic number
                mov.d       [r15+KHeapFtr.fill],0   ; not needed, but good idea
                mov.q       [r15+KHeapFtr.hdr],rsi  ; set the header pointer

;----------------------------------------------------------------------------------------------
; For the left footer and right header, these are now part of the free block.  To avoid
; confusion when debugging, set these contents to 0.
;----------------------------------------------------------------------------------------------

                mov.q       [rdi+KHeapHdr.size],0   ; the new and improved size
                mov.d       [rdi+KHeapHdr.magic],0  ; store the magic number
                mov.d       [rdi+KHeapHdr.hole],0   ; this is a hole
                mov.q       [rdi+KHeapHdr.prev],0   ; this block is not in the ordered list
                mov.q       [rdi+KHeapHdr.next],0   ; this block is not in the ordered list
                mov.d       [r14+KHeapFtr.magic],0  ; set the magic number
                mov.d       [r14+KHeapFtr.fill],0   ; not needed, but good idea
                mov.q       [r14+KHeapFtr.hdr],0    ; set the header pointer

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

                mov.q       rax,rsi             ; set the return value

.out:           pop         r15                 ; restore r15
                pop         r14                 ; restore r14
                pop         rdi                 ; restore rdi
                pop         rsi                 ; restore rsi
                pop         rbp                 ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void RemoveFromList(qword blockAddr) -- Remove an block pointed from the heap ordered list.
;                                         This function will also maintain all the pointers in
;                                         the heap structure.  This function does not return
;                                         the block; the calling function is to know what block
;                                         it is operating with.
;----------------------------------------------------------------------------------------------

RemoveFromList:
                push        rbp                     ; push caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx - will use
                push        rcx                     ; save rcx
                push        rsi                     ; save rsi - we will use
                push        rdi                     ; save rdi
                push        r9                      ; save r9

                mov.q       r9,[rbp+16]             ; get the block address
                cmp.q       r9,0                    ; is the address null?
                je          .out                    ; if so, exit

;----------------------------------------------------------------------------------------------
; handle a few special cases: check the beginning pointer to see if they are the same
;----------------------------------------------------------------------------------------------

                mov.q       rbx,kHeap               ; get the heap address

                mov.q       rdi,[rbx+KHeap.heapBegin]   ; get the pointer
                cmp.q       rdi,r9                  ; are they the same
                jne         .chk512                 ; if not, skip and jump to next check

                mov.q       rax,[rdi+KHeapHdr.next] ; get the address of 'next' fld
                mov.q       [rbx+KHeap.heapBegin],rax   ; move the pointer

;----------------------------------------------------------------------------------------------
; handle a few special cases: check the 512 byte pointer to see if they are the same
;----------------------------------------------------------------------------------------------

.chk512:        mov.q       rdi,[rbx+KHeap.heap512] ; get the pointer
                cmp.q       rdi,r9                  ; are they the same
                jne         .chk1K                  ; if not, skip and jump to next check

                mov.q       rax,[rdi+KHeapHdr.next] ; get the address of 'next' fld
                mov.q       [rbx+KHeap.heap512],rax ; move the pointer

;----------------------------------------------------------------------------------------------
; handle a few special cases: check the 1K byte pointer to see if they are the same
;----------------------------------------------------------------------------------------------

.chk1K:         mov.q       rdi,[rbx+KHeap.heap1K]  ; get the pointer
                cmp.q       rdi,r9                  ; are they the same
                jne         .chk4K                  ; if not, skip and jump to next check

                mov.q       rax,[rdi+KHeapHdr.next] ; get the address of 'next' fld
                mov.q       [rbx+KHeap.heap1K],rax  ; move the pointer

;----------------------------------------------------------------------------------------------
; handle a few special cases: check the 4K byte pointer to see if they are the same
;----------------------------------------------------------------------------------------------

.chk4K:         mov.q       rdi,[rbx+KHeap.heap4K]  ; get the pointer
                cmp.q       rdi,r9                  ; are they the same
                jne         .chk16K                 ; if not, skip and jump to next check

                mov.q       rax,[rdi+KHeapHdr.next] ; get the address of 'next' fld
                mov.q       [rbx+KHeap.heap4K],rax  ; move the pointer

;----------------------------------------------------------------------------------------------
; handle a few special cases: check the 1K byte pointer to see if they are the same
;----------------------------------------------------------------------------------------------

.chk16K:        mov.q       rdi,[rbx+KHeap.heap16K] ; get the pointer
                cmp.q       rdi,r9                  ; are they the same
                jne         .remove                 ; if not, skip and jump to next check

                mov.q       rax,[rdi+KHeapHdr.next] ; get the address of 'next' fld
                mov.q       [rbx+KHeap.heap16K],rax ; move the pointer

;----------------------------------------------------------------------------------------------
; The special cases handled, remove the entry from the ordered list
;----------------------------------------------------------------------------------------------

.remove:        mov.q       rdi,[r9+KHeapHdr.next]  ; get next address
                cmp.q       rdi,0                   ; is the next addr 0?
                je          .remove2                ; if so, skip this part

                lea.q       rax,[rdi+KHeapHdr.prev] ; get addr of next-prev fld
                mov.q       rsi,[r9+KHeapHdr.prev]  ; get prev addr
                mov.q       [rax],rsi               ; set next->prev = prev

.remove2:       mov.q       rsi,[r9+KHeapHdr.prev]  ; get prev address
                cmp.q       rsi,0                   ; is the prev addr 0?
                je          .clean                  ; if so, skip this part

                lea.q       rax,[rsi+KHeapHdr.next] ; get addr of prev-next fld
                mov.q       rdi,[r9+KHeapHdr.next]  ; get next addr
                mov.q       [rax],rdi               ; set prev->next = next

;----------------------------------------------------------------------------------------------
; Entry has been removed from the list; clean up its pointers
;----------------------------------------------------------------------------------------------

.clean:         mov.q       [r9+KHeapHdr.prev],0    ; set address to 0
                mov.q       [r9+KHeapHdr.next],0    ; set address to 0

.out:           pop         r9                      ; restore r9
                pop         rdi                     ; restore rdi
                pop         rsi                     ; restore rsi
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword SplitBlock(qword blockAddr, qword Size) -- Split a block of memory into 2 smaller
;                                                  blocks.  These 2 smaller blocks will be:
;                                                  1) the block that will be allocated
;                                                  2) the remaining memory hole that will be
;                                                     put back into the ordered list.
;
; This function returns the header for the block to allocate.
;----------------------------------------------------------------------------------------------

SplitBlock:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our frame
                push        rcx                     ; save rcx -- will modify
                push        rsi                     ; save rsi -- will modify
                push        rdi                     ; save rdi -- will modify
                push        r14                     ; save r14 -- will modify
                push        r15                     ; save r15 -- will modify

                mov.q       rsi,[rbp+16]            ; get the block address
                mov.q       rcx,[rbp+24]            ; get the new size

;----------------------------------------------------------------------------------------------
; First we need to setup our pointers for the first and second blocks of memory
;----------------------------------------------------------------------------------------------

                mov.q       rdi,rsi                 ; prepare the second hdr address
                add.q       rdi,rcx                 ; and move it to the new location

;----------------------------------------------------------------------------------------------
; now we can remove and invalidate the entry strucure -- no longer valid for use after this
;----------------------------------------------------------------------------------------------

                push        rsi                     ; pass the entry
                call        RemoveFromList          ; call the function
                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; OK, now rsi is the pointer to the left side header; rdi is the right side header.  At this
; point we need to calcualte the location of the footers.  The left side footer is actually
; immediately before the right side header.  The right side footer is pointed to by the current
; left side header.  r14 will point to the left side footer; r15 will point to the right side
; footer.
;----------------------------------------------------------------------------------------------

                mov.q       r14,rdi                 ; start with the right side header
                sub.q       r14,KHeapFtr_size       ; back up to the footer location

                mov.q       r15,rsi                 ; start with the left side header
                add.q       r15,[rsi+KHeapHdr.size] ; move to the next header
                sub.q       r15,KHeapFtr_size       ; back up to the footer location

;----------------------------------------------------------------------------------------------
; Now we need to rebuild the 2 headers and 2 footers.  Start with the left-side header.  This
; is the block we will allocate, so it will not be a hole.
;----------------------------------------------------------------------------------------------

                mov.d       [rsi+KHeapHdr.magic],KHEAP_MAGIC    ; set the magic number
                mov.d       [rsi+KHeapHdr.hole],0   ; it is not a hole
                mov.q       [rsi+KHeapHdr.size],rcx ; this is the size we requested
                mov.q       [rsi+KHeapHdr.prev],0   ; this block does not point to anything
                mov.q       [rsi+KHeapHdr.next],0   ; this block does not point to anything

;----------------------------------------------------------------------------------------------
; now we doctor up the left side footer
;----------------------------------------------------------------------------------------------

                mov.d       [r14+KHeapFtr.magic],KHEAP_MAGIC    ; set the magic number
                mov.d       [r14+KHeapFtr.fill],0   ; not needed, but good idea
                mov.q       [r14+KHeapFtr.hdr],rsi  ; set the header pointer

;----------------------------------------------------------------------------------------------
; now we clean up the right side header, just like above (well, almost)
;----------------------------------------------------------------------------------------------

                mov.d       [rdi+KHeapHdr.magic],KHEAP_MAGIC    ; set the magic number
                mov.d       [rdi+KHeapHdr.hole],1   ; it is a hole
                mov.q       [rdi+KHeapHdr.size],r15 ; calc this val; start with footer
                add.q       [rdi+KHeapHdr.size],KHeapFtr_size   ; move past footer
                sub.q       [rdi+KHeapHdr.size],rdi ; sub hdr locn; what's left is size
                mov.q       [rdi+KHeapHdr.prev],0   ; this block does not point to anything
                mov.q       [rdi+KHeapHdr.next],0   ; this block does not point to anything

;----------------------------------------------------------------------------------------------
; finally we clean up the right side footer
;----------------------------------------------------------------------------------------------

                mov.d       [r15+KHeapFtr.magic],KHEAP_MAGIC    ; set the magic number
                mov.d       [r15+KHeapFtr.fill],0   ; not needed, but good idea
                mov.q       [r15+KHeapFtr.hdr],rdi  ; set the header pointer

;----------------------------------------------------------------------------------------------
; with our data set properly, we can add the right side back to the free ordered list
;----------------------------------------------------------------------------------------------

                push        rdi                     ; push the hdr addr
                call        AddToList               ; call the function
                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

                mov.q       rax,rsi                 ; return the hdr address

.out:
                pop         r15                     ; restore r15
                pop         r14                     ; restore r14
                pop         rdi                     ; restore rdi
                pop         rsi                     ; restore rsi
                pop         rcx                     ; restore rcx
                pop         rbp                     ; restore caller's frame
                ret


;==============================================================================================
; Error, crash, and burn
;==============================================================================================


;----------------------------------------------------------------------------------------------
; void kHeapError(qword hdr, qword msg) -- this function is called in the event of a kernel
;                                          heap error.  It will not return.  It will dump some
;                                          of the critical related heap structures and will
;                                          die a miserable death.
;----------------------------------------------------------------------------------------------

                global      kHeapError

kHeapError:
                cli                         ; immediately clear interrupts -- we will never ret
                push        rbp             ; save caller's frame -- might want to unwind stack
                mov.q       rbp,rsp         ; create our own frame; we dont ret -- save no regs
                sub.q       rsp,64          ; make room for 8 parameters for function calls

                mov.q       [rsp],0x0c      ; set the color: white on red
                call        TextSetAttr     ; set the attribute color
                call        TextClear       ; clear the screen to a red color

                xor.q       r15,r15         ; clear r15 since it might not get set later

;----------------------------------------------------------------------------------------------
; line 1 -- Screen header so you know what kind of error it is
;----------------------------------------------------------------------------------------------

.line01:        mov.q       rax,kHeapErr1   ; get the header text for the screen
                mov.q       [rsp],rax       ; set the parameter
                call        TextPutString   ; and write it to the screen

;----------------------------------------------------------------------------------------------
; lines 2 & 3 -- Error message so you know why you are seeing this screen (plus a blank line)
;----------------------------------------------------------------------------------------------

.line02:        mov.q       [rsp],0x07      ; set the color: grey on red
                call        TextSetAttr     ; and set the attribute

                mov.q       rax,[rbp+24]    ; get the error message
                mov.q       [rsp],rax       ; store it as a parm
                call        TextPutString   ; and write it to the screen

                mov.q       [rsp],13        ; we want to put a linefeed on the screen
                call        TextPutChar     ; go ahead and write it
                call        TextPutChar     ; and again to create a blank line

;----------------------------------------------------------------------------------------------
; line 4 -- the heap structure heading and the block header heading and addresses
;----------------------------------------------------------------------------------------------

.line04:        mov.q       rax,kHeapTxt    ; get the address of the kHeap text
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                mov.q       rbx,kHeap       ; get the address of the kHeap Struct
                mov.q       [rsp],rbx       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen

                mov.q       rax,HdrTxt      ; get the address of the Header text
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                mov.q       rsi,[rbp+16]    ; get the address of the kHeap Struct
                mov.q       [rsp],rsi       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen
                mov.q       rcx,rsi         ; save this address for comparison later

;----------------------------------------------------------------------------------------------
; line 5 -- heapBegin member and block header magic number
;----------------------------------------------------------------------------------------------

.line05:        mov.q       rax,hBeginTxt   ; get the address of the .heapBegin txt
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                mov.q       rax,[rbx+KHeap.heapBegin]   ; get addr in var kHeap.heapBegin
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen

                mov.q       rax,hdrMagic    ; get the address of the .heapBegin txt
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                cmp.q       rcx,0           ; do we have a null address?
                je          .line06         ; if so, skip the next part

                xor.q       rax,rax         ; clear rax
                mov.d       eax,[rsi+KHeapHdr.magic]    ; get addr in var kHeapHdr.magic
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexDWord ; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 6 -- heap512 member and block header hole flag
;----------------------------------------------------------------------------------------------

.line06:        mov.q       rax,h512Txt     ; get the address of the .heap512 txt
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                mov.q       rax,[rbx+KHeap.heap512] ; get addr in var kHeap.heap512
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen

                mov.q       rax,hdrHole     ; get the address of the .hole txt
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                cmp.q       rcx,0           ; do we have a null address?
                je          .line07         ; if so, skip the next part

                xor.q       rax,rax         ; clear rax
                mov.d       eax,[rsi+KHeapHdr.hole] ; get addr in var kHeapHdr.hole
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexDWord ; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 7 -- heap1K member and block size
;----------------------------------------------------------------------------------------------

.line07:        mov.q       rax,h1kTxt      ; get the address of the .heap1K txt
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                mov.q       rax,[rbx+KHeap.heap1K]  ; get addr in var kHeap.heap1K
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen

                mov.q       rax,hdrSize     ; get the address of the .heapSize txt
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                cmp.q       rcx,0           ; do we have a null address?
                je          .line08         ; if so, skip the next part

                mov.q       rax,[rsi+KHeapHdr.size] ; get addr in var kHeapHdr.size
                mov.q       [rsp],rax       ; and set the parameter
                mov.q       r15,rax         ; save the entry address for later
                call        TextPutHexQWord ; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 8 -- heap4K member and prev block
;----------------------------------------------------------------------------------------------

.line08:        mov.q       rax,h4kTxt      ; get the address of the .heap4K txt
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                mov.q       rax,[rbx+KHeap.heap4K]  ; get addr in var kHeap.heap4K
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen

                mov.q       rax,hdrPrev     ; get the address of the .szie txt
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                cmp.q       rcx,0           ; do we have a null address?
                je          .line09         ; if so, skip the next part

                mov.q       rax,[rsi+KHeapHdr.prev] ; get addr in var kHeapHdr.prev
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 9 -- heap16K member and next block
;----------------------------------------------------------------------------------------------

.line09:        mov.q       rax,h16kTxt     ; get the address of the .heap16K txt
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                mov.q       rax,[rbx+KHeap.heap16K] ; get addr in var kHeap.heap16K
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen

                mov.q       rax,hdrNext     ; get the address of the .szie txt
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                cmp.q       rcx,0           ; do we have a null address?
                je          .line10         ; if so, skip the next part

                mov.q       rax,[rsi+KHeapHdr.next] ; get addr in var kHeapHdr.next
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 10 -- heap start address and the block booter heading and address
;----------------------------------------------------------------------------------------------

.line10:        mov.q       rax,hStrTxt     ; get the address of the .strAddr txt
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                mov.q       rax,[rbx+KHeap.strAddr] ; get addr in var kHeap.strAddr
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen


;----------------------------------------------------------------------------------------------
; line 11 -- heap current ending address and the block footer magic number
;----------------------------------------------------------------------------------------------

.line11:        mov.q       rax,hEndTxt     ; get the address of the .endAddr txt
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                mov.q       rax,[rbx+KHeap.endAddr] ; get addr in var kHeap.endAddr
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen

                mov.q       rax,FtrTxt      ; get the address of the Footer txt
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                cmp.q       rcx,0           ; do we have a null address?
                je          .line12         ; if so, skip the next part

                add.q       rsi,[rsi+KHeapHdr.size] ; move the hdr pointer
                sub.q       rsi,KHeapFtr_size   ; back out the size of the footer
                mov.q       [rsp],rsi       ; and set the parameter
                mov.q       rcx,rsi         ; save this address for later
                call        TextPutHexQWord ; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 12 -- heap theoretical max address and the block footer fill dword (s/b 0)
;----------------------------------------------------------------------------------------------

.line12:        mov.q       rax,hMaxTxt     ; get the address of the .maxAddr txt
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                mov.q       rax,[rbx+KHeap.maxAddr] ; get addr in var kHeap.maxAddr
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen

                mov.q       rax,hdrMagic    ; we can reuse this text
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                cmp.q       rcx,0           ; do we have a null address?
                je          .line13         ; if so, skip the next part

                xor.q       rax,rax         ; clear out high rax bits
                mov.d       eax,[rsi+KHeapFtr.magic]    ; move the magic number
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexDWord ; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 13 -- block footer fill dword
;----------------------------------------------------------------------------------------------

.line13:        mov.q       rax,ftrFill     ; get the address of .fill text
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                cmp.q       rcx,0           ; do we have a null address?
                je          .line14         ; if so, skip the next part

                xor.q       rax,rax         ; clear rax
                mov.d       eax,[rsi+KHeapFtr.fill] ; move the fill value
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexDWord ; and write it to the screen


;----------------------------------------------------------------------------------------------
; line 14 -- pointer to the header in the block footer
;----------------------------------------------------------------------------------------------

.line14:        mov.q       rax,ftrHdr      ; get the address of .fill text
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                cmp.q       rcx,0           ; do we have a null address?
                je          .out            ; if so, skip the next part

                mov.q       rax,[rsi+KHeapFtr.hdr]  ; move the pointer
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen


;----------------------------------------------------------------------------------------------
; here is where we halt; interrupts already disabled
;----------------------------------------------------------------------------------------------

.out:           mov.q       [rsp],13        ; set up for printing new lines
                call        TextPutChar     ; and write it to the screen
                call        TextPutChar     ; and write it to the screen
                call        TextPutChar     ; and write it to the screen

.hlt:           jmp         .hlt            ; here we die
