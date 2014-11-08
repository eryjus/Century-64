;==============================================================================================
;
; private.inc
;
; This file contains the external symbols that are used in all modules throughout this system.
;
;    Date     Tracker  Pgmr  Description
; ----------  ------   ----  ------------------------------------------------------------------
; 2014/10/06  Initial  ADCL  Initial version
;
;==============================================================================================

;----------------------------------------------------------------------------------------------
; -- the following macros are to make coding simpler
;----------------------------------------------------------------------------------------------

%define			add.b		add byte
%define			add.w		add word
%define			add.d		add dword
%define			add.q		add qword

%define			and.b		and byte
%define			and.w		and word
%define			and.d		and dword
%define			and.q		and qword

%define			cmp.b		cmp byte
%define			cmp.w		cmp word
%define			cmp.d		cmp dword
%define			cmp.q		cmp qword

%define			lea.b		lea byte
%define			lea.w		lea word
%define			lea.d		lea dword
%define			lea.q		lea qword

%define			mov.b		mov byte
%define			mov.w		mov word
%define			mov.d		mov dword
%define			mov.q		mov qword

%define			sub.b		sub byte
%define			sub.w		sub word
%define			sub.d		sub dword
%define			sub.q		sub qword

%define			test.q		test byte
%define			test.w		test word
%define			test.d		test dword
%define			test.q		test qword

%define			xor.b		xor byte
%define			xor.w		xor word
%define			xor.d		xor dword
%define			xor.q		xor qword

;----------------------------------------------------------------------------------------------
; -- the following symbols are added by the linker
;----------------------------------------------------------------------------------------------

				extern		bootStart
				extern		bootClear
				extern		bootEnd
				extern		bssEnd
				extern		kernelStart

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in loader.s
;----------------------------------------------------------------------------------------------

VIRT_BASE		equ			0xffffffff80000000

%ifndef	__LOADER_S__
				extern		mbEAX
				extern		mbEBX
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in pagetables.s
;----------------------------------------------------------------------------------------------

%ifndef	__PAGETABLES_S__
				extern		PML4Table
				extern		PDPT
				extern 		PD
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in text.s
;----------------------------------------------------------------------------------------------

%ifndef	__TEXT_S__
				extern		TextClear
				extern		TextPutHexByte
				extern		TextPutHexWord
				extern		TextPutHexDWord
				extern		TextPutHexQWord
				extern		TextPutChar
				extern		TextPutString
				extern		TextSetAttr
				extern		TextSetBlockCursor
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in mbcheck.s
;----------------------------------------------------------------------------------------------

%ifndef	__MBCHECK_S__
				extern		CheckMB
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in physmm.s
;----------------------------------------------------------------------------------------------

%ifndef	__PHYSMM_S__
				extern		PMMInit
				extern		PMMMarkBlockFree
				extern		PMMMarkBlockUsed
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in virtmm.s
;----------------------------------------------------------------------------------------------

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in kheap.s
;----------------------------------------------------------------------------------------------

%ifndef	__KHEAP_S__
				extern		HeapInit
				extern		kmalloc
				extern		kfree
%endif

;----------------------------------------------------------------------------------------------
; These flags are used to identify the type of page in the paging tables.  These flags are
; located at bits 11:9, so each of these flags needs to be adjusted (. & 0x7) << 9 to write to
; the page table entry and then (. >> 9) & 0x7 when read from the page table entry.
;----------------------------------------------------------------------------------------------
VMM_NORMAL		equ			0x0
VMM_SHARED		equ			0x1

VMM_SUCCESS		equ			0x00000000		; no errors; no warnings
VMM_WARN_ALIGN	equ			0x00000001		; the address is not page-aligned; aligned it
VMM_WARN_SHARED	equ			0x00000002		; the address belongs to shared memory
VMM_ERR_NOMAP	equ			0xffffffff		; the address is not mapped

%ifndef	__VIRTMM_S__
				extern		VMMInit
				extern		VMMUnmapPage
%endif
