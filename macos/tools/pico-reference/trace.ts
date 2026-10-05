// Runs a flash image in rp2040js (https://github.com/wokwi/rp2040js) with scripted inputs and prints the summary
// PicoTests reproduces: copy into rp2040js/demo, then
// npx tsx demo/trace.ts image.bin seconds pins events.json
// events: [[nanos, "pin", gpio, 0|1], [nanos, "adc", channel, value], [nanos, "serial", "text"]]
import fs from 'fs';
import { Simulator } from '../src/simulator.js';
import { USBCDC } from '../src/usb/cdc.js';
import { ConsoleLogger, LogLevel } from '../src/utils/logging.js';
import { bootromB1 } from './bootrom.js';

const [image, secondsText, pinsText, eventsFile] = process.argv.slice(2);
const events: [number, string, number | string, number?][] = eventsFile
  ? JSON.parse(fs.readFileSync(eventsFile, 'utf8'))
  : [];
const simulator = new Simulator();
const mcu = simulator.rp2040;
mcu.loadBootrom(bootromB1);
mcu.logger = new ConsoleLogger(LogLevel.Error);
mcu.flash.set(fs.readFileSync(image), 0);
const cdc = new USBCDC(mcu.usbCtrl);
let serial = '';
cdc.onSerialData = (value) => {
  serial += Buffer.from(value).toString('latin1');
};
const bits = (x: number) => {
  const view = new DataView(new ArrayBuffer(8));
  view.setFloat64(0, x);
  return view.getBigUint64(0).toString(16);
};
const pins = pinsText.split(',').map(Number);
const summary: Record<number, { count: number; sum: number; last: string[] }> = {};
for (const pin of pins) {
  summary[pin] = { count: 0, sum: 0, last: [] };
  mcu.gpio[pin].addListener((state) => {
    const s = summary[pin];
    s.count++;
    s.sum += simulator.clock.nanos;
    s.last.push(`${bits(simulator.clock.nanos)}:${state}`);
    if (s.last.length > 3) s.last.shift();
  });
}
mcu.core.PC = 0x10000000;
const cycleNanos = 1e9 / 125_000_000;
const end = Number(secondsText) * 1e9;
const { clock } = simulator;
let instructions = 0;
let next = 0;
while (clock.nanos < end) {
  while (next < events.length && clock.nanos >= events[next][0]) {
    const [, kind, a, b] = events[next++];
    if (kind === 'pin') mcu.gpio[a as number].setInputValue(!!b);
    else if (kind === 'adc') mcu.adc.channelValues[a as number] = b as number;
    else for (const c of a as string) cdc.sendSerialByte(c.charCodeAt(0));
  }
  if (mcu.core.waiting) {
    clock.tick(clock.nanosToNextAlarm);
  } else {
    const cycles = mcu.core.executeInstruction();
    instructions++;
    clock.tick(cycles * cycleNanos);
  }
}
const lines = [`instructions ${instructions} cycles ${mcu.core.cycles} nanos ${bits(clock.nanos)}`];
for (const pin of pins) {
  const s = summary[pin];
  lines.push(`GP${pin} ${s.count} ${bits(s.sum)} ${s.last.join(' ')}`);
}
lines.push(`registers ${Array.from(mcu.core.registers).map((r) => (r >>> 0).toString(16)).join(' ')}`);
console.log(lines.join('\n'));
console.log(JSON.stringify(serial));
