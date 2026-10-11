// An STM32F405/407 around the Cortex-M4 core: its memories (1 MB of flash, 128 KB of SRAM, 64 KB of CCM), its clock
// tree, flash interface (with programming, for a firmware's saved settings), GPIO and EXTI, DMA, ADCs, timers, SPI
// and I2S, I2C, USARTs, DAC and RNG: what Mutable Instruments' and 4ms' modules use. Registers are modelled as the
// reference manual (RM0090) gives them, as far as those firmwares reach.
//
// What the chip is connected to is given to it as functions: the devices on its buses (a codec on I2C and I2S, a DAC
// on SPI) and its pins' levels and voltages, set from outside between runs.

#ifndef STM32F4_H
#define STM32F4_H

#include "CortexM4.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct STM32F4 STM32F4;

/// The devices on the chip's buses. Each is called as the chip's peripheral does it, during a run; any can be NULL.
typedef struct {
    void *context;
    /// I2C (bus 1-3) as a master: a start (or repeated start) with an address byte's 7-bit address and direction;
    /// returns whether a device acknowledged
    bool (*i2c_start)(void *context, int bus, uint8_t address, bool read);
    /// a byte written after the address; returns whether it was acknowledged
    bool (*i2c_write)(void *context, int bus, uint8_t byte);
    /// a byte read; `ack` is whether the master acknowledges it (asks for another)
    uint8_t (*i2c_read)(void *context, int bus, bool ack);
    void (*i2c_stop)(void *context, int bus);
    /// SPI (1-3) as a master: a frame of `bits` (8 or 16) shifted out, the frame shifted in returned
    uint32_t (*spi_exchange)(void *context, int spi, uint32_t frame, int bits);
    /// I2S (2 or 3): a stereo frame sent, and the one to receive (its full-duplex extension) asked for. Samples are
    /// as the data format gives them (16, 24 or 32 bits), sign-extended.
    void (*i2s_frame)(void *context, int spi, int32_t left, int32_t right, int32_t *in_left, int32_t *in_right);
    /// a USART (1-6) has sent a byte
    void (*usart_send)(void *context, int usart, uint8_t byte);
} STM32F4Devices;

/// A chip with its crystal (HSE) at `hse_hz` (8 MHz on Mutable's modules)
STM32F4 *stm32f4_create(double hse_hz);
void stm32f4_destroy(STM32F4 *chip);
CM4 *stm32f4_core(STM32F4 *chip);
void stm32f4_set_devices(STM32F4 *chip, const STM32F4Devices *devices);

/// The flash's bytes (1 MB from 0x08000000), erased (0xFF) when created: a firmware is copied in at its address
uint8_t *stm32f4_flash(STM32F4 *chip);
/// Reset: the core from the vector table at the start of flash or, where that is erased (a firmware built to run
/// behind a bootloader that is not there), from the first vector table found after it at a 16 KB boundary; the
/// peripherals at their reset values. The flash keeps its contents.
void stm32f4_reset(STM32F4 *chip);

/// Runs the core and the peripherals for `cycles` of the core's clock (HCLK) at least, or until it stops
CM4Stop stm32f4_run(STM32F4 *chip, uint64_t cycles);
/// The core's clock (HCLK), as the firmware has set the clock tree: 16 MHz from reset
double stm32f4_hclk(const STM32F4 *chip);
/// Time since reset, in seconds, through the clock changes
double stm32f4_time(const STM32F4 *chip);

/// Pins, by port (0 for A ... 4 for E) and number. An input's level as the circuit drives it (`driven` false: left
/// floating, so that the pin's pull, if it has one, sets it)
void stm32f4_set_input(STM32F4 *chip, int port, int pin, bool driven, bool high);
/// A pin's voltage, for the ADCs (against a 3.3 V reference)
void stm32f4_set_voltage(STM32F4 *chip, int port, int pin, double volts);
/// A pin's mode (0 input, 1 output, 2 alternate function, 3 analog) and the level it drives (an output's, or a
/// timer's or the DAC's through its alternate function), with `level` as a fraction for the DAC's analog output
enum { STM32F4_INPUT = 0, STM32F4_OUTPUT = 1, STM32F4_ALTERNATE = 2, STM32F4_ANALOG = 3 };
int stm32f4_pin_mode(const STM32F4 *chip, int port, int pin);
bool stm32f4_pin_level(const STM32F4 *chip, int port, int pin);
/// Whether an output pin drives its level (push-pull, or open drain driving low) rather than letting it float
bool stm32f4_pin_driven(const STM32F4 *chip, int port, int pin);
/// The DAC's channel (1 or 2) output, in volts (PA4 and PA5), or a negative value when it is off
double stm32f4_dac_volts(const STM32F4 *chip, int channel);

#ifdef __cplusplus
}
#endif

#endif
