;==============================================================================================
;
; mbcheck.s
;
; This file contains the initial functions that will parse the multiboot structures and report
; and/or store the results.
;
; Currently, this is a 64-bit .text section of code, but might be better moved to a 64-bit
; .boot section of code since it will only get executed once.
;
; The following functions are provided in this source file:
;	void CheckMB(void);
;
; The following functions are internal functions not availeble publicly:
;	void LoadMB1Info(void);
;   void LoadMB2Info(void);
;	void LoadNonMBInfo(void);
;	void ReportResults(void);
;
;	void MB1GetMemLimits(register MBInfo *mbi);
;	void MB1GetBootDrive(register MBInfo *mbi);
;	void MB1GetCmdLine(register MBInfo *mbi);
;	void MB1GetMods(register MBInfo *mbi);
;	void MB1GetAOUT(register MBInfo *mbi); -- STUB
;	void MB1GetELF(register MBInfo *mbi); -- STUB
;	void MB1GetMMap(register MBInfo *mbi);
;	void MB1GetDrives(register MBInfo *mbi); -- STUB
;	void MB1GetConfig(register MBInfo *mbi); -- STUB
;	void MB1GetBootLoaderName(register MBInfo *mbi); -- STUB
;	void MB1GetAPMTable(register MBInfo *mbi); -- STUB
;	void MB1GetVBE(register MBInfo *mbi); --STUB
;
;    Date     Tracker  Pgmr  Description
; ----------  ------   ----  ------------------------------------------------------------------
; 2014/10/07  Initial  ADCL  Initial code
;
;==============================================================================================

%define		__MBCHECK_S__
%include	'private.inc'

MAGIC1 		equ			0x2badb002
MAGIC2		equ			0x36d76289

MBMAXMODS	equ			8
MOD_START	equ			0x00				; offset to the mod_start member
MOD_END		equ			0x04				; offset to the mod_end member
MOD_STRING	equ			0x08				; offset to teh mod_string member
MOD_SIZE	equ			0x10				; the size of an individual entry

MBMAXMMAP	equ			512					; the maximum number of bytes in the mmap

;==============================================================================================
; The .data section contains global variables
;==============================================================================================

			section		.data

bootMsg1 	db			'Determined that this kernel was booted by a ',0
bootMB1		db			'Multiboot 1 compliant boot loader',13,0
bootMB2		db			'Multiboot 2 compliant boot loader',13,0
bootNonMB	db			'non-compliant boot loader',13,0
mbBadAddr	db			'The multiboot information pointer is not valid; '
			db			'attempting a non-MB compliant setup',13,0

MMapError	db			'WARNING: the multiboot memory map exceeded the space allocated',13,0
NoMMap		db			'There is no Memory Map data found; assuming 4GB',13,0
mmapType	db			' of type ',0
mmapLen		db			' length ',0

mbiMemGood	db			0					; do we have good mbi.mem* info?
mbiMemLower	dd			0					; the mbi.mem_lower value
mbiMemUpper dd			0					; the mbi.mem_upper value

mbiBootDrvGood	db		0					; do we have good mbi.boot_device info?
mbiBootDevice	dd		0					; the mbi.boot_device value

mbiCmdLnGood	db		0					; do we have good mbi.cmdline info?
mbiCmdLine	dq			0					; the mbi.cmdline value

mbiModsGood	db			0					; do we have good mbi_mods* info
mbiModsCnt	dd			0					; the number of mods loaded (s/b <=MBMAXMODS)
mbiModsTbl	times (MBMAXMODS * 4)	dd	0	; this is the table for the modules

mbiAOUTGood	db			0					; do we have good a.out symbol info?
mbiAOUTTabSize	dd		0					; the mbi.aout_tabsize value
mbiAOUTStrSize	dd		0					; the mbi.aout_strsize value
mbiAOUTAddr	dd			0					; the mbi.aout_addr value

mbiELFGood	db			0					; do we have good elf symbol info?
mbiELFNum	dd			0					; the mbi.elf_num value
mbiELFsize	dd			0					; the mbi.elf_size value
mbiELFAddr	dd			0					; the mbi.elf_addr value
mbiELFShndx	dd			0					; the mbi.elf_shndx value

mbiMMapGood	db			0					; do we have a good memory map?
mbiMMapLen	dd			0					; size of the memory map
			dd			0					; this field is actually part of the next struct
mbiMMap		times(MBMAXMMAP)	dd	0		; the memory map table

mbiDrvsGood	db			0					; do we have good drives info?
mbiDrvLen	dd			0					; the mbi.drives_length value
mbiDrvAddr	dd			0					; the mbi.drived_addr value

mbiCfgGood	db			0					; do we have a good Config table?
mbiCfgTable	dd			0					; the mbi.config_table value

mbiLdrGood	db			0					; do we ahve a good boot loader name?
mbiLoaderName	dd		0					; the mbi.boot_loader_name value

mbiApmGood	db			0					; do we have good APM info?
mbiApmTable	dd			0					; the mbi.amp_table value

mbiVBEGood	db			0					; do we have good vbe info?
mbiVBECtrl	dd			0					; the mbi.vbe_control_info value
mbiVBEModeInfo	dd		0					; the mbi.vbe_mode_info value
mbiVBEMode	dw			0					; the mbi.vbe_mode value
mbiVBEIfcSeg	dw		0					; the mbi.vbe_interface_seg value
mbiVBEIfcOff	dw		0					; the mbi.vbe_interface_off value
mbiVBEIfcLen	dw		0					; the mbi.vbe_interface_len value

;==============================================================================================
; The .text section is the 64-bit kernel proper -- might change this section to be .boot.
;==============================================================================================

			section		.text
			bits		64

;----------------------------------------------------------------------------------------------
; void CheckMB(void) -- Check the multiboot magic number and determine if the kernel was booted
;                       with a compliant boot loader.  If so, branch to the proper function to
;                       load out internal structures.
;----------------------------------------------------------------------------------------------

			global		CheckMB

CheckMB:
			push		rbp								; create a frame
			mov			rbp,rsp
			push		rbx								; we will modify rbx

			mov			rbx,qword bootMsg1				; get the message prolog
			push		rbx								; and push it on the stack
			call		TextPutString					; display the message
			add			rsp,8							; clean up the stack

			xor			rax,rax							; clear rax
			mov			rbx,qword mbEAX					; get the affress of the var
			mov			eax,dword [rbx]					; get the value

			cmp			eax,MAGIC1						; multiboot 1?
			jne			.chk2							; if not check mb2

			mov			rbx,qword bootMB1				; get the message for MB1
			push		rbx								; and push it on the stack
			call		TextPutString					; display the message
			add			rsp,8							; clean up the stack

			call		LoadMB1Info						; call the function to get data

			jmp			.out							; we can skip the rest

.chk2:
			cmp			eax,MAGIC2						; multiboot 2?
			jne			.other							; if not, report another boot loader

			mov			rbx,qword bootMB2				; get the message for MB2
			push		rbx								; and push it on the stack
			call		TextPutString					; display the message
			add			rsp,8							; clean up the stack

			call		LoadMB2Info						; call the function to get data

			jmp			.out							; we can skip the rest

.other:
			mov			rbx,qword bootNonMB				; get the non-compliant boot loader msg
			push		rbx								; and push it on the stack
			call		TextPutString					; display the message
			add			rsp,8							; clean up the stack

			call		LoadNonMBInfo					; call the function to get data

.out:
			call		ReportResults					; print the results of our search...

			pop			rbx								; restore rbx
			pop			rbp								; restore caller's frame
			ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void LoadMB1Info(void) -- Read the MB1 data structures and load our data structures
;----------------------------------------------------------------------------------------------

LoadMB1Info:
			push		rbp								; create a frame
			mov			rbp,rsp
			push		rbx								; we will modify rbx

;----------------------------------------------------------------------------------------------
; First make sure we have a good address
;----------------------------------------------------------------------------------------------

			xor			rax,rax							; clear rax
			mov			rbx,qword mbEBX					; get the information address
			mov			eax,dword [rbx]					; rax now should have the hdr address

			cmp			rax,0							; is the address a good one?
			jne			.goodAddr						; if not 0, assume good

			mov			rbx,qword mbBadAddr				; load the address of the error msg
			push		rbx								; and put it on the stack
			call		TextPutString					; print the error msg
			add			rsp,8							; clean up

			call		LoadNonMBInfo					; try to see what info we can get
			jmp			.out

;----------------------------------------------------------------------------------------------
; Start by getting the flags to see what might be good; print the meta information
;----------------------------------------------------------------------------------------------

.goodAddr:

			mov			rbx,rax							; move the address to the rbx reg
			xor			rax,rax							; clear rax
			mov			eax,dword [rbx]					; get the flags

;----------------------------------------------------------------------------------------------
; At this point, rax holds the flags and rbx holds the address of the info struct
;
; test flag 11
;----------------------------------------------------------------------------------------------

.flag11:	push		rax								; save our flags
			test		rax,1<<11						; test the bit
			jz			.NoF11							; jump if no
			call		MB1GetVBE						; get the VBE Information
.NoF11:		pop			rax								; restore the flags

;----------------------------------------------------------------------------------------------
; test flag 10
;----------------------------------------------------------------------------------------------

.flag10:	push		rax								; save our flags
			test		rax,1<<10						; test the bit
			jz			.NoF10							; jump if no
			call		MB1GetAPMTable					; get the APM Table
.NoF10:		pop			rax								; restore the flags

;----------------------------------------------------------------------------------------------
; test flag 9
;----------------------------------------------------------------------------------------------

.flag09:	push		rax								; save our flags
			test		eax,1<<9						; test the bit
			jz			.NoF09							; jump if No
			call		MB1GetBootLoaderName			; get the boot loader name
.NoF09:		pop			rax								; restore the flags

;----------------------------------------------------------------------------------------------
; test flag 8
;----------------------------------------------------------------------------------------------

.flag08:	push		rax								; save our flags
			test		eax,1<<8						; test the bit
			jz			.NoF08							; jump if no
			call		MB1GetConfig					; get the BIOS Config Table
.NoF08:		pop			rax								; restore the flags

;----------------------------------------------------------------------------------------------
; test flag 7
;----------------------------------------------------------------------------------------------

.flag07:	push		rax								; save our flags
			test		eax,1<<7						; test the bit
			jz			.NoF07							; jump if no
			call		MB1GetDrives					; get the system drives
.NoF07:		pop			rax								; restore the flags

;----------------------------------------------------------------------------------------------
; test flag 6
;----------------------------------------------------------------------------------------------

.flag06:	push		rax								; save our flags
			test		eax,1<<6						; test the bit
			jz			.NoF06							; jump if no
			call		MB1GetMMap						; get the memory map
.NoF06		pop			rax								; restore the flags

;----------------------------------------------------------------------------------------------
; test flag 5
;----------------------------------------------------------------------------------------------

.flag05:	push		rax								; save our flags
			test		eax,1<<5						; test the bit
			jz			.NoF05							; jump if no
			call		MB1GetELF						; get the elf symbols
.NoF05		pop			rax								; restore the flags

;----------------------------------------------------------------------------------------------
; test flag 4
;----------------------------------------------------------------------------------------------

.flag04:	push		rax								; save our flags
			test		eax,1<<4						; test the bit
			jz			.NoF04							; jump if no
			call		MB1GetAOUT						; get the a.out symbols
.NoF04:		pop			rax								; restore the flags

;----------------------------------------------------------------------------------------------
; test flag 3
;----------------------------------------------------------------------------------------------

.flag03:	push		rax								; save our flags
			test		eax,1<<3						; test the bit
			jz			.NoF03							; jump if no
			call		MB1GetMods						; get the modules loaded
.NoF03		pop			rax								; restore the flags

;----------------------------------------------------------------------------------------------
; test flag 2
;----------------------------------------------------------------------------------------------

.flag02:	push		rax								; save flags
			test		eax,1<<2						; test the bit
			jz			.NoF02							; jump if no
			call		MB1GetCmdLine					; go get the command line
.NoF02:		pop			rax								; restore the flags

;----------------------------------------------------------------------------------------------
; test flag 1
;----------------------------------------------------------------------------------------------

.flag01:	push		rax								; save our flags
			test		eax,1<<1						; test the bit
			jz			.NoF01							; jump if no
			call		MB1GetBootDrive					; go get the boot device
.NoF01:		pop			rax								; restore the flags

;----------------------------------------------------------------------------------------------
; test flag 0
;----------------------------------------------------------------------------------------------

.flag00:	push		rax
			test		eax,1<<0						; test the bit
			jz			.NoF00							; jump if no
			call		MB1GetMemLimits					; go get the memory limits
.NoF00:		pop			rax								; restore the flags

;----------------------------------------------------------------------------------------------
; End the line
;----------------------------------------------------------------------------------------------

.out:
			pop			rbx								; restore rbx
			pop			rbp								; restore caller's frame
			ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void LoadMB2Info(void) -- Read the MB2 data structures and load our data structures
;----------------------------------------------------------------------------------------------

LoadMB2Info:
			push		rbp								; create a frame
			mov			rbp,rsp
			push		rbx								; we will modify rbx

			pop			rbx								; restore rbx
			pop			rbp								; restore caller's frame
			ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void LoadNonMBInfo(void) -- Do the best we can to figure out what data we have and load out
;                             data structures
;----------------------------------------------------------------------------------------------

LoadNonMBInfo:
			push		rbp								; create a frame
			mov			rbp,rsp
			push		rbx								; we will modify rbx

			pop			rbx								; restore rbx
			pop			rbp								; restore caller's frame
			ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void MB1GetMemLimits(register MBInfo *mbi) -- read and store the memory limits info.  RBX
;                                               contains the address of the mbi struct on
;                                               entry
;----------------------------------------------------------------------------------------------

MB1GetMemLimits:
			push		rbp								; create a frame
			mov			rbp,rsp
			push		rbx								; we will modify rbx

			xor			rax,rax							; clear rax
			mov			eax,dword [rbx+4]				; get the mem_lower value
			mov			rsi,qword mbiMemLower			; get the address of the var
			mov			dword [rsi],eax					; save the value

			xor			rax,rax							; clear rax
			mov			eax,dword [rbx+8]				; get the mem_lower value
			mov			rsi,qword mbiMemUpper			; get the address of the var
			mov			dword [rsi],eax					; save the value

			mov			rsi,qword mbiMemGood			; get the address of the var
			add			byte [rsi],1					; mark the data as good

			pop			rbx								; restore rbx
			pop			rbp								; restore caller's frame
			ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void void MB1GetBootDrive(register MBInfo *mbi) -- read the boot drive.  RBX contains the
;                                                    address of the mbi struct on entry
;----------------------------------------------------------------------------------------------

MB1GetBootDrive:
			push		rbp								; create a frame
			mov			rbp,rsp
			push		rbx								; we will modify rbx

			xor			rax,rax							; clear rax
			mov			eax,dword [rbx+12]				; get the mem_lower value
			mov			rsi,qword mbiBootDevice			; get the address of the var
			mov			dword [rsi],eax					; save the value

			mov			rsi,qword mbiBootDrvGood		; get the address of the var
			add			byte [rsi],1					; mark the data as good

			pop			rbx								; restore rbx
			pop			rbp								; restore caller's frame
			ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void MB1GetCmdLine(register MBInfo *mbi) -- read the kernel command line.  RBX contains the
;                                             address of the mbi struct on entry
;----------------------------------------------------------------------------------------------

MB1GetCmdLine:
			push		rbp								; create a frame
			mov			rbp,rsp
			push		rbx								; we will modify rbx

			xor			rax,rax							; clear rax
			mov			eax,dword [rbx+16]				; get the mem_lower value
			mov			rsi,qword mbiCmdLine			; get the address of the var
			mov			qword [rsi],rax					; save the value

			mov			rsi,qword mbiCmdLnGood			; get the address of the var
			add			byte [rsi],1					; mark the data as good

			pop			rbx								; restore rbx
			pop			rbp								; restore caller's frame
			ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void MB1GetMods(register MBInfo *mbi) -- retrieve the info about loaded modules.  RBX
;                                          contains the address of the mbi struct on entry
;----------------------------------------------------------------------------------------------

MB1GetMods:
			push		rbp								; create a frame
			mov			rbp,rsp
			push		rbx								; we will modify rbx

			xor			rax,rax							; clear rax
			mov			eax,dword [rbx+20]				; get the mem_lower value
			mov			rsi,qword mbiModsCnt			; get the address of the var
			mov			dword [rsi],eax					; save the value
			mov			rcx,rax							; save this number in the counter also

			cmp			rcx,0							; fo we have no modules?
			je			.none							; if none, jump
			cmp			rcx,MBMAXMODS					; do we have too many loaded modules
			ja			.tooMany						; if so we have too many

			mov			rsi,qword mbiModsGood			; get the address of the var
			add			byte [rsi],1					; mark the data as good
			jmp			.loadTbl						; go load the table

.tooMany:
			mov			rsi,qword mbiModsGood			; get the address of the var
			sub			byte [rsi],1					; mark the data that we have too many
			mov			rcx,MBMAXMODS					; set the limit; we just suffer

.loadTbl:
			shl			rcx,2							; each entry has 4 elements 2^2 = 4
			xor			rax,rax							; clear rax
			mov			eax,dword [rbx+24]				; get the address
			mov			rsi,rax							; and we get the start of the address

			mov			rdi,qword mbiModsTbl			; get the address of the table
			cld											; make sure we increment
			rep			movsd							; copy the data

.none:
			pop			rbx								; restore rbx
			pop			rbp								; restore caller's frame
			ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void MB1GetAOUT(register MBInfo *mbi) -- retrieve the info about a.out symbols table.  RBX
;                                          contains the address of the mbi struct on entry
;
;                                          This function is a stub
;----------------------------------------------------------------------------------------------

MB1GetAOUT:
			push		rbp								; create a frame
			mov			rbp,rsp
			push		rbx								; we will modify rbx


			pop			rbx								; restore rbx
			pop			rbp								; restore caller's frame
			ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void MB1GetELF(register MBInfo *mbi) -- retrieve the info about the elf symbol table.  RBX
;                                         contains the address of the mbi struct on entry
;
;                                          This function is a stub
;----------------------------------------------------------------------------------------------

MB1GetELF:
			push		rbp								; create a frame
			mov			rbp,rsp
			push		rbx								; we will modify rbx


			pop			rbx								; restore rbx
			pop			rbp								; restore caller's frame
			ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void MB1GetMMap(register MBInfo *mbi) -- retrieve the info about the memory map.  RBX
;                                          contains the address of the mbi struct on entry
;----------------------------------------------------------------------------------------------

MB1GetMMap:
			push		rbp								; create a frame
			mov			rbp,rsp
			push		rbx								; we will modify rbx

			xor			rax,rax							; clear rax
			mov			eax,dword [rbx+44]				; get the mmap length
			mov			rsi,qword mbiMMapLen			; get the address of the var
			mov			dword [rsi],eax					; save the value

			mov			rcx,rax
			cmp			rcx,0							; is the length 0?
			je			.none

			cmp			rcx,MBMAXMMAP					; if the length > MBMAXMMAP?
			ja			.tooLong						; jump if so

			mov			rsi,qword mbiMMapGood			; get the address of the var
			add			byte [rsi],1					; mark the data as good
			jmp			.loadTable						; otherwise go load the table

.tooLong:
			mov			rcx,MBMAXMMAP					; srtifically set the length
			mov			rsi,qword mbiMMapGood			; get the address of the var
			sub			byte [rsi],1					; mark the data as incomplete

.loadTable:
			xor			rax,rax							; clear rax
			mov			eax,dword [rbx+48]				; get the address
			mov			rsi,rax							; and we get the start of the address
;			sub			rsi,4							; backup to allow for the size field

			mov			rdi,qword mbiMMap				; get the address of the table
;			sub			rdi,4							; backup to allow for the size field
			cld											; make sure we increment
			rep			movsd							; copy the data

.none:
			pop			rbx								; restore rbx
			pop			rbp								; restore caller's frame
			ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void MB1GetDrives(register MBInfo *mbi) -- retrieve the info about system drives.  RBX
;                                            contains the address of the mbi struct on entry
;
;                                            This function is a stub
;----------------------------------------------------------------------------------------------

MB1GetDrives:
			push		rbp								; create a frame
			mov			rbp,rsp
			push		rbx								; we will modify rbx


			pop			rbx								; restore rbx
			pop			rbp								; restore caller's frame
			ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void MB1GetConfig(register MBInfo *mbi) -- retrieve the info about the BIOS config table.
;                                            RBX contains the address of the mbi struct on
;                                            entry
;
;                                            This function is a stub
;----------------------------------------------------------------------------------------------

MB1GetConfig:
			push		rbp								; create a frame
			mov			rbp,rsp
			push		rbx								; we will modify rbx


			pop			rbx								; restore rbx
			pop			rbp								; restore caller's frame
			ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void MB1GetBootLoaderName(register MBInfo *mbi) -- retrieve the boot loader name.  RBX
;                                                    contains the address of the mbi struct on
;                                                    entry
;
;                                                    This function is a stub
;----------------------------------------------------------------------------------------------

MB1GetBootLoaderName:
			push		rbp								; create a frame
			mov			rbp,rsp
			push		rbx								; we will modify rbx


			pop			rbx								; restore rbx
			pop			rbp								; restore caller's frame
			ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void MB1GetAPMTable(register MBInfo *mbi) -- retrieve the info about APM.  RBX contains the
;                                              address of the mbi struct on entry
;
;                                              This function is a stub
;----------------------------------------------------------------------------------------------

MB1GetAPMTable:
			push		rbp								; create a frame
			mov			rbp,rsp
			push		rbx								; we will modify rbx


			pop			rbx								; restore rbx
			pop			rbp								; restore caller's frame
			ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void MB1GetVBE(register MBInfo *mbi) -- retrieve the info about VBE.  RBX contains the
;                                         address of the mbi struct on entry
;
;                                         This function is a stub
;----------------------------------------------------------------------------------------------

MB1GetVBE:
			push		rbp								; create a frame
			mov			rbp,rsp
			push		rbx								; we will modify rbx


			pop			rbx								; restore rbx
			pop			rbp								; restore caller's frame
			ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void ReportResults(void) -- Report the results of scanning the Multiboot information to the
;                             screen.
;----------------------------------------------------------------------------------------------

ReportResults:
			push		rbp								; create a frame
			mov			rbp,rsp
			push		rbx								; we will modify rbx

			mov			rbx,qword mbiMMapGood			; get the address of the variable
			xor			rax,rax							; clear
			mov			al,byte [rbx]					; get the variable
			cmp			al,0x00							; do we even have a good map?
			je			.noMMap							; if not, exit
			cmp			al,0xff							; do we have a memory limit problem?
			jne			.print							; if we are good, go print

			push		qword 0x0c						; we want red on black
			call		TextSetAttr						; Set the attribute

			mov			rbx,qword MMapError				; get the address of hte string
			push		rbx								; push it on the stack
			call 		TextPutString					; print the error
			add			rsp,8							; clean up the stack

			mov			qword [rsp],0x0f				; set back to normal attr
			call		TextSetAttr						; set the attrubite
			add			rsp,8							; clean the stack

.print:
			mov			rsi,qword mbiMMap				; get the start of the table
			xor			rcx,rcx							; clear out a byte counter

			mov			rbx,qword mbiMMapLen			; get the table length field
			xor			rdx,rdx							; clear rdx
			mov			edx,dword [rbx]					; get the table length

.loop:
			cmp			rcx,rdx							; compare the 2 lengths
			jae			.loopOut						; is we have exhausted all our data

;----------------------------------------------------------------------------------------------
; set/reset out pointer
;----------------------------------------------------------------------------------------------

			mov			rdi,qword [rsi+4]					; get the base address

;----------------------------------------------------------------------------------------------
; Get the base address and write it to the screen (with the hyphen)
;----------------------------------------------------------------------------------------------

			push		rsi								; this time we need to save a bunch
			push		rbx
			push		rcx
			push		rdx

			push		rdi								; push the hex number
			call		TextPutHexQWord					; write the qword

			mov			rdi,qword mmapLen
			mov			qword [rsp],rdi					; put the hyphen out
			call		TextPutString					; and write it
			add			rsp,8							; clean up the parm

			pop			rdx								; get out values back
			pop			rcx
			pop			rbx
			pop			rsi

;----------------------------------------------------------------------------------------------
; Get the length and write it to the screen (with the " of type " string)
;----------------------------------------------------------------------------------------------

			mov			rdi,qword [rsi+12]				; get the length

			push		rsi								; this time we need to save a bunch
			push		rbx
			push		rcx
			push		rdx

			push		rdi								; push the hex number
			call		TextPutHexQWord					; write the qword

			mov			rbx,qword mmapType				; get the string
			mov			qword [rsp],rbx					; replace it on the stack
			call		TextPutString					; write the string
			add			rsp,8							; clean up the parm

			pop			rdx								; get out values back
			pop			rcx
			pop			rbx
			pop			rsi

;----------------------------------------------------------------------------------------------
; Finally, get the type and write it to the screen (with the <CR>)
;----------------------------------------------------------------------------------------------

			xor			rdi,rdi							; clear rdi
			mov			edi,dword [rsi+20]				; get the type

			push		rsi								; this time we need to save a bunch
			push		rbx
			push		rcx
			push		rdx

			push		rdi								; push the hex number
			call		TextPutHexByte					; mask it down to a byte

			mov			qword [rsp],13					; put a <CR>
			call		TextPutChar						; and write it
			add			rsp,8							; clean up stack

			pop			rdx								; get out values back
			pop			rcx
			pop			rbx
			pop			rsi

;----------------------------------------------------------------------------------------------
; Now, increment our size position and loop
;----------------------------------------------------------------------------------------------

			xor			rax,rax							; clear rax
			mov			eax,dword [rsi]					; get the block size
			add			rax,4							; need to sdjust for the size
			add			rcx,rax							; add the number of bytes
			add			rsi,rax							; move to the next block
			jmp			.loop							; and loop


.loopOut:
			push		qword 13						; push a <CR>
			call		TextPutChar						; and write it
			add			rsp,8							; clean up the stack

			jmp			.out							; leave the subroutine

.noMMap:
			push		qword 0x0c						; we want red on black
			call		TextSetAttr						; Set the attribute

			mov			rbx,qword NoMMap				; get the address of hte string
			push		rbx								; push it on the stack
			call 		TextPutString					; print the error
			add			rsp,8							; clean up the stack

			mov			qword [rsp],0x0f				; set back to normal attr
			call		TextSetAttr						; set the attrubite
			add			rsp,8							; clean the stack

.out:
			pop			rbx								; restore rbx
			pop			rbp								; restore caller's frame
			ret

;==============================================================================================

