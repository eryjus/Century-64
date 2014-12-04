#==============================================================================================
#
# makefile
#
# This file contains the recipes to make the Century-64 kernel.
#
#*********************************************************************************************
#
#       Century-64 is a 64-bit Hobby Operating System written mostly in assembly.
#       Copyright (C) 2014  Adam Scott Clark
#
#       This program is free software: you can redistribute it and/or modify
#       it under the terms of the GNU General Public License as published by
#       the Free Software Foundation, either version 3 of the License, or
#       any later version.
#
#       This program is distributed in the hope that it will be useful,
#       but WITHOUT ANY WARRANTY; without even the implied warranty of
#       MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#       GNU General Public License for more details.
#
#       You should have received a copy of the GNU General Public License along
#       with this program.  If not, see http://www.gnu.org/licenses/gpl-3.0-standalone.html.
#
#**********************************************************************************************
#
# You can use the following typical commands in this file:
#    make iso			-- to make the kernel file and build a bootable iso image
#    make build			-- build the kernel only (used for tighter developmetn cycles)
#    make clean			-- clean up your mess for a full rebuild
#
#    Date     Tracker  Pgmr  Description
# ----------  ------   ----  ------------------------------------------------------------------
# 2014/09/24  Initial  ADCL  Initial vesion
#
#==============================================================================================

TGT-DIR=bin
TGT-BLD=century-64.bin
TGT-FILE=$(TGT-DIR)/$(TGT-BLD)
TGT-ISO=$(subst .bin,.iso,$(TGT-BLD))
TGT-CDROM=$(TGT-DIR)/$(TGT-ISO)

LINK-SCRIPT=linker.ld

ASM=nasm -felf64 -Isrc/ -Iinclude/
LD=x86_64-elf-gcc -ffreestanding -O2 -nostdlib -z max-page-size=0x1000
LD-SCRIPT=-T $(LINK-SCRIPT)
LD-LIBS=-lgcc
OBJCOPY=x86_64-elf-objcopy

ASM-SRC=$(wildcard src/*.s)
OBJ=$(sort $(subst .s,.o,$(subst src/,obj/,$(ASM-SRC))))


.PHONY: commit
commit: clean
	read -r -p "Enter the commit message: " MSG && echo $$MSG && git add . && git commit -m "$$MSG" && git push -u origin master

.PHONY: iso
iso: $(TGT-CDROM)

$(TGT-CDROM): $(TGT-FILE) bin/grub.cfg makefile
	echo Creating $@...
	mkdir -p iso/boot/grub
	cp bin/grub.cfg iso/boot/grub/
	cp $(TGT-FILE) iso/boot/
	grub2-mkrescue -o $(TGT-CDROM) iso
	rm -fR iso

.PHONY: build
build: $(TGT-FILE)

$(TGT-FILE): $(OBJ) $(LINK-SCRIPT) makefile
	echo Linking $@...
	mkdir -p bin
	$(LD) $(LD-SCRIPT) -o $@ $(OBJ) $(LD-LIBS)
	$(OBJCOPY) --only-keep-debug $@ $(subst .bin,.sym,$@) && chmod -x $(subst .bin,.sym,$@)

obj/%.o: src/%.s src/*.inc makefile
	echo Assembling $<...
	mkdir -p obj
	$(ASM) $< -o $@

bin/grub.cfg: makefile
	echo Generating $@...
	mkdir -p bin
	echo set timeout=3                    >  bin/grub.cfg
	echo set default=0	                  >> bin/grub.cfg
	echo menuentry \"Century-64\" {       >> bin/grub.cfg
	echo   multiboot /boot/century-64.bin >> bin/grub.cfg
	echo   boot							  >> bin/grub.cfg
	echo }								  >> bin/grub.cfg
	echo menuentry \"Century-64 mb2\" {   >> bin/grub.cfg
	echo   multiboot2 /boot/century-64.bin>> bin/grub.cfg
	echo   boot							  >> bin/grub.cfg
	echo }								  >> bin/grub.cfg

.PHONY: clean
clean:
	echo Cleaning...
	rm -fR obj
	rm -fR bin
	rm -fR iso
