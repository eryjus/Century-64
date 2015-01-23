;==============================================================================================
;
; loader.s
;
; This file contains the initial functions and structures required by the Multiboot loader to
; properly transfer control to the kernel after loading it in memory.  There are structures
; that are required to be 4-byte aligned and must be in the first 8K of the file for the final
; binary to be Multiboot compliant.  These structures are implemented here.
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
;    Date     Tracker  Pgmr  Description
; ----------  -------  ----  ------------------------------------------------------------------
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
; 2014/10/12  #169     ADCL  For me, the ABI standard is causing me issues. For whatever reason,
;                            I am having trouble keeping track of "registers I want to save as
;                            the caller" rather than "saving all registers I will modify as the
;                            callee". I will adopt the latter standard so that debugging will
;                            be easier to manage, with the exception of rax.  DF in rFLAGS will
;                            be maintained as clear.
;                            Established the final connection to the Physical Memory Manager
;                            Initialization.
; 2014/10/20  #185     ADCL  Removed the *big* alignments as needed; let the linker script
;                            handle aligning sections.  Small qword or less size alignments for
;                            system structures left in place.
;             #180     ADCL  Moved the final GDT into higher memory (in the .data section).
; 2014/11/19  #200     ADCL  OK, according to the Intel manual (Vol 3A; section 9.8.5), the
;                            following are the steps needed to get into IA-32e Mode:
;                            1.  Start from protected mode (Multiboot will handle this) and
;                                disable paging (which again, Multiboot will have not enabled)
;                            2.  Enable CR4.PAE
;                            3.  Setup and load (in the first 4GB physical memory) the paging
;                                tables and load CR3 with the address of the PML4 table (32
;                                bit address!!!)
;                            4.  Enable IA32_EFER.LME
;                            5.  Enable CR0.PG
;                            6.  Jump to higher memory
;                            So...., we are going to try to streamline getting into long mode
;                            according to the steps above.
;                            At the same time, I will reformat this source file to match the
;                            adopted coding style and clean it up for general readibility.
; 2014/11/29  #201     ADCL  Reclaim the memory that was used to get into 64-bit mode.
;             #208           All the final clean-up has been completed.
; 2014/12/01  #215     ADCL  So, the GDT is going to be built from kernel heap.  So, the one
;                            that is created as soon as we get into higher memory is not
;                            needed.  Remove that GDT and replace it with a call to GDTInit.
;                            In addition, some general cleanup of unnecessary calls.
; 2014/12/02  #217     ADCL  Relocated the paging clean into a function in virtmm.s.
; 2014/12/23  #205     ADCL  Added initailization for the Debugging Console (COM1).
; 2015/01/04  #247     ADCL  Recreated the idle process as the butler process and then created
;                            a pure (clean) idle process.
;
;==============================================================================================

%define         __LOADER_S__
%include        'private.inc'

                global      mbEAX
                global      mbEBX

;----------------------------------------------------------------------------------------------
; Setup to some constants that will be used in our kernel
;----------------------------------------------------------------------------------------------

MBMODALIGN      equ         1<<0
MBMEMINFO       equ         1<<1
MBVIDINFO       equ         1<<2
MBAOUT          equ         1<<16               ; this will not be used in our kernel

MBMAGIC         equ         0x1badb002
MBFLAGS         equ         (MBMODALIGN | MBMEMINFO | MBVIDINFO)
MBCHECK         equ         -(MBMAGIC + MBFLAGS)

MBMAGIC2        equ         0xe85250d6
MBLEN           equ         MultibootHeader2End - MultibootHeader2
MBCHECK2        equ         (-(MBMAGIC2 + 0 + MBLEN) & 0xffffffff)

STACKSIZE       equ         0x400              ; 1K stack

;==============================================================================================
; The .multiboot section will be loaded at 0x100000 (1MB).  It is intended to provide the
; necessary data for a multiboot loader to find the information required.  The linker script
; will put this section first.  Once fully booted, the memory for this section will be
; reclaimed.
;==============================================================================================

                section     .multiboot
                align       8

MultibootHeader:                            ; Offset  Description
                dd          MBMAGIC             ;    0    multiboot magic number
                dd          MBFLAGS             ;    4    multiboot flags
                dd          MBCHECK             ;    8    checksum
                dd          0                   ;    c    header address (flag bit 16)
                dd          0                   ;   10    load address (flag bit 16)
                dd          0                   ;   14    load end address (flag bit 16)
                dd          0                   ;   18    bss end address (flag bit 16)
                dd          0                   ;   1c    entry address (flag bit 16)
                dd          1                   ;   20    vidoe mode (1 == text) (flag bit 2)
                dd          80                  ;   24    video columns (flag bit 2)
                dd          25                  ;   28    video rows (flag bit 2)
                dd          8                   ;   2c    video color depth (flag bit 2)

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

                align       8

MultibootHeader2:                           ; Description
                dd          MBMAGIC2            ;   multiboot2 magic number
                dd          0                   ;   architecture: 0=32-bit protected mode
                dd          MBLEN               ;   total length of the mb2 header
                dd          MBCHECK2            ;   mb2 checksum

                align       8                   ; 8-byte aligned
Type4Start:                                 ; Console Flags
                dw          4                   ;   type=4
                dw          1                   ;   not optional
                dd          Type4End-Type4Start ;   size = 12
                dd          1<<1                ;   EGA text support
Type4End:

                align       8                   ; 8-byte aligned
Type6Start:                                 ; Modue align
                dw          6                   ;   Type=6
                dw          1                   ;   Not optional
                dd          Type6End-Type6Start ;   size = 8 bytes even tho the doc says 12
Type6End:

                align       8                   ; 8-byte aligned
                                            ; termination tag
                dw          0                   ; type=0
                dw          0                   ; flags=0
                dd          8                   ; size=8

MultibootHeader2End:

;----------------------------------------------------------------------------------------------
; These messages exist here because they are not needed after initialization
;----------------------------------------------------------------------------------------------

noCPUIDmsg:     db          'OpCode cpuid is not available on this processor; cannot enter '
                db          'long mode',0
noFuncMsg:      db          'Extended CPUID functions not available; cannot enter long mode',0
noLongMsg:      db          'Long mode not supported on this CPU; cannot continue',0

;----------------------------------------------------------------------------------------------
; The following is our initial GDT; we will use it to replace the bootloader GDT right away
;----------------------------------------------------------------------------------------------

                align       8
gdt32:
                dq          0                   ; GDT entry 0x00
                dq          0x00cf9a000000ffff  ; DGT entry 0x08
                dq          0x00cf92000000ffff  ; GDT entry 0x10
gdt32End:

gdtr32:                                     ; this is out initial GDTR
                dw          gdt32End-gdt32-1
                dd          gdt32

;----------------------------------------------------------------------------------------------
; The following is our GDT we need to enter 64-bit code; we will use it to replace the 32-bit
; GDT
;----------------------------------------------------------------------------------------------

                align       8

gdt64:
                dq          0                   ; GDT entry 0x00
                dq          0x00a09a0000000000  ; GDT entry 0x08
                dq          0x00a0920000000000  ; GDT entry 0x10
gdt64End:

gdtr64:                                     ; this is the GDT to jump into long mode
                dw          gdt64End-gdt64-1
                dd          gdt64


mbEAX:          dd          0                   ; we will store eax from MB here for later
mbEBX:          dd          0                   ; we will store ebx from MB here for later as well

;==============================================================================================
; The .bootstack is a temporary stack needed by the 32-bit boot code.
;==============================================================================================

                section     .bootstack

stack32:        times(STACKSIZE)    db      0

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

                section     .bootcode
                global      EntryPoint
                bits        32

EntryPoint:
;----------------------------------------------------------------------------------------------
; Make sure we are in the state we expect -- in case we find a boot loader that is not
; compliant.
;----------------------------------------------------------------------------------------------

                cli                                 ; no interrupts, please -- just in case
                cld                                 ; make sure we increment -- per ABI

                mov.d       [mbEAX],eax             ; we need to save eax; it has data we want
                mov.d       [mbEBX],ebx             ; we also need to save ebx

                mov.b       al,0xff                 ; disable the PIC
                out         0xa1,al
                out         0x21,al

;----------------------------------------------------------------------------------------------
; Setup our own GDT -- we don't know where the other has been...
;----------------------------------------------------------------------------------------------

                mov.d       eax,gdtr32              ; get the address of our gdt
                lgdt        [eax]                   ; Load our own GDT
                jmp         0x08:.gdt32enable       ; we need a jump like this to reload the CS.

.gdt32enable:
                mov.d       eax,0x10                ; set the segment selector for data that we...
                mov.w       ds,ax                   ; ... set to DS
                mov.w       es,ax                   ; ... set to ES
                mov.w       fs,ax                   ; ... set to FS
                mov.w       gs,ax                   ; ... set to GS
                mov.w       ss,ax                   ; ... and set to SS
                mov.d       esp,stack32+STACKSIZE   ; and we create a stack

;----------------------------------------------------------------------------------------------
; We have reached our first milestone: we now use our own GDT.  Celebrate by clearing the
; the screen and putting an "A" in the first row, first column.
;----------------------------------------------------------------------------------------------

                mov.d       edi,0xb8000             ; set the screen buffer location
                mov.d       ecx,80*25               ; set the nbr of attr/char pairs to write
                xor.d       eax,eax                 ; clear eax
                mov.w       ax,0x0f20               ; set the attr/char pair to write
                rep         stosw                   ; clear the screen

                mov.d       edi,0xb8000             ; go back to the first column
                mov.w       [edi],(0x0f<<8)|'A'     ; put an "A" on the screen
                add.d       edi,2                   ; move to the next position on the screen

;----------------------------------------------------------------------------------------------
; Make sure we are in protected mode
;----------------------------------------------------------------------------------------------

                mov.d       eax,cr0                 ; get CR0 to set protected mode on
                or.d        eax,1<<0                ; make sure the PE bit is on
                mov.d       ecx,1<<31               ; set up the paging bit
                not.d       ecx                     ; bitwise not
                and.d       eax,ecx                 ; make sure paging is disabled
                mov.d       ebx,.tgt1               ; random failures can occur if do not jmp
                mov.d       cr0,eax                 ; set CR0 with the new flags

                jmp         ebx                     ; make this code comply with Intel docs

;----------------------------------------------------------------------------------------------
; Since we now KNOW we are in protected mode, let's call that our second milestons.  Put a "B"
; on the screen.
;
; Note that at this point, we have also accomplished the first step required to get into
; long mode (as mentioned in the header comments).
;----------------------------------------------------------------------------------------------

 .tgt1:         mov.d       eax,0x10                ; set the segment selector for data segs
                mov.w       ds,ax
                mov.w       es,ax
                mov.w       fs,ax
                mov.w       gs,ax
                mov.w       ss,ax
                mov.d       esp,esp

                mov.w       [edi],(0x0f<<8)|'B'     ; put an "B" on the screen
                add.d       edi,2                   ; move to the next pos on the screen

;----------------------------------------------------------------------------------------------
; Now, we need to do a little housekeeping.  Determine if the CPUID opcode is available...
;----------------------------------------------------------------------------------------------

                pushfd                              ; start by pushing the flags register
                pop         eax                     ; we want to be able to manipulate it
                mov.d       ecx,eax                 ; and we need a copy of it to compare later
                xor.d       eax,1<<21               ; the ID bit is bit 21; flip it
                push        eax                     ; put the changed flags back on the stack
                popfd                               ; and put it back in the flags reg...
                pushfd                              ; now, we need to see if our chg remained
                pop         eax                     ; eax will have the the ID bit; we can test
                                                    ; against bit 21 ecx to see if the chg held
                push        ecx                     ; first, restore the original flags
                popfd                               ; back into the flags register

                and.d       eax,1<<21               ; we want to mask out our flag in case
                and.d       ecx,1<<21               ; something else changed
                cmp.d       eax,ecx                 ; are they the same?
                jnz         .CPUIDOK                ; if they are not, we can use CPUID

                mov.d       esi,noCPUIDmsg          ; set the message
                jmp         dieMsg                  ; jump to common point to display the message

;----------------------------------------------------------------------------------------------
; Now we KNOW we can use CPUID to determine other features.  Celebrate by putting a "C" on the
; screen
;----------------------------------------------------------------------------------------------

.CPUIDOK:
                mov.w       [edi],(0x0f<<8)|'C'     ; put an "C" on the screen
                add.d       edi,2                   ; move to the next pos on screen

;----------------------------------------------------------------------------------------------
; Well, we can use CPUID. but can we determine if long mode is supported with CPUID?
;----------------------------------------------------------------------------------------------

                mov.d       eax,0x80000000          ; need to know what ext functs are avail
                cpuid                               ; go get the info
                cmp.d       eax,0x80000001          ; can we call the function?
                jnb         .ExtFuncOK              ; if so, We can use  extended functions

                mov.d       esi,noFuncMsg           ; set the message
                jmp         dieMsg                  ; jump to common point to display the msg

;----------------------------------------------------------------------------------------------
; Finally, we can actually query the CPU if it support long mode
;----------------------------------------------------------------------------------------------

.ExtFuncOK:
                mov.d       eax,0x80000001          ; need to know if long mode is supported
                cpuid
                test.d      edx,1<<29               ; bit 29 specifies long mode is supported
                jnz         .LongOK                 ; if so, we want to continue
                test.d      edx,1<<20               ; either bit could be set
                jnz         .LongOK                 ; if so, we want to continue

                mov.d       esi,noLongMsg           ; set the message
                jmp         dieMsg                  ; and fall through to display and die

;----------------------------------------------------------------------------------------------
; Now we KNOW that long mode is available.  Celebrate by putting a "D" on the screen
;----------------------------------------------------------------------------------------------

.LongOK:
                mov.w       [edi],(0x0f<<8)|'D'     ; put an "D" on the screen
                add.d       edi,2                   ; move to the next pos onthe screen

;----------------------------------------------------------------------------------------------
; Set the flags needed to enter long mode, taking care of #2 above
;----------------------------------------------------------------------------------------------

                mov.d       eax,cr4                 ; get the CR4 control register
                or.d        eax,1<<5                ; set PAE in CR4
                mov.d       cr4,eax                 ; and save it back in the CR4 reg

                call        PagingInit              ; initialize the paging tables, & set CR3

                mov.d       ecx,0xc0000080          ; we want the EFER MSR
                rdmsr                               ; get the model specific register
                or.d        eax,1<<8                ; Set the LM bit for long mode
                wrmsr                               ; and put the result back

;----------------------------------------------------------------------------------------------
; Enable paging
;----------------------------------------------------------------------------------------------

                mov.d       ecx,cr0
                or.d        ecx,1<<31               ; set PG in CR0 to enable paging
                mov.d       cr0,ecx

;----------------------------------------------------------------------------------------------
; Now we we have turned on paging.  If we are able to execute the next line of code, then we
; will have been successful in getting paging properly set up.  We will check by putting an
; "E" on the screen.
;----------------------------------------------------------------------------------------------

                mov.w       [edi],(0x0f<<8)|'E'     ; put an "E" on the screen
                add.d       edi,2                   ; move to the next pos on the screen

;----------------------------------------------------------------------------------------------
; Now, all we have to do to get into long mode is replace the GDT with a 64-bit version and
; jump to 64-bit code.
;----------------------------------------------------------------------------------------------

                mov.d       eax,gdtr64              ; get the address of the temp 64-bit GDT
                lgdt        [eax]                   ; Load our own GDT
                jmp         0x08:gdt64enable        ; and jump into 64-bit code space

;----------------------------------------------------------------------------------------------
; Error messages if we are not able to enter long mode
;----------------------------------------------------------------------------------------------

dieMsg:                                             ; we have a msg to display...  display it
                mov.d       edi,0xb8000             ; start in the upper left corner.

.loop:
                mov.b       ah,0x0f
                mov.b       al,[esi]                ; get the next (attr<<8|char) to display
                cmp.b       al,0                    ; is it 0?
                je          .dieNow                 ; if so, we reach the end of the string
                mov.w       [edi],ax                ; now, display the attr/char combo
                add.d       edi,2                   ; move to the next screen pos
                inc         esi                     ; move to the next char to display
                jmp         .loop


.dieNow:        hlt
                jmp         .dieNow


;**********************************************************************************************
;**********************************************************************************************
;**********************************************************************************************
;******************************  64-bit code follows from here...  ****************************
;**********************************************************************************************
;**********************************************************************************************
;**********************************************************************************************

                section     .boot2
                bits        64
                align       8

gdt64enable:
                mov.q       rax,0x10                ; set the segment selector for DS
                mov.w       ds,ax
                mov.w       es,ax
                mov.w       fs,ax
                mov.w       gs,ax
                mov.w       ss,ax
                mov.q       rsp,rsp                 ; keep the same stack

;----------------------------------------------------------------------------------------------
; go and find the multiboot signature
;----------------------------------------------------------------------------------------------

                mov.q       rax,CheckMB             ; this must be a far call!!!
                call        rax                     ; get MB info and map free memory

;----------------------------------------------------------------------------------------------
; At this point, we have now entered 64-bit code.  Our GDT is sill sitting in the space we
; want to reclaim later and we are not yet running in higher-half code.  But, at least we are
; in a 64-bit world.  Celebrate by putting an "F" on the screen.
;----------------------------------------------------------------------------------------------

                mov.w       [edi],(0x0f<<8)|'F'     ; put an "F" on the screen
                add.d       edi,2                   ; move to the next pos on the screen

;----------------------------------------------------------------------------------------------
; Now we can jump to the higher half
;----------------------------------------------------------------------------------------------

                mov.q       rax,StartHigherHalf     ; get the address of our higher-half entry
                jmp         rax                     ; and jump to it

;==============================================================================================
; The .text section is the 64-bit kernel proper
;==============================================================================================

                section     .text
                bits        64

StartHigherHalf:
                mov.q       rbx,0xb8000+12
                mov.w       [rbx],0x0f<<8|'G'       ; put a "G" on the screen

;----------------------------------------------------------------------------------------------
; Print the banner text
;----------------------------------------------------------------------------------------------
%ifndef DISABLE_DBG_CONSOLE
                call        DbgConsoleInit
%endif

                call        TextSetNoCursor         ; make cursor go away
                call        TextClear               ; clear the screen

                mov.q       rbx,HelloString         ; get the hello string to print
                push        rbx                     ; and push it on the stack
                call        TextPutString           ; put it on the screen
                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; Init Memory Managers: Physical, Virtual, Heap
;----------------------------------------------------------------------------------------------

                call        PMMInit                 ; initialize the physical frames in PMM
                call        PMMInit2                ; if more than 32GB memory, we to complete
                call        HeapInit                ; initialize the heap
                call        VMMInit                 ; complete init of vmm & get a stack
                push        rax                     ; we need to save this stack for later

                call        GDTInit                 ; initialize the final GDT and TSSs
                call        IDTInit                 ; initialize the IDT

;----------------------------------------------------------------------------------------------
; we need to change the stack at the highest call level so we don't lose any return RIP values.
;----------------------------------------------------------------------------------------------

                pop         rax                     ; get the stack address back
                add.q       rax,STACK_SIZE          ; adjust to the top of the stack
                mov.q       rbx,0x10                ; set the stack selector
                mov.w       ss,bx                   ; set the ss reg
                mov.q       rsp,rax                 ; load the new stack pointer

;----------------------------------------------------------------------------------------------
; reclaim the memory we no longer need
;----------------------------------------------------------------------------------------------

                call        ReclaimMemory           ; reclaim any available memory

;----------------------------------------------------------------------------------------------
; Now, initialize the process structures and establish the idle process
;----------------------------------------------------------------------------------------------

                call        SpurInit                ; initialize the Spurious Interrupt Handler
                call        SchedulerInit           ; initialize the scheduler
                call        ProcessInit             ; initialize the current process

;----------------------------------------------------------------------------------------------
; Create the idle process, and maintain it's priority properly
;----------------------------------------------------------------------------------------------

                push        0                       ; 0 additional parameters
                mov.q       rax,idle                ; the starting address
                push        rax                     ; push it on the stack
                mov.q       rax,idleProc            ; the name of the process
                push        rax                     ; push it on the stack
                call        CreateProcess           ; create the running process
                add.q       rsp,24                  ; clean up the stack

                push        qword PTY_IDLE          ; we need to set the pty to idle
                push        rax                     ; the process we just created
                call        ProcessSetPty           ; go set the priority
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; Now for some testing....
;----------------------------------------------------------------------------------------------

.test:          sti

                push        0
                mov.q       rax,testProcA
                push        rax
                mov.q       rax,textProcA
                push        rax
                call        CreateProcess
                add.q       rsp,24


                push        0
                mov.q       rax,testProcB
                push        rax
                mov.q       rax,textProcB
                push        rax
                call        CreateProcess
                add.q       rsp,24

;----------------------------------------------------------------------------------------------
; Just die for now; more to come here
;----------------------------------------------------------------------------------------------

                mov.q       rax,currentProcess      ; get our own process structure var
                mov.q       rax,[rax]               ; now, get the process address
                push        qword PTY_IDLE          ; we need to downgrade to idle
                push        rax                     ; push our structure address
                call        ProcessSetPty           ; change the process priority
                add.q       rsp,16                  ; clean up the stack

.loop:          hlt
                jmp         .loop



testProcA:      push        'A'
.loop:          call        TextPutChar
                jmp         .loop

testProcB:      push        'B'
.loop:          call        TextPutChar
                jmp         .loop

;----------------------------------------------------------------------------------------------
; void idle(void) -- This process is the idle process and will only get CPU time when nothing
;                    else is available to run on the CPU.  It's implementation is rather
;                    trivial, as a busy loop.
;----------------------------------------------------------------------------------------------

idle:           jmp         idle

;==============================================================================================
; The .rodata segment will hold all data related to the kernel
;==============================================================================================

                section     .rodata

HelloString:
                db          'Welcome to Century-64, a 64-bit Hobby Operating System',13
                db          "  (it's gonna take a century to finish!)",13,13
                db          "---------- __o       __o       __o       __o",13
                db          "-------- _`\<,_    _`\<,_    _`\<,_    _`\<,_",13
                db          "------- (*)/ (*)  (*)/ (*)  (*)/ (*)  (*)/ (*)",13
                db          "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~",13
                db          "   ... speed is good!",13,13,
%ifndef DISABLE_DBG_CONSOLE
                db          "Debugging log enabled on COM1 (19200-8-N-1)"
%endif
                db          13,
                db          13,13,13,13,13,13,13,13
                db          "            Century-64  Copyright (C) 2014-2015  Adam Scott Clark",13,13
                db          "This program comes with ABSOLUTELY NO WARRANTY.  This is free software, and you",13
                db          "are welcome to redistribute it under certain conditions.  For more information,",13
                db          "see http://www.gnu.org/licenses/gpl-3.0-standalone.html",13,0

kHeapMsg:
                db          '                     This is a test kHeap error message',0

textProcA       db          'testProcA',0
textProcB       db          'testProcB',0
idleProc        db          'idle',0
