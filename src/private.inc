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
; -- the following symbols are found in loader.s
;----------------------------------------------------------------------------------------------

%ifndef	__LOADER_S__
			extern		mbEAX
			extern		mbEBX
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in pagetables.s
;----------------------------------------------------------------------------------------------

%ifndef	__PAGETABLES_S__
			extern		PML4Table
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
%endif

;----------------------------------------------------------------------------------------------
; -- the following symbols are found in mbcheck.s
;----------------------------------------------------------------------------------------------

%ifndef	__MBCHECK_S__
			extern		CheckMB
%endif
