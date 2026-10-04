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

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Map.Entry;

import org.knowm.configuration.YamlConfigurationFactory;
import org.knowm.configuration.provider.UTF8StringConfigurationSourceProvider;
import org.knowm.jackson.Jackson;
import org.knowm.jspice.component.Component;
import org.knowm.jspice.component.element.linear.Resistor;
import org.knowm.jspice.component.source.DCCurrent;
import org.knowm.jspice.netlist.Netlist;
import org.knowm.jspice.netlist.spice.SPICENetlistBuilder;
import org.knowm.jspice.simulate.SimulationConfig;
import org.knowm.jspice.simulate.SimulationPlotData;
import org.knowm.jspice.simulate.SimulationPreCheck;
import org.knowm.jspice.simulate.SimulationResult;
import org.knowm.jspice.simulate.dcoperatingpoint.DCOperatingPoint;
import org.knowm.jspice.simulate.dcoperatingpoint.DCOperatingPointResult;
import org.knowm.jspice.simulate.dcoperatingpoint.NodalAnalysisConvergenceException;
import org.knowm.jspice.simulate.dcsweep.DCSweepConfig;
import org.knowm.jspice.simulate.transientanalysis.TransientAnalysis;
import org.knowm.jspice.simulate.transientanalysis.TransientConfig;
import org.knowm.jspice.netlist.spice.SPICEUtils;
import org.knowm.validation.BaseValidator;

/**
 * Runs a netlist given as text (SPICE or YAML) and returns the results as plain maps and lists, ready to be serialized to JSON for the
 * web UI.
 */
public class SimulationService {

  /** Transient analyses with more time steps than this are rejected, to keep the UI responsive. */
  static final int MAX_POINTS = 200_000;

  public enum Format {
    SPICE, YAML;

    /** YAML netlists always have a top-level `components:` key, SPICE netlists never do */
    public static Format detect(String netlist) {

      for (String line : netlist.split("\\R")) {
        if (line.startsWith("components:")) {
          return YAML;
        }
      }
      return SPICE;
    }
  }

  public Map<String, Object> simulate(String netlistText, Format format) throws Exception {

    long start = System.nanoTime();
    Netlist netlist = parse(netlistText, format == null ? Format.detect(netlistText) : format);

    Map<String, Object> result;
    SimulationConfig config = netlist.getSimulationConfig();
    if (config instanceof DCSweepConfig) {
      result = dcSweep(netlist, (DCSweepConfig) config);
    } else if (config instanceof TransientConfig) {
      result = transientAnalysis(netlist, (TransientConfig) config);
    } else {
      result = dcOperatingPoint(netlist);
    }
    result.put("elapsedMs", (System.nanoTime() - start) / 1_000_000);
    return result;
  }

  Netlist parse(String netlistText, Format format) throws Exception {

    if (netlistText == null || netlistText.trim().isEmpty()) {
      throw new IllegalArgumentException("The netlist is empty.");
    }
    if (format == Format.YAML) {
      return new YamlConfigurationFactory<>(Netlist.class, BaseValidator.newValidator(), Jackson.newObjectMapper(), "")
          .build(new UTF8StringConfigurationSourceProvider(), netlistText);
    }
    return SPICENetlistBuilder.buildFromSPICENetlist(netlistText, new UTF8StringConfigurationSourceProvider());
  }

  private Map<String, Object> dcOperatingPoint(Netlist netlist) {

    DCOperatingPointResult dcop = new DCOperatingPoint(netlist).run();

    List<Map<String, Object>> values = new ArrayList<>();
    for (Entry<String, Double> entry : dcop.getNodeLabels2Value().entrySet()) {
      values.add(value(entry.getKey(), entry.getValue()));
    }
    for (Entry<String, Double> entry : dcop.getDeviceLabels2Value().entrySet()) {
      values.add(value(entry.getKey(), entry.getValue()));
    }

    Map<String, Object> result = new LinkedHashMap<>();
    result.put("analysis", "dcop");
    result.put("values", values);
    result.put("warnings", new ArrayList<String>());
    return result;
  }

  /**
   * Like {@link org.knowm.jspice.simulate.dcsweep.DCSweep}, but records every node voltage and device current at each step instead of a
   * single observable, so the UI can plot any of them.
   */
  private Map<String, Object> dcSweep(Netlist netlist, DCSweepConfig config) {

    netlist.verifyCircuit();
    SimulationPreCheck.verifyComponentToSweepOrDriveId(netlist, config.getSweepID());
    if (config.getStepSize() <= 0) {
      throw new IllegalArgumentException("step_size must be greater than zero.");
    }
    double steps = (config.getEndValue() - config.getStartValue()) / config.getStepSize();
    if (steps > MAX_POINTS) {
      throw new IllegalArgumentException("The sweep has " + (long) steps + " steps; the limit is " + MAX_POINTS + ". Use a larger step_size.");
    }

    Component swept = netlist.getComponent(config.getSweepID());
    List<Double> x = new ArrayList<>();
    Map<String, List<Double>> series = new LinkedHashMap<>();
    List<String> warnings = new ArrayList<>();

    BigDecimal stop = BigDecimal.valueOf(config.getEndValue());
    BigDecimal step = BigDecimal.valueOf(config.getStepSize());
    for (BigDecimal i = BigDecimal.valueOf(config.getStartValue()); i.compareTo(stop) <= 0; i = i.add(step)) {
      swept.setSweepValue(i.doubleValue());
      DCOperatingPointResult dcop;
      try {
        dcop = new DCOperatingPoint(netlist).run();
      } catch (NodalAnalysisConvergenceException e) {
        warnings.add("Skipped " + config.getSweepID() + " = " + i + ": the operating point did not converge.");
        continue;
      }
      x.add(i.doubleValue());
      Map<String, Double> all = new LinkedHashMap<>(dcop.getNodeLabels2Value());
      all.putAll(dcop.getDeviceLabels2Value());
      for (Entry<String, Double> entry : all.entrySet()) {
        List<Double> values = series.computeIfAbsent(entry.getKey(), k -> new ArrayList<>());
        // pad if this quantity appeared late
        while (values.size() < x.size() - 1) {
          values.add(null);
        }
        values.add(finite(entry.getValue()));
      }
    }

    String sweepLabel = sweepLabel(swept);
    // a quantity identical to the swept value (e.g. the current of a swept current source) only clutters the plot
    series.values().removeIf(values -> values.equals(x));

    Map<String, Object> result = new LinkedHashMap<>();
    result.put("analysis", "sweep");
    result.put("xLabel", sweepLabel);
    result.put("xUnit", unitOf(sweepLabel));
    result.put("x", x);
    result.put("series", toSeries(series));
    result.put("observe", config.getObserveID());
    result.put("warnings", warnings);
    return result;
  }

  private Map<String, Object> transientAnalysis(Netlist netlist, TransientConfig config) {

    BigDecimal stop = SPICEUtils.bigDecimalFromString(config.getStopTime());
    BigDecimal step = SPICEUtils.bigDecimalFromString(config.getTimeStep());
    if (step.signum() <= 0) {
      throw new IllegalArgumentException("The time step must be greater than zero.");
    }
    if (stop.divide(step, java.math.MathContext.DECIMAL64).doubleValue() > MAX_POINTS) {
      throw new IllegalArgumentException("The analysis has more than " + MAX_POINTS + " time steps. Use a larger time step or a shorter stop time.");
    }

    SimulationResult simulationResult = new TransientAnalysis(netlist, config).run();

    List<Double> x = new ArrayList<>();
    Map<String, List<Double>> series = new LinkedHashMap<>();
    boolean first = true;
    for (Entry<String, SimulationPlotData> entry : simulationResult.getSimulationPlotDataMap().entrySet()) {
      if (first) {
        for (Number n : entry.getValue().getxData()) {
          x.add(n.doubleValue());
        }
        first = false;
      }
      List<Double> values = new ArrayList<>();
      for (Number n : entry.getValue().getyData()) {
        values.add(finite(n.doubleValue()));
      }
      series.put(entry.getKey(), values);
    }

    Map<String, Object> result = new LinkedHashMap<>();
    result.put("analysis", "transient");
    result.put("xLabel", "Time");
    result.put("xUnit", "s");
    result.put("x", x);
    result.put("series", toSeries(series));
    result.put("warnings", new ArrayList<String>());
    return result;
  }

  private static List<Map<String, Object>> toSeries(Map<String, List<Double>> series) {

    List<Map<String, Object>> list = new ArrayList<>();
    for (Entry<String, List<Double>> entry : series.entrySet()) {
      Map<String, Object> s = new LinkedHashMap<>();
      s.put("name", entry.getKey());
      s.put("unit", unitOf(entry.getKey()));
      s.put("values", entry.getValue());
      list.add(s);
    }
    return list;
  }

  private static Map<String, Object> value(String name, Double value) {

    Map<String, Object> map = new LinkedHashMap<>();
    map.put("name", name);
    map.put("unit", unitOf(name));
    map.put("value", finite(value));
    return map;
  }

  /** JSON has no NaN or Infinity */
  private static Double finite(Double value) {

    return value == null || value.isNaN() || value.isInfinite() ? null : value;
  }

  static String unitOf(String label) {

    if (label.startsWith("V(")) {
      return "V";
    } else if (label.startsWith("I(")) {
      return "A";
    } else if (label.startsWith("R(")) {
      return "Ω";
    }
    return "";
  }

  private static String sweepLabel(Component component) {

    if (component instanceof Resistor) {
      return "R(" + component.getId() + ")";
    } else if (component instanceof DCCurrent) {
      return "I(" + component.getId() + ")";
    }
    return "V(" + component.getId() + ")";
  }
}
