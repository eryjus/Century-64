;==============================================================================================
;
; physmm.s
;
; This file contains the functions and data that will be used to manage the physical memory
; layer of this kernel
;
; After a number of days of internal debate, I have settled on a bitmap for my memory manager
; implementation.  I will implement this bitmap with one slight modification to the simplistic
; implementation: I will maintain a pointer in the bitmap where the last block was found to be
; available and start subsequent searches there.  From an allocation perspective, the logic is
; simple: we cannot assume that memory ever gets freed, so why go back and start looking for
; free memory when we have already determined that there is none.  If we reach the end of
; memory, we will loop and look again from the beginning.
;
; I settled on this model because of the memory requirements.  While speed is an issue, I
; also need to consider how to handle the structures since this is all (so far) written in
; assembly.  At the point I am setting this up, I have no kernel heap manager, so allocating
; and deallocating is a bit of a mess (unless I want to statically allocate an array and
; maintain a flag available/used).  In addition, looking at pairs (block #,# of blocks) of
; free memory looks great to start with.  However, if memory becomed heavily fragmented, then
; the result is quite a lot of overhead (odd blocks free for 4GB results in pairs: (1,1),
; (3,1), (5,1), etc; 512K pairs; 8 bytes per pair = 4MB structures worst case and twice that
; for 16 byte pairs).  The bitmap is static at 128K for the same memory amount.  The static
; nature of the structure appealed to me greatly.
;
; I have not yet determined that I need to allow for "configuous" memory to be allocated.  So,
; I'm going to skip this for now and come back to it if I deem it necessary.  For the moment,
; any contiguous memory is allocated at compile time.
;
; The bitmap will be 131,072 qwords (1MB) and each bit (8 Mbit total) will represent a 4K page.
; This then allows the bitmap to represent 32GB of memory.  A bit will be set to 0 if a page is
; used and 1 is a page is available.  This scheme allows a quick qword to be compared to 0
; and if the result is true, then we move on the investigate the next 64-bits.  If the result
; is not true, then we know we have a free page in there and we will dig into it to determine
; which page is available.
;
; In order to support more than 32GB of memory, a second phase PMMInit2 will be called to
; prepare to support the rest of the memory above 32GB.  For now, this function is stubbed
; only, but is already called from the loader.s EntryPoint.
;
; The following functions are published in this file:
;   void PMMInit(void);
;   void MarkBlockFree(qword strart, qword length);
;   void MarkBlockUsed(qword strart, qword length);
;   qword AllocFrame(void);
;   qword AllocFrameLimit(qword maxAddr);
;   void FreeFrame(qword frame);
;
; The following functions are internal functions:
;   void SetBitFree(qword addr);
;   void SetBitUsed(qword addr);
;
; The following function is an error reporting function from which there is no return:
;   void pmmError(qword msg);
;
;    Date     Tracker  Pgmr  Description
; ----------  ------   ----  ------------------------------------------------------------------
; 2014/10/10  Initial  ADCL  Initial code
; 2014/10/12  #169     ADCL  For me, the ABI standard is causing me issues. For whatever reason,
;                            I am having trouble keeping track of "registers I want to save as
;                            the caller" rather than "saving all registers I will modify as the
;                            callee". I will adopt the latter standard so that debugging will
;                            be easier to manage, with the exception of rax.  DF in RFLAGS will
;                            be maintained as clear.
;                            At the same time reformat for spacing
; 2014/11/16  #200     ADCL  As a result of reorganizing the memory, this module needs to be
;                            addressed.  In particular, the memory manager needs to properly
;                            detect and use all of the memory available, not just fixed at 4GB.
;                            It also needs to be able to be put in charge quickly (can this
;                            happen before paging is enabled for the first time? -- probably
;                            not without great diffculty, but it is worth looking at).
;                            At the same time, there are new codint styles being put into place
;                            and this file needs to brought up to snuff.
; 2014/11/24  #200     ADCL  I am pleased to be at the point where I now need to address the
;                            physical memory allocation model.  This model can better serve the
;                            system by having a single allocation function that does the bulk
;                            of the work.  This function will be PMMAllocFrameLimit.  It will
;                            allocate the next frame no higher than a specified memory limit.
;                            The second function PMMAllocFrame will simply call
;                            PMMAllocFrameLimit with an upper limit of -1, meaning it can
;                            allocate from anywhere in the system.
; 2014/11/25  #206     ADCL  Adding a bunch of sanity checks into the physical memory
;                            management function.  Included in this is to restructure how the
;                            pmm data is maintained into a structure on the .bss segment.  I
;                            will also be adding a "panic" screen when there is an error.
; 2014/11/29  #202     ADCL  Completed the mapping and management of physical memory above 32GB
;
;==============================================================================================

%define         __PHYSMM_S__
%include        'private.inc'

                extern      MapPageInTables         ; we will need this to init tables
                extern      nextFrame               ; we will need this to init vars

PMM_PHYS        equ         0x0000000000300000      ; the physical address for the PMM bitmap
PMM_VIRT        equ         0xfffff00000000000      ; the virtual address for the PMM bitmap
_32GB           equ         0x0000000800000000      ; a constant for 32GB
Frames32GB      equ         _32GB>>12               ; a constant for 32GB frame count

;----------------------------------------------------------------------------------------------
; This data structure is used by the physical memory manager to keep track of itself.
;----------------------------------------------------------------------------------------------

struc PMM
    .bitmap     resq        1                       ; this is the address of our bitmap
    .bmFrames   resq        1                       ; the number of frames in the bitmap
    .sysFrames  resq        1                       ; total system frames reported by multiboot
    .curFrames  resq        1                       ; our current managed limit
    .searchIdx  resq        1                       ; last available frame loc'n (in qwords)
    .maxIndex   resq        1                       ; the last index (in qwords) in bitmap
    .freeFrames resq        1                       ; the current number of free frames
endstruc

;==============================================================================================
; This is the .bss section.  It contains uninitialized data.
;==============================================================================================

                section     .bss

pmm             resb        PMM_size                ; this is the heap management struct

;==============================================================================================
; This is the read only data (.rodata) and will be included in the .text section at link
;==============================================================================================

                section     .rodata

pmmErrHdr       db          '                          Physical Memory Manager Error',13,0
pmmErrStruct    db          13,'                        pmm         ',0
pmmErr.bitmap   db          13,'                        .bitmap     ',0
pmmErr.bmFrame  db          13,'                        .bmFrames   ',0
pmmErr.sysFram  db          13,'                        .sysFrames  ',0
pmmErr.curFram  db          13,'                        .curFrames  ',0
pmmErr.srchIdx  db          13,'                        .searchIdx  ',0
pmmErr.maxIdx   db          13,'                        .maxIndex   ',0
pmmErr.free     db          13,'                        .freeFrames ',0

errFBlkAlign    db          '              In MarkBlockFree, starting address alignment bad',0
errFBlkAlign2   db          '                In MarkBlockFree, block length alignment bad',0
errFBlkBound    db          '             In MarkBlockFree, block start not in managed bounds',0
errFBlkBound2   db          '          In MarkBlockFree, block start+length not in managed bounds',0

errUBlkAlign    db          '              In MarkBlockUsed, starting address alignment bad',0
errUBlkAlign2   db          '                In MarkBlockUsed, block length alignment bad',0
errUBlkBound    db          '             In MarkBlockUsed, block start not in managed bounds',0
errUBlkBound2   db          '          In MarkBlockUsed, block start+length not in managed bounds',0

errFBitAlign    db          '                In SetBitFree, starting address alignment bad',0
errFBitBound    db          '               In SetBitFree, block start not in managed bounds',0

errUBitAlign    db          '                In SetBitUsed, starting address alignment bad',0
errUBitBound    db          '               In SetBitUsed, block start not in managed bounds',0

errInit2        db          '           In PMMInit2, Unrecognized state for initialization > 32GB',0
errInit2Nomem   db          '           In PMMInit2, Unable to allocate memory for bitmap > 32GB',0

;==============================================================================================
; this .text section contains the code to implement the Physical Memory Management layer
;==============================================================================================

                section     .text
                bits        64

;----------------------------------------------------------------------------------------------
; void PMMInit(void) -- Initialize the bitmap structure.  The logic for this will be as
;                       follows:
;
; 1.  Get the memory limit as reported by multiboot
; 2.  Determine how many bitmap frames we need to manage our physical memory
; 3.  Set up the remaining fields in the PMM structure
; 4.  Set the whole lot to be 'used'
; 5.  Read the memory map and set type 1 entries to be 'free'
; 6.  Go back a third time and set the known physical memory to be 'used':
;     * Kernel Code
;     * Kernel Data
;     * Paging Tables
;     * PMM bitmap
;
; Once this initialization is complete, the PMM should now be put in charge of the physical
; memory allocations.  This means no more cowboy shit when it comes to allocating physical
; memory.
;----------------------------------------------------------------------------------------------

                global      PMMInit

PMMInit:
                push        rbp                     ; save the caller's frame
                mov         rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; rave rcx
                push        rdx                     ; save rdx
                push        rsi                     ; save rsi
                push        rdi                     ; save rdi
                push        r11                     ; save r11

;----------------------------------------------------------------------------------------------
; set out pointer to the pmm structure
;----------------------------------------------------------------------------------------------

                mov.q       r11,pmm                 ; set the address of the PMM mgmt structure

;----------------------------------------------------------------------------------------------
; First, determine just how much memory we have to work with.  GetMemLimit is going to return
; the highest reported memory in the system.  We are working with frames.  So we will need to
; convert this to frames.  Luckily, this is easy: just shift right 12 bits.  We need to
; truncate any partial frame (VERY unlikely) anyway since we won't be able to use it.
;----------------------------------------------------------------------------------------------

                mov.q       rax,GetMemLimit         ; this must be a far call
                call        rax                     ; get the memory limit; rax now has mem amt

                shr.q       rax,12                  ; convert to frames trunc partials (rare)
                mov.q       [r11+PMM.sysFrames],rax ; save the MB upper memory limit

                mov.q       rcx,Frames32GB          ; damned 32-bit immediates!!
                cmp.q       rax,rcx                 ; are we dealing with more than 32GB?
                jbe         .saveMax                ; if not, just go on
                mov.q       rax,rcx                 ; truncate the memory to 32GB

.saveMax:       mov.q       [r11+PMM.curFrames],rax ; save the current managed limit

;----------------------------------------------------------------------------------------------
; Step #1 is complete.
;
; Now we need to determine how many frames of bitmap we need to manage our total physical
; memory.  This should be easy as 1 bitmap frame (4KB) contains 32Kbits.  Therefore,
; 1 frame of bitmap can manage 32K frames of physical memeory.  Confused?  I can be too!
; The answer, though, is simple: shift right by 15 bits to get the number of bitmap frames we
; need.
;
; Finally, in this case, we need to adjust for having any partial bitmap frames worth of
; physical memory frames as we want to be able to manage all of it.
;----------------------------------------------------------------------------------------------

                mov.q       rcx,rax                 ; move the frame count to a work reg
                shr.q       rcx,15                  ; get the number of frames

                test.q      rax,0x0000000000007fff  ; do we have a partial frame leftover?
                jz          .calcFrames             ; if no partial frame, skip next part

                inc         rcx                     ; we have a partial frame, inc count

.calcFrames:    mov.q       [r11+PMM.bmFrames],rcx  ; save the number of frames in the bitmap

;----------------------------------------------------------------------------------------------
; Step #2 is complete.
;
; Now we initialize the remaining fields in the PMM structure.  It's actually pretty straight
; forward.  pmm.bitmap is actually a constant and is easily populated.  pmm.bmFrames,
; pmm.sysFrames, and pmm.curFrames have already been initialized with the work we have done so
; far.  pmm.freeFrames is initialized to 0.  That leaves pmm.searchIdx and pmm.maxIndex.
;
; pmm.maxIndex is actually a qword count of the frames in the bitmap.  512 qwords per 4K, so we
; shift pmm.bmFrames << 9 to get the max index.
;
; pmm.searchIdx is taken from the highest physical memory we know we have used.  That actually
; comes from the PagingInit() function which has a nextFrame variable.  We can take that
; frame address stored in the nextFrame variable and convert it to an index and we will start
; searching there.  So, we shift:
; * right by 12 to convert the physical address into a physical frame
; * right by 3 to convert the physical frame into a byte offset into the bitmap
; * right by 3 to convert the byte offset into a qword index into the bitmap
; All told, we shift right by 18 bits to convert an address into a bitmap index.
;----------------------------------------------------------------------------------------------

                mov.q       rax,PMM_VIRT                ; get the virt address of the bitmap
                mov.q       [r11+PMM.bitmap],rax        ; and store it in the struct field

                shl.q       rcx,9                       ; convert bmFrames to index max
                mov.q       [r11+PMM.maxIndex],rcx      ; store that in the struct

                mov.q       rbx,nextFrame               ; get the address of the next frame
                xor.q       rcx,rcx                     ; clear rcx -- reading dword
                mov.d       ecx,[rbx]                   ; collect that frame address
                shr.q       rcx,18                      ; convert the address into an index
                mov.q       [r11+PMM.searchIdx],rcx     ; save the search starting point

                mov.q       [r11+PMM.freeFrames],0      ; set the free frames to 0

;----------------------------------------------------------------------------------------------
; This now completes step #3.
;
; Now, we need to go through and set the entire bitmap to be used.  We do this because the
; memory map from multiboot is not assumed to be complete and any missing memory should be
; assumed to be not available.  Remember, we limit ourselves to 32BG of frames.
;
; Note also that the method here is chosed for 2 reasons: 1) for speed, and 2) to preserve the
; set up we did with the pmm.freeFrames field.  The functions to mark a frame free and used
; will maintain this count.  So, with everthing "artificially" set to be used, when we free
; the memory in the next step using these "real" functions, this free frames count will be
; properly maintained.
;
; Note also that this method will extend beyond the limits of the actual number of physical
; frames in that if there is any extra space left over, that extra space will also be set to
; a used state.  In this way, we guarantee that we will not offer a frame of physical memory
; that does not exist.
;----------------------------------------------------------------------------------------------

                mov.q       rcx,[r11+PMM.bmFrames]  ; get the bitmap # frames
                shl.q       rcx,9                   ; convert the frames to qwords
                mov.q       rdi,[r11+PMM.bitmap]    ; get the starting address of the bitmap
                xor.q       rax,rax                 ; clear rax to set the qwords to used

                rep         stosq                   ; set the bitmap to used

;----------------------------------------------------------------------------------------------
; This completes step #4.
;
; The next step consists of taking the type 1 entries of the multiboot memory map (available
; memory) and setting the frames to be free.  However, this time we will use the
; PMMMarkBlockFree function (which in turn uses the PMMSetBitFree function to maintain the free
; frames count).
;
; We start by getting the first free mmap block from multiboot.  If null, we have the last
; entry and need to move on.
;----------------------------------------------------------------------------------------------

                mov.q       rax,GetFreeFirst        ; get the address of the function
                call        rax                     ; and make a far call to it

;----------------------------------------------------------------------------------------------
; At this point, rax has the address of the mmap structure or NULL if we are done with all
; free entries
;----------------------------------------------------------------------------------------------

.loop:          cmp.q       rax,0                   ; are we done?
                je          .mapKernel              ; if so, go map the kernel memory

;----------------------------------------------------------------------------------------------
; We need to doubel check that the starting address < 32GB and that the starting address + size
; is also < 32GB.
;----------------------------------------------------------------------------------------------

                mov.q       rbx,[rax+FreeMem.str]   ; get the starting address
                mov.q       rsi,_32GB               ; get the _32GB constant
                cmp.q       rbx,rsi                 ; are we starting > 32GB?
                jae         .iter                   ; if so, next block please

                mov.q       rcx,[rax+FreeMem.size]  ; get the size of the block
                mov.q       rdx,rcx                 ; we need a working value as well
                add.q       rdx,rbx                 ; add the start and the size together
                cmp.q       rdx,rsi                 ; is the end of the block > 32GB?
                jb          .free                   ; < 32GB, we are good to free the block

;----------------------------------------------------------------------------------------------
; here we need to adjust the size back to have the block end at 32GB.  The algorithm is simple:
; 32GB - starting address is the new size.
;----------------------------------------------------------------------------------------------

                mov.q       rcx,_32GB               ; start with 32GB
                sub.q       rcx,rbx                 ; back out the starting address

;----------------------------------------------------------------------------------------------
; now we just need to mark the block as free
;----------------------------------------------------------------------------------------------

.free:          and.q       rbx,~0x0fff             ; align the starting address
                and.q       rcx,~0x0fff             ; align the block size

                push        rcx                     ; push the size
                push        rbx                     ; push the starting address
                call        MarkBlockFree           ; free the block
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; get the next block
;----------------------------------------------------------------------------------------------

.iter:          mov.q       rax,GetFreeNext         ; get the address of the function
                call        rax                     ; and make a far call to it

                jmp         .loop                   ; loop again

;----------------------------------------------------------------------------------------------
; This completes step #5.
;
; The last step is to record the physical memory being used in the system.  The way I see it,
; there are 2 ways to handle this:
; 1) go through the paging tables and for every present page, mark the associated frame as
;    used in the bitmap.
; 2) We know what we have done so far in the physical memory space, just mark it as used.
;
; So, for now, I am going with option 2 even though option 1 would be less prone to missing
; something.  I think I have a good handle on the blocks to map:
; * Addresses 0 - 4MB was identity mapped in PagingInit().  The PMM bitmap is already included
;   in this mapping, so we should be good with that space.
; * Addresses 4MB - nextFrame in pagetables.s will need to be marked used.  This space is used
;   by the paging tables.
;
; Note that there is no need to map these 2 segments separately.  We can simply start at
; address 0 and continue mapping until we get to nextFrame.  Put another way, nextFrame is also
; the amount of memory to mark as used if we start at address 0.  That's what I will do.
;----------------------------------------------------------------------------------------------

.mapKernel:     xor.q       rax,rax                 ; clear upper bits of rax
                mov.d       eax,[nextFrame]         ; get next frame addr from pagetables.s
                push        rax                     ; push it on the stack
                push        0                       ; and push the starting address 0
                call        MarkBlockUsed           ; mark the block as used
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:           pop         r11                     ; restore r11
                pop         rdi                     ; restore rdi
                pop         rsi                     ; restore rsi
                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void PMMInit2(void) -- When we initialized the physical memory manager in PMMInit(), we only
;                        established memory for a limit of 32GB of physical memory.  It is
;                        possible that the computer could have much more than this -- up to
;                        256TB of physical memory.  We want to be able to manage and make use
;                        of all of this memory.  PMMInit2 will extend the initialization of the
;                        PMM sturcture to include all available physical memory.
;
; This function is called regardless of the memory installed on the system.  When this function
; is called, there are 3 mutually exclusive conditions that could be met and each has its own
; actions to be taken:
; 1)  The value in pmm.sysFrames is the same as the value in pmm.curFrames and the value in
;     both these fields is == _32GB.  This means we have exactly 32GB physical memory installed
;     on the system and the highest address reported by multiboot is exactly 32GB.  In this
;     case, our initialization is complete and we can exit.  Note that this is an unlikely
;     scenario.
; 2)  The value in pmm.sysFrames is the same as the value in pmm.curFrames and the value in
;     both these fields is <> _32GB.  This means we have less than 32GB physical memory
;     installed on the system.  In this case, we need to clean up the extra frames allocated to
;     the bitmap > pmm.bmFrames and release these back to the PMM.
; 3)  The value in pmm.sysFrames is > 32GB.  This means we have more than 32GB memory installed
;     on the system and will need to extend the initialization of the additional memory.  The
;     logic for this extended inisialization will look very similar to PMMInit(), except that
;     we will operate on the portions above _32GB rather than below _32GB.  Also, we now have
;     the benefit of the VMM being online, so the actual code should be simplified a bit.
;
; Anything other than one of these 3 specific scenarios will generate an error and stop the
; system.
;
; Finally, it is important to recognize that we are "rounding up" to 32GB.  One frame of bitmap
; is able to keep track of 128MB of physical memory.  So, a system with physical memory in the
; range from 32GB-(128MB-4KB) to 32GB is all considered to have the same amount of memory:
; 32GB.  This is because it takes the same number of frames to manage this memory.
;----------------------------------------------------------------------------------------------

                global      PMMInit2

PMMInit2:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rsi                     ; save rsi
                push        r9                      ; save r9
                push        r10                     ; save r10
                push        r11                     ; save r11

                mov.q       r11,pmm                 ; get the memory management struct addr

;----------------------------------------------------------------------------------------------
; First, we need to determine which state we are in.  State #1 is not the most likely, so we
; will check that last.  State #3 is simpler than state #2, so we will check that first.
;----------------------------------------------------------------------------------------------

                mov.q       rbx,[r11+PMM.curFrames] ; get the current number of frames
                shl.q       rbx,12                  ; convert frames to address length

                mov.q       rcx,[r11+PMM.sysFrames] ; get the number of frames
                shl.q       rcx,12                  ; convert frames to address length

                mov.q       rax,_32GB               ; get the 32GB constant
                cmp.q       rcx,rax                 ; how we relate to 32GB
                ja          .state3                 ; more than 32GB, we have state 3
                jb          .s2chk                  ; if less than 32GB, double check state 2

;----------------------------------------------------------------------------------------------
; here we know pmm.sysFrames holds 32GB exactly.  double check pmm.curFrames to make sure we
; have state #1.
;----------------------------------------------------------------------------------------------

                cmp.q       rbx,rax                 ; how are we comparing against 32GB
                je          .state1                 ; pretty sure we have state 1 now
                jmp         .error                  ; we know we have a problem

;----------------------------------------------------------------------------------------------
; double check that we have state2.
;----------------------------------------------------------------------------------------------

.s2chk:         cmp.q       rbx,rax                 ; how are we comparing against 32GB
                jne         .state2                 ; pretty sure we have state 2 now
                jmp         .error                  ; we know we have a problem

;----------------------------------------------------------------------------------------------
; we have an error, so let's report it
;----------------------------------------------------------------------------------------------

.error:         mov.q       rax,errInit2            ; get the error message address
                push        rax                     ; push it on the stack
                call        pmmError                ; display the error screen

;----------------------------------------------------------------------------------------------
; we think we are working with state1: exactly 32GB memory; the last check is to make sure
; pmm.sysFrames == pmm.curFrames.
;----------------------------------------------------------------------------------------------

.state1:        cmp.q       rbx,rcx                 ; compare pmm.sysFrames with pmm.curFrames
                jne         .error                  ; if not the same, we have an error

;----------------------------------------------------------------------------------------------
; from here it is trivial...  we are fully initialized and fully cleaned up.  Just exit!
;----------------------------------------------------------------------------------------------

                jmp         .out                    ; we are done; exit

;----------------------------------------------------------------------------------------------
; we think we are working with state2: < 32GB memory; the last check is to make sure
; pmm.sysFrames == pmm.curFrames.
;----------------------------------------------------------------------------------------------

.state2:        cmp.q       rbx,rcx                 ; compare pmm.sysFrames with pmm.curFrames
                jne         .error                  ; if not the same, we have an error

;----------------------------------------------------------------------------------------------
; At this point, we know that we have less than 32GB of memory and we will be able to release
; at least 1 frame of memory.  Actually, we will unmap the page and free the frame until since
; we will only release the identity mapping we did in lower memory.
;
; So, how do we know where to freeing these pages?  Well, that's what pmm.bmFrames is for.
; pmm.bmFrames is the first frame that we can free (since the frames are 0-based).  Finally,
; since there are 256 frames in the space we allocated, it is very easy to figure out exactly
; what we need to deallocate.
;----------------------------------------------------------------------------------------------

                mov.q       rbx,[r11+PMM.bmFrames]  ; get the number of frames

                mov.q       rcx,256                 ; set the maximum number of pages possible
                sub.q       rcx,rbx                 ; get the number of pages we want to clear

                shl.q       rbx,12                  ; convert the frames to addresses

                mov.q       rsi,[r11+PMM.bitmap]    ; get the bitmap address
                add.q       rsi,rbx                 ; get the address of the first page to free

;----------------------------------------------------------------------------------------------
; now we have everything prepared and it's just a matter of calling the vmm function to free
; the memory
;----------------------------------------------------------------------------------------------

                push        rcx                     ; push the number of pages to free
                push        rsi                     ; push the starting frame to free
                call        VMMFree                 ; go and free the memory
                add.q       rsp,16                  ; clean up the stack

                jmp         .out                    ; that's it!  we are done; exit

;----------------------------------------------------------------------------------------------
; we are working with state3: > 32GB memory; there is nothing else to check.
;
; So, the first thing we need to do is to recalculate the bmFrames and other fields we will
; ultimately be updating in the pmm structure.  Keep in mind that since the pmm is fully
; operational with 32GB memory, we cannot update these fields in the structure with the full
; new values until everything has been properly initialized.  As a result, we need to keep the
; new values in work fields to be sure we don't create a problem.
;----------------------------------------------------------------------------------------------

.state3:
                mov.q       r9,[r11+PMM.sysFrames]  ; get the total number of frames we manage
                mov.q       rax,Frames32GB          ; get the constant val of 32GB frame count
                sub.q       r9,rcx                  ; r9 holds the new value for pmm.curFrames

                mov.q       r10,r9                  ; copy the curFrames into r10
                shr.q       r10,15                  ; convert curFrames into bmFrames

                test.q      r9,0x0000000000007fff   ; do we have a partial frame leftover?
                jz          .calcFrames             ; if not, we can skip the extra frame

                inc         r10                     ; add 1 extra frame to manage the partial

.calcFrames:    sub.q       r10,256                 ; we already allocated 256 frames...

                mov.q       rsi,[r11+PMM.bitmap]    ; get the bitmap address
                add.q       rsi,0x100000            ; move past the first 1MB, already mapped

;----------------------------------------------------------------------------------------------
; Now we need to ask the VMM to map the additional pages.  This is a significant step since the
; VMM is going to ask the PMM for additional memory and the PMM is not yet fully initialized.
; Going through some quick calculations and fact checking, we know we have more than 32GB of
; memory on the system to manage.  We know we can have up to 256TB of memory physically
; installed on the system.  If we take 256TB and shift right by 12 bits to convert this to
; physical frames and then shift right again by 15 bits to convert this to bitmap frames
; required (shift right by 27 bits), we need a total of 8GB of memory to manage all 256TB of
; system physical memory.  Since we are already managing 32GB of memory, we have enough memory
; available to establish the bitmap for all possible physical memory.
;----------------------------------------------------------------------------------------------

                push        r10                     ; push the number of pages we need
                push        rsi                     ; push the starting virtual address
                call        VMMAlloc                ; go and allocate the memory
                add.q       rsp,16                  ; clean up the stack

                cmp.q       rax,VMM_ERR_NOMEM       ; did we run out of memory?
                jne         .clear                  ; if not, we can clear the bits

                mov.q       rax,errInit2Nomem       ; get the error message
                push        rax                     ; push it on the stack
                call        pmmError                ; report the error and kill system

;----------------------------------------------------------------------------------------------
; so, just like in PMMInit above, we will follow the same method to setup the bitmap.  First
; we will 'artificially' mark everything as used.
;----------------------------------------------------------------------------------------------

.clear:         mov.q       rcx,R10                 ; get the bitmap additional # frames
                shl.q       rcx,9                   ; convert the frames to qwords
                mov.q       rdi,rsi                 ; get the starting addr for add'l bitmap
                xor.q       rax,rax                 ; clear rax to set the qwords to used

                rep         stosq                   ; set the bitmap to used

;----------------------------------------------------------------------------------------------
; Also, just like above, we will mark everything that multiboot gave us as free memory as free.
;----------------------------------------------------------------------------------------------

                mov.q       rax,GetFreeFirst        ; get the address of the function
                call        rax                     ; and make a far call to it

;----------------------------------------------------------------------------------------------
; At this point, rax has the address of the mmap structure or NULL if we are done with all
; free entries
;----------------------------------------------------------------------------------------------

.loop:          cmp.q       rax,0                   ; are we done?
                je          .out                    ; if so, go map the kernel memory

;----------------------------------------------------------------------------------------------
; We need to double check that the ending address is >32GB.  If it is not, we skip the block.
; If it is > 32GB, then we need to make sure the starting address is >=32GB.  If it is < 32GB,
; we will adjust it up to 32GB since we already initialized up to 32GB.
;----------------------------------------------------------------------------------------------

                mov.q       rbx,[rax+FreeMem.str]   ; get the starting address
                mov.q       rcx,[rax+FreeMem.size]  ; get the size of the block
                mov.q       rdx,rcx                 ; we need a working value as well
                add.q       rdx,rbx                 ; add the start and the size together
                mov.q       r12,_32GB               ; get the _32GB constant

                cmp.q       rdx,r12                 ; are we ending < 32GB?
                jb          .iter                   ; if so, next block please

                cmp.q       rbx,r12                 ; is the start >= 32GB
                jae          .free                  ; < 32GB, we are good to free the block

;----------------------------------------------------------------------------------------------
; here we need to adjust the starting physical memory address to 32GB
;----------------------------------------------------------------------------------------------

                add.q       rcx,rbx                 ; adjust the size back to start addr == 0
                mov.q       rbx,_32GB               ; start with 32GB
                sub.q       rcx,rbx                 ; adjust the size to the new start addr

;----------------------------------------------------------------------------------------------
; now we just need to mark the block as free
;----------------------------------------------------------------------------------------------

.free:          and.q       rbx,~0x0fff             ; align the starting address
                and.q       rcx,~0x0fff             ; align the block size

                push        rcx                     ; push the size
                push        rbx                     ; push the starting address
                call        MarkBlockFree           ; free the block
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; get the next block
;----------------------------------------------------------------------------------------------

.iter:          mov.q       rax,GetFreeNext         ; get the address of the function
                call        rax                     ; and make a far call to it

                jmp         .loop                   ; loop again

;----------------------------------------------------------------------------------------------
; Note that we have no need to go back and map out anything that was used before the PMM was
; put in charge.  This is because nothing has been used above 32GB.
;
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                pop         r11                     ; restore r11
                pop         r10                     ; restore r10
                pop         r9                      ; restore r9
                pop         rsi                     ; restore rsi
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void MarkBlockFree(qword strart, qword length) -- Mark a block of pages free.  This function
;                                                   should only be called from within this
;                                                   source or from the Virtual Memory manager.
;
; The following sanity checks are completed in this function:
; 1. start&0xfff == 0
; 2. end&0xfff == 0
; 3. start <= pmm.curFrames<<12
; 4. (start+length) <= pmm.curFrames<<12
;----------------------------------------------------------------------------------------------

                global      MarkBlockFree

MarkBlockFree:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdi                     ; save rdi
                push        r11                     ; save r11

                mov.q       r11,pmm                 ; get the structure address

;----------------------------------------------------------------------------------------------
; get the arguments into the registers and start the sanity checks.
;
; sanity check #1 is that start & 0xfff == 0
;----------------------------------------------------------------------------------------------

.test1:         mov.q       rdi,[rbp+16]            ; get the starting address
                test.q      rdi,0x0fff              ; is the addr page aligned?
                jz          .test2                  ; if none set, we can move on

                mov.q       rax,errFBlkAlign        ; get the error message
                push        rax                     ; push the parm
                call        pmmError                ; call teh error screen and die

;----------------------------------------------------------------------------------------------
; sanity check #2 -- length is page aligned
;----------------------------------------------------------------------------------------------

.test2:         mov.q       rcx,[rbp+24]            ; get the size
                test.q      rcx,0x0fff              ; is the length page aligned?
                jz          .test3                  ; if none set, we can move on

                mov.q       rax,errFBlkAlign2       ; get the error message
                push        rax                     ; push the parm
                call        pmmError                ; call teh error screen and die

;----------------------------------------------------------------------------------------------
; sanity check #3 -- start address <= pmm.curFrames << 12
;----------------------------------------------------------------------------------------------

.test3:         mov.q       rax,[r11+PMM.curFrames] ; get the frame count
                shl.q       rax,12                  ; convert frames to address
                cmp.q       rdi,rax                 ; is start address <= pmm.curFrames << 12?
                jbe         .test4                  ; if good, we go on

                mov.q       rax,errFBlkBound        ; get the error message
                push        rax                     ; push the parm
                call        pmmError                ; call teh error screen and die

;----------------------------------------------------------------------------------------------
; sanity check #4 -- start address + length <= pmm.curFrames << 12
;----------------------------------------------------------------------------------------------

.test4:         mov.q       rbx,rdi                 ; get the starting address
                add.q       rbx,rcx                 ; add the length
                cmp.q       rbx,rax                 ; is start + length <= pmm.curFrames << 12?
                jbe         .good                   ; if good, we go on

                mov.q       rax,errFBlkBound2       ; get the error message
                push        rax                     ; push the parm
                call        pmmError                ; call teh error screen and die

;----------------------------------------------------------------------------------------------
; OK, so we got here, we know we have something we will be able to work with
;----------------------------------------------------------------------------------------------

.good:          sub.q       rsp,8                   ; make room on the stack for 1 parm
                shr.q       rcx,12                  ; convert the byte length into frames

;----------------------------------------------------------------------------------------------
; this is the business part of this function.  free each bit in the bitmap
;----------------------------------------------------------------------------------------------

.loop:          mov.q       [rsp],rdi               ; set this value for the function
                call        SetBitFree              ; call the function

                add.q       rdi,0x1000              ; move to the next page
                loop        .loop                   ; dec rcx & loop until rcx is 0

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:           add.q       rsp,8                   ; clean up the stack

                pop         r11                     ; restore r11
                pop         rdi                     ; restore rdi
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore the caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void MarkBlockUsed(qword strart, qword length) -- Mark a block of pages used.  This function
;                                                   should only be called from within this
;                                                   source or from the Virtual Memory manager.
;
; The following sanity checks are completed in this function:
; 1. start&0xfff == 0
; 2. end&0xfff == 0
; 3. start <= pmm.curFrames<<12
; 4. (start+length) <= pmm.curFrames<<12
;----------------------------------------------------------------------------------------------

                global      MarkBlockUsed

MarkBlockUsed:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdi                     ; save rdi
                push        r11                     ; save r11

                mov.q       r11,pmm                 ; get the structure address

;----------------------------------------------------------------------------------------------
; get the arguments into the registers and start the sanity checks.
;
; sanity check #1 is that start & 0xfff == 0
;----------------------------------------------------------------------------------------------

.test1:         mov.q       rdi,[rbp+16]            ; get the starting address
                test.q      rdi,0x0fff              ; is the addr page aligned?
                jz          .test2                  ; if none set, we can move on

                mov.q       rax,errUBlkAlign        ; get the error message
                push        rax                     ; push the parm
                call        pmmError                ; call teh error screen and die

;----------------------------------------------------------------------------------------------
; sanity check #2 -- length is page aligned
;----------------------------------------------------------------------------------------------

.test2:         mov.q       rcx,[rbp+24]            ; get the size
                test.q      rcx,0x0fff              ; is the length page aligned?
                jz          .test3                  ; if none set, we can move on

                mov.q       rax,errUBlkAlign2       ; get the error message
                push        rax                     ; push the parm
                call        pmmError                ; call teh error screen and die

;----------------------------------------------------------------------------------------------
; sanity check #3 -- start address <= pmm.curFrames << 12
;----------------------------------------------------------------------------------------------

.test3:         mov.q       rax,[r11+PMM.curFrames] ; get the frame count
                shl.q       rax,12                  ; convert frames to address
                cmp.q       rdi,rax                 ; is start address <= pmm.curFrames << 12?
                jbe         .test4                  ; if good, we go on

                mov.q       rax,errUBlkBound        ; get the error message
                push        rax                     ; push the parm
                call        pmmError                ; call teh error screen and die

;----------------------------------------------------------------------------------------------
; sanity check #4 -- start address + length <= pmm.curFrames << 12
;----------------------------------------------------------------------------------------------

.test4:         mov.q       rbx,rdi                 ; get the starting address
                add.q       rbx,rcx                 ; add the length
                cmp.q       rbx,rax                 ; is start + length <= pmm.curFrames << 12?
                jbe         .good                   ; if good, we go on

                mov.q       rax,errUBlkBound2       ; get the error message
                push        rax                     ; push the parm
                call        pmmError                ; call teh error screen and die

;----------------------------------------------------------------------------------------------
; OK, so we got here, we know we have something we will be able to work with
;----------------------------------------------------------------------------------------------

.good:          sub.q       rsp,8                   ; make room on the stack for 1 parm
                shr.q       rcx,12                  ; convert the byte length into frames

;----------------------------------------------------------------------------------------------
; this is the business part of this function.  free each bit in the bitmap
;----------------------------------------------------------------------------------------------

.loop:          mov.q       [rsp],rdi               ; set this value for the function
                call        SetBitUsed              ; call the function

                add.q       rdi,0x1000              ; move to the next page
                loop        .loop                   ; loop until rcx is 0

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:           add.q       rsp,8                   ; clean up the stack

                pop         r11                     ; restore r11
                pop         rdi                     ; restore rdi
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore the caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void PMMSetBitFree(qword addr) -- Mark a page as free by setting its flag to be a '1'
; void PMMFreeFrame(qword frame) -- Free a memory frame back to the pool.
;
; These functions do the same thing (the only possible difference might be clearing the page
; before releasing the frame.
;
; The following sanity checks are completed in this function:
; 1. addr&0xfff == 0
; 2. addr <= pmm.curFrames<<12
;----------------------------------------------------------------------------------------------

                global      FreeFrame

FreeFrame:
SetBitFree:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdx                     ; save rdx
                push        rsi                     ; save rsi
                push        r11                     ; save r11
                pushfq                              ; save flags
                cli                                 ; PMMFreeMem is called globally; clear ints

                mov.q       r11,pmm                 ; get the structure address

;----------------------------------------------------------------------------------------------
; sanity check #1 is that addr & 0xfff == 0
;----------------------------------------------------------------------------------------------

                mov.q       rax,[rbp+16]            ; get the frame address
                test.q      rax,0x0fff              ; is the addr page aligned?
                jz          .test2                  ; if none set, we can move on

                mov.q       rax,errFBitAlign        ; get the error message
                push        rax                     ; push the parm
                call        pmmError                ; call thes error screen and die

;----------------------------------------------------------------------------------------------
; sanity check #2 -- start address <= pmm.curFrames << 12
;----------------------------------------------------------------------------------------------

.test2:         mov.q       rcx,[r11+PMM.curFrames] ; get the frame count
                shl.q       rcx,12                  ; convert frames to address
                cmp.q       rax,rcx                 ; is start address <= pmm.curFrames << 12?
                jbe         .good                   ; if good, we go on

                mov.q       rax,errFBitBound        ; get the error message
                push        rax                     ; push the parm
                call        pmmError                ; call the error screen and die

;----------------------------------------------------------------------------------------------
; setup the information needed to reference the bitmap
;----------------------------------------------------------------------------------------------

.good:          shr.q       rax,12                  ; divide by 4K to get frame #

                mov.q       rcx,rax                 ; we will need to get the bit number
                and.q       rcx,0x003f              ; mask out the bit number -- fits in cl

                mov.q       rbx,rax                 ; we need to get the qword offset to bitmap
                shr.q       rbx,6                   ; divide by 64 to get qword number
                shl.q       rbx,3                   ; multiply by 8 to get a byte offset

                mov.q       rdx,1                   ; make rdx 1
                shl.q       rdx,cl                  ; rdx now holds the bit mask we want to chk

;----------------------------------------------------------------------------------------------
; now we need to get to the address in the bitmap
;----------------------------------------------------------------------------------------------

                mov.q       rsi,[r11+PMM.bitmap]    ; get the table address
                add.q       rsi,rbx                 ; rsi now holds the address of the qword
                or.q        [rsi],rdx               ; set the bit to free

;----------------------------------------------------------------------------------------------
; finally, we increment the number of free frames
;----------------------------------------------------------------------------------------------

                lea.q       rax,[r11+PMM.freeFrames] ; get the address of the free frames field
                inc         qword [rax]              ; increment the number of free frames

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

                popfq                               ; restore the flags (restore int flag)
                pop         r11                     ; restore r11
                pop         rsi                     ; restore rsi
                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void SetBitUsed(qword addr) -- Mark a page as used by setting its flag to be a '0'
;
; The following sanity checks are completed in this function:
; 1. addr&0xfff == 0
; 2. addr <= pmm.curFrames<<12
;----------------------------------------------------------------------------------------------

SetBitUsed:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdx                     ; save rdx
                push        rsi                     ; save rsi
                pushfq                              ; save flags
                cli                                 ; PMMFreeMem is called globally; clear ints

                mov.q       r11,pmm                 ; get the structure address

;----------------------------------------------------------------------------------------------
; sanity check #1 is that addr & 0xfff == 0
;----------------------------------------------------------------------------------------------

                mov.q       rax,[rbp+16]            ; get the frame address
                test.q      rax,0x0fff              ; is the addr page aligned?
                jz          .test2                  ; if none set, we can move on

                mov.q       rax,errUBitAlign        ; get the error message
                push        rax                     ; push the parm
                call        pmmError                ; call thes error screen and die

;----------------------------------------------------------------------------------------------
; sanity check #2 -- start address <= pmm.curFrames << 12
;----------------------------------------------------------------------------------------------

.test2:         mov.q       rcx,[r11+PMM.curFrames] ; get the frame count
                shl.q       rcx,12                  ; convert frames to address
                cmp.q       rax,rcx                 ; is start address <= pmm.curFrames << 12?
                jbe         .good                   ; if good, we go on

                mov.q       rax,errUBitBound        ; get the error message
                push        rax                     ; push the parm
                call        pmmError                ; call the error screen and die

;----------------------------------------------------------------------------------------------
; setup the information needed to reference the bitmap
;----------------------------------------------------------------------------------------------

.good:          shr.q       rax,12                  ; divide by 4K to get page #

                mov.q       rcx,rax                 ; we will need to get the bit number
                and.q       rcx,0x000000000000003f  ; mask out the bit number -- fits in cl

                mov.q       rbx,rax                 ; we need to get the qword offset to bitmap
                shr.q       rbx,6                   ; divide by 64 to get qword number
                shl.q       rbx,3                   ; multiply by 8 to get a byte offset

                mov.q       rdx,1                   ; make rdx 1
                shl.q       rdx,cl                  ; rdx now holds the bit mask we want to chk

                not.q       rdx                     ; flip the bits

;----------------------------------------------------------------------------------------------
; now we need to get to the address in the bitmap
;----------------------------------------------------------------------------------------------

                mov.q       rsi,PMM_VIRT            ; get the table address
                add.q       rsi,rbx                 ; rsi now holds the address of the qword
                and.q       [rsi],rdx               ; set the bit to used

;----------------------------------------------------------------------------------------------
; finally, we decrement the number of free frames
;----------------------------------------------------------------------------------------------

                lea.q       rax,[r11+PMM.freeFrames] ; get the address of the free frames field
                dec         qword [rax]              ; decrement the number of free frames

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

                popfq                               ; restore the flags (restore int flag)
                pop         rsi                     ; restore rsi
                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword AllocFrame(void) -- allocate a frame of physical memory anywhere in the system.
;----------------------------------------------------------------------------------------------

                global      AllocFrame

AllocFrame:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame

                push        -1                      ; set no limit
                call        AllocFrameLimit         ; go allocate the memory
                add.q       rsp,8                   ; clean up the stack

                pop         rbp                     ; restore the caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword AllocFrameLimit(qword limit) -- allocate a frame of physical memory that is fully
;                                       in address space LOWER (not equal to) the limit
;                                       specified.  The only exception is if the limit is
;                                       -1 (0xffff ffff ffff ffff), then the frame can come
;                                       from anywhere in the system.
;----------------------------------------------------------------------------------------------

                global      AllocFrameLimit

AllocFrameLimit:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdx                     ; save rdx
                push        rsi                     ; save rsi
                push        r9                      ; save r9
                push        r11                     ; save r11
                push        r14                     ; save r14
                push        r15                     ; save r15
                pushfq                              ; save the flags for int state
                cli                                 ; please don't interrupt me!

                mov.q       r11,pmm                 ; get the structure address

;----------------------------------------------------------------------------------------------
; we need to set up some registers for our search.
;----------------------------------------------------------------------------------------------

                mov.q       r15,[r11+PMM.searchIdx] ; get the starting value
                mov.q       r14,r15                 ; we also need a working value

                mov.q       r9,[rbp+16]             ; finally, we need to calc the upper limit
                cmp.q       r9,-1                   ; do we have a limit
                je          .skipLimit              ; if no limit, skip the calc
                shr.q       r9,18                   ; we need an upper index for searching

;----------------------------------------------------------------------------------------------
; get the start of the bitmap table
;----------------------------------------------------------------------------------------------

.skipLimit:     mov.q       rbx,[r11+PMM.bitmap]    ; get the bitmap address

;----------------------------------------------------------------------------------------------
; check if we have gone past our limits -- check max address
;----------------------------------------------------------------------------------------------

.loop:          cmp.q       r9,-1                   ; do we have a limit?
                je          .nextChk                ; if no limit, skip next part

                cmp.q       r9,r14                  ; are we past our limit?
                jb          .nextChk                ; in range, go to next check

                xor.q       r14,r14                 ; clear the index so we can continue search

;----------------------------------------------------------------------------------------------
; reached end of table?
;----------------------------------------------------------------------------------------------

.nextChk:       mov.q       rax,[r11+PMM.maxIndex]  ; get the end on list var
                cmp.q       r14,rax                 ; are we at the end of the list?
                jb          .chkDone                ; if not at last byte, go chk is checked all
                xor         r14,r14                 ; start over at byte 0

;----------------------------------------------------------------------------------------------
; now, let's get the table qword and check if there is something free
;----------------------------------------------------------------------------------------------

.chkDone:       mov.q       rax,r14                 ; get the working value
                shl.q       rax,3                   ; convert the value to qwords

                mov.q       rcx,[rbx+rax]           ; get the bitmap qword
                cmp.q       rcx,0                   ; is the memory fully booked?
                jne         .found                  ; if some space, go get it

;----------------------------------------------------------------------------------------------
; nothing found, increment and loop
;----------------------------------------------------------------------------------------------

                inc         r14                     ; continue our search

                cmp.q       r14,r15                 ; check if we have fully looped
                jne         .loop                   ; if not, go check again

.noneFound:     mov.q       rax,0xffffffffffffffff  ; set the return to -1
                jmp         .out                    ; exit

;----------------------------------------------------------------------------------------------
; let's make sure we know what we know:
;  * rbx holds the address of the PMM_VIRT
;  * rcx holds the bitmap qword we found to have a free frame
;  * r14 holds the qword offset for the bitmap; this becomes the bits 63-18 of the frame
;
; we need to determine the free block bit which will become bits 17-12 of the frame; and
; remember that since we are 4K frame aligned, bits 11-0 will be 0.
;
; Now we only want to update the pmm.searchIdx var if we were not limited
;----------------------------------------------------------------------------------------------

.found:         cmp.q       r9,-1                   ; are we limited?
                jne         .calcAddr               ; if limited, we do not want to update index

                mov.q       [r11+PMM.searchIdx],r14 ; store the index

.calcAddr:      mov.q       rax,rcx             ; move the bitmap to rax
                xor.q       rcx,rcx             ; start at the lowest mem bit

.loop2:         mov.q       rdx,1               ; set a bit to check
                shl.q       rdx,cl              ; shift the bit to the proper location
                test.q      rax,rdx             ; check the bit
                jnz         .bitFound           ; we founf the proper bit; exit loop

                add.q       rcx,1               ; move to the next bit
                cmp.q       rcx,64              ; have we checked them all?
                jae         .noneFound          ; if we exhaust our options, exit with -1

                jmp         .loop2              ; loop some more

;----------------------------------------------------------------------------------------------
; now, we know the following:
;   * rbx holds the address of the PMM_VIRT
;   * rax holds the bitmap we found to have a free frame (which we don't need anymore)
;   * r14 holds the qword offset for the bitmap; this becomes the bits 63-18 of the frame
;   * rcx holds the bit number for the addr; this becomes bits 17-12 of the frame
;
; now we just need to assemble the final address, and mark the bit as used
;----------------------------------------------------------------------------------------------

.bitFound:      shl.q       r14,6               ; assemble in r14; make room for the bit#
                or.q        r14,rcx             ; mask in the bit number
                shl.q       r14,12              ; now we have the proper address in r14

                push        r14                 ; push it on the stack for a parm
                call        SetBitUsed          ; set the bit as used
                pop         rax                 ; set the return value as well

.out:
                popfq
                pop         r15                 ; restore r15
                pop         r14                 ; restore r14
                pop         r11                 ; restore r11
                pop         r9                  ; restore r9
                pop         rsi                 ; restore rsi
                pop         rdx                 ; restore rdx
                pop         rcx                 ; restore rcx
                pop         rbx                 ; restore rbx
                pop         rbp                 ; restore the caller's frame
                ret

;==============================================================================================

;==============================================================================================
; Error, crash, and burn
;==============================================================================================

;----------------------------------------------------------------------------------------------
; void pmmError(qword msg) -- this function is called in the event of a physical memory manager
;                             error.  It will not return.  It will dump some of the critical
;                             related pmm structures and will die a miserable death.
;----------------------------------------------------------------------------------------------

                global      pmmError

pmmError:
                cli                         ; immediately clear interrupts -- we will never ret
                push        rbp             ; save caller's frame -- might want to unwind stack
                mov.q       rbp,rsp         ; create our own frame; we dont ret -- save no regs
                sub.q       rsp,64          ; make room for 8 parameters for function calls

                mov.q       [rsp],0x0c      ; set the color: white on red
                call        TextSetAttr     ; set the attribute color
                call        TextClear       ; clear the screen to a red color

;----------------------------------------------------------------------------------------------
; line 1 -- Screen header so you know what kind of error it is
;----------------------------------------------------------------------------------------------

.line01:        mov.q       rax,pmmErrHdr   ; get the header text for the screen
                mov.q       [rsp],rax       ; set the parameter
                call        TextPutString   ; and write it to the screen

;----------------------------------------------------------------------------------------------
; lines 2 & 3 & 4 -- Error message so you know why you are seeing this screen (plus a blank line)
;----------------------------------------------------------------------------------------------

.line02:        mov.q       [rsp],0x07      ; set the color: grey on red
                call        TextSetAttr     ; and set the attribute

                mov.q       rax,[rbp+16]    ; get the error message
                mov.q       [rsp],rax       ; store it as a parm
                call        TextPutString   ; and write it to the screen

                mov.q       [rsp],13        ; we want to put a linefeed on the screen
                call        TextPutChar     ; go ahead and write it
                call        TextPutChar     ; and again to create a blank line

;----------------------------------------------------------------------------------------------
; line 5 -- the pmm strucutre heading and its address
;----------------------------------------------------------------------------------------------

.line05:        mov.q       rax,pmmErrStruct; get the address of the pmm header text
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                mov.q       rbx,pmm         ; get the address of the pmm Struct
                mov.q       [rsp],rbx       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 6 --
;----------------------------------------------------------------------------------------------

.line06:        mov.q       rax,pmmErr.bitmap   ; get the address of the pmm header text
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                mov.q       rax,[rbx+PMM.bitmap]    ; get the bitmap address
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 7 --
;----------------------------------------------------------------------------------------------

.line07:        mov.q       rax,pmmErr.bmFrame  ; get the address of the pmm header text
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                mov.q       rax,[rbx+PMM.bmFrames]  ; get the bitmap address
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 8 --
;----------------------------------------------------------------------------------------------

.line08:        mov.q       rax,pmmErr.sysFram  ; get the address of the pmm header text
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                mov.q       rax,[rbx+PMM.sysFrames] ; get the system Frames address
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 9 --
;----------------------------------------------------------------------------------------------

.line09:        mov.q       rax,pmmErr.curFram  ; get the address of the pmm header text
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                mov.q       rax,[rbx+PMM.curFrames] ; get the current frames address
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 10 --
;----------------------------------------------------------------------------------------------

.line10:        mov.q       rax,pmmErr.srchIdx  ; get the address of the pmm header text
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                mov.q       rax,[rbx+PMM.searchIdx] ; get the search Index address
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 11 --
;----------------------------------------------------------------------------------------------

.line11:        mov.q       rax,pmmErr.maxIdx   ; get the address of the pmm header text
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                mov.q       rax,[rbx+PMM.maxIndex]  ; get the max Index address
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutHexQWord ; and write it to the screen

;----------------------------------------------------------------------------------------------
; line 12 --
;----------------------------------------------------------------------------------------------

.line12:        mov.q       rax,pmmErr.free; get the address of the pmm header text
                mov.q       [rsp],rax       ; and set the parameter
                call        TextPutString   ; and write it to the screen

                mov.q       rax,[rbx+PMM.freeFrames]; get the free frames address
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
