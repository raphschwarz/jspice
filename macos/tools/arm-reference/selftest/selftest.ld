/* The self-test's memory: an STM32F4's flash (seen at 0 as well) and 128 KB of RAM */
MEMORY {
    FLASH (rx) : ORIGIN = 0x08000000, LENGTH = 64K
    RAM (rwx)  : ORIGIN = 0x20000000, LENGTH = 128K
}
ENTRY(reset)
SECTIONS {
    .text : {
        KEEP(*(.vectors))
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > FLASH
    .ARM.exidx : { *(.ARM.exidx*) } > FLASH
    /* the results the test reads, at the start of RAM */
    .results (NOLOAD) : { KEEP(*(.results)) } > RAM
    .data : {
        _data = .;
        *(.data*)
        . = ALIGN(4);
        _edata = .;
    } > RAM AT > FLASH
    _data_load = LOADADDR(.data);
    .bss (NOLOAD) : {
        _bss = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > RAM
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
