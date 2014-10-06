;==============================================================================================
;
; loader.s
;
; This file contains the initial functions and structures required by the Multiboot loader to
; properly transfer control to the kernel after loading it in memory.  There are structures
; that are required to be 4-byte aligned and must be in the first 8K of the file for the final
; binary to be Multiboot compliant.  These structures are implemented here.
;
;    Date     Tracker  Pgmr  Description
; ----------  ------   ----  ------------------------------------------------------------------
; 2014/09/24  Initial  ADCL  Leveraged from osdev.org -- "Higher Half Bare Bones" wiki
; 2014/09/25  Initial  ADCL  Since "Higher Half Bare Bones" did not work, scrapped it all for
;                            a run at "64-bit Higher Half Kernel with GRUB2.
; 2014/09/26  Initial  ADCL  After a lot of work and a sleepless night, I have finally been
;                            able to get an elf64 image to boot with GRUB2 using the multiboot
;                            1 header.  The key to making this work was changing the page size
;                            for the linker to be 0x800 (2K).  The multiboot header is found
;                            on the third page and needs to be in the first 8K of the file.
;                            With a page size of 2K, this offset is at 4K.  If I bump the page
;                            size to the next power of 2 (0x1000 or 4K) when the multiboot
;                            header is at 8K.  You would think that is right, but it turns out
;                            that the entire header bust be contained within 8K, putting it
;                            just out of reach.  The parameter on x86_64-elf-gcc that makes
;                            this successful is "-z max-page-size=0x800".
;                            Due to issues in the linker.ld script which have been resolved,
;                            the multiboot header is now in the second page, not the third.
;                            Changing back to "-z max-page-size=0x1000".
;                            Added back in the higher-half bare bones code (well, some of it)
;                            and wrote the character to the screen from the higher-half .text
;                            section.
; 2014/09/28  Initial  ADCL  Added code from the "Setting Up Long Mode" wiki.
;             #157     ADCL  Created the initial GDT and enabled it.
; 2014/10/04  Initial  ADCL  After a log of work trying to get the system to boot properly,
;                            and a hint from Brendan at osdev.org, I need to reconsider
;                            the memory layout.  Brendan shared the following problem
;                            with "immediate values":
;                            http://forum.osdev.org/viewtopic.php?f=1&t=28573#p240973,
;                            and ahd the following suggestion om memory layout:
;                            http://forum.osdev.org/viewtopic.php?f=1&t=28573#p240979.
;                            In short, I'm taking his advice and redoing the startup code.
;
;==============================================================================================

;----------------------------------------------------------------------------------------------
; Setup to some constants that will be used in our kernel
;----------------------------------------------------------------------------------------------

MBMODALIGN	equ			1<<0
MBMEMINFO	equ			1<<1
MBVIDINFO	equ			1<<2
MBAOUT		equ			1<<16				; this will not be used in our kernel

MBMAGIC		equ			0x1badb002
MBFLAGS		equ			(MBMODALIGN | MBMEMINFO | MBVIDINFO)
MBCHECK		equ			-(MBMAGIC + MBFLAGS)

MBMAGIC2	equ			0xe85250d6
MBLEN		equ			MultibootHeader2End - MultibootHeader2
MBCHECK2	equ			(-(MBMAGIC2 + 0 + MBLEN) & 0xffffffff)

STACKSIZE	equ			0x4000				; 16K stack

;==============================================================================================
; The .multiboot section will be loaded at 0x100000 (1MB).  It is intended to provide the
; necessary data for a multiboot loader to find the information required.  The linker script
; will put this section first.  Once fully booted, this section will be reclaimed.
;==============================================================================================
			section		.multiboot
			align		8

MultibootHeader:							; Offset  Description
			dd			MBMAGIC				;    0    multiboot magic number
			dd			MBFLAGS				;    4    multiboot flags
			dd			MBCHECK				;    8    checksum
			dd			0					;    c    header address (flag bit 16)
			dd			0					;   10    load address (flag bit 16)
			dd			0					;   14    load end address (flag bit 16)
			dd			0					;   18    bss end address (flag bit 16)
			dd			0					;   1c    entry address (flag bit 16)
			dd			1					;   20    vidoe mode (1 == text) (flag bit 2)
			dd			80					;   24    video columns (flag bit 2)
			dd			25					;   28    video rows (flag bit 2)
			dd			8					;   2c    video color depth (flag bit 2)

;----------------------------------------------------------------------------------------------
; So, I was thinking, why would I not be able to provide BOTH the multiboot header 1 and the
; multiboot header 2 in the same file?  I could not think of any technical reason except that
; grub needs to know which signature to look for.  The command in grub.cfg is multiboot2 for
; the newer version.  The following multiboot2 header also works.  The key is going to make
; sure we get the system in a state that we can get into a consistent state for the rest of
; the kernel initialization.  The following is the multiboot2 header for this implementation.
;
; **NOTE** the docuentation does not tell you that each of tag structures must be 8-byte
; aligned.  Therefore you will see 'align 8' lines throughout this structure.
;----------------------------------------------------------------------------------------------

			align		16

MultibootHeader2:							; Description
			dd			MBMAGIC2			;   multiboot2 magic number
			dd			0					;   architecture: 0=32-bit protected mode
			dd			MBLEN				;   total length of the mb2 header
			dd			MBCHECK2			;   mb2 checksum

			align		8					; 8-byte aligned
Type4Start:									; Console Flags
			dw			4					;   type=4
			dw			1					;   not optional
			dd			Type4End-Type4Start	;   size = 12
			dd			1<<1				;   EGA text support
Type4End:

			align		8					; 8-byte aligned
Type6Start:									; Modue align
			dw			6					;   Type=6
			dw			1					;   Not optional
			dd			Type6End-Type6Start	;   size = 8 bytes even tho the doc says 12
Type6End:

			align		8					; 8-byte aligned
											; termination tag
			dw			0					; type=0
			dw			0					; flags=0
			dd			8					; size=8

MultibootHeader2End:

;----------------------------------------------------------------------------------------------
; These messages exist here because they are not needed after initialization
;----------------------------------------------------------------------------------------------

noCPUIDmsg:	db			'OpCode cpuid is not available on this processor; cannot enter long '
			db			'mode',0
noFuncMsg:	db			'Extended CPUID functions not available; cannot enter long mode',0
noLongMsg:	db			'Long mode not supported on this CPU; cannot continue',0

;----------------------------------------------------------------------------------------------
; These are our own initial GDTs; they will change later and we will not need them after init
;----------------------------------------------------------------------------------------------

			align		8
gdtr1:										; this is out initial GDTR
			dw			gdt1End-gdt1-1
			dd			gdt1

gdt1:
			dq			0					; GDT entry 0x00
			dq			0x00cf9A000000ffff	; DGT entry 0x08
			dq			0x00cf92000000ffff	; GDT entry 0x10
gdt1End:

gdtr64:										; this is the GDT to jump into long mode
			dw			gdtEnd-gdt-1
			dd			gdt

gdtr:
			dw			gdtEnd-gdt-1
			dq			gdt

			align		8

gdt:
			dq			0					; GDT entry 0x00
			dq			0x00a09a0000000000	; GDT entry 0x08
			dq			0x00a0920000000000	; GDT entry 0x10
gdtEnd:

mbEAX:		dd			0					; we will store eax from MB here for later
mbEBX:		dd			0					; we will store ebx from MB here for later as well

;==============================================================================================
; The .bootstack is a temporary stack needed by the 32-bit boot code.
;==============================================================================================

			section		.bootstack
			align		0x1000

stack32:	times(STACKSIZE)	db		0

;==============================================================================================
; The .bootcode section is a booting code section that is 32-bit code and used to get into long
; mode.  Once initilalization is complete, we will reclaim this memory as it will not be needed
; anymore.
;
; Note that since we are in protected mode coming from the boot loader, we will assume that we
; are at least a 32-bit processor.  We might want to go back later to make sure we can handle
; gracefully a really really old computer, but that is not a top priority.  By the time it does
; bubble up to the top of the list, is expect that 64-bit processors will be ancient anyway.
;==============================================================================================

			section		.bootcode
			global		EntryPoint
			align		0x1000

			bits		32

EntryPoint:
;----------------------------------------------------------------------------------------------
; Make sure we are in the state we expect -- in case we find a boot loader that is not
; compliant.
;----------------------------------------------------------------------------------------------

			cli								; no interrupts, please

			mov			[mbEAX],eax			; we need to save eax as it has data we want
			mov			[mbEBX],ebx			; we also need to save ebx as it also has data

			mov			al,0xff				; disable the PIC
			out			0xa1,al
			out			0x21,al

;----------------------------------------------------------------------------------------------
; Setup our own GDT -- we don't know where the other has been...
;----------------------------------------------------------------------------------------------

			lgdt		[gdtr1]				; Load our own GDT
			jmp			0x08:.gdt1enable	; we need a jump like this to reload the CS.

.gdt1enable:
			mov			eax,0x10			; set the segment selector for data that we...
			mov			ds,ax				; ... set to DS
			mov			es,ax				; ... set to ES
			mov			fs,ax				; ... set to FS
			mov			gs,ax				; ... set to GS
			mov			ss,ax				; ... and set to SS
			mov			esp,stack32+STACKSIZE	; and we create a stack

;----------------------------------------------------------------------------------------------
; We have reached our first milestone: we now use our own GDT.  Celebrate by clearing the
; the screen and putting an "A" in the first row, first column.
;----------------------------------------------------------------------------------------------

			mov			edi,0xb8000			; set the screen buffer location
			mov			ecx,80*25			; set the number of attr/char pairs to write
			xor			eax,eax				; clear eax
			mov			ax,0x0f20			; set the attr/char pair to write
			cld
			rep			stosw				; clear the screen

			mov			edi,0xb8000			; go back to the first column
			mov			dword [edi+(0*2)],(0x0f<<8)|'A'	; put an "A" on the screen

;----------------------------------------------------------------------------------------------
; Make sure we are in protected mode
;----------------------------------------------------------------------------------------------

			mov			eax,cr0				; get CR0 to see if protected mode is on
			or			eax,1<<0			; make sure the PE bit is on
			and			eax,0x7fffffff		; make sure paging is disabled
			mov			cr0,eax

;----------------------------------------------------------------------------------------------
; Since we now KNOW we are in protected mode, let's call that our second milestons.  Put a "B"
; on the screen.
;----------------------------------------------------------------------------------------------

			mov			dword [edi+(1*2)],(0x0f<<8)|'B'	; put an "B" on the screen

;----------------------------------------------------------------------------------------------
; Determine if the CPUID opcode is available...
;----------------------------------------------------------------------------------------------

			pushfd							; start by pushing the flags register
			pop			eax					; we want to be able to manipulate it
			mov			ecx,eax				; and we need a copy of it to compare later
			xor			eax,1<<21			; the ID bit is bit 21; flip it
			push		eax					; put the changed flags back on the stack
			popfd							; and put it back in the flags reg...
			pushfd							; now, we need to see if our change was kept...
			pop			eax					; eax will have the the ID bit; we can test
											; against bit 21 of ecx to see if the change held
			push		ecx					; first, restore the original flags
			popfd							; back into the flags register

			and			eax,1<<21			; we want to mask out our flag, just in case
			and			ecx,1<<21			; something else changed
			cmp			eax,ecx				; are they the same?
			jnz			.CPUIDOK			; if they are not, we can use CPUID

			mov			esi,noCPUIDmsg		; set the message
			jmp			dieMsg				; jump to common point to display the message

;----------------------------------------------------------------------------------------------
; Now we KNOW we can use CPUID to determine other features.  Celebrate by putting a "C" on the
; screen
;----------------------------------------------------------------------------------------------

.CPUIDOK:
			mov			dword [edi+(2*2)],(0x0f<<8)|'C'	; put an "C" on the screen

;----------------------------------------------------------------------------------------------
; Well, we can use CPUID. but can we determine if long mode is supported with CPUID?
;----------------------------------------------------------------------------------------------

			mov			eax,0x80000000		; need to know what extended functions are avail.
			cpuid							; go get the info
			cmp			eax,0x80000001		; can we call the function?
			jnb			.ExtFuncOK			; if so, We can use  extended functions

			mov			esi,noFuncMsg		; set the message
			jmp			dieMsg				; jump to common point to display the message

;----------------------------------------------------------------------------------------------
; Finally, we can actually query the CPU if it support long mode
;----------------------------------------------------------------------------------------------

.ExtFuncOK:
			mov			eax,0x80000001		; need to know if long mode is supported
			cpuid
			test		edx,1<<29			; bit 29 holds whether long mode is supported
			jnz			.LongOK				; if so, we want to continue
			test		edx,1<<20			; either bit could be set
			jnz			.LongOK				; if so, we want to continue

			mov			esi,noLongMsg		; set the message
			jmp			dieMsg				; and fall through to display and die

;----------------------------------------------------------------------------------------------
; Now we KNOW that long mode is available.  Celebrate by putting a "D" on the screen
;----------------------------------------------------------------------------------------------

.LongOK:
			mov			dword [edi+(3*2)],(0x0f<<8)|'D'	; put an "D" on the screen

;----------------------------------------------------------------------------------------------
; Set the flags needed to enter long mode
;----------------------------------------------------------------------------------------------

			mov			ecx,cr4
			or			ecx,1<<5			; set PAE in CR4
			mov			cr4,ecx

			mov 		ecx,0xc0000080		; we want the EFER MSR
			rdmsr							; get the model specific register
			or			eax,1<<8			; Set the LM bit for long mode
			wrmsr							; and put the result back

;----------------------------------------------------------------------------------------------
; Enable paging
;----------------------------------------------------------------------------------------------

			extern		PML4Table

			mov			ecx,PML4Table		; load cr3 with out PML4 table
			mov			cr3,ecx

			mov			ecx,cr0
			or			ecx,1<<31			; set PG in CR0 to enable paging
			mov			cr0,ecx

;----------------------------------------------------------------------------------------------
; Now we we have turned on paging.  If we are able to execute the next line of code, then we
; will have been successful in getting paging properly set up.  We will check by putting an
; "E" on the screen.
;----------------------------------------------------------------------------------------------

			mov			dword [edi+(4*2)],(0x0f<<8)|'E'	; put an "E" on the screen

;----------------------------------------------------------------------------------------------
; Now, all we have to do to get into long mode is replace the GDT with a 64-bit version and
; jump to 64-bit code.
;----------------------------------------------------------------------------------------------

			lgdt		[gdtr64]			; Load our own GDT
			jmp			0x08:gdt64enable

;----------------------------------------------------------------------------------------------
; Error messages if we are not able to enter long mode
;----------------------------------------------------------------------------------------------



dieMsg:										; we have a message to display...  display it
			mov			edi,0xb8000			; start un the upper left corner.

.loop:
			mov			ah,0x0f
			mov			al,[esi]			; get the next (attr<<8|char) to display
			cmp			al,0				; is it 0?
			je			.dieNow				; if so, we reach the end of the string
			mov			[edi],ax			; now, display the attr/char combo
			add			edi,2				; move to the next screen pos
			inc			esi					; move to the next char to display
			jmp			.loop


.dieNow:	hlt
			jmp			.dieNow

;----------------------------------------------------------------------------------------------
; 64-bit code follows from here...
;----------------------------------------------------------------------------------------------

			bits		64
			align		8

gdt64enable:
			mov			rax,0x10			; set the segment selector for DS
			mov			ds,ax
			mov			es,ax
			mov			fs,ax
			mov			gs,ax
			mov			ss,ax

			mov			rsp,stack+STACKSIZE

;----------------------------------------------------------------------------------------------
; At this point, we have now entered 64-bit code.  Our GDT is sill sitting in the space we
; want to reclaim later and we are not yet running in higher-half code.  But, at least we are
; in a 64-bit world.  Celebrate by putting an "F" on the screen.
;----------------------------------------------------------------------------------------------

			mov			dword [edi+(5*2)],(0x0f<<8)|'F'	; put an "F" on the screen

;----------------------------------------------------------------------------------------------
; Now we can jump to the higher half
;----------------------------------------------------------------------------------------------

			mov			rax,StartHigherHalf
			jmp			rax

;==============================================================================================
; The .data segment will hold all data related to the kernel
;==============================================================================================

			section		.data

VIRT_BASE	equ			0xffffffff80000000

			align		8

;==============================================================================================
; The .text section is the 64-bit kernel proper
;==============================================================================================

			section		.text
			bits		64

			extern		TextClear

StartHigherHalf:
			mov			ebx,0xb8000
			mov			word [ebx+(6*2)],0x0f<<8|'G'	; put a "G" on the screen

;----------------------------------------------------------------------------------------------
; Now that we are finally in higher-memory, we can set the final GDT.  However, there is a
; catch: the GDT must be in 32-bit accessable memory!!!  Therefore, we need to set this up
; in lower memory.  I pick the lower address of the boot stack (whcih we are no longer using
; at this point.
;----------------------------------------------------------------------------------------------

			lgdt		[gdtr]							; Load our own GDT
			jmp		.gdtenable

.gdtenable:
			mov			eax,0x10						; set the segment selector for DS
			mov			ds,ax
			mov			es,ax
			mov			fs,ax
			mov			gs,ax
			mov			ss,ax

			mov			ebx,0xb8000
			mov			word [ebx+(7*2)],0x0f<<8|'H'	; put a "H" on the screen

;----------------------------------------------------------------------------------------------
; At this point, the memory layout looks like this:
;
; #	Physical Addr	Size		Virtual Addr 1			Virtual Addr 2			Usage
; -	-------------	--------	------------------		-------------------		-----------
; 1	0x00000000 		1MB			0x0000000000000000		0xffffffff80000000		Open
; 2	0x00100000		4KB			0x0000000000100000		0xffffffff80100000		MBHdr&Code
; 3	0x00101000		16KB		0x0000000000101000		0xffffffff80101000		Boot Stack
; 4	0x00105000		12KB		0x0000000000105000		0xffffffff80105000		Open
; 5	0x00108000		28KB		0x0000000000108000		0xffffffff80108000		Paging Tbls
; 6	0x0010f000		4K			0x000000000010f000		0xffffffff8010f000		64-bit code
; 7	0x00110000		16K			0x0000000000110000		0xffffffff80110000		kernel stack
; 8 0x00114000		up to 2M	0x0000000000114000		0xffffffff80114000		open
;
; So, with the above information we want to do the following:
; 1, 4, & 8 -- These memory blocks will become part of the free memory pool; we will drop both
;              high and low memory mappings
; 2 -- Keep this memory allocated as it holds out GDT (may want to relocate in the future); we
;      will drop the high memory mapping
; 3 -- Free this memory back to the free memory pool; we will drop the high and low memory
;      mappings
; 5 -- Keep allocated (perhaps to allocate backwards through the old boot Stack for future); we
;      will drop the high-memory mapping
; 6 -- The kernel proper; we will drop the low memory mapping
; 7 -- The bss (a data segment will be added in here somewhere, which we want to keep); we will
;      drop the low memory mapping.
;
; **** NOTE ****
; This memory map will change as the code grows.  Care has been taken to align the section
; starts on page boundaries.  However, for now, the order of things is not likely to change.
;----------------------------------------------------------------------------------------------

			call		TextClear

.loop:
			cli
			hlt
			jmp			.loop

;==============================================================================================
; The .bss section so far contains the kernel stack
;==============================================================================================

			section		.bss
			align		0x1000

stack:		resb		STACKSIZE

;==============================================================================================
