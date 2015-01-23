;==============================================================================================
;
; virtmm.s
;
; This file contains the functions and data that will be used to manage the virtual memory
; layer of this kernel.
;
;**********************************************************************************************
;
;       Century-64 is a 64-bit Hobby Operating System written mostly in assembly.
;       Copyright (C) 2014-2015  Adam Scott Clark
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
; Like the physical memory layer, this layer caused me a lot of internal debate.  Not about how
; to architect the layer, but how responsible to make it for the memory.  Should the VMM keep
; track of all virtual memeory independently, or should I make the requester responsible for
; knowing what it wants and let the VMM report back errors with the request?
;
; Well, after some comments from Brendan, I decided on the former design.  The comments are
; here: http://forum.osdev.org/viewtopic.php?f=1&t=28554&start=15#p240955.
;
; My own thoughts for this module are tracked here: http://redmine:3000/issues/174 (on my own
; personal network; so, if you are looking at this from github you are kinda out of luck).
;
; I am also adding stack alloction support into this source file.  All stacks will be 16KB big
; to make the work easier.  I already have a region of memory dedicated to stacks from which
; the kernel stack is already pulled: 0xffff f002 0000 0000 for 8GB.  At 16KB, this is room for
; exactly 524,288 (or 512K) stacks.  Using a bitmap to manage these, it will take 65,536 bytes
; to keep track of these stacks, 8192 qwords, or 16 pages.  It's not particularly large or
; sophisticated, so the management will be nearly trivial.
;
; The following are the functions delivered in this source file:
;   qword VMMInit(void);
;   void MapPageInTables(qword vAddr, qword pAddr);
;   dword UnmapPageInTables(qword virtAddr);
;   qword VMMAlloc(qword virtAddr, qword pages);
;   qword VMMFree(qword virtAddr, qword pages);
;   void ReclaimMemory(void);
;   qword AllocStack(void);
;
; The following are the internal functions that will be used in this source file:
;   qword MmuPML4Table(qword addr);
;   qword MmuPDPTable(qword addr);
;   qword MmuPDirectory(qword addr);
;   qword MmuPTable(qword addr);
;   qword MmuPML4Offset(qword addr);
;   qword MmuPDPOffset(qword addr);
;   qword MmuPDOffset(qword addr);
;   qword MmuPTOffset(qword addr);
;   qword MmuNewTable(void);
;   qword MmuIsPageMapped(qword virtAddr);
;
;    Date     Tracker  Pgmr  Description
; ----------  -------  ----  ------------------------------------------------------------------
; 2014/10/17  Initial  ADCL  Initial code
; 2014/11/15  #200     ADCL  OK, this source will undergo several major changes.  First, I will
;                            leverage several macros and functions from a post by bluemoon
;                            here: http://forum.osdev.org/viewtopic.php?f=15&t=25545#p212397.
;                            At the same time, I will update this source to comform to the new
;                            coding styles I have adopted in other files.
; 2014/11/24  #200     ADCL  So, MapPageInTables now needs to be rewritten to account for the
;                            fact that it is called when paging is enabled and the PMM now has
;                            control over physical memory management.
; 2014/11/30  #212     ADCL  Bochs was working properly; QEMU was not working properly.  I
;                            found the reason was that I was clearing too many pages from the
;                            higher-half code pages.  However, the real core issue was that
;                            UnmapPageInTables was not clearing the TLB for that address.
; 2014/12/02  #217     ADCL  Relocated the paging clean into a function here.
; 2014/12/02  #213     ADCL  As a result of creating the TSS, and along with all the stacks
;                            we will leverage in that structure, I will be creating a function
;                            to allocate a stack from the pool of stack memory.  This memory
;                            can support up to 524,288 stacks (512K), each 16K in size.  All
;                            stacks will be the same size, so it makes allocation easy to
;                            manage.
; 2015/01/04  #228     ADCL  Make sure that the virtual memory from 0xffff ff7f ffe0 0000 to
;                            0cffff ff7f ffef ffff cannot be allocated.
;
;==============================================================================================

%define         __VIRTMM_S__
%include        'private.inc'

;----------------------------------------------------------------------------------------------
; Each structure type will have a memory location.  These are defined in the following wiki:
; http://redmine:3000/projects/century-64/wiki/Virtual_Memory_Layout (which is on my personal
; network.  If you would like the whole memory map, please e-mail me at hobbyos@eryjuys.com.
; The important bits for this source are:
;  * 0xffff ff80 0000 0000  Page Tables (PT)
;  * 0xffff ffff c000 0000	Page Directories (PD)
;  * 0xffff ffff ffe0 0000  Page Directory Pointer Tables (PDPT)
;  * 0xffff ffff ffff f000  PML4 Table
;----------------------------------------------------------------------------------------------

MMU_PT_BASE     equ         0xffffff8000000000
MMU_PD_BASE     equ         0xffffffffc0000000
MMU_PDPT_BASE   equ         0xffffffffffe00000
MMU_PML4_BASE   equ         0xfffffffffffff000

VMM_PHYS_START  equ         0x0000000000400000

PAGE_TREE_TEMP  equ         0xffffff7ffffff000  ; this is a temporary location to be used
                                                ; to clear a page table struct before adding
                                                ; into the paging structure tree for real.

STACK_LOC       equ         0xfffff00200000000
STACK_BM_SIZE   equ         (16*1024)           ; 16K for the stack bitmap

;==============================================================================================
; This is the .bss section.  It contains uninitialized data.
;==============================================================================================

                section     .bss

stackBitmap     resq        1                   ; This is a pointer to the stack alloc bitmap

;==============================================================================================
; The .text section is part of the kernel proper
;==============================================================================================

                section     .text
                bits        64

;----------------------------------------------------------------------------------------------
; Now the following functions are important in that for any given address, we want to be able
; to calculate the address of the actual structure for all 4 levels.  For the structures like
; the Page Tables (PT), we have a rather large address range in which to work.  We will need to
; be able to narrow it down the the specific table (4K aligned, of course) quickly.
;----------------------------------------------------------------------------------------------


;----------------------------------------------------------------------------------------------
; qword MmuPML4Table(qword addr) -- for any given address, return the vurtual address of the
;                                   required PML4 Table.  In actuality, this can only be 1
;                                   possible address, but let's go through the motions anyway.
;----------------------------------------------------------------------------------------------

MmuPML4Table:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame

                mov.q       rax,MMU_PML4_BASE       ; get the address of the table

                pop         rbp                     ; restore the caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword MmuPDPTable(qword addr) -- for any given address, return the virtual address of the
;                                  required PDP Table.
;----------------------------------------------------------------------------------------------

MmuPDPTable:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rcx                     ; save rcx

                mov.q       rax,[rbp+16]            ; get the address
                shr.q       rax,27                  ; adjust for the PDPT part of the address
                mov.q       rcx,0x00000000001ff000  ; set the and mask
                and.q       rax,rcx                 ; and truncate the canonical bits
                add.q       rax,MMU_PDPT_BASE       ; add in the base address to get an offset

                pop         rcx                     ; restore rcx
                pop         rbp                     ; restore the caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword MmuPDirectory(qword addr) -- for any given address, return the virtual address of the
;                                    required Page Directory.
;----------------------------------------------------------------------------------------------

MmuPDirectory:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rcx                     ; save rcx

                mov.q       rax,[rbp+16]            ; get the address
                shr.q       rax,18                  ; adjust for the PD part of the addr
                mov.q       rcx,0x000000003ffff000  ; set the and mask
                and.q       rax,rcx                 ; and truncate the canonical bits
                add.q       rax,MMU_PD_BASE         ; add in the base address to get an offset

                pop         rcx                     ; restore rcx
                pop         rbp                     ; restore the caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword MmuPTable(qword addr) -- for any given address, return the virtual address of the
;                                required Page Table
;----------------------------------------------------------------------------------------------

MmuPTable:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rcx                     ; save rcx

                mov.q       rax,[rbp+16]            ; get the address
                shr.q       rax,9                   ; adjust for the PT part of the addr
                mov.q       rcx,0x0000007ffffff000  ; set the bit mask
                and.q       rax,rcx                 ; and truncate the canonical bits
                mov.q       rcx,MMU_PT_BASE         ; get the base address of the PTables
                add.q       rax,rcx                 ; add it to the offset

                pop         rcx                     ; restore rcx
                pop         rbp                     ; restore the caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword MmuPML4Offset(qword addr) -- for any given address, return the offset from the start of
;                                    the table (in bytes) for the actual table entry.
;----------------------------------------------------------------------------------------------

MmuPML4Offset:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame

                mov.q       rax,[rbp+16]            ; get the desired address to look up
                shr.q       rax,(39-3)              ; shift right 39 bits (-3 since use qwords)
                and.q       rax,(511<<3)            ; calc final address (again, in qwords)

                pop         rbp                     ; restore the caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword MmuPDPOffset(qword addr) -- for any given address, return the offset from the start of
;                                   the table (in bytes) for the actual table entry.
;----------------------------------------------------------------------------------------------

MmuPDPOffset:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame

                mov.q       rax,[rbp+16]            ; get the desired address to look up
                shr.q       rax,(30-3)              ; shift right 30 bits (-3 since use qwords)
                and.q       rax,(511<<3)            ; calc final address (again, in qwords)

                pop         rbp                     ; restore the caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword MmuPDOffset(qword addr) -- for any given address, return the offset from the start of
;                                  the table (in bytes) for the actual table entry.
;----------------------------------------------------------------------------------------------

MmuPDOffset:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame

                mov.q       rax,[rbp+16]            ; get the desired address to look up
                shr.q       rax,(21-3)              ; shift right 21 bits (-3 since use qwords)
                and.q       rax,(511<<3)            ; calc final address (again, in qwords)

                pop         rbp                     ; restore the caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword MmuPTOffset(qword addr) -- for any given address, return the offset from the start of
;                                  the table (in bytes) for the actual table entry.
;----------------------------------------------------------------------------------------------

MmuPTOffset:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame

                mov.q       rax,[rbp+16]            ; get the desired address to look up
                shr.q       rax,(12-3)              ; shift right 12 bits (-3 since use qwords)
                and.q       rax,(511<<3)            ; calc final address (again, in qwords)

                pop         rbp                     ; restore the caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword MmuNewTable(void) -- Allocate a new physical frame from the PMM and initialize it to
;                            all 0s.  Then, we can return the physical frame address to the
;                            calling function.
;
; Note that in this function we will not go through MapPageInTables for 2 reasons:
; 1) for speed -- we know in PagingInit we created the structure to this page
; 2) we want to eliminate the possibility of recursion -- which should never happen anyway,
;    but it's good to think about it
;----------------------------------------------------------------------------------------------

MmuNewTable:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdi                     ; save rdi

;----------------------------------------------------------------------------------------------
; get the address and offset of the page table we will update
;----------------------------------------------------------------------------------------------

                mov.q       rax,PAGE_TREE_TEMP      ; push the address we want
                push        rax                     ; damned 32-bit immediates!!!
                call        MmuPTable               ; get the table address
                mov.q       rbx,rax                 ; save the result in rbx

                call        MmuPTOffset             ; get the offset into the table
                add.q       rsp,8                   ; clean up the stack
                mov.q       rcx,rax                 ; save the result in rcx

;----------------------------------------------------------------------------------------------
; get a new frame an put it in the table
;----------------------------------------------------------------------------------------------

                call        AllocFrame              ; get get a frame -- don't care where

                mov.q       [rbx+rcx],rax           ; save the result in the Page Table
                or.q        [rbx+rcx],0x03          ; set the R/W and present flags

;----------------------------------------------------------------------------------------------
; new we want to save the work we have done since we don't want to have to redo it.  Our task
; here is to clear the frame before we put it in its real location.
;----------------------------------------------------------------------------------------------

                push        rax                     ; save our rax value
                push        rbx                     ; save our rbx value
                push        rcx                     ; save our rcx value

                mov.q       rax,PAGE_TREE_TEMP      ; we need to flush the TLB
                invlpg      [rax]                   ; flush it!

                mov.q       rdi,PAGE_TREE_TEMP      ; we need to clear this frame
                xor.q       rax,rax                 ; we want to fill with 0s
                mov.q       rcx,0x1000>>8           ; set the number of qwords to clear

                rep         stosq                   ; clear the page

                pop         rcx                     ; restore our rcx value
                pop         rbx                     ; restore our rbx value

;----------------------------------------------------------------------------------------------
; Finally, we only need to remove the frame from the tables and return it to the physical
; frame address to the caller.
;----------------------------------------------------------------------------------------------

                mov.q       [rbx+rcx],0             ; clear the mapping in the table

                mov.q       rax,PAGE_TREE_TEMP      ; we need to flush the TLB
                invlpg      [rax]                   ; flush it!

                pop         rax                     ; restore our rax value

                pop         rdi                     ; restore rdi
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore the caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void MmuIsPageMapped(qword vAddr) -- Determine if the specified address (page) is mapped in
;                                      the paging tables.  It is not as simple as looking at
;                                      the page table level since the specific page table
;                                      might not actually exist, which will cause a page fault
;                                      when trying to access.
;
; So, for this function, we need to walk the paging tree to determine if all the intermediate
; structures exist.  If one does not, then we will exit reporting that the page is not mapped.
;----------------------------------------------------------------------------------------------

                global      MmuIsPageMapped         ; not really but PMM will use

MmuIsPageMapped:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rsi                     ; save rsi
                push        r9                      ; save r9

                mov.q       rsi,[rbp+16]            ; get the virtual address
                xor.q       r9,r9                   ; set a temp return value: 0 not mapped

;----------------------------------------------------------------------------------------------
; first get the PML4 table entry to see if the pdpt table is mapped
;----------------------------------------------------------------------------------------------

                push        rsi                     ; push virtual address
                call        MmuPML4Table            ; get the pml4 table address
                mov.q       rbx,rax                 ; move the table address
                call        MmuPML4Offset           ; get the pml4 table offset
                add.q       rsp,8                   ; clean up the stack

                test.q      [rbx+rax],0x01          ; is the entry 'present'
                jz          .out                    ; if not, exit

;----------------------------------------------------------------------------------------------
; now get the PDPT table entry to see if the PD table is mapped
;----------------------------------------------------------------------------------------------

                push        rsi                     ; push virtual address
                call        MmuPDPTable             ; get the pdpt table address
                mov.q       rbx,rax                 ; move the table address
                call        MmuPDPOffset            ; get the pdpt table offset
                add.q       rsp,8                   ; clean up the stack

                test.q      [rbx+rax],0x01          ; is the entry 'present'
                jz          .out                    ; if not, exit

;----------------------------------------------------------------------------------------------
; now get the PD table entry to see if the PT table is mapped
;----------------------------------------------------------------------------------------------

                push        rsi                     ; push virtual address
                call        MmuPDirectory           ; get the PD table address
                mov.q       rbx,rax                 ; move the table address
                call        MmuPDOffset             ; get the PD table offset
                add.q       rsp,8                   ; clean up the stack

                test.q      [rbx+rax],0x01          ; is the entry 'present'
                jz          .out                    ; if not, exit

;----------------------------------------------------------------------------------------------
; now get the PT table entry to see if the page table is mapped
;----------------------------------------------------------------------------------------------

                push        rsi                     ; push virtual address
                call        MmuPTable               ; get the PT table address
                mov.q       rbx,rax                 ; move the table address
                call        MmuPTOffset             ; get the PT table offset
                add.q       rsp,8                   ; clean up the stack

                test.q      [rbx+rax],0x01          ; is the entry 'present'
                jz          .out                    ; if not, exit

;----------------------------------------------------------------------------------------------
; finally, the page is mapped if we get here; report that fact
;----------------------------------------------------------------------------------------------

                inc         r9                      ; was 0; now 1

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:           mov.q       rax,r9                  ; set the real return value

                pop         r9                      ; restore r9
                pop         rsi                     ; restore rsi
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret


;==============================================================================================

;----------------------------------------------------------------------------------------------
; void MapPageInTables(qword vAddr, qword pAddr) -- Map the specified virtual address to the
;                                                   specified physical address using the
;                                                   current PML4 table.  pAddr may be passed in
;                                                   as -1, in which case the virtual address is
;                                                   prepared, but not mapped to any physical
;                                                   address.
;
; This function will check each tree level to ensure that the level is populated (present)
; and if not, it will create and initialize it.
;
; For the moment, all the entries will be R/W and Present (bitwise or'd with 0x03).
;----------------------------------------------------------------------------------------------

                global      MapPageInTables         ; not really but PMM will use

MapPageInTables:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; the structure address we are working with
                push        rcx                     ; a general purpose counter
                push        rdx                     ; the index into the structure for entry
                push        rdi                     ; pointer to the entry we are working with
                push        r9                      ; this will be the virtual address to map
                push        r15                     ; a working reg for new structures

;----------------------------------------------------------------------------------------------
; First, we get the virtual address of the PML4 table.  This table is guaranteed to exist
; since paging is enabled.  If it was not, we would have much bigger problems long before ever
; getting to this place in the code.
;----------------------------------------------------------------------------------------------

.pml4:
                mov.q       r9,[rbp+16]             ; get the virtual address we want to map
                push        r9                      ; push the virtual address
                call        MmuPML4Table            ; get the pml4 table virtual address
                add.q       rsp,8                   ; clean up the stack
                mov.q       rbx,rax                 ; move the result into the right reg

;----------------------------------------------------------------------------------------------
; Now we have the following state:
; r9  -- the virtual address we want to map
; rbx -- the virtual address of the pml4 table
;
; Now we want to go calculate the offset of the pml4 table we want to check.  Cur
;----------------------------------------------------------------------------------------------

                push        r9                      ; push it on the stack as parm
                call        MmuPML4Offset           ; get the offset
                add.q       rsp,8                   ; clean up the stack
                mov.q       rdx,rax                 ; save the offset in rdx

;----------------------------------------------------------------------------------------------
; Now we have the following state:
; r9  -- the virtual address we want to map
; rbx -- the virtual address of the pml4 table
; rdx -- the byte offset from the start of the PML4 table to the PML4Entry we need to check
;
; The next thing to do is check the entry to make sure it is present.  We can do this as an
; offset from rbx.
;----------------------------------------------------------------------------------------------

                mov.q       rdi,[rbx+rdx]           ; get the entry
                test.q      rdi,0x01                ; is the PML4 Entry present?
                jnz         .pdpt                   ; if so, move to the pdpt level

;----------------------------------------------------------------------------------------------
; If we made it to this point, we do not have a 'present' pdp table for the virtual address
; in question.  We need to make one.  The registers have the following values:
; r9  -- the virtual address we want to map
; rbx -- the virtual address of the pml4 table
; rdx -- the byte offset from the start of the PML4 table to the PML4Entry we need to create
; rdi -- some garbage value
;
; So, out next step is to call MmuNewTable to properly create a new table for us.  Then we can
; insert the shiny new table into our structures and continue mapping.
;----------------------------------------------------------------------------------------------

                call        MmuNewTable             ; get a new and initialized table for us

                mov.q       [rbx+rdx],rax           ; set the address in the pml4 table entry
                or.q        [rbx+rdx],0x03          ; set the entry to be R/W & Present

.pdpt:

;----------------------------------------------------------------------------------------------
; now, at this point we know we have a good pdpt table and can safely reference it.  Our next
; step is to get the virtual address of this page directory.  Our registers are currently as
; follows:
; r9  -- the virtual address we want to map
; rax -- inconsistent -- can be considered garbage
; rbx -- the virtual address of the pml4 table
; rdx -- the byte offset from the start of the PML4 table to the PML4Entry we checked
; rdi -- inconsistent -- can be considered garbage
;
; so we call the function to get the proper pdpt address.
;----------------------------------------------------------------------------------------------

                push        r9                      ; push the virtual address
                call        MmuPDPTable             ; get the pdp table virtual address
                add.q       rsp,8                   ; clean up the stack
                mov.q       rbx,rax                 ; move the result into the right reg

;----------------------------------------------------------------------------------------------
; Now we have the following state:
; r9  -- the virtual address we want to map
; rbx -- the virtual address of the pdp table
;
; Now we want to go calculate the index of the pdp table we want to check.
;----------------------------------------------------------------------------------------------

                push        r9                      ; push it on the stack as parm
                call        MmuPDPOffset            ; get the index
                add.q       rsp,8                   ; clean up the stack
                mov.q       rdx,rax                 ; save the index in rdx

;----------------------------------------------------------------------------------------------
; Now we have the following state:
; r9  -- the virtual address we want to map
; rbx -- the virtual address of the pdp table
; rdx -- the byte offset from the start of the PDP table to the PDPTEntry we need to check
;
; The next thing to do is check the entry to make sure it is present.  We can do this as an
; offset from rbx.
;----------------------------------------------------------------------------------------------

                mov.q       rdi,[rbx+rdx]           ; get the entry
                test.q      rdi,0x01                ; is the PDPT Entry present?
                jnz         .pd                     ; if so, move to the pd level

;----------------------------------------------------------------------------------------------
; If we made it to this point, we do not have a 'present' page directory for the virtual addr
; in question.  We need to make one.  The registers have the following values:
; r9  -- the virtual address we want to map
; rbx -- the virtual address of the pdp table
; rdx -- the byte offset from the start of the PDP table to the PDPTEntry we need to create
; rdi -- some garbage value
;
; So, out next step is to call MmuNewTable to properly create a new table for us.  Then we can
; insert the shiny new table into our structures and continue mapping.
;----------------------------------------------------------------------------------------------

                call        MmuNewTable             ; get a new and initialized table for us

                mov.q       [rbx+rdx],rax           ; set the address in the pdp table entry
                or.q        [rbx+rdx],0x03          ; set the entry to be R/W & Present

.pd:

;----------------------------------------------------------------------------------------------
; now, at this point we know we have a good page directory and can safely reference it.  Our
; next step is to get the virtual address of this page table.  Our registers are currently as
; follows:
; r9  -- the virtual address we want to map
; rax -- inconsistent -- can be considered garbage
; rbx -- the virtual address of the pdpt table
; rdx -- the byte offset from the start of the pdpt table to the PDPTEntry we checked
; rdi -- inconsistent -- can be considered garbage
;
; so we call the function to get the proper pdpt address.
;----------------------------------------------------------------------------------------------

                push        r9                      ; push the virtual address
                call        MmuPDirectory           ; get the pd table virtual address
                add.q       rsp,8                   ; clean up the stack
                mov.q       rbx,rax                 ; move the result into the right reg

;----------------------------------------------------------------------------------------------
; Now we have the following state:
; r9  -- the virtual address we want to map
; rbx -- the virtual address of the pd table
;
; Now we want to go calculate the index of the pd table we want to check.
;----------------------------------------------------------------------------------------------

                push        r9                      ; push it on the stack as parm
                call        MmuPDOffset             ; get the index
                add.q       rsp,8                   ; clean up the stack
                mov.q       rdx,rax                 ; save the index in rdx

;----------------------------------------------------------------------------------------------
; Now we have the following state:
; r9  -- the virtual address we want to map
; rbx -- the virtual address of the pdp table
; rdx -- the byte offset from the start of the PD table to the PDEntry we need to check
;
; The next thing to do is check the entry to make sure it is present.  We can do this as an
; offset from rbx.
;----------------------------------------------------------------------------------------------

                mov.q       rdi,[rbx+rdx]           ; get the entry
                test.q      rdi,0x01                ; is the PD Entry present?
                jnz         .pt                     ; if so, move to the pt level

;----------------------------------------------------------------------------------------------
; If we made it to this point, we do not have a 'present' page table for the virtual addr
; in question.  We need to make one.  The registers have the following values:
; r9  -- the virtual address we want to map
; rbx -- the virtual address of the pd table
; rdx -- the byte offset from the start of the PD table to the PDEntry we need to create
; rdi -- some garbage value
;
; So, out next step is to call MmuNewTable to properly create a new table for us.  Then we can
; insert the shiny new table into our structures and continue mapping.
;----------------------------------------------------------------------------------------------

                call        MmuNewTable             ; get a new and initialized table for us

                mov.q       [rbx+rdx],rax           ; set the address in the pd table entry
                or.q        [rbx+rdx],0x03          ; set the entry to be R/W & Present

.pt:

;----------------------------------------------------------------------------------------------
; now, at this point we know we have a good page table and can safely reference it.  Our
; next step is to get the virtual address of this page table.  Our registers are currently as
; follows:
; r9  -- the virtual address we want to map
; rax -- inconsistent -- can be considered garbage
; rbx -- the virtual address of the pd table
; rdx -- the byte offset from the start of the pd table to the PDEntry we checked
; rdi -- inconsistent -- can be considered garbage
;
; first check if we need to actually map a physical page
;----------------------------------------------------------------------------------------------

                mov.q       rax,[rbp+24]            ; get the physical address into rax
                cmp.q       rax,-1                  ; do we want to map a physical address?
                je          .out                    ; if not, we can exit

;----------------------------------------------------------------------------------------------
; we got here, so we need to get the virtual address of the page table
;----------------------------------------------------------------------------------------------

                push        r9                      ; push the virtual address
                call        MmuPTable               ; get the page table virtual address
                add.q       rsp,8                   ; clean up the stack
                mov.q       rbx,rax                 ; move the result into the right reg

;----------------------------------------------------------------------------------------------
; Now we have the following state:
; r9  -- the virtual address we want to map
; rbx -- the virtual address of the page table
;
; Now we want to go calculate the index of the page table we want to check.
;----------------------------------------------------------------------------------------------

                push        r9                      ; push it on the stack as parm
                call        MmuPTOffset             ; get the index
                add.q       rsp,8                   ; clean up the stack
                mov.q       rdx,rax                 ; save the index in rdx

;----------------------------------------------------------------------------------------------
; Now we have the following state:
; r9  -- the virtual address we want to map
; rbx -- the virtual address of the pdp table
; rdx -- the byte offset from the start of the page table to the PtEntry we need to check
;
; now all we need to do is map the page.
;----------------------------------------------------------------------------------------------

                mov.q       rax,[rbp+24]            ; get the physical address into rax (again)
                mov.q       [rbx+rdx],rax           ; set the address in the page table entry
                or.q        [rbx+rdx],0x03          ; set the entry to be R/W & Present
                invlpg      [r9]                    ; clear the tlb buffer

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                pop         r15                     ; restore r15
                pop         r9                      ; restore r9
                pop         rdi                     ; restore rdi
                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret


;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword UnmapPageInTables(qword vAddr) -- Unmaps the specified page in virtual memory and
;                                         returns the physical address to which it was mapped.
;
; *********************************************************************************************
; *********************************************************************************************
; **************************  I M P O R T A N T   N O T E ! ! ! *******************************
; *********************************************************************************************
; *********************************************************************************************
;
; This fucntion assumes that the page is question is mapped.  Therefore the calling function is
; REQUIRED to ensure that there is a valid mapping before calling this funciton.  Failure to do
; so will result in a page fault and therefore undesirable results.
;----------------------------------------------------------------------------------------------

                global      UnmapPageInTables

UnmapPageInTables:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; our page table address
                push        rcx                     ; the virtual address we are unmapping

;----------------------------------------------------------------------------------------------
; since we are guaranteed to have a mapped page, we go straight to the proper page table and
; find the entry.
;----------------------------------------------------------------------------------------------

                mov.q       rcx,[rbp+16]            ; get the virtual page address

                push        rcx                     ; go ahead and push it on the stack
                call        MmuPTable               ; get the page table address
                mov.q       rbx,rax                 ; save off the page table address
                call        MmuPTOffset             ; and immediately go get the offset
                add.q       rsp,8                   ; clean up the stack

                mov.q       rcx,[rbx+rax]           ; get the page from the page tables
                mov.q       [rbx+rax],0             ; unmap the page

;----------------------------------------------------------------------------------------------
; at this point, it's might be worth checking all the higher level tables to see if we can
; clear some of the higher level tables.  This tasks is logged as Redmine #176.
;----------------------------------------------------------------------------------------------

                and.q       rcx,~0x0fff             ; get the physical frame address
                mov.q       rax,rcx                 ; set the return value

;----------------------------------------------------------------------------------------------
; finally, flush the TLB buffer
;----------------------------------------------------------------------------------------------

                mov.q       rcx,[rbp+16]            ; get the vurtual address again
                invlpg      [rcx]                   ; flush the TLB for this address

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qwsord VMMInit(void) -- Complete the initialzation that was started in 32-bit mode and un-map
;                        the pages that were mapped with a broad paint brush.  It's time to
;                        fine tune the virtual memory map.
;
; This function is going to have to be completely rewritten since the bulk of its work was
; completed with PagingInit().
;
; VMMInit will return the address of the stack (the lowest address), so the stack pointer will
; need to be adjusted to align to the other side of the stack since stacks grow down.
;----------------------------------------------------------------------------------------------

                global      VMMInit

VMMInit:
                push        rbp                     ; save rbp
                mov.q       rbp,rsp                 ; create a stack frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdi                     ; save rdi

;----------------------------------------------------------------------------------------------
; First, let's start by initializing the stack bitmap
;----------------------------------------------------------------------------------------------

                mov.q       rax,STACK_BM_SIZE       ; we need to allocate 16K from the heap
                call        kmalloc                 ; go get a block of memory
                                                    ; for the moment, assume we got a block

                mov.q       rbx,stackBitmap         ; get the address of the var
                mov.q       [rbx],rax               ; save the bitmap pointer

                mov.q       rdi,rax                 ; set the destination
                mov.q       rcx,STACK_BM_SIZE>>3    ; convert bytes to qwords
                mov.q       rax,-1                  ; fill the bitmap, setting all to free

                rep         stosq                   ; clear the bitmap

;----------------------------------------------------------------------------------------------
; allocate a real stack for the kernel
;----------------------------------------------------------------------------------------------

                call        AllocStack              ; go and allocate a stack

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

                pop         rdi                     ; restore rdi
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore previous frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword VMMAlloc(qword virtAddr, qword pages) -- Allocate a block of virtual memory starting at
;                                                virtAddr and continuine for pages pages.
;
; This function will not replace already allocated pages.  An allocated page is one whose entry
; in the entry in the page table is not 0.  This check should work as when we get into swapping
; pages to disk later, I suspect that there will be some additional flags and such that will
; indicate this condition that will not leave the page all 0.  We already have a function to
; create a new table that will ensure that when a new page table is created, it is first fully
; filled with 0 entries before is is placed in the table structure for real.
;
; Note that it is not expected that the physical memory that backs this virtual memory
; allocation is contiguous.  It is not expected that this function will identity map any
; block of memory.  There are no limits placed on where in physical memory this page will
; be mapped.
;
; Though we should be able to service any request presented for which there is enough memory,
; there are a few sanity checks we will perform as we attempt to allocate memory:
; 0. We will not allocated any memory in the region from 0xffff ff7f ffe0 0000 to
;    0xffff ff7f ffef ffff.
; 1. virtAddr needs to be page-aligned.  If it is not, we will truncate the address to a page
;    and report a warning to the calling function.
; 2. None of the pages from virtAddr to (virtAddr+(pages<<12)) should be mapped already.  If
;    and are, then we will skip that allocation (we will not overwrite a page with a new frame
;    of memory) and continue on.  The calling function will be warned of this condition.  In
;    the event we have an alignment warning and a page already mapped warning, the page already
;    mapped warning will be returned to the calling function.
; 3. In the event we are not able to allocate any physical memory, this error condition will be
;    reported back to the calling function.  This error could occur mid-stream and might result
;    in the block being partially allocated.  We might need to deal with this at some point in
;    the future -- we might need to un-allocate the frames in the event of a failure.  However,
;    it its current configuration, the calling function is at liberty to simply retry the
;    allocation on failure and the missing blocks would get filled in (assuming enough memory
;    is available on the next call).
;----------------------------------------------------------------------------------------------

                global      VMMAlloc

VMMAlloc:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rsi                     ; save rsi
                push        r9                      ; temp return value

                xor.q       r9,r9                   ; clear r9 to assume success

;----------------------------------------------------------------------------------------------
; sanity check #1: page aligned address?
;----------------------------------------------------------------------------------------------

                mov.q       rsi,[rbp+16]            ; get the virtual address
                test.q      rsi,0x0fff              ; check if we are page aligned
                jz          .aligned                ; if we are OK, go on with the allocation

                and.q       rsi,~0x0fff             ; truncate to a page
                mov.q       r9,VMM_WARN_ALIGN       ; set the alignment warning

;----------------------------------------------------------------------------------------------
; now, get the number of pages we need to allocate
;----------------------------------------------------------------------------------------------

.aligned:       mov.q       rcx,[rbp+24]            ; number of pages

;----------------------------------------------------------------------------------------------
; loop through each page requested and perform the following:
; 0) Check if we are allocating memory in the deisgnated PF range
; 1) is the page allocated (i.e. != 0)?
; 2) allocate a frame from PMM.
; 3) if out of memory, set error and return
; 4) map the page
; 5) loop until we have address all the requested pages

;----------------------------------------------------------------------------------------------

.loop:          mov.q       rax,VMM_PF_START        ; get the starting PF address
                cmp.q       rsi,rax                 ; are we before the low address
                jb          .good                   ; if so, jump

                mov.q       rax,VMM_PF_END          ; get the ending PF address
                cmp.q       rsi,rax                 ; are we above the high address
                jbe         .pfMem                  ; if not, we jump out

;----------------------------------------------------------------------------------------------
; So, we start with the check #1.  Note that this is not as simple as it looks on the
; surface.  There is a chance that the actual page table has not been built and therefore
; does not exist.  Accessing that missing page table would cause a page fault.  We don't want
; that.  So, rather than building all this logic in this function, call MmuIsPageMapped() to
; make this determination for us.  I'm sure we will reuse that logic again somewhere anyway.
;----------------------------------------------------------------------------------------------

.good:          push        rsi                     ; push the virtual address
                call        MmuIsPageMapped         ; find out if the page is mapped
                add.q       rsp,8                   ; clean up the stack

                cmp.q       rax,1                   ; is the page mapped?
                je          .mapped                 ; it is so, jump over the allocation code

;----------------------------------------------------------------------------------------------
; step 2: allocate a frame from the PMM & 3: check the results
;----------------------------------------------------------------------------------------------

                call        AllocFrame              ; get a frame from the PMM
                cmp.q       rax,-1                  ; did we get a frame?
                je          .noMem                  ; if not, report our of memory

;----------------------------------------------------------------------------------------------
; step 4: map the page
;----------------------------------------------------------------------------------------------

                push        rax                     ; push the physical frame
                push        rsi                     ; push the virtual page
                call        MapPageInTables         ; map the page
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; step 5: time to iterate the loop; once we are done we jump over the next section to exit
;----------------------------------------------------------------------------------------------

.iter:          add.q       rsi,0x1000              ; move to the next page
                loop        .loop                   ; dec rcx & cmp == 0
                jmp         .done                   ; we are done

;----------------------------------------------------------------------------------------------
; we found a mapped page; set the error and move on
;----------------------------------------------------------------------------------------------

.mapped:        mov.q       r9,VMM_WARN_MAPPED      ; set the return value to mapped
                jmp         .iter                   ; go back and iterate the loop

;----------------------------------------------------------------------------------------------
; we ran out of memory, exit now and report the results
;----------------------------------------------------------------------------------------------

.noMem:         mov.q       r9,VMM_ERR_NOMEM        ; set the return value to error
                jmp         .out                    ; go ahead and exit

;----------------------------------------------------------------------------------------------
; We are trying to allocate memory in the region from VMM_PF_START to VMM_PF_END; report and
; exit
;----------------------------------------------------------------------------------------------

.pfMem:         mov.q       r9,VMM_ERR_BAD_MEM      ; set the return value to error
                jmp         .out                    ; go ahead and exit

;----------------------------------------------------------------------------------------------
; we're done!! prepare to report the results
;----------------------------------------------------------------------------------------------

.done:

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                mov.q       rax,r9                  ; copy return val to rax

                pop         r9                      ; restore r9
                pop         rsi                     ; restore rsi
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword VMMFree(qword virtAddr, qword pages) -- Free a block of pages from the paging tables
;                                               starting at virtAddr and going for pages pages.
;
; This function is the opposite of VMMFree.  No only will is remove the page from the paging
; tree structure, but it will also release the physcial frame back to the PMM.  It is therefore
; the responsibility of the caller to KNOW how many references there are for the physcial frame
; before asking the PMM to free the memory.  This sounds risky to me and I might need to figure
; out a reference count algorithm to add into the mix.  This will be determined as the system
; grows.
;
; We should be able to service any request that is presented to this function.  However, there
; are some sanity checks that need to be completed as well to make sure we are doing the right
; thing.  These are:
; 1.  virtAddr should be page-aligned.  If not, then the address will be truncated to a page
;     and a warning will be presented back to the calling function.
; 2.  Each page should be mapped.  In the event one is not mapped, a warning is returned back
;     the the calling function and the page in question is skipped (for obvious reasons).
;----------------------------------------------------------------------------------------------


                global      VMMFree

VMMFree:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rsi                     ; save rsi
                push        r9                      ; temp return value

                xor.q       r9,r9                   ; clear r9 to assume success

;----------------------------------------------------------------------------------------------
; first, make sure we have a page-aligned address
;----------------------------------------------------------------------------------------------

                mov.q       rcx,[rbp+24]            ; get the number of pages to free

                mov.q       rsi,[rbp+16]            ; get the address of the pages to start
                test.q      rsi,0x0fff              ; are we page aligned?
                jz          .loop                   ; skip any alignment

                mov.q       r9,VMM_WARN_ALIGN       ; set a warning return message
                and.q       rsi,~0x0fff             ; page align the address

;----------------------------------------------------------------------------------------------
; so now we get into the business of freeing pages.  The first thing is to determine if the
; page is actually mapped.
;----------------------------------------------------------------------------------------------

.loop:          push        rsi                     ; push the virtual address
                call        MmuIsPageMapped         ; and go find out if the page is mapped
                add.q       rsp,8                   ; clean up the stack

                cmp.q       rax,0                   ; 0 means the page is not mapped
                je          .notMapped              ; if not mapped, go report the codition

;----------------------------------------------------------------------------------------------
; We know we have a mapped page for this address, so we need to go unmap it.
;----------------------------------------------------------------------------------------------

                push        rsi                     ; push the virtual address again
                call        UnmapPageInTables       ; go and unmap the page in the tables
                add.q       rsp,8                   ; clean up the stack

                push        rax                     ; rax has the physical address
                call        FreeFrame               ; go free the physical frame as well
                add.q       rsp,8                   ; and clean up the stack again

;----------------------------------------------------------------------------------------------
; from here, just iterate until we are done
;----------------------------------------------------------------------------------------------

.iter:          add.q       rsi,0x1000              ; move to the next page
                loop        .loop                   ; dec rcx, cmp rcx == 0

                jmp         .out                    ; we can exit now

;----------------------------------------------------------------------------------------------
; at this point, we are trying to unmap a page that is not mapped.  Set the return value and
; iterate.
;----------------------------------------------------------------------------------------------

.notMapped:     mov.q       r9,VMM_WARN_NOTMAPPED   ; set the return value
                jmp         .iter                   ; go back and iterate

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                mov.q       rax,r9                  ; copy return val to rax

                pop         r9                      ; restore r9
                pop         rsi                     ; restore rsi
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void ReclaimMemory(void) -- Reclaim memory after initialization.  Anything that was used to
;                             get the system operational will be reclaimed by this function.
;                             most of this is virtual memory, but some will be physcial pages
;                             as well.
;----------------------------------------------------------------------------------------------

                global      ReclaimMemory

ReclaimMemory:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx

;----------------------------------------------------------------------------------------------
; now, reclaim all the temporary used space
; A) Unmap the space from 0 to 640K
;----------------------------------------------------------------------------------------------

                xor.q       rbx,rbx                 ; clear rax
                mov.q       rcx,0xa0                ; we need to unmap 160 pages
                sub.q       rsp,8                   ; make room for 1 parameter

.cleanup1:      mov.q       [rsp],rbx               ; set the address to clear
                call        UnmapPageInTables       ; go and unmap the page

                add.q       rbx,0x1000              ; move to the next page
                loop        .cleanup1               ; loop until we unmap all the pages...

;----------------------------------------------------------------------------------------------
; B) Unmap the sapce from 0xffff 8000 0010 0000 to kernelStart
;----------------------------------------------------------------------------------------------

                mov.q       rbx,0xffff800000100000  ; start of higher half code
                mov.q       rcx,kernelStart         ; start to calc the number of pages
                sub.q       rcx,rbx                 ; now we have the size
                shr.q       rcx,12                  ; convert bytes to pages

.cleanup2:      mov.q       [rsp],rbx               ; set the address to clear
                call        UnmapPageInTables       ; go and unmap the page

                add.q       rbx,0x1000              ; move to the next page
                loop        .cleanup2               ; loop until we unmap all the pages...

;----------------------------------------------------------------------------------------------
; C) Free the space from 0x100000 (1MB) to bootEnd
;----------------------------------------------------------------------------------------------
                extern      CODE_VIRT

                mov.q       rbx,kernelStart         ; get the end of the boot code section
                mov.q       rax,CODE_VIRT           ; get the virtual offset
                sub.q       rbx,rax                 ; subtract code virtual offset
                sub.q       rbx,0x100000            ; subtract back 1MB
                shr.q       rbx,12                  ; and convert the result to pages

                push        rbx                     ; push it as parm on stack
                mov.q       rbx,0x100000            ; we want 1MB
                push        rbx                     ; push it as parm on stack
                call        VMMFree                 ; reclaim the memory
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; D) Unmap the space from bootEnd to 0x300000
;----------------------------------------------------------------------------------------------

                mov.q       rbx,bootEnd             ; start of higher half code
                mov.q       rcx,0x300000            ; start to calc the number of pages
                sub.q       rcx,rbx                 ; now we have the size
                shr.q       rcx,12                  ; convert bytes to pages

.cleanup3:      mov.q       [rsp],rbx               ; set the address to clear
                call        UnmapPageInTables       ; go and unmap the page

                add.q       rbx,0x1000              ; move to the next page
                loop        .cleanup3               ; loop until we unmap all the pages...

                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword AllocStack(void) -- Allocate a 16KB stack from the stack area, mark the stack as used,
;                           and allocate the frames needed for this stack.  Return its LOW
;                           address, so the calling function will need to adjust since the
;                           stack grows down.
;----------------------------------------------------------------------------------------------

                global      AllocStack

AllocStack:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rcx                     ; save rcx
                push        rdx                     ; save rdx
                push        rdi                     ; save rdi
                push        r9                      ; save r9
                pushfq                              ; save the flags
                cli                                 ; no interrupts, please

;----------------------------------------------------------------------------------------------
; First, let's initialize the registers
;----------------------------------------------------------------------------------------------

                mov.q       rbx,stackBitmap         ; get the address of the bitmap pointer
                mov.q       rdi,[rbx]               ; get the bitmap address is rdi
                mov.q       rbx,rdi                 ; make rbx also point to bitmap start
                xor.q       rax,rax                 ; clear rax
                mov.q       rcx,STACK_BM_SIZE>>3    ; get the number of qwords to look through

.search:        cmp.q       [rdi],0                 ; are all the stacks used?
                jne         .found                  ; we have a free stack

                add.q       rdi,8                   ; move to the next qword
                loop        .search                 ; search some more

;----------------------------------------------------------------------------------------------
; We have no free stack, we will return 0.
;----------------------------------------------------------------------------------------------

.none:          xor.q       rax,rax                 ; clear the return value
                jmp         .out                    ; no more room; return 0

;----------------------------------------------------------------------------------------------
; So, we know we have an available stack.  We determine the byte offset of the qword using the
; following formula: STACK_BM_SIZE - (rcx<<3).  This will provide the qword we need to further
; investigate.  From there, we just need to query the bits one at a time to find the proper
; stack.
;----------------------------------------------------------------------------------------------

.found:
                mov.q       rax,rcx                 ; move the qword offset
                shl.q       rax,3                   ; convert the qwords to bytes
                mov.q       rcx,STACK_BM_SIZE       ; get the byte size
                sub.q       rcx,rax                 ; rcx now holds the byte offset into bmap

                mov.q       rax,[rbx+rcx]           ; get the qword in question; some bit is 1
                mov.q       rdx,rcx                 ; move the qword offset
                xor.q       rcx,rcx                 ; clear rcx

;----------------------------------------------------------------------------------------------
; now, we want to test the bits in turn to determine the free stack
;----------------------------------------------------------------------------------------------

.loop:          mov.q       r9,1                    ; we need to work with a single bit
                shl.q       r9,cl                   ; shift the bit to get the right mask

                test.q      rax,r9                  ; is the bit 1?
                jnz         .markUsed               ; we found it, go mark it as used

                inc         rcx                     ; move to the next bit
                cmp.q       rcx,63                  ; have we tested all bits?
                ja          .none                   ; something happened, we have none

                jmp         .loop                   ; loop to check the next one

;----------------------------------------------------------------------------------------------
; we found our bit. marking it used is simple.  However we need to preserve the values in
; rax, rbx, rcx, and rdx
;----------------------------------------------------------------------------------------------

.markUsed:      not.q       r9                      ; invert this bit mask
                and.q       [rbx+rdx],r9            ; and mark the stack as used

;----------------------------------------------------------------------------------------------
; now we can calculate the low address of the stack and set it to be returned.  We know the
; starting address of the stack range as STACK_LOC.  Each qword in the bitmap controls 64
; stacks (each 16K).  rdx has the byte offset of the qword we know to have the stack we want.
; So, we will need to convert rdx back to a qword index by using rdx >> 3.  Now, we need to
; adjust for the qwords we skipped.  This is done by rdx << 20 since each qword controls 1MB
; of stack space (bytes).  This results in a net rdx << 17 operation.  rdx also hold the number
; of 16K stacks we need to adjust to.  So, we can adjust rcx << 14 to get the offset to the
; start of the stack space.  Now, we add STACK_LOC, rdx, and rcx together, and we get the LOW
; address of the stack we want to return.
;----------------------------------------------------------------------------------------------

                shl.q       rdx,17                  ; adjust rcx
                shl.q       rcx,14                  ; adjust rdx

                mov.q       rax,STACK_LOC           ; get the base stack space address
                add.q       rax,rdx                 ; adjust for qwords skipped
                add.q       rax,rcx                 ; adjust for bits skipped

;----------------------------------------------------------------------------------------------
; the final task here is to make sure the virtual memory we just allocated is mapped.
;----------------------------------------------------------------------------------------------

                mov.q       r9,STACK_BM_SIZE        ; get the stack size
                shr.q       r9,12                   ; convert to pages -- assumes page multiple
                push        r9                      ; push pages to alloc
                push        rax                     ; push starting address
                call        VMMAlloc                ; go and allocate the pages
                pop         rax                     ; we need to recover our address
                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:
                popfq                               ; restore flags (with interrupts)
                pop         r9                      ; restore r9
                pop         rdi                     ; restore rdi
                pop         rdx                     ; restore rdx
                pop         rcx                     ; restore rcx
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================
