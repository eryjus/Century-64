;==============================================================================================
;
; pagetables.s
;
; This file contains the functions required to establish the initial paging tables prior to
; handing control over the the Virtual Memory Manager.  These tables are required to get the
; kernel into Higher Memory and to enable paging.  Enabling paging is required to get the
; CPU into long mode.
;
; All of this code (since the CPU is not in long mode when this is called) is 32-bit code
; and is located in the .boot section.  It is intended to reclaim all of this space once we
; have properly transitioned to long mode and completed all our initialization.   The initial
; structures of the paging tables MUST be located in the first 4GB of memory.  We start at
; 4MB and grow from there.
;
; Note that much of this logic has analogous functions in virtmm.s (64-bit functions).
;
; The following functions are published in this file:
;   void PagingInit(void);
;
; The following functions are internal functions:
;   dword GetNewTable(void);
;   dword PML4Offset(dword HiAddr, dword LoAddr);
;   dword PDPTOffset(dword HiAddr, dword LoAddr);
;   dword PDOffset(dword HiAddr, dword LoAddr);
;   dword PTOffset(dword HiAddr, dword LoAddr);
;   void MapPage(dword PML4, dword HiVirtAddr, dword LoVirtAddr, dword PhysAddr);
;
;    Date     Tracker  Pgmr  Description
; ----------  -------  ----  ------------------------------------------------------------------
; 2014/10/05  Initial  ADCL  Initial coding.
; 2014/10/17  virtMM   ADCL  As a result of implementing the virtual memory manager, I have
;                            pre-set the flag in the upper memory as shared, since it will have
;                            to exist for all paging structures (pml4).
; 2014/11/15  #200     ADCL  In order to get the first change (moving the .text, .data, and
;                            .bss sections to their new locations) associated with this
;                            tracker number complete, the paging tables are going to have to
;                            change.  For this first part, I will be hand-coding this change
;                            into static tables in an attempt to get the system to boot again.
;                            So, with that said, I need to identity-map the first 4MB memory,
;                            and then map 0xffff c000 0000 0000 to physical 0 for 2MB; and map
;                            0xffff d000 0000 0000 to physical 2MB for 2MB.
; 2014/11/20  #200     ADCL  Work on 32-bit code to dynamically setup the paging tables.  These
;                            tables must conform to the structures that will be used in long
;                            mode as they will not be rebuilt.
;
;==============================================================================================


;==============================================================================================
; The .paging section is there to statically map the first initial paging structures.  We
; will not be mapping all 256TB address space, but rather just identitiy mapping the first 2MB
; and then also mapping virtual address 0xffffffff00000000 to physical address
; 0x0000000000000000.  We will be releasing the map for the lower virtual memory.  However,
; this physical memory will remain throughout the life of the system.  (We might tune it later)
;
; Remember that CR3 needs to hold a PHYSICAL address of the paging tables.
;==============================================================================================

%define         __PAGETABLES_S__
%include        'private.inc'

                global      nextFrame           ; not really, but we need it for PMMInit
                section     .bootdata

PG_TBL_START    equ         0x00400000          ; starting point for the paging tables
nextFrame       dd          PG_TBL_START        ; initialize our starting point

;==============================================================================================
; In an attempt to eliminate the .paging section altogether, I am going to work on dynamically
; allocating the paging tables.  These will be 64-bit tables, but built in 32-bit code.  As a
; result, this code will not be used any further than initialization.  It only makes sense to
; put this code in the .boot section so that it can be reclaimed once the boot is complete.
;
; In addition, since the code to enable paging is 32-bit code, the paging tables MUST be in
; 32-bit address space.  This means that the paging tables MUST reside below 4GB in physical
; memory.
;==============================================================================================

                section     .boot
                bits        32

;----------------------------------------------------------------------------------------------
; dword GetNewTable(void) -- Obtain the physical address for and initialize a new paging table.
;                            Initialization means setting all the bytes in the table to be 0.
;----------------------------------------------------------------------------------------------

GetNewTable:
                push        ebp                     ; save the caller's frame
                mov.d       ebp,esp                 ; create our own frame
                push        ecx                     ; save ecx -- counter register
                push        edi                     ; save edi -- table address

                mov.d       edi,[nextFrame]         ; get the next frame
                add.d       [nextFrame],0x1000      ; move to the next frame
                push        edi                     ; save edi -- we will want this addr again

                mov.d       ecx,0x1000>>2           ; set the number of dwords to clear
                xor.d       eax,eax                 ; clear eax

                rep         stosd                   ; clear the frame

                pop         eax                     ; pull the address back into eax for return

                pop         edi                     ; restore edi
                pop         ecx                     ; restore ecx
                pop         ebp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; dword PML4Offset(dword HiAddr, dword LoAddr) -- take a 64-bit virtual address (split into
;                                                 upper and lower parts) and calculate the byte
;                                                 offset into the PML4 table.
;----------------------------------------------------------------------------------------------

PML4Offset:
                push        ebp                     ; save the caller's frame
                mov.d       ebp,esp                 ; create our own frame

                mov.d       eax,[ebp+8]             ; get the high address dword
                shr.d       eax,(39-32-3)           ; shift 7 bits right and multiply by 8
                and.d       eax,(511<<3)            ; calc final address (again, in qwords)

                pop         ebp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; dword PDPTOffset(dword HiAddr, dword LoAddr) -- take a 64-bit virtual address (split into
;                                                 upper and lower parts) and calculate the byte
;                                                 offset into the PDPT table.  Note that this
;                                                 offset is assembled from both parameters.
;
; Overall in a 64-bit address, we need bits 30:38.  Therefore, 30:31 come from the low address
; and 32:38 is in the high address.
;----------------------------------------------------------------------------------------------

PDPTOffset:
                push        ebp                     ; save the caller's frame
                mov.d       ebp,esp                 ; create our own frame
                push        ebx                     ; save ebx - work register

                mov.d       eax,[ebp+12]            ; get the low address dword
                shr.d       eax,30                  ; put these 2 bits in the low 2 bits
                and.d       eax,3                   ; mask out these 2 bits

                mov.d       ebx,[ebp+8]             ; get the high address dword
                shl.d       ebx,2                   ; need bits 32:38 (really 0:6) in 2:8
                and.d       ebx,0x000001fc          ; mask out these bits as well

                or.d        eax,ebx                 ; combine the 2 values in eax
                shl.d       eax,3                   ; multiply by 8 to get byte offset

                pop         ebx                     ; restore ebx
                pop         ebp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; dword PDOffset(dword HiAddr, dword LoAddr) -- take a 64-bit virtual address (split into
;                                               upper and lower parts) and calculate the byte
;                                               offset into the PD table.
;----------------------------------------------------------------------------------------------

PDOffset:
                push        ebp                     ; save the caller's frame
                mov.d       ebp,esp                 ; create our own frame

                mov.d       eax,[ebp+12]            ; get the high address dword
                shr.d       eax,(21-3)              ; shift 21 bits right and multiply by 8
                and.d       eax,(511<<3)            ; calc final address (again, in qwords)

                pop         ebp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; dword PTOffset(dword HiAddr, dword LoAddr) -- take a 64-bit virtual address (split into
;                                               upper and lower parts) and calculate the byte
;                                               offset into the PT table.
;----------------------------------------------------------------------------------------------

PTOffset:
                push        ebp                     ; save the caller's frame
                mov.d       ebp,esp                 ; create our own frame

                mov.d       eax,[ebp+12]            ; get the high address dword
                shr.d       eax,(12-3)              ; shift 12 bits right and multiply by 8
                and.d       eax,(511<<3)            ; calc final address (again, in qwords)

                pop         ebp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void MapPage(dword PML4, dword HiVirtAddr, dword LoVirtAddr, dword PhysAddr) --
;
; This function will take a virtual address (split up into Hi and Lo dwords) and map it to the
; proper physical address.  It will check each level of the table as it goes and if a new table
; needs to be created it will create one.  Remember that we are working in 32-bit code, so each
; entry will need to be built in 2 parts: the hi dword at [addr] and the lo word at [addr+4].
; We are little endian.  In all cases, the hi dword in any entry should be 0x00000000.
;----------------------------------------------------------------------------------------------

MapPage:
                push        ebp                     ; save the caller's frame
                mov.d       ebp,esp                 ; set our own stack frame
                push        ebx                     ; save ebx -- table address
                push        ecx                     ; save ecx -- high virtual address
                push        edx                     ; save edx -- low virtual address
                push        esi                     ; save esi -- the entry address

                mov.d       ebx,[ebp+8]             ; get the pml4 address
                mov.d       ecx,[ebp+12]            ; get the hi virtual address
                mov.d       edx,[ebp+16]            ; get the lo virtual address

;----------------------------------------------------------------------------------------------
; start with the pml4 table.  Make sure the entry has a good table address in it.
;----------------------------------------------------------------------------------------------

.pml4:          push        edx                     ; push the lo address
                push        ecx                     ; push the hi address
                call        PML4Offset              ; get the offset in bytes to the entry
                add.d       esp,8                   ; remove 2 parms from stack

                lea.d       esi,[ebx+eax]           ; now we have the address we really want
                mov.d       ebx,[esi]               ; set the next table address
                and.d       ebx,0xfffff000          ; mask out the address bits

                test.d      [esi],0x01              ; is the next table present?
                jnz         .pdpt                   ; if so, move on to the pdpt

                call        GetNewTable             ; get and initialize a new table
                mov.d       [esi+4],0               ; set the hi dword to 0
                mov.d       [esi],eax               ; set the address in the entry
                or.d        [esi],0x03              ; set the entry as R/W & Present

                mov.d       ebx,eax                 ; set the next table address

;----------------------------------------------------------------------------------------------
; next is the pdpt table.  Make sure we have a good table address.  ebx points to pdpt table.
;----------------------------------------------------------------------------------------------

.pdpt:          push        edx                     ; push the lo address
                push        ecx                     ; push the hi address
                call        PDPTOffset              ; get the offset in bytes to the entry
                add.d       esp,8                   ; remove 2 parms from stack

                lea.d       esi,[ebx+eax]           ; now we have the address we really want
                mov.d       ebx,[esi]               ; set the next table address
                and.d       ebx,0xfffff000          ; mask out the address bits

                test.d      [esi],0x01              ; is the next table present?
                jnz         .pd                     ; if so, move on to the pd

                call        GetNewTable             ; get and initialize a new table
                mov.d       [esi+4],0               ; set the hi dword to 0
                mov.d       [esi],eax               ; set the address in the entry
                or.d        [esi],0x03              ; set the entry as R/W & Present

                mov.d       ebx,eax                 ; set the next table address

;----------------------------------------------------------------------------------------------
; next is the pd table.  Make sure we have a good table address.  ebx points to pd table.
;----------------------------------------------------------------------------------------------

.pd:            push        edx                     ; push the lo address
                push        ecx                     ; push the hi address
                call        PDOffset                ; get the offset in bytes to the entry
                add.d       esp,8                   ; remove 2 parms from stack

                lea.d       esi,[ebx+eax]           ; now we have the address we really want
                mov.d       ebx,[esi]               ; set the next table address
                and.d       ebx,0xfffff000          ; mask out the address bits

                test.d      [esi],0x01              ; is the next table present?
                jnz         .pt                     ; if so, move on to the pt

                call        GetNewTable             ; get and initialize a new table
                mov.d       [esi+4],0               ; set the hi dword to 0
                mov.d       [esi],eax               ; set the address in the entry
                or.d        [esi],0x03              ; set the entry as R/W & Present

                mov.d       ebx,eax                 ; set the next table address

;----------------------------------------------------------------------------------------------
; next is the pt table.  At this point, things change.  The entry in the page table is the
; physical address, not another table.  We need to set the physical address as requested.
;----------------------------------------------------------------------------------------------

.pt:            push        edx                     ; push the lo address
                push        ecx                     ; push the hi address
                call        PTOffset                ; get the offset in bytes to the entry
                add.d       esp,8                   ; remove 2 parms from stack

                lea.d       esi,[ebx+eax]           ; now we have the address we really want

                mov.d       eax,[ebp+20]            ; get the physical address we are mapping
                mov.d       [esi+4],0               ; set the hi dword to 0
                mov.d       [esi],eax               ; set the physical address
                or.d        [esi],0x03              ; set the entry as R/W & Present

;----------------------------------------------------------------------------------------------
; Clean up and exit
;----------------------------------------------------------------------------------------------

                pop         esi                     ; restore esi
                pop         edx                     ; restore edx
                pop         ecx                     ; restore ecx
                pop         ebx                     ; restore ebx
                pop         ebp                     ; pop ebp from the stack
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void PagingInit(void) -- Initialize the paging structures.
;----------------------------------------------------------------------------------------------

                global      PagingInit

PagingInit:
                push        ebp                     ; save the caller's frame
                mov.d       ebp,esp                 ; create our own frame
                push        ebx                     ; save ebx -- pml4 address
                push        esi                     ; save esi -- virtual lo address
                push        edi                     ; save edi -- physical address

;----------------------------------------------------------------------------------------------
; So, the first thing we need to do is get the address of the PML4.  We need to guarantee that
; this address is equal to PG_TBL_START since we will use that address to populate cr3.
;----------------------------------------------------------------------------------------------

                call        GetNewTable             ; get an initialized new table
                mov.d       ebx,eax                 ; save the resulting table in ebx

                sub.d       esp,16                  ; create room on the stack for 4 parms

;----------------------------------------------------------------------------------------------
; we need to recursively map the pml4 table
;----------------------------------------------------------------------------------------------

                mov.d       [ebx+0xff8],ebx         ; this is the recursive mapping
                or.d        [ebx+0xff8],0x03        ; set the r/w and present bits

;----------------------------------------------------------------------------------------------
; now that we have a pml4 table, we need to start mapping our memory.  Our kernel is loaded at
; physical location 1MB, data at 2MB, and paging tables at 4MB.  Plus we need the lower 1MB of
; data and other stuff.  However, we should not need access to the paging tables after this
; initialization routine, so let's identity map the first 4MB of memory.
;----------------------------------------------------------------------------------------------

                xor.d       esi,esi                 ; clear esi
                mov.d       [esp],ebx               ; set the pml4 address
                mov.d       [esp+4],0               ; the high virtual address is 0

.loop1:         cmp.d       esi,0x00400000          ; have we reached 4MB?
                jae         .next1                  ; jump to the next part

                mov.d       [esp+8],esi             ; the low virtual address
                mov.d       [esp+12],esi            ; is itentity mapped
                call        MapPage                 ; go map the page

                add.d       esi,0x1000              ; move the the next page/frame
                jmp         .loop1                  ; loop again

;----------------------------------------------------------------------------------------------
; Now, we need to deal with the kernel code.  This code was loaded by multiboot at physical
; address 0x0010 0000.  However, we need to map this physical address to virtual address
; 0xffff 8000 0010 0000.  What makes this challenging is that the ending address for this
; mapping is stored as kernelEnd by the linker.  kernelEnd is a 64-bit value.  To get around
; this limitation, we will map an entire 1MB physical memory now and go back to un-map the
; unused portion of this memory once we are in long mode.
;----------------------------------------------------------------------------------------------

.next1:         mov.d       esi,0x00100000          ; set up lower virtual address
                mov.d       edi,0x00100000          ; set physical mem to 1MB
                mov.d       [esp],ebx               ; set the pml4 address
                mov.d       [esp+4],0xffff8000      ; the high virtual address is 0xffff8000

.loop2:         cmp.d       edi,0x00200000          ; have we reached 2MB?
                jae         .next2                  ; jump to the next part

                mov.d       [esp+8],esi             ; the low virtual address
                mov.d       [esp+12],edi            ; is mapped from offset 0x100000
                call        MapPage                 ; go map the page

                add.d       esi,0x1000              ; move the the next page
                add.d       edi,0x1000              ; move the the next frame
                jmp         .loop2                  ; loop again

;----------------------------------------------------------------------------------------------
; Next we deal with the kernel data (and bss).  We have the same problem as we did with the
; kernel code, so we will map from 2MB to 3MB and go back to upmap pages once we are in
; 64-bit mode.  We need to map virtual address 0xffff 9000 0000 0000 to 0x0020 0000.
;----------------------------------------------------------------------------------------------

.next2:         xor.d       esi,esi                 ; clear esi
                mov.d       edi,0x00200000          ; set physical mem to 2MB
                mov.d       [esp],ebx               ; set the pml4 address
                mov.d       [esp+4],0xffff9000      ; the high virtual address is 0xffff9000

.loop3:         cmp.d       edi,0x00300000          ; have we reached 3MB?
                jae         .next3                  ; jump to the next part

                mov.d       [esp+8],esi             ; the low virtual address
                mov.d       [esp+12],edi            ; is mapped from offset 0x2000
                call        MapPage                 ; go map the page

                add.d       esi,0x1000              ; move the the next page
                add.d       edi,0x1000              ; move the the next frame
                jmp         .loop3                  ; loop again

;----------------------------------------------------------------------------------------------
; The heap comes next.  This is a little more complicated since it does not have any physical
; memory allocated to it at compile time.  As a result, we will move the initialization of the
; heap memory pages to the heap initialization function.  It will have to be responsible for
; allocating its physical memory as well mapping its virtual memory.  Therefore, we do nothing
; here.
;
; Now we move on to the phyiscal memory manager.  In virtual memory, we have an 8GB section of
; memory reserved to manage the full theoretical 256TB of physical memory.  Now, seriously, it
; is unrealistic and rediculous to even think of mapping all 8GB of virtual memory to physical
; address space.  One 4K frame can map up to 128MB of physical memory in a bitmap.  So, the
; challenge here is to decide how much to map now (if any) and how much to map later (if any).
;
; Since I had to break up the physical memory management bitmap into 2 sections (<=32GB
; portion and >32GB portion), it is necessary to map virtual 0xffff f000 0000 0000 to
; physical 0x300000 for an entire 1MB.
;----------------------------------------------------------------------------------------------

.next3:         xor.d       esi,esi                 ; clear esi
                mov.d       edi,0x00300000          ; set physical mem to 3MB
                mov.d       [esp],ebx               ; set the pml4 address
                mov.d       [esp+4],0xfffff000      ; the high virtual address is 0xfffff000

.loop4:         cmp.d       edi,0x00400000          ; have we reached 4MB?
                jae         .next4                  ; jump to the next part

                mov.d       [esp+8],esi             ; the low virtual address
                mov.d       [esp+12],edi            ; is mapped from offset 0x2000
                call        MapPage                 ; go map the page

                add.d       esi,0x1000              ; move the the next page
                add.d       edi,0x1000              ; move the the next frame
                jmp         .loop4                  ; loop again

;----------------------------------------------------------------------------------------------
; The next thing to do is to map the kernel stack space.  This is located at STACK_LOC and has
; a size of STACK_SIZE.
;----------------------------------------------------------------------------------------------

.next4:         xor.d       esi,esi                 ; clear esi
                mov.d       [esp],ebx               ; set the pml4 address
                mov.d       [esp+4],0xfffff002      ; the high virtual address is 0xfffff002
                mov.d       [esp+12],0              ; we will map the stack to phys 0 for now

.loop5:         cmp.d       esi,STACK_SIZE          ; have we reached the stack size?
                jae         .next5                  ; jump to the next part

                mov.d       [esp+8],esi             ; the low virtual address
                call        MapPage                 ; go map the page

                add.d       esi,0x1000              ; move the the next page
                jmp         .loop5                  ; loop again

;----------------------------------------------------------------------------------------------
; Finally, this brings us to the point where we need a temporary location to map a frame of
; memory for initialization before putting it into the paging structures for real.  This
; location of virtual memory is at 0xffff ff7f ffff f000.  We MUST have this mapped as if we
; do not have it mapped the first time we go to use it it will create a recursive infinite
; loop.  For now, we will map this virtual page to physical address 0.  This will not be a
; problem since we will map it again right before we access the page.
;----------------------------------------------------------------------------------------------

.next5:         mov.d       [esp+4],0xffffff7f      ; the high virtual address is 0xffffff7f
                mov.d       [esp+8],0xfffff000      ; the low virtual address
                mov.d       [esp+12],0              ; for now, map this page to phys addr 0
                call        MapPage                 ; go map the page

;----------------------------------------------------------------------------------------------
; What is left after this, then, is the recursive mapping entries, which are not needed.
; So we are done for now with the paging initialization.
;
; finally, clean up and exit
;----------------------------------------------------------------------------------------------

.out:           add.d       esp,16                  ; clean up the stack
                mov.d       cr3,ebx                 ; store the address of the pml4 in cr3

                pop         edi                     ; restore edi
                pop         esi                     ; restore esi
                pop         ebx                     ; restore ebx
                pop         ebp                     ; restore caller's frame
                ret
