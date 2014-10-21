;==============================================================================================
;
; virtmm.s
;
; This file contains the functions and data that will be used to manage the virtual memory
; layer of this kernel
;
; Like the physical memory layer, this layer caused me a lot of internal debate.  Not about how
; to architect the layer, but how responsible to make it for the memory.  Should the VMM keep
; track of all virtual memeory independently, or should I make the requester responsible for
; knowing what it wants and let the VMM report back errors with the request?
;
; Well, after some comments from Brendan, I decided on the former design.  The comments are
; here: http://forum.osdev.org/viewtopic.php?f=1&t=28554&start=15#p240955.
;
; My own thoughts for this module are tracked here: http://redmine:3000/issues/174 (on my own
; personal network; so, if you are looking at this from github you are out of luck).  In short,
; this is a summary of the immediate first implementation:
;
; 		Based on some thoughts by Brendan in the thread linked below, the VMM should only be
;		architected to respond to specific requests. The caller needs to know what it is
;		asking for, and the VMM should be able to respond with success/failure.
;
; 		Here are some thoughts on functions I need immediately:
; 		* VMMAllocPages(virtAddr, pages, flags) -- Allocate <pages> frames of physical memory
;			and then maps them to virtual memory at virtAddr; will preset the frames to 0; sets
;			the region's flags
; 		* VMMFreePages(virtAddr, pages) -- Free a region of <pages> memory frames and free the
;			corresponding frames
; 		* VMMSetPageFlags(virtAddr, flags) -- Sets a page's flags in the Page Table Entry
; 		* VMMMapPage(virtAddr, frameAddr, flags) -- used during startup and creating user Page
;			Structures for shared memory; maps a virtual address page to a physical address
;			frame and set the specified flags in on the page
; 		* VMMUnmapPage(virtAddr) -- un-maps the specified page
;
; With all of that, the following are the functions delivered in this source file:
; void VMMInit(void);
; dword VMMUnmapPage(qword virtAddr);
;
;    Date     Tracker  Pgmr  Description
; ----------  ------   ----  ------------------------------------------------------------------
; 2014/10/17  Initial  ADCL  Initial code
;
;==============================================================================================

%define			__VIRTMM_S__
%include		'private.inc'

;==============================================================================================
; The .text section is part of the kernel proper
;==============================================================================================
				section		.text
				bits		64

;----------------------------------------------------------------------------------------------
; void VMMInit(void) -- Initialize the Virtual Memory manager structures in preparation to turn
;                       over control to the Virtual Memory Manager.
;----------------------------------------------------------------------------------------------

				global		VMMInit

VMMInit:
				push		rbp						; save rbp
				mov			rbp,rsp					; create a stack frame
				push		rbx						; save rbx -- will be out virt addr reg

;----------------------------------------------------------------------------------------------
; First, we want to unmap all entries in the first 640K; nothing in our kernel is mapped there.
;
; This is section #1 in the memory map in loader.s.
;----------------------------------------------------------------------------------------------

				xor			rbx,rbx					; need to clear rbx -- start at addr 0
				sub			rsp,8					; make room on the stack for parm

.loop1:
				mov			qword [rsp],rbx			; put the virt addr on the stack
				call		VMMUnmapPage			; and go unmap the page

				add			rbx,0x1000				; move to the next page
				cmp			rbx,qword 0xA0000		; less than 640K?
				jb			.loop1					; if so, loop again

;----------------------------------------------------------------------------------------------
; Now, we skip up past 1M and past the multiboot area (which contains our GDT and other
; common 32-bit addressable structures.  The linker provides this address as bootClear.  We
; will clear up to bootEnd (also provided by the linker).
;
; This is sections #3 & #4 in loader.s.
;----------------------------------------------------------------------------------------------

				mov			rbx,qword bootClear		; this should be page aligned already

.loop2:
				mov			qword [rsp],rbx			; put the virt addr on the stack
				call		VMMUnmapPage			; and go unmap the page

				add			rbx,0x1000				; move to the next page
				cmp			rbx,qword bootEnd		; less than our 32-bit booting code et al?
				jb			.loop2					; if so, loop again

;----------------------------------------------------------------------------------------------
; Finally, for the last of our low-memory cleanup, we need to clear out the identity mappings
; for the kernel proper.  This is from kernelStart (linker provided) to 2M.  However,
; kernelStart is a virtual memory addresses, so we will need to adjust it back down to physical
; memory addresses.
;
; This is sections #6, #7, #8 & #9 in loader.s.
;----------------------------------------------------------------------------------------------

				mov			rbx,qword kernelStart-VIRT_BASE	; this should be page aligned

.loop3:
				mov			qword [rsp],rbx			; put the virt addr on the stack
				call		VMMUnmapPage			; and go unmap the page

				add			rbx,0x1000				; move to the next page
				cmp			rbx,qword 0x200000		; less than 2M?
				jb			.loop3					; if so, loop again


;----------------------------------------------------------------------------------------------
; Now that we have gotten to this point, we will be unmapping higher memory.  Now, we will have
; some real work to do.  First, all of this memory was marked as shared.  If we want to unmap
; the memory, we need to remove the shared flag.  Secondly, for most of the pages we free (but
; certainly not all pages), there will also be an associated frame that needs to be deallocated
; with the Physical Memory Manager.
;
; From the memory map in loader.s, section #1 can be unmapped and deallocated.
;----------------------------------------------------------------------------------------------

;----------------------------------------------------------------------------------------------
; Clean up and exit
;----------------------------------------------------------------------------------------------

				add			rsp,8					; clean up the stack

				pop			rbx						; restore rbx
				pop			rbp						; restore previous frame
				ret

;----------------------------------------------------------------------------------------------
; dword VMMUnmapPage(qword wirtAddr) -- unmap a virtual memory page, but do not release the
;                                       physical memory.  if the address is not page-aligned
;                                       then a warning will be returned and the address will
;                                       be aligned anyway and processing will continue.  If
;                                       the address is shared memory, then nothing happens and
;                                       a warning is returned.  If the memoey is not mapped
;                                       then nothing happens and an error is returned.
;----------------------------------------------------------------------------------------------

				global		VMMUnmapPage

VMMUnmapPage:
				push		rbp						; save rbp
				mov			rbp,rsp					; create a stack frame
				push		rbx						; save rbx; our virtual address saved
				push		rcx						; save rcx
				push		rsi						; save rsi
				push		r8						; save r8; use it as temporary rv

				xor			r8,r8					; assume a successful unmap; save temp rv

;----------------------------------------------------------------------------------------------
; Start by checking if the address is page-aligned; if not align it and set a temp return value
;----------------------------------------------------------------------------------------------

				mov			rax,qword [rbp+16]		; get the address to unmap
				mov			rbx,rax					; we also need a working value
				and			rax,0x0fff				; is the address page aligned
				cmp			rax,0					; is the result aligned?
				je			.aligned				; if so, skip the alignment

				and			rbx,qword 0xfffffffffffff000	; mask out a page-aligned address
				xor			rax,rax					; clear out rax
				mov			eax,VMM_WARN_ALIGN		; set the warning
				mov			r8,rax					; save the temporary return value

;----------------------------------------------------------------------------------------------
; Now we have a page-aligned address; get the PML4 Table Entry address and check present flag
;----------------------------------------------------------------------------------------------

.aligned:
				mov			rax,cr3					; get the address of the pml4 table
				and			rax,qword 0xfffffffffffff000 	; mask out the table addr & align
				mov			rcx,rbx					; get the virtual address into rcx
				shr			rcx,39-3				; move addr; want 47:39 in 11:3
				and			rcx,0x0ff8				; mask bits 11:3; 2:0 are 0
				or			rax,rcx					; rax has addr of pml4 entry

				mov			rcx,qword [rax]			; get the page directory pointer
				test		rcx,1<<0				; test the 'present' bit
				jz			.nomap					; if not present, no mapped address

;----------------------------------------------------------------------------------------------
; Now we have a page-aligned address; get the PDP Table Entry address and check present flag
;----------------------------------------------------------------------------------------------

				mov			rax,rcx					; get the new address with which to work
				and			rax,qword 0xfffffffffffff000 	; mask out the table addr & align
				mov			rcx,rbx					; get the virtual address into rcx
				shr			rcx,30-3				; move addr; want 38:30 in 11:3
				and			rcx,0x0ff8				; mask out bits 11:3; 2:0 are 0
				or			rax,rcx					; rax now has the address of the entry

				mov			rcx,qword [rax]			; get the page directory pointer
				test		rcx,1<<0				; test the 'present' bit
				jz			.nomap					; if not present, no mapped address

;----------------------------------------------------------------------------------------------
; Now we have a page-aligned address; get the Page Directory Table Entry address and check
; present flag
;----------------------------------------------------------------------------------------------

				mov			rax,rcx					; get the new address with which to work
				and			rax,qword 0xfffffffffffff000 	; mask out the table addr & align
				mov			rcx,rbx					; get the virtual address into rcx
				shr			rcx,21-3				; move addr; want 29:21 in 11:3
				and			rcx,0x0ff8				; mask out bits 11:3; 2:0 are 0
				or			rax,rcx					; rax now has the address of the entry

				mov			rcx,qword [rax]			; get the page directory pointer
				test		rcx,1<<0				; test the 'present' bit
				jz			.nomap					; if not present, no mapped address

;----------------------------------------------------------------------------------------------
; Now we have a page-aligned address; get the Page Table Entry address and check present flag
;----------------------------------------------------------------------------------------------

				mov			rax,rcx					; get the new address with which to work
				and			rax,qword 0xfffffffffffff000 	; mask out the table addr & align
				mov			rcx,rbx					; get the virtual address
				shr			rcx,12-3				; move addr; want 20:12 in 11:3
				and			rcx,0x0ff8				; mask out bits 11:3; 2:0 are 0
				or			rax,rcx					; rax now has the address of the entry

				mov			rcx,qword [rax]			; get the page directory pointer
				test		rcx,1<<0				; test the 'present' bit
				jz			.nomap					; if not present, no mapped address

;----------------------------------------------------------------------------------------------
; check if we are trying to clear a shared page
;----------------------------------------------------------------------------------------------

				test		rcx,VMM_SHARED<<9		; need to mask out the Shared bit
				jnz			.shared					; we have shared memory

;----------------------------------------------------------------------------------------------
; clear the page and invalidate the cache for the address
;----------------------------------------------------------------------------------------------

				xor			rcx,rcx					; set the page to 0
				mov			qword [rax],rcx			; store the page back to the page tables
				invlpg		[rbx]					; clear the page from the TLB cache

				xor			rax,rax					; clear rax
				mov			eax,VMM_SUCCESS			; rv is success
				mov			r8,rax					; set temp return value
				jmp			.out					; and exit

.shared:
				xor			rax,rax					; clear rax
				mov			eax,VMM_WARN_SHARED		; set the wanrning to no map
				mov			r8,rax					; set temp return value
				jmp			.out					; leave

.nomap:
				xor			rax,rax					; clear rax
				mov			eax,VMM_ERR_NOMAP		; set the wanrning to no map
				mov			r8,rax					; set temp return value

;----------------------------------------------------------------------------------------------
; clean up and return the result
;----------------------------------------------------------------------------------------------

.out:
				mov			rax,r8					; set the return value

				pop			r8						; restore r8
				pop			rsi						; restore rsi
				pop			rcx						; restore rcx
				pop			rbx						; restore rbx
				pop			rbp						; restore previous frame
				ret
