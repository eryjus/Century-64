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

%define         add.b       add byte
%define         add.w       add word
%define         add.d       add dword
%define         add.q       add qword

%define         and.b       and byte
%define         and.w       and word
%define         and.d       and dword
%define         and.q       and qword

%define         cmp.b       cmp byte
%define         cmp.w       cmp word
%define         cmp.d       cmp dword
%define         cmp.q       cmp qword

%define         lea.b       lea byte
%define         lea.w       lea word
%define         lea.d       lea dword
%define         lea.q       lea qword

%define         mov.b       mov byte
%define         mov.w       mov word
%define         mov.d       mov dword
%define         mov.q       mov qword

%define         not.b       not byte
%define         not.w       not word
%define         not.d       not dword
%define         not.q       not qword

%define         or.b        or byte
%define         or.w        or word
%define         or.d        or dword
%define         or.q        or qword

%define         shl.b       shl byte
%define         shl.w       shl word
%define         shl.d       shl dword
%define         shl.q       shl qword

%define         shr.b       shr byte
%define         shr.w       shr word
%define         shr.d       shr dword
%define         shr.q       shr qword

%define         sub.b       sub byte
%define         sub.w       sub word
%define         sub.d       sub dword
%define         sub.q       sub qword

%define         test.q      test byte
%define         test.w      test word
%define         test.d      test dword
%define         test.q      test qword

%define         xor.b       xor byte
%define         xor.w       xor word
%define         xor.d       xor dword
%define         xor.q       xor qword

%define         BREAK       xchg bx,bx


;----------------------------------------------------------------------------------------------
; -- the following symbols are added by the linker
;----------------------------------------------------------------------------------------------

                extern      bootStart
                extern      bootClear
                extern      bootEnd
                extern      bssEnd
                extern      kernelStart
                extern      kernelEnd

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in loader.s
;----------------------------------------------------------------------------------------------

VIRT_BASE       equ         0xffffffff80000000

STACK_LOC       equ         0xfffff00200000000
STACK_SIZE      equ         0x0000000000004000              ; 16K

%ifndef __LOADER_S__
                extern      mbEAX
                extern      mbEBX
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in pagetables.s
;----------------------------------------------------------------------------------------------

%ifndef __PAGETABLES_S__
                extern      PagingInit
                extern      PML4Table
                extern      PDPT
                extern      PD
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in text.s
;----------------------------------------------------------------------------------------------

%ifndef __TEXT_S__
                extern      TextClear
                extern      TextPutHexByte
                extern      TextPutHexWord
                extern      TextPutHexDWord
                extern      TextPutHexQWord
                extern      TextPutChar
                extern      TextPutString
                extern      TextSetAttr
                extern      TextSetBlockCursor
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in mbcheck.s
;----------------------------------------------------------------------------------------------

struc FreeMem
    .str        resq        1                       ; starting address of the block
    .size       resq        1                       ; ending address of the block (not length)
    .addr       resd        1                       ; the address of the current entry
    .len        resd        1                       ; the remaining length of the mmap
endstruc

%ifndef __MBCHECK_S__
                extern      CheckMB
                extern      GetMemLimit
                extern      GetFreeFirst
                extern      GetFreeNext
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in physmm.s
;----------------------------------------------------------------------------------------------

%ifndef __PHYSMM_S__
                extern      PMMInit
                extern      PMMInit2
                extern      MarkBlockFree
                extern      MarkBlockUsed
                extern      AllocFrame
                extern      AllocFrameLimit
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in kheap.s
;----------------------------------------------------------------------------------------------

%ifndef __KHEAP_S__
                extern      HeapInit
                extern      kmalloc
                extern      kfree
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in virtmm.s
;----------------------------------------------------------------------------------------------

VMM_SUCCESS     equ         0x0000000000000000
VMM_WARN_ALIGN  equ         0x0000000000000001
VMM_WARN_MAPPED equ         0x0000000000000002
VMM_ERR_NOMEM   equ         0xffffffffffffffff

%ifndef __VIRTMM_S__
                extern      VMMInit
                extern      VMMAlloc
                extern      VMMFree
%endif
