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
/*                                                                                           */
/*===========================================================================================*/


ENTRY(EntryPoint)

PAGING = 0x0000000000400000;		/* 4MB */
VIRT_BASE = 0xffffffff80000000;

SECTIONS
{
	. = 0x100000;
	bootStart = .;

	.boot :
	{
		*(.multiboot)
		*(.bootcode)
		*(.bootstack)
	}

	bootEnd = .;

	. = 0x108000;

	.paging :
	{
		*(.paging)
	}

	. += VIRT_BASE;

	.text ALIGN(0x1000) : AT(ADDR(.text) - VIRT_BASE)
	{
		*(.text)
		*(.rodata)
	}

	.data ALIGN(0x1000) : AT(ADDR(.data) - VIRT_BASE)
	{
		*(.data)
	}

	.bss ALIGN(0x1000) : AT(ADDR(.bss) - VIRT_BASE)
	{
		*(COMMON)
		*(.bss)
	}

	bssEnd = .;
}
