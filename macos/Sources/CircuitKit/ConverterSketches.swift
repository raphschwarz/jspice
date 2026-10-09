import Foundation

// The sketches of the converter examples, with their firmware compiled ahead as for the other examples:
// tools/avr-reference/sketches/mcp4822.ino and adcdac.ino (Arduino Uno), tools/pico-reference/sketches/i2s.ino (Pico)

extension ArduinoSketches {
    static let mcp4822Code = """
        // Two slow waves from an MCP4822 over SPI: a 2 Hz sine on output A and a 2 Hz triangle on output B, each between
        // about 0.04 V and 2 V (its 2.048 V reference, gain 1): control voltages for a synth
        #include <SPI.h>

        const int csPin = 10;

        void writeDAC(byte channel, int code) {
          // bit 15 picks the channel, 13 sets gain 1, 12 turns it on; then the 12-bit code
          unsigned int word = (channel ? 0x8000 : 0) | 0x3000 | (code & 0x0FFF);
          digitalWrite(csPin, LOW);
          SPI.transfer16(word);
          digitalWrite(csPin, HIGH);
        }

        void setup() {
          pinMode(csPin, OUTPUT);
          digitalWrite(csPin, HIGH);
          SPI.begin();
          SPI.beginTransaction(SPISettings(8000000, MSBFIRST, SPI_MODE0));
        }

        void loop() {
          float cycles = millis() / 500.0;  // 2 Hz
          float sine = sin(2 * PI * cycles);
          float triangle = 4 * fabs(cycles - floor(cycles + 0.5)) - 1;
          writeDAC(0, 2048 + 2000 * sine);
          writeDAC(1, 2048 + 2000 * triangle);
        }
        """

    static let mcp4822Firmware = """
        DJRtAAyUmgEMlMEBDJSVAAyUlQAMlJUADJSVAAyU1wQMlJUADJSVAAyUlQAMlJUADJSVAAyUlQAMlJUADJSVAAyU6AEMlJUADJTmAwyUGAQMlJUADJSV
        AAyUlQAMlJUADJSVAAyUlQAFqEzNstROuTg2qQIMULmRhogIPKaqqiq+AAAAgD8AAAAIAAIBAAADBAcAAAAAAAAAAAECBAgQIECAAQIECBAgAQIECBAg
        BAQEBAQEBAQCAgICAgIDAwMDAwMAAAAAJQAoACsAAAAAACQAJwAqAAIASAQRJB++z+/Y4N6/zb8R4KDgseDq5vDhAsAFkA2SqDGxB9n3IeCo4bHgAcAd
        kqk8sgfh9xDgzebQ4ATAIZf+AQ6ULQjMNtEHyfcOlDQFDJQzCAyUAAAMtAX8DcCevQAADbQH/v3PnrWOvQAADbQH/v3PjrUIlY69AAANtAf+/c+OtZ69
        AAANtAf+/c+etQiVz5Pfk8Dg0OOIIxHwwODQ639wxivXK2DgiuAOlN4CzgEOlJcAYeCK4N+Rz5EMlN4CYeCK4A6UogJh4IrgDpTeAg6UYwGAkRoBiCOB
        8J+3+JSAkRoBgTB59I2zgJMYAS2zgJEZAYCVgiONu5+/gOWMvYHgjb0IlZCTGAH4z0+SX5Jvkn+Sj5Kfkq+Sv5LPkt+S75L/kg6UMgIOlFgGIOAw4Erv
        U+QOlLAFawF8ASvtP+BJ7FDkDpQ+Bw6UqwcrATwBIOAw4EDgX+PHAbYBDpREBQ6UlQZLAVwBIOAw4ErvVOTDAbIBDpQ+ByDgMOBA4FXkDpREBQ6UIgaA
        4A6UtAClAZQBxwG2AQ6UQwWfdyDgMOBA6FDkDpQ+ByDgMOBA6F/jDpRDBSDgMOBK71TkDpQ+ByDgMOBA4FXkDpREBQ6UIgaB4P+Q75DfkM+Qv5CvkJ+Q
        j5B/kG+QX5BPkAyUtADPk8+3+JSAkRsBgREnwOjr8OCEkeTq8OCUkegv8ODuD/8f5FP/T6WRtJHskekjIfRh4IrgDpTeAmHgiuAOlKICjLWAYYy9jLWA
        ZIy9YeCN4A6UogJh4IvgDpSiAoCRGwGPX4CTGwHPv8+RCJUIlR+SD5IPtg+SESQvkz+TT5Nfk2+Tf5OPk5+Tr5O/k++T/5PgkQAB8JEBAQmV/5Hvkb+R
        r5GfkY+Rf5FvkV+RT5E/kS+RD5APvg+QH5AYlR+SD5IPtg+SESQvkz+TT5Nfk2+Tf5OPk5+Tr5O/k++T/5PgkQIB8JEDAQmV/5Hvkb+Rr5GfkY+Rf5Fv
        kV+RT5E/kS+RD5APvg+QH5AYlR+SD5IPtg+SESQvkz+Tj5Ofk6+Tv5OAkR0BkJEeAaCRHwGwkSABMJEcASPgIw8tN1j1AZahHbEdIJMcAYCTHQGQkx4B
        oJMfAbCTIAGAkSEBkJEiAaCRIwGwkSQBAZahHbEdgJMhAZCTIgGgkyMBsJMkAb+Rr5GfkY+RP5EvkQ+QD74PkB+QGJUm6CMPApahHbEd0s8vt/iUYJEd
        AXCRHgGAkR8BkJEgAS+/CJV4lIS1gmCEvYS1gWCEvYW1gmCFvYW1gWCFve7m8OCAgYFggIPh6PDgEIKAgYJggIOAgYFggIPg6PDggIGBYICD4evw4ICB
        hGCAg+Dr8OCAgYFggIPq5/DggIGEYICDgIGCYICDgIGBYICDgIGAaICDEJLBAAiVgzCB8Cj0gTCZ8IIwqfAIlYcwqfCIMMnwhDCx9ICRgACPfQPAgJGA
        AI93gJOAAAiVhLWPd4S9CJWEtY99+8+AkbAAj3eAk7AACJWAkbAAj335z8+T35OQ4PwB5lb/TySRglWfT/wBhJGII8nwkOCID5kf/AHkU/9PpZG0kfwB
        7lP/T8WR1JFhEQ3An7f4lIyRIJWCI4yTiIEoIyiDn7/fkc+RCJViMFH0n7f4lDyRgi+AlYMjjJPogS4r78+Pt/iU7JEuKyyTj7/qzx+Tz5PfkygvMOD5
        AepX/0+EkfkB5lb/T9SR+QHiVf9PxJHMI6nwFi+BEQ6UeQLsL/Dg7g//H+5T/0+lkbSRj7f4lOyREREIwNCV3iPck4+/35HPkR+RCJXeK/jP/AGRjSKN
        iS+Q4IBcn0+CG5EJj3OZJwiV/AGRjYKNmBcx8IKN6A/xHYWNkOAIlY/vn+8IlfwBkY2CjZgXYfCija4Pvy+xHV2WjJGSjZ9fn3OSj5DgCJWP75/vCJX8
        AVONRI0lLzDghC+Q4IIbkwtUFxDwz5YIlQGXCJWO45TgiStJ8IDgkOCJKynwDpQ+BIERDJQAAAiV/AGkjagPuS+xHaNav08skYSNkOABlo9zmSeEj6aJ
        t4ksk6CJsYmMkYNwgGSMk5ONhI2YEwbAAojzieAtgIGPfYCDCJXPk9+T7AGIjYgjufCqibuJ6In5iYyRhf0DwICBhv0NwA+2B/z3z4yRhf/yz4CBhf/t
        z84BDpRXA+nP35HPkQiV75L/kg+TH5PPk9+T7AGB4IiPm42MjZgTGsDoifmJgIGF/xXAn7f4lO6J/4lgg+iJ+YmAgYNwgGSAg5+/geCQ4N+Rz5EfkQ+R
        /5DvkAiV9i4LjRDgD18fTw9zESfgLoyNjhEMwA+2B/z6z+iJ+YmAgYX/9c/OAQ6UVwPxz+uN7A/9L/Ed41r/T/CCn7f4lAuP6on7iYCBgGLPzx+SD5IP
        tg+SESQvk4+Tn5Pvk/+T4JE1AfCRNgGAgeCROwHwkTwBgv0bwJCBgJE+AY9fj3MgkT8BghdB8OCRPgHw4Otd/k+Vj4CTPgH/ke+Rn5GPkS+RD5APvg+Q
        H5AYlYCB9M8fkg+SD7YPkhEkL5M/k0+TX5Nvk3+Tj5Ofk6+Tv5Pvk/+TheKR4A6UVwP/ke+Rv5GvkZ+Rj5F/kW+RX5FPkT+RL5EPkA++D5AfkBiVheKR
        4A6UDAMh4IkrCfQg4IIvCJXl4vHgE4ISgojuk+Cg4LDghIOVg6aDt4OJ4JHgkYOAg4XskOCVh4SHhOyQ4JeHhoeA7JDgkYuAi4HskOCTi4KLguyQ4JWL
        hIuG7JDgl4uGixGOEo4TjhSOCJWvkr+Sz5Lfku+S/5IPkx+Tz5Pfk2wBewGLAQQPFR/rAV4Brhi/CMAX0QdZ8GmR1gHtkfyRAZDwgeAtxgEJlYkreffF
        Ad+Rz5EfkQ+R/5DvkN+Qz5C/kK+QCJWBMDnwGPCCMFHwCJUQkm4ACJWAkW8AjX+Ak28ACJWAkXAAjX+Ak3AAgeCAk7AAgJGxAIh/hGCAk7EAEJKzAAiV
        z5PIL4CRBAHIEw3A5u3w4ISRn++QkwQBDpSiBGDgjC/PkQyU3gKP7/fPH5IPkg+2D5IRJC+TP5NPk1+Tb5N/k4+Tn5Ovk7+T75P/k4CRxQGQkcYBoJHH
        AbCRyAGJK4oriyvR8ZCRwgHgkcMB8JHEAYCBiSeAg4CRxQGQkcYBoJHHAbCRyAEYFhkGGgYbBpz0gJHFAZCRxgGgkccBsJHIAQGXoQmxCYCTxQGQk8YB
        oJPHAbCTyAH/ke+Rv5GvkZ+Rj5F/kW+RX5FPkT+RL5EPkA++D5AfkBiVgJEEAQ6UwgTqzwiVDpQ+Ag6UMwUOlMwAyeTT4A6U8gAgl+HzDpRJA/nPUFi7
        J6onDpRbBQyU7AYOlN4GOPAOlOUGIPA59J8/GfQm9AyU2wYO9OCV5/sMlKwG6S8OlP0GWPO6F2IHcweEB5UHIPB59Kb1DJQ3Bw704JULLrovoC0LAbkB
        kAEMAcoBoAERJP8nWRuZ8Fk/UPRQPmjxGhbwQKIvIy80L0QnWF/zz0aVN5UnlaeV8EBTlcn3fvQfFroLYgtzC4QLuvCRUKHw/w+7H2Yfdx+IH8L3DsC6
        D2Ifcx+EH0j0h5V3lWeVt5X3lZ4/CPCwz5OViA8I8Jkn7g+XlYeVCJUOlMQFDJTsBg6U5QZY8A6U3gZA8Cn0Xz8p8AyUrAZREQyUOAcMlNsGDpT9Bmjz
        mSOx81UjkfOVG1ULuyeqJ2IXcweEBzjwn19fTyIPMx9EH6ofqfM10A4uOvDg6DLQkVBQQOaVABzK9yvQ/i8p0GYPdx+IH7sfJhc3B0gHqwew6AnwuwuA
        Lb8B/yeTWF9POvCeP1EFePAMlKwGDJQ4B18/5POYPtTzhpV3lWeVt5X3lZ9fyfeID5EdlpWHlZf5CJXh4GYPdx+IH7sfYhdzB4QHugcg8GIbcwuEC7oL
        7h+I9+CVCJUOlCkGaJSxEQyUOAcIlQ6UBQeI8J9XmPC5L5knt1Gw8OHwZg93H4gfmR8a8LqVyfcUwLEwkfAOlDcHseAIlQyUNwdnL3gviCe4XznwuT/M
        84aVd5VnlbOV2fc+9JCVgJVwlWGVf0+PT59PCJXolAnAl/s+9JCVgJVwlWGVf0+PT59PmSOp8Pkvlum7J5OV9pWHlXeVZ5W3lfER+M/69LsPEfRg/xvA
        b19/T49Pn08WwIgjEfCW6RHAdyMh8J7ohy92LwXAZiNx8Jbohi9w4GDgKvCalWYPdx+IH9r3iA+WlYeVl/kIlQ6UHweQ8J83SPSRERbwDJQ4B2DgcOCA
        6J/rCJUm9BsWYR1xHYEdDJSyBgyUzQaX+Z9ngOhw4GDgCJWII3H0dyMh8JhQhyt2LwfAZiMR9JknDcCQUYYrcOBg4CrwmpVmD3cfiB/a94gPlpWHlZf5
        CJWfPzHwkVAg9IeVd5VnlbeViA+RHZaVh5WX+QiVn++A7AiVACQKlBYWFwYYBgkGCJUAJAqUEhYTBhQGBQYIlQkuA5QADBH0iCNS8LsPQPS/KxH0YP8E
        wG9ff0+PT59PCJVX/ZBYRA9VH1nwXz9x8EeViA+X+5kfYfCfP3nwh5UIlRIWEwYUBlUf8s9GlfHfCMAWFhcGGAaZH/HPhpVxBWEFCJQIlQ6UBQeg8L7n
        uReI9Lsnnzhg9BYWsR1nL3gviCeYX/fPhpV3lWeVsR2TlZY5yPMIleiUuydmJ3cnywGX+QiVDpRRBwyU7AYOlN4GOPAOlOUGIPCVIxHwDJSsBgyU2wYR
        JAyUOAcOlP0GcPOVn8HzlQ9Q4FUfYp/wAXKfuyfwDbEdY5+qJ/ANsR2qH2SfZiewDaEdZh+CnyInsA2hHWIfc5+wDaEdYh+Dn6ANYR0iH3SfMyegDWEd
        Ix+En2ANIR2CL3Yvai8RJJ9XUECa8PHwiCNK8O4P/x+7H2Yfdx+IH5FQUECp954/UQWA8AyUrAYMlDgHXz/k85g+1POGlXeVZ5W3lfeV55WfX8H3/iuI
        D5EdlpWHlZf5CJWfkw6UtQcPkAf87l8MlN4HDJTbBg6UBQfY8+iU4OC7J59X8PAq7T/gSewGwO4Puw9mH3cfiB8o8LI6YgdzB4QHKPCyWmILcwuEC+OV
        mpVy94A4MPSalbsPZh93H4gf0veQSAyUzwbvk+D/B8Ci6irtP+BJ7F/rDpRbBQ6U7AYPkAOUAfyQWOjm8OAMlPIHn5OPk3+Tb5P/k++TmwGsAQ6UPgfv
        kf+RDpQGCC+RP5FPkV+RDJQ+B9+Tz5Mfkw+T/5Lvkt+SewGMAWiUBsDaLu8BDpRRB/4B6JSlkSWRNZFFkVWRpvPvAQ6UWwX+AZcBqAHalGn335DvkP+Q
        D5Efkc+R35EIle4P/x8FkPSR4C0JlPiU/8+ZAZkB/wAAAACZA3UEOgN5AwwDJgMYAwA=
        """

    static let adcDacCode = """
        // Reads the knob on CH0 of an MCP3008 (SPI) and sets an MCP4725 (I2C) to the same voltage: the DAC's output follows
        // the knob. The readings go to the serial monitor.
        #include <SPI.h>
        #include <Wire.h>

        const int csPin = 10;
        unsigned long lastPrint = 0;

        int readADC(int channel) {
          digitalWrite(csPin, LOW);
          SPI.transfer(0x01);                                  // the start bit
          byte high = SPI.transfer(0x80 | (channel << 4));     // single-ended, the channel; back: the code's top two bits
          byte low = SPI.transfer(0);                          // back: its low eight
          digitalWrite(csPin, HIGH);
          return (high & 0x03) << 8 | low;
        }

        void writeDAC(int code) {
          Wire.beginTransmission(0x60);
          Wire.write(0x40);                // write the DAC register
          Wire.write(code >> 4);           // D11-D4
          Wire.write((code & 0x0F) << 4);  // D3-D0
          Wire.endTransmission();
        }

        void setup() {
          Serial.begin(9600);
          pinMode(csPin, OUTPUT);
          digitalWrite(csPin, HIGH);
          SPI.begin();
          SPI.beginTransaction(SPISettings(1000000, MSBFIRST, SPI_MODE0));
          Wire.begin();
          Wire.setClock(400000);
        }

        void loop() {
          int reading = readADC(0);  // 0-1023 of VREF
          writeDAC(reading * 4);     // 0-4092 of VDD
          if (millis() - lastPrint >= 200) {
            lastPrint = millis();
            Serial.print("CH0: ");
            Serial.println(reading);
          }
        }
        """

    static let adcDacFirmware = """
        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
        jg+Ak9UB8ODqUv5PgIHpz+CR1QGB4I4PgJPVAYCRuwDw4OpS/k+Ag5CR1QGAkdQBmBfI8oXo2M/gkdUBgeCOD4CT1QGAkbsA8ODqUv5PgIOAkQECgRFc
        z4HggJMAAoTqgJO8ABCSAwIlzw6UBgOAkZEBgDIw9OCRkQHw4O5W/k8QgmCRkQFw4OCR9gHwkfcBgumR4AmVEJKRAQzPhezgzxCSkAE1zwiVH5IPkg+2
        D5IRJC+TP5NPk1+Tb5N/k4+Tn5Ovk7+T75P/k+CRAAHwkQEBCZX/ke+Rv5GvkZ+Rj5F/kW+RX5FPkT+RL5EPkA++D5AfkBiVH5IPkg+2D5IRJC+TP5NP
        k1+Tb5N/k4+Tn5Ovk7+T75P/k+CRAgHwkQMBCZX/ke+Rv5GvkZ+Rj5F/kW+RX5FPkT+RL5EPkA++D5AfkBiVH5IPkg+2D5IRJC+TP5OPk5+Tr5O/k4CR
        BQKQkQYCoJEHArCRCAIwkQQCI+AjDy03WPUBlqEdsR0gkwQCgJMFApCTBgKgkwcCsJMIAoCRCQKQkQoCoJELArCRDAIBlqEdsR2AkwkCkJMKAqCTCwKw
        kwwCv5GvkZ+Rj5E/kS+RD5APvg+QH5AYlSboIw8ClqEdsR3Szy+3+JRgkQUCcJEGAoCRBwKQkQgCL78IlT+3+JSAkQkCkJEKAqCRCwKwkQwCJrWomwXA
        Lz8Z8AGWoR2xHT+/ui+pL5gviCe8Ac0BYg9xHYEdkR1C4GYPdx+IH5kfSpXR9wiVeJSEtYJghL2EtYFghL2FtYJghb2FtYFghb3u5vDggIGBYICD4ejw
        4BCCgIGCYICDgIGBYICD4Ojw4ICBgWCAg+Hr8OCAgYRggIPg6/DggIGBYICD6ufw4ICBhGCAg4CBgmCAg4CBgWCAg4CBgGiAgxCSwQAIlYMwgfAo9IEw
        mfCCMKnwCJWHMKnwiDDJ8IQwsfSAkYAAj30DwICRgACPd4CTgAAIlYS1j3eEvQiVhLWPffvPgJGwAI93gJOwAAiVgJGwAI99+c/Pk9+TkOD8AeRY/08k
        kYBXn0/8AYSRiCPJ8JDgiA+ZH/wB4lX/T6WRtJH8AexV/0/FkdSRYRENwJ+3+JSMkSCVgiOMk4iBKCMog5+/35HPkQiVYjBR9J+3+JQ8kYIvgJWDI4yT
        6IEuK+/Pj7f4lOyRLissk4+/6s8fk8+T35MoLzDg+QHoWf9PhJH5AeRY/0/UkfkB4Ff/T8SRzCOp8BYvgREOlHEG7C/w4O4P/x/sVf9PpZG0kY+3+JTs
        kRERCMDQld4j3JOPv9+Rz5EfkQiV3iv4z/wBkY0ijYkvkOCAXJ9PghuRCY9zmScIlfwBkY2CjZgXMfCCjegP8R2FjZDgCJWP75/vCJX8AZGNgo2YF2Hw
        oo2uD78vsR1dloyRko2fX59zko+Q4AiVj++f7wiV/AFTjUSNJS8w4IQvkOCCG5MLVBcQ8M+WCJUBlwiViOmY4IkrSfCA4JDgiSsp8A6UmAiBEQyUAAAI
        lfwBpI2oD7kvsR2jWr9PLJGEjZDgAZaPc5knhI+mibeJLJOgibGJjJGDcIBkjJOTjYSNmBMGwAKI84ngLYCBj32AgwiVz5Pfk+wBiI2II7nwqom7ieiJ
        +YmMkYX9A8CAgYb9DcAPtgf898+MkYX/8s+AgYX/7c/OAQ6UTwfpz9+Rz5EIle+S/5IPkx+Tz5Pfk+wBgeCIj5uNjI2YExrA6In5iYCBhf8VwJ+3+JTu
        if+JYIPoifmJgIGDcIBkgIOfv4HgkODfkc+RH5EPkf+Q75AIlfYuC40Q4A9fH08PcxEn4C6MjY4RDMAPtgf8+s/oifmJgIGF//XPzgEOlE8H8c/rjewP
        /S/xHeNa/0/wgp+3+JQLj+qJ+4mAgYBiz8/Pkt+S75L/kh+Tz5Pfk+wBagF7ARIv6In5iYLggIPBFIHu2AbhBPEEofBg4HngjeOQ4KcBlgEOlGwKIVAx
        CUEJUQlWlUeVN5UnlSEVgOE4B5jw6In5iRCCYOh06I7hkOCnAZYBDpRsCiFQMQlBCVEJVpVHlTeVJ5Xshf2FMIPuhf+FIIMYjuyJ/YkQg+qJ+4mAgYBh
        gIPqifuJgIGIYICD6on7iYCBgGiAg+qJ+4mAgY99gIPfkc+RH5H/kO+Q35DPkAiVH5IPkg+2D5IRJC+Tj5Ofk++T/5PgkR0C8JEeAoCB4JEjAvCRJAKC
        /RvAkIGAkSYCj1+PcyCRJwKCF0Hw4JEmAvDg41/9T5WPgJMmAv+R75GfkY+RL5EPkA++D5AfkBiVgIH0zx+SD5IPtg+SESQvkz+TT5Nfk2+Tf5OPk5+T
        r5O/k++T/5ON4JLgDpRPB/+R75G/ka+Rn5GPkX+Rb5FfkU+RP5EvkQ+QD74PkB+QGJWN4JLgDpQEByHgiSsJ9CDggi8Ile3g8uATghKCiO6T4KDgsOCE
        g5WDpoO3g4HikeCRg4CDheyQ4JWHhIeE7JDgl4eGh4DskOCRi4CLgeyQ4JOLgouC7JDglYuEi4bskOCXi4aLEY4SjhOOFI4Ila+Sv5LPkt+S75L/kg+T
        H5PPk9+TbAF7AYsBBA8VH+sBXgGuGL8IwBfRB1nwaZHWAe2R/JEBkPCB4C3GAQmViSt598UB35HPkR+RD5H/kO+Q35DPkL+Qr5AIlfsBAZAAIOn3MZev
        AUYbVwvcAe2R/JECgPOB4C0JlGEVcQUR8AyU/AiQ4IDgCJXcAe2R/JEBkPCB4C0JlG/iceAMlPwIj5Kfkq+Sv5Lvkv+SD5Mfk8+T35PNt963oZcPtviU
        3r8Pvs2/fAH6AcsBGaIiMAj0KuCOAQ9dH0+CLpEssSyhLL8BpQGUAQ6UbAr5AcoBajAM9WBd2AFuk40BIyskKyUrefeQ4IDgEJch8L0BxwEOlPwIoZYP
        tviU3r8Pvs2/35HPkR+RD5H/kO+Qv5CvkJ+Qj5AIlWlc3s/Pkt+S75L/kg+TH5PPk9+TIRUxBYH03AHtkfyRAZDwgeAtZC/fkc+RH5EPkf+Q75DfkM+Q
        CZQqMDEFAfUq4Hf/HcBqAXsB7AFt4g6UEwmMAUQnVSe6AUwZXQluCX8JKuDOAQ6UHgmAD5Ef35HPkR+RD5H/kO+Q35DPkAiV35HPkR+RD5H/kO+Q35DP
        kAyUHgmaAasBdw9mC3cLDJRqCQ+TH5PPk9+T7AEOlLIJjAHOAQ6UGgmAD5Ef35HPkR+RD5EIlYEwOfAY8IIwUfAIlRCSbgAIlYCRbwCNf4CTbwAIlYCR
        cACNf4CTcACB4ICTsACAkbEAiH+EYICTsQAQkrMACJXPk8gvgJEEAcgTDcDo6/DghJGf75CTBAEOlMsJYOCML8+RDJTWBo/v988fkg+SD7YPkhEkL5M/
        k0+TX5Nvk3+Tj5Ofk6+Tv5Pvk/+TgJGtApCRrgKgka8CsJGwAokriiuLK9HxkJGqAuCRqwLwkawCgIGJJ4CDgJGtApCRrgKgka8CsJGwAhgWGQYaBhsG
        nPSAka0CkJGuAqCRrwKwkbACAZehCbEJgJOtApCTrgKgk68CsJOwAv+R75G/ka+Rn5GPkX+Rb5FfkU+RP5EvkQ+QD74PkB+QGJWAkQQBDpTrCerPCJUO
        lDYGDpRcCg6UtgDB5NfgDpQXASCX4fMOlEEH+c+h4houqhu7G/0BDcCqH7sf7h//H6IXswfkB/UHIPCiG7ML5Av1C2Yfdx+IH5kfGpRp92CVcJWAlZCV
        mwGsAb0BzwEIle4P/x8FkPSR4C0JlPiU/89sBWwF/0NIMDogAAAAAADyASECjwG7AZIBmQGsAQAAAACRB88IMgdxBwQHHgcQBw0KAA==
        """
}

extension PicoSketches {
    static let i2sCode = """
        // Raspberry Pi Pico: a 440 Hz sine to a PCM5102 I2S DAC. The I2S library's own PIO program sends the bits (BCK on
        // GP20, LRCK on GP21, DIN on GP22), each frame a 32-bit word (left in the top half, right in the bottom) that the
        // sketch puts in the state machine's FIFO itself, about 21.9 kHz (125 MHz over 89 × 64)
        #include <I2S.h>
        #include "pio_i2s.pio.h"

        const float rate = 125e6 / (89 * 64);
        const int bck = 20, din = 22;
        PIO pio = pio0;
        uint sm;
        float phase = 0;

        void setup() {
          sm = pio_claim_unused_sm(pio, true);
          uint offset = pio_add_program(pio, &pio_i2s_out_program);
          pio_i2s_out_program_init(pio, sm, offset, 0, din, bck, 16, 2);
          // two PIO cycles a bit, 16 bits a channel, two channels: 64 cycles a frame
          pio_sm_set_clkdiv_int_frac(pio, sm, 89, 0);
          pio_sm_set_enabled(pio, sm, true);
        }

        void loop() {
          int16_t sample = (int16_t)(sinf(phase) * 16000);
          phase += 2 * PI * 440 / rate;
          if (phase > 2 * PI) phase -= 2 * PI;
          // waits while the FIFO is full: the PIO takes a word every frame
          pio_sm_put_blocking(pio, sm, (uint32_t)(uint16_t)sample << 16 | (uint16_t)sample);
        }
        """

    static let i2sFirmware = """
        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
        """
}
