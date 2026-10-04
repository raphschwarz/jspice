/**
 * jspice is distributed under the GNU General Public License version 3
 * and is also available under alternative licenses negotiated directly
 * with Knowm, Inc.
 *
 * Copyright (c) 2016-2017 Knowm Inc. www.knowm.org
 *
 * Knowm, Inc. holds copyright
 * and/or sufficient licenses to all components of the jspice
 * package, and therefore can grant, at its sole discretion, the ability
 * for companies, individuals, or organizations to create proprietary or
 * open source (even if not GPL) modules which may be dynamically linked at
 * runtime with the portions of jspice which fall under our
 * copyright/license umbrella, or are distributed under more flexible
 * licenses than GPL.
 *
 * The 'Knowm' name and logos are trademarks owned by Knowm, Inc.
 *
 * If you have any questions regarding our licensing policy, please
 * contact us at `contact@knowm.org`.
 */
package org.knowm.jspice.ui;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.within;

import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.Scanner;

import org.junit.Test;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;

public class TestSimulationService {

  private final SimulationService service = new SimulationService();

  @Test
  @SuppressWarnings("unchecked")
  public void everyBundledExampleSimulates() throws Exception {

    List<Map<String, Object>> examples;
    try (InputStream in = getClass().getResourceAsStream("/examples/index.json")) {
      examples = new ObjectMapper().readValue(in, new TypeReference<List<Map<String, Object>>>() {
      });
    }
    assertThat(examples).isNotEmpty();
    for (Map<String, Object> example : examples) {
      Map<String, Object> result = service.simulate(resource("/examples/" + example.get("file")), null);
      assertThat(result.get("analysis")).as(example.get("id") + " analysis").isEqualTo(example.get("analysis"));
      if (!"dcop".equals(result.get("analysis"))) {
        assertThat((List<?>) result.get("x")).as(example.get("id") + " points").hasSizeGreaterThan(10);
        assertThat((List<?>) result.get("series")).as(example.get("id") + " series").isNotEmpty();
        int points = ((List<?>) result.get("x")).size();
        for (Map<String, Object> series : (List<Map<String, Object>>) result.get("series")) {
          assertThat((List<?>) series.get("values")).as(example.get("id") + " " + series.get("name") + " values").hasSize(points);
        }
      }
    }
  }

  @Test
  public void voltageDividerOperatingPoint() throws Exception {

    Map<String, Object> result = service.simulate(resource("/examples/voltage-divider.cir"), null);
    assertThat(value(result, "V(out)")).isCloseTo(10.0 * 2 / 3, within(1e-9));
    assertThat(value(result, "I(R1)")).isCloseTo(10.0 / 3000, within(1e-12));
  }

  @Test
  public void spiceVoltageSourceWithoutDcKeyword() throws Exception {

    Map<String, Object> result = service.simulate("* bare value\nV1 in 0 5\nR1 in 0 1k\n.end\n", SimulationService.Format.SPICE);
    assertThat(value(result, "V(in)")).isCloseTo(5.0, within(1e-9));
  }

  @Test
  public void capacitorCurrentMatchesSeriesResistorCurrent() throws Exception {

    // R1 and C1 are in series, so the same current flows through both at every time step
    Map<String, Object> result = service.simulate(resource("/examples/rc-step-response.cir"), null);
    List<Double> resistor = series(result, "I(R1)");
    List<Double> capacitor = series(result, "I(C1)");
    assertThat(capacitor).hasSameSizeAs(resistor);
    for (int i = 0; i < resistor.size(); i++) {
      assertThat(capacitor.get(i)).as("I(C1) at step " + i).isCloseTo(resistor.get(i), within(1e-9));
    }
  }

  @Test
  public void rcFilterAttenuatesTheOutput() throws Exception {

    Map<String, Object> result = service.simulate(resource("/examples/rc-filter-sine.cir"), null);
    assertThat(result.get("xUnit")).isEqualTo("s");
    double in = peak(series(result, "V(in)"));
    double out = peak(series(result, "V(out)"));
    assertThat(in).isCloseTo(1.0, within(0.01));
    assertThat(out).isLessThan(0.9 * in).isGreaterThan(0.6 * in);
  }

  @Test
  public void cmosInverterSweepRecordsEveryNode() throws Exception {

    Map<String, Object> result = service.simulate(resource("/examples/cmos-inverter.yml"), null);
    assertThat(result.get("xLabel")).isEqualTo("V(Vin)");
    List<Double> out = series(result, "V(out)");
    assertThat(out.get(0)).isCloseTo(5.0, within(0.01));
    assertThat(out.get(out.size() - 1)).isCloseTo(0.0, within(0.01));
    // the swept source's value equals x and is dropped
    assertThat(series(result, "V(in)")).isNull();
  }

  @Test
  @SuppressWarnings("unchecked")
  public void pulseDelayHoldsTheFirstLevel() throws Exception {

    Map<String, Object> result = service.simulate(resource("/examples/rc-step-response.cir"), null);
    List<Double> x = (List<Double>) result.get("x");
    List<Double> in = series(result, "V(in)");
    List<Double> out = series(result, "V(out)");
    for (int i = 0; i < x.size(); i++) {
      double t = x.get(i);
      if (t < 0.99e-3) {
        assertThat(in.get(i)).as("V(in) at t=" + t).isEqualTo(0.0);
        assertThat(out.get(i)).as("V(out) at t=" + t).isCloseTo(0.0, within(1e-9));
      } else if (t > 1.01e-3 && t < 5.99e-3) {
        assertThat(in.get(i)).as("V(in) at t=" + t).isEqualTo(5.0);
      } else if (t > 6.01e-3 && t < 10.99e-3) {
        assertThat(in.get(i)).as("V(in) at t=" + t).isEqualTo(0.0);
      }
    }
    // one time constant after the edge the capacitor is at 63 %
    int oneTau = x.indexOf(x.stream().filter(t -> t >= 2e-3).findFirst().get());
    assertThat(out.get(oneTau)).isCloseTo(5 * (1 - Math.exp(-1)), within(0.1));
  }

  @Test(expected = IllegalArgumentException.class)
  public void emptyNetlistIsRejected() throws Exception {

    service.simulate("   ", null);
  }

  @Test
  public void formatDetection() {

    assertThat(SimulationService.Format.detect("# comment\ncomponents:\n- type: resistor")).isEqualTo(SimulationService.Format.YAML);
    assertThat(SimulationService.Format.detect("* title\nR1 a 0 1k")).isEqualTo(SimulationService.Format.SPICE);
  }

  private static double peak(List<Double> values) {

    double max = 0;
    // skip the first period, where the filter is still settling
    for (Double v : values.subList(values.size() / 5, values.size())) {
      max = Math.max(max, Math.abs(v));
    }
    return max;
  }

  @SuppressWarnings("unchecked")
  static double value(Map<String, Object> result, String name) {

    for (Map<String, Object> v : (List<Map<String, Object>>) result.get("values")) {
      if (v.get("name").equals(name)) {
        return (Double) v.get("value");
      }
    }
    throw new AssertionError("no value " + name + " in " + result.get("values"));
  }

  @SuppressWarnings("unchecked")
  static List<Double> series(Map<String, Object> result, String name) {

    for (Map<String, Object> s : (List<Map<String, Object>>) result.get("series")) {
      if (s.get("name").equals(name)) {
        return (List<Double>) s.get("values");
      }
    }
    return null;
  }

  static String resource(String path) {

    try (Scanner scanner = new Scanner(TestSimulationService.class.getResourceAsStream(path), StandardCharsets.UTF_8.name())) {
      return scanner.useDelimiter("\\A").next();
    }
  }
}
