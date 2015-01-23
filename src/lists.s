;==============================================================================================
;
; lists.s
;
; This file contains the functions and structures needed to manage a list.  A list of what
; is not really important.
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
; The inspiration for this list structure and imlpementation is taken from the Linux list
; implementation.  References can be found in the _Linux_Kernel_Development_ book, chapter 6
; and the linux source file at:
; http://www.cs.fsu.edu/~baker/devices/lxr/http/source/linux/include/linux/list.h
;
; In short, the lists are implemented as a doubly linked circular list.
;
; The following functions are published in this source:
;   void ListAddHead(qword newListAddr, qword listHead);
;   void ListAddTail(qword newListAddr, qword listHead);
;   void ListDel(qword listEntry);
;   void ListDelInit(qword listEntry);
;   qword ListNext(qword listHead);
;   qword ListEmpty(qword listHead);
;
; The following functions are internal to the source file:
;   void __list_add(qword newListAddr, qword pListAddr, qword nListAddr);
;   void __list_del(qword pListAddr, qword nListAddr);
;
;    Date     Tracker  Pgmr  Description
; ----------  -------  ----  ------------------------------------------------------------------
; 2014/11/07  Initial  ADCL  Initial version
;
;==============================================================================================

%define     __LISTS_S__
%include    'private.inc'

;==============================================================================================
; This is the code section of the source file.  It will be part of the kernel.
;==============================================================================================

                section     .text
                bits        64

;----------------------------------------------------------------------------------------------
; void __list_add(qword newListAddr, qword pListAddr, qword nListAddr) --
;                                               Insert a list item between 2 known list items.
;                                               This is an internal working function and
;                                               will never be called from outside this module.
;
; This function requires that pListAddr.next == nListAddr and that nListAddr.prev == pListAddr.
; So we will add these as sanity checks and will report the discremancies to the screen.
; however, for the moment, we will not kill the kernel.  I figure it will die soon enough.
;----------------------------------------------------------------------------------------------

__list_add:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx
                push        rsi                     ; save rsi
                push        rdi                     ; save rdi

;----------------------------------------------------------------------------------------------
; first, get the parameters into working registers.
;----------------------------------------------------------------------------------------------

                mov.q       rsi,[rbp+24]            ; get pListAddr
                mov.q       rdi,[rbp+32]            ; get nListAddr
                mov.q       rbx,[rbp+16]            ; get newListAddr

;----------------------------------------------------------------------------------------------
; now the sanity checks
; 1) is nListAddr.prev == pListAddr?
;----------------------------------------------------------------------------------------------

                cmp.q       rsi,[rdi+List.prev]     ; are they the same?
                je          .chk2                   ; if they are, go to the next check

                sub.q       rsp,8                   ; make room on the stack for 1 parm
                mov.q       [rsp],0x0c              ; set the error color
                call        TextSetAttr             ; set the attribute

                mov.q       rax,Err1a               ; get the start of the error message
                mov.q       [rsp],rax               ; and put it on the stack
                call        TextPutString           ; write the string to the screen

                mov.q       [rsp],rsi               ; get the prev address
                call        TextPutHexQWord         ; write the address to the screen

                mov.q       rax,Errb                ; get the next part of the error message
                mov.q       [rsp],rax               ; and put it on the stack
                call        TextPutString           ; write the string to the screen

                mov.q       rax,[rdi+List.prev]     ; get the address in nListAddr.prev
                mov.q       [rsp],rax               ; set the address on the stack
                call        TextPutHexQWord         ; write the address to the screen

                mov.q       rax,Err1c               ; get the next part of the error message
                mov.q       [rsp],rax               ; and put it on the stack
                call        TextPutString           ; write the string to the screen

                mov.q       [rsp],rdi               ; get the address of nListAddr
                call        TextPutHexQWord         ; write the address to the screen

                mov.q       rax,Errd                ; get the end of the error message
                mov.q       [rsp],rax               ; and put it on the stack
                call        TextPutString           ; write the string to the screen
                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; 2) is pListAddr.next == nListAddr?
;----------------------------------------------------------------------------------------------

.chk2:          cmp.q       rdi,[rsi+List.next]     ; are they the same?
                je          .good                   ; if they are, go to the add part

                sub.q       rsp,8                   ; make room on the stack for 1 parm
                mov.q       [rsp],0x0c              ; set the error color
                call        TextSetAttr             ; set the attribute

                mov.q       rax,Err2a               ; get the start of the error message
                mov.q       [rsp],rax               ; and put it on the stack
                call        TextPutString           ; write the string to the screen

                mov.q       [rsp],rdi               ; get the next address
                call        TextPutHexQWord         ; write the address to the screen

                mov.q       rax,Errb                ; get the next part of the error message
                mov.q       [rsp],rax               ; and put it on the stack
                call        TextPutString           ; write the string to the screen

                mov.q       rax,[rsi+List.next]     ; get the address in pListAddr.next
                mov.q       [rsp],rax               ; set the address on the stack
                call        TextPutHexQWord         ; write the address to the screen

                mov.q       rax,Err2c               ; get the next part of the error message
                mov.q       [rsp],rax               ; and put it on the stack
                call        TextPutString           ; write the string to the screen

                mov.q       [rsp],rsi               ; get the address of pListAddr
                call        TextPutHexQWord         ; write the address to the screen

                mov.q       rax,Errd                ; get the end of the error message
                mov.q       [rsp],rax               ; and put it on the stack
                call        TextPutString           ; write the string to the screen
                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; now we can do the work of adding the list entry
;----------------------------------------------------------------------------------------------

.good:          mov.q       [rdi+List.prev],rbx     ; nListAddr.prev = newListAddr
                mov.q       [rbx+List.next],rdi     ; newListAddr.next = nListAddr
                mov.q       [rbx+List.prev],rsi     ; newListAddr.prev = pListAddr
                mov.q       [rsi+List.next],rbx     ; pListAddr.next = newListAddr

;----------------------------------------------------------------------------------------------
; finally, clean up and exit
;----------------------------------------------------------------------------------------------

                pop         rdi                     ; restore rdi
                pop         rsi                     ; restore rsi
                pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void ListAddHead(qword newListAddr, qword listHead) -- This function will add an entry to the
;                                                        list right after the head.  This
;                                                        function is good for implementing
;                                                        stacks.
;----------------------------------------------------------------------------------------------

                global      ListAddHead

ListAddHead:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame

;----------------------------------------------------------------------------------------------
; call the worker function to do the heavy lifting
;----------------------------------------------------------------------------------------------

                mov.q       rax,[rbp+24]            ; get the listHead parm
                push        qword [rax+List.next]   ; push the next addr on the stack
                push        rax                     ; push the listHead on stack
                push        qword [rbp+16]          ; push the newListAddress on stack
                call        __list_add              ; call the worker function
                add.q       rsp,24                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void ListAddTail(qword newListAddr, qword listHead) -- This function will add an entry to the
;                                                        list right after the tail.  This
;                                                        function is good for implementing
;                                                        queues.
;----------------------------------------------------------------------------------------------

                global      ListAddTail

ListAddTail:
                push        rbp                     ; save the caller's frame
                mov.q       rbp,rsp                 ; create our own frame

;----------------------------------------------------------------------------------------------
; call the worker function to do the heavy lifting
;----------------------------------------------------------------------------------------------

                mov.q       rax,[rbp+24]            ; get the listHead parm
                push        rax                     ; push the listHead on stack
                push        qword [rax+List.prev]   ; push the prev addr on the stack
                push        qword [rbp+16]          ; push the newListAddress on stack
                call        __list_add              ; call the worker function
                add.q       rsp,24                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void __list_del(qword pListAddr, qword nListAddr) -- This is an internal worker function
;                                                      used to remove an entry from the list.
;                                                      This function is only to be used where
;                                                      we know the pListAddr and nListAddr
;                                                      are on either side of the entry to be
;                                                      removed AND we have a reference to that
;                                                      entry.
;----------------------------------------------------------------------------------------------

__list_del:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rsi                     ; save rsi
                push        rdi                     ; save rdi

;----------------------------------------------------------------------------------------------
; close the gap in the list around the entry
;----------------------------------------------------------------------------------------------

                mov.q       rsi,[rbp+16]            ; get the prevList pointer
                mov.q       rdi,[rbp+24]            ; get the nextList pointer

                mov.q       [rdi+List.prev],rsi     ; set next->prev to prev
                mov.q       [rsi+List.next],rdi     ; set prev->next to next

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

                pop         rdi                     ; save rdi
                pop         rsi                     ; save rsi
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void ListDel(qword listEntry) -- This function will remove an entry from the list.  It will
;                                  set listEntry.prev and listEntry.next addresses to a bad
;                                  pointer guaranteed to generate a PageFault in the event
;                                  they are dereferenced, which should facilitate debugging.
;                                  These bad pointers are unique to each member.
;
; Included in this function are some sanity checks. Since entry->prev->next == entry and
; entry->next->prev == entry.  We will confirm this before we do anything.  However, we will
; not kill the system on these error just yet.
;----------------------------------------------------------------------------------------------

ListDel:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx

;----------------------------------------------------------------------------------------------
; sanity check #1) entry->prev->next == entry
;----------------------------------------------------------------------------------------------

                mov.q       rbx,[rbp+16]            ; get entry
                mov.q       rax,[rbx+List.prev]     ; get the prev address
                mov.q       rax,[rax+List.next]     ; get the next address
                cmp.q       rax,rbx                 ; make sure they are the same
                je          .chk2                   ; if so, we can move on

                sub.q       rsp,8                   ; make room on the stack for 1 parm
                mov.q       [rsp],0x0c              ; set the error color
                call        TextSetAttr             ; set the attribute

                mov.q       rax,Err3a               ; get the start of the error message
                mov.q       [rsp],rax               ; and put it on the stack
                call        TextPutString           ; write the string to the screen

                mov.q       rax,[rbx+List.prev]     ; get the prev address
                mov.q       rax,[rax+List.next]     ; get the next address
                mov.q       [rsp],rax               ; push it on the stac
                call        TextPutHexQWord         ; write the address to the screen

                mov.q       rax,Erre                ; get the next part of the error message
                mov.q       [rsp],rax               ; and put it on the stack
                call        TextPutString           ; write the string to the screen

                mov.q       [rsp],rbx               ; set the address on the stack
                call        TextPutHexQWord         ; write the address to the screen

                mov.q       rax,Errf                ; get the next part of the error message
                mov.q       [rsp],rax               ; and put it on the stack
                call        TextPutString           ; write the string to the screen
                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; sanity check #2) entry->prev->next == entry
;----------------------------------------------------------------------------------------------

.chk2:          mov.q       rax,[rbx+List.next]     ; get the next address
                mov.q       rax,[rax+List.prev]     ; get the prev address
                cmp.q       rax,rbx                 ; make sure they are the same
                je          .good                   ; if so, we can move on

                sub.q       rsp,8                   ; make room on the stack for 1 parm
                mov.q       [rsp],0x0c              ; set the error color
                call        TextSetAttr             ; set the attribute

                mov.q       rax,Err3a               ; get the start of the error message
                mov.q       [rsp],rax               ; and put it on the stack
                call        TextPutString           ; write the string to the screen

                mov.q       rax,[rbx+List.next]     ; get the next address
                mov.q       rax,[rax+List.prev]     ; get the prev address
                mov.q       [rsp],rax               ; push it on the stac
                call        TextPutHexQWord         ; write the address to the screen

                mov.q       rax,Erre                ; get the next part of the error message
                mov.q       [rsp],rax               ; and put it on the stack
                call        TextPutString           ; write the string to the screen

                mov.q       [rsp],rbx               ; set the address on the stack
                call        TextPutHexQWord         ; write the address to the screen

                mov.q       rax,Errf                ; get the next part of the error message
                mov.q       [rsp],rax               ; and put it on the stack
                call        TextPutString           ; write the string to the screen
                add.q       rsp,8                   ; clean up the stack

;----------------------------------------------------------------------------------------------
; remove the entry from the list
;----------------------------------------------------------------------------------------------

.good:          push        qword [rbx+List.next]   ; push the next address
                push        qword [rbx+List.prev]   ; push the prev address
                call        __list_del              ; call the worker function
                add.q       rsp,16                  ; clean up the stack

;----------------------------------------------------------------------------------------------
; now, make sure we get a page fault in case someone does something stupid with entry->prev or
; entry->next
;----------------------------------------------------------------------------------------------

                mov.q       rax,BADLISTPREV         ; get the bad pointer address
                mov.q       [rbx+List.prev],rax     ; set the bad pointer
                mov.q       rax,BADLISTNEXT         ; get the bad pointer address
                mov.q       [rbx+List.next],rax     ; set the bad pointer

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

                pop         rbx                     ; save rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; void ListDelInit(qword listEntry) -- This function will remove an entry from the list and
;                                      initialize the .next and .prev members of listEntry
;                                      to be self-pointing.
;----------------------------------------------------------------------------------------------

                global      ListDelInit

ListDelInit:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame

;----------------------------------------------------------------------------------------------
; first, do the work
;----------------------------------------------------------------------------------------------

                push        qword [rbp+16]          ; push the parm on the stack
                call        ListDel                 ; remove it from the list
                add.q       rsp,8                   ; clean up the stack

                mov.q       rax,[rbp+16]            ; get the entry address
                InitializeList      rax             ; initialize the list structure in rax

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword ListNext(qword listHead) -- Remove the next entry from the list, pointed to by
;                                   head->next.
;----------------------------------------------------------------------------------------------

                global      ListNext

ListNext:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame

;----------------------------------------------------------------------------------------------
; first, check if we can do the work
;----------------------------------------------------------------------------------------------

                push        qword [rbp+16]          ; push the list head on the stack
                call        ListEmpty               ; is the list empty
                add.q       rsp,8                   ; clean up the stack
                cmp.q       rax,0                   ; is the list empty?
                je          .good                   ; we have something, so go on

                xor.q       rax,rax                 ; clear the return value
                jmp         .out                    ; go exit

;----------------------------------------------------------------------------------------------
; now, remove the entry
;----------------------------------------------------------------------------------------------

.good:          mov.q       rax,[rbp+16]            ; get the head param
                push        qword [rax+List.next]   ; push the parm on the stack
                call        ListDelInit             ; remove it from the list and init vals
                pop         rax                     ; clean up the stack & set return val

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:           pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;----------------------------------------------------------------------------------------------
; qword ListEmpty(qword listHead) -- returns 1 if the list is empty, 0 if it is not empty
;----------------------------------------------------------------------------------------------

                global      ListEmpty

ListEmpty:
                push        rbp                     ; save caller's frame
                mov.q       rbp,rsp                 ; create our own frame
                push        rbx                     ; save rbx

                mov.q       rbx,[rbp+16]            ; get the listHead parm
                cmp.q       rbx,[rbx+List.next]     ; do we have an empty list
                je          .empty                  ; if so, report it empty

                xor.q       rax,rax                 ; not empty, so return 0
                jmp         .out                    ; and leave

.empty          mov.q       rax,1                   ; return 1 for an empty list

;----------------------------------------------------------------------------------------------
; clean up and exit
;----------------------------------------------------------------------------------------------

.out:           pop         rbx                     ; restore rbx
                pop         rbp                     ; restore caller's frame
                ret

;==============================================================================================

;==============================================================================================
; This is the read only data (.rodata) and will be included in the .text section at link
;==============================================================================================

                section     .rodata

Err1a           db          'List corruption.  next->prev should be prev (',0
Err1c           db          '.  (next = ',0

Err2a           db          'List corruption.  prev->next should be next (',0
Err2c           db          '.  (prev = ',0

Errb            db          '), but was ',0
Errd            db          ').',13,0

Err3a           db          'List corruption.  prev->next should be ',0

Err4a           db          'List corruption.  next->prev should be ',0

Erre            db          ' but was ',0
Errf            db          '.',13,0
