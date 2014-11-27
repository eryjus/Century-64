/*===========================================================================================*/
/*                                                                                           */
/* linker.ld                                                                                 */
/*                                                                                           */
/* This file contains the command script to feed to the linker that will determine how and   */
/* where to put the sections of the executable.  Most notably, the .multiboot section needs  */
/* to come first as it is required to be in the first 8K of the file.                        */
/*                                                                                           */
/*    Date     Tracker  Pgmr  Description                                                    */
/* ----------  ------   ----  -------------------------------------------------------------- */
/* 2014/09/24  Initial  ADCL  Leveraged from osdev.org -- "Higher Half Bare Bones" wiki      */
/* 2014/09/25  Initial  ADCL  Since "Higher Half Bare Bones" did not work, scrapped it all   */
/*                            for a run at "64-bit Higher Half Kernel with GRUB2.            */
/* 2014/09/26  Initial  ADCL  After a lot of work and a sleepless night, I have finally been */
/*                            able to get an elf64 image to boot with GRUB2 using the        */
/*                            multiboot 1 header.  The key to making this work was changing  */
/*                            the page size for the linker to be 0x800 (2K).  See loader.s   */
/*                            for more details.  In addition, I have been able to force the  */
/*                            multiboot section to be written first in the output file.      */
/*                            In order to accomplish this, I had to remove all the other     */
/*                            sections and VIRT_BASE manipulations that were taking place.   */
/*                            These will have to be added back in carefully as we go on from */
/*                            here.                                                          */
/* 2014/10/05  Initial  ADCL  Changed the command file to properly link 64-bit code at       */
/*                            0xfffffff800000000.                                            */
/* 2014/11/14  #200     ADCL  Reset the kernel address as follows:                           */
/*                            0xffff 8000 0000 0000 -- Kernel code virtual base              */
/*                            0xffff 9000 0000 0000 -- Kernel data and bss sections          */
/*                            0xffff a000 0000 0000 -- Kernel heap                           */
/*                            0xffff b000 0000 0000 -- Driver code                           */
/*                            0xffff c000 0000 0000 -- Driver data and bss                   */
/*                            0xffff d000 0000 0000 -- Driver heap                           */
/*                            0xffff e000 0000 0000 -- Kernel/driver shared data ( ???? )    */
/*                            0xffff ff80 0000 0000 -- Page Tables                           */
/*                            0xffff ffff c000 0000 -- Page Directories                      */
/*                            0xffff ffff ffe0 0000 -- Page Directory Pointer Tables         */
/*                            0xffff ffff ffff f000 -- PML4 Table                            */
/*                                                                                           */
/*===========================================================================================*/

ENTRY(EntryPoint)
OUTPUT_FORMAT(elf64-x86-64)

ENTRY_BASE = 0x0000000000100000;
CODE_VIRT  = 0xffff800000000000;
DATA_VIRT  = 0xffff900000000000;
DATA_PHYS  = 0x0000000000200000;

SECTIONS
{
	. = ENTRY_BASE;
	bootStart = .;

	.boot :
	{
		*(.multiboot)
		bootClear = .;
		*(.bootcode)
		*(.bootdata)
		*(.boot2)
		*(.bootstack)
	}

	bootEnd = .;

	. += CODE_VIRT;

	kernelStart = .;

	.text ALIGN(0x1000) : AT(ADDR(.text) - CODE_VIRT)
	{
		*(.text)
		*(.rodata)
	}

	kernelEnd = .;

	. = DATA_VIRT;

	.data ALIGN(0x1000) : AT(DATA_PHYS)
	{
		*(.data)
	}

	.bss ALIGN(0x1000) : AT(DATA_PHYS + SIZEOF(.data))
	{
		*(COMMON)
		*(.bss)
	}

	bssEnd = .;
}
