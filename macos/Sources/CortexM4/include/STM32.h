// STM32 chips around the Cortex-M4 core: what Mutable Instruments' and 4ms' modules use.
//
// - The STM32F405/407 (RM0090): 1 MB of flash, 128 KB of SRAM and 64 KB of CCM; its clock tree with PLLI2S, flash in
//   sectors, GPIO and EXTI, DMA in streams, three ADCs, timers, SPI and I2S with full-duplex extensions, I2C, USARTs,
//   DAC and RNG. Rings, Clouds, Elements, Warps, Marbles.
// - The STM32F373 (RM0313): 256 KB of flash and 32 KB of SRAM at 72 MHz; its clock tree, flash in pages, the same
//   GPIO, EXTI and timers, DMA in channels, a 12-bit ADC and three 16-bit sigma-delta ADCs, SPI and I2S, USARTs and
//   DACs. Plaits, Stages, Tides 2.
// - The STM32F103 (RM0008), medium density: 128 KB of flash and 20 KB of SRAM at 72 MHz; the F1's GPIO (CRL and CRH)
//   with AFIO, its clock tree, flash in 1 KB pages, DMA1, two ADCs, timers 1-4, SPI, I2C and USARTs. Its core is a
//   Cortex-M3, which runs as the M4 without its FPU and DSP instructions. Braids, Peaks, Frames, Streams.
//
// Registers are modelled as the reference manuals give them, as far as those firmwares reach.
//
// What the chip is connected to is given to it as functions: the devices on its buses (a codec on I2C and I2S, a DAC
// on SPI) and its pins' levels and voltages, set from outside between runs.

#ifndef STM32_H
#define STM32_H

#include "CortexM4.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct STM32 STM32;

/// The chips modelled
typedef enum { STM32_F405 = 0, STM32_F373 = 1, STM32_F103 = 2 } STM32Model;

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
    /// left-justified in 32 bits, whatever the data format (16, 24 or 32 bits).
    void (*i2s_frame)(void *context, int spi, int32_t left, int32_t right, int32_t *in_left, int32_t *in_right);
    /// a USART (1-6) has sent a byte
    void (*usart_send)(void *context, int usart, uint8_t byte);
} STM32Devices;

/// A chip with its crystal (HSE) at `hse_hz` (8 MHz on Mutable's modules)
STM32 *stm32_create_model(STM32Model model, double hse_hz);
/// An STM32F405
STM32 *stm32_create(double hse_hz);
STM32Model stm32_model(const STM32 *chip);
/// The flash's size in bytes
uint32_t stm32_flash_size(const STM32 *chip);
void stm32_destroy(STM32 *chip);
CM4 *stm32_core(STM32 *chip);
void stm32_set_devices(STM32 *chip, const STM32Devices *devices);

/// The flash's bytes (from 0x08000000), erased (0xFF) when created: a firmware is copied in at its address
uint8_t *stm32_flash(STM32 *chip);
/// Reset: the core from the vector table at the start of flash or, where that is erased (a firmware built to run
/// behind a bootloader that is not there), from the first vector table found after it at a 16 KB boundary; the
/// peripherals at their reset values. The flash keeps its contents.
void stm32_reset(STM32 *chip);

/// Runs the core and the peripherals for `cycles` of the core's clock (HCLK) at least, or until it stops
CM4Stop stm32_run(STM32 *chip, uint64_t cycles);
/// The core's clock (HCLK), as the firmware has set the clock tree: 16 MHz from reset
double stm32_hclk(const STM32 *chip);
/// Time since reset, in seconds, through the clock changes
double stm32_time(const STM32 *chip);

/// Pins, by port (0 for A ... 4 for E) and number. An input's level as the circuit drives it (`driven` false: left
/// floating, so that the pin's pull, if it has one, sets it)
void stm32_set_input(STM32 *chip, int port, int pin, bool driven, bool high);
/// A pin's voltage, for the ADCs (against a 3.3 V reference)
void stm32_set_voltage(STM32 *chip, int port, int pin, double volts);
/// A pin's mode (0 input, 1 output, 2 alternate function, 3 analog) and the level it drives (an output's, or a
/// timer's or the DAC's through its alternate function), with `level` as a fraction for the DAC's analog output
enum { STM32_INPUT = 0, STM32_OUTPUT = 1, STM32_ALTERNATE = 2, STM32_ANALOG = 3 };
int stm32_pin_mode(const STM32 *chip, int port, int pin);
bool stm32_pin_level(const STM32 *chip, int port, int pin);
/// Whether an output pin drives its level (push-pull, or open drain driving low) rather than letting it float
bool stm32_pin_driven(const STM32 *chip, int port, int pin);
/// The DAC's channel (1 or 2) output, in volts (PA4 and PA5), or a negative value when it is off
double stm32_dac_volts(const STM32 *chip, int channel);

// The pins a circuit reaches, by index, in the order the model lists them: the 64-pin package's I/O. The F405's:
// PA0-PA15, PB0-PB15, PC0-PC15, PD2 (49). The F373's: PA0-PA15, PB0-PB15, PC0-PC15, PD8, PE8, PE9, PF6, PF7 (53). The
// functions below take and give them in that order.
int stm32_pin_count(STM32Model model);
/// The port (0 for A) and number of the pin at `index`
int stm32_pin_port(STM32Model model, int index);
int stm32_pin_number(STM32Model model, int index);
/// The circuit's voltage on each pin: its level read with hysteresis (high above 0.6 of `supply`, low below 0.3, as
/// it was between), and the voltage the ADCs read
void stm32_set_pin_voltages(STM32 *chip, const double *volts, int count, double supply);
/// One pin's voltage alone (a device answering on a bus while the chip runs)
void stm32_set_pin_voltage(STM32 *chip, int index, double volts, double supply);
/// What each pin does, as the circuit sees it
enum { STM32_FLOATING = 0, STM32_PULLED_UP = 1, STM32_PULLED_DOWN = 2, STM32_DRIVEN_LOW = 3, STM32_DRIVEN_HIGH = 4 };
void stm32_pin_states(const STM32 *chip, uint8_t *states, int count);
/// Pins whose driven level is told to `listener` as it changes while the chip runs, with the cycle it changed at
typedef void (*STM32PinListener)(void *context, uint64_t cycle, int index, bool high);
void stm32_watch_pins(STM32 *chip, const int *indices, int count, STM32PinListener listener, void *context);
/// Bytes for a USART (1-6) to receive, one at a time at its baud rate, once its receiver is on; how many still wait
void stm32_usart_input(STM32 *chip, int usart, const uint8_t *bytes, int count);
int stm32_usart_input_waiting(const STM32 *chip, int usart);

#ifdef __cplusplus
}
#endif

#endif
