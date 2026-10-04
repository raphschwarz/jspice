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
package org.knowm.jspice;

import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.PrintStream;

import org.knowm.configuration.ConfigurationException;
import org.knowm.configuration.ConfigurationFactory;
import org.knowm.configuration.YamlConfigurationFactory;
import org.knowm.configuration.provider.ConfigurationSourceProvider;
import org.knowm.configuration.provider.FileConfigurationSourceProvider;
import org.knowm.configuration.provider.ResourceConfigurationSourceProvider;
import org.knowm.jackson.Jackson;
import org.knowm.jspice.netlist.Netlist;
import org.knowm.jspice.netlist.spice.SPICENetlistBuilder;
import org.knowm.jspice.simulate.SimulationConfig;
import org.knowm.jspice.simulate.SimulationPlotter;
import org.knowm.jspice.simulate.SimulationResult;
import org.knowm.jspice.simulate.dcoperatingpoint.DCOPConfig;
import org.knowm.jspice.simulate.dcoperatingpoint.DCOperatingPoint;
import org.knowm.jspice.simulate.dcoperatingpoint.DCOperatingPointResult;
import org.knowm.jspice.simulate.dcsweep.DCSweep;
import org.knowm.jspice.simulate.dcsweep.DCSweepConfig;
import org.knowm.jspice.simulate.transientanalysis.TransientAnalysis;
import org.knowm.jspice.simulate.transientanalysis.TransientConfig;
import org.knowm.jspice.ui.JSpiceServer;
import org.knowm.validation.BaseValidator;

public class JSpice {

  private static boolean isFromCommandline = false;
  private static String outFormat = "";
  private static String fileName = "";

  public static void main(String[] args) {

    if (args.length == 0 || args[0].equals("--ui") || args[0].equals("--port") || args[0].equals("--no-browser")) {
      launchUI(args);
      return;
    }
    if (args[0].equals("-h") || args[0].equals("--help")) {
      System.out.println("Usage:");
      System.out.println("  java -jar jspice.jar                              open the JSpice web UI in your browser");
      System.out.println("  java -jar jspice.jar --ui [--port N] [--no-browser]");
      System.out.println("  java -jar jspice.jar <netlist.cir | netlist.yml>  simulate a netlist and write <netlist>.out");
      System.exit(0);
    }
    if (!new File(args[0]).isFile()) {
      System.err.println("Error: netlist file not found: " + args[0]);
      System.exit(1);
    }
    isFromCommandline = true;
    fileName = args[0];
    try {
      simulate(args[0]);
    } catch (Exception e) {
      System.err.println("Error: simulation of " + args[0] + " failed: " + e);
      System.exit(1);
    }
  }

  private static void launchUI(String[] args) {

    int port = JSpiceServer.DEFAULT_PORT;
    boolean openBrowser = true;
    for (int i = 0; i < args.length; i++) {
      if (args[i].equals("--no-browser")) {
        openBrowser = false;
      } else if (args[i].equals("--port") && i + 1 < args.length) {
        port = Integer.parseInt(args[++i]);
      }
    }
    try {
      JSpiceServer.launch(port, openBrowser);
    } catch (Exception e) {
      System.err.println("Error: could not start the JSpice UI: " + e);
      System.exit(1);
    }
  }

  private static void writeResults(String outFileName, String results) {

    try (PrintStream out = new PrintStream(new FileOutputStream(outFileName))) {
      out.print(results);
      System.out.println("...............Writing simulation results to.........." + outFileName);
    } catch (FileNotFoundException e) {
      System.err.println("Error: could not write results to " + outFileName + ": " + e.getMessage());
    }
  }

  public static SimulationResult simulate(String fileName) throws IOException, ConfigurationException {

    Netlist netlist = null;

    // SPICE Netlist, must end in `.cir`
    if (fileName.endsWith(".cir")) {

      //      System.out.println("...............Executing netList.... " + fileName);

      try {
        netlist = SPICENetlistBuilder.buildFromSPICENetlist(fileName, new FileConfigurationSourceProvider());
      } catch (FileNotFoundException e) {
        // could not load from file, try from resources (for testing purposes usually)
        netlist = SPICENetlistBuilder.buildFromSPICENetlist(fileName, new ResourceConfigurationSourceProvider());
      }

      // YAML file
    } else {

      ConfigurationFactory<Netlist> yamlConfigurationFactory = new YamlConfigurationFactory<Netlist>(Netlist.class, BaseValidator.newValidator(),
          Jackson.newObjectMapper(), "");

      ConfigurationSourceProvider provider = new FileConfigurationSourceProvider();

      netlist = yamlConfigurationFactory.build(provider, fileName);
    }

    // 3. Run it  
    //    System.out.println("netList: \n" + netlist);

    return simulate(netlist);
  }

  public static SimulationResult simulate(Netlist netlist) {

    SimulationConfig simulationConfig = netlist.getSimulationConfig();

    if (simulationConfig == null || simulationConfig instanceof DCOPConfig) {

      DCOperatingPointResult dcOpResult = new DCOperatingPoint(netlist).run();
      System.out.println(dcOpResult.toString());
      if (isFromCommandline) {
        writeResults(fileName + ".out", dcOpResult.toString());
      }
      return null;

    } else if (simulationConfig instanceof DCSweepConfig) {

      DCSweepConfig dcSweepConfig = (DCSweepConfig) simulationConfig;

      // run DC sweep
      DCSweep dcSweep = new DCSweep(netlist);
      dcSweep.addSweepConfig(dcSweepConfig);
      SimulationResult simulationResult = dcSweep.run(dcSweepConfig.getObserveID());
      if (isFromCommandline) {
        String table = simulationResult.toTableString(simulationResult.getxDataLabel());
        System.out.println(table);
        writeResults(fileName + ".out", table);
      } else {
        //        System.out.println(simulationResult.toString());
        SimulationPlotter.plot(simulationResult, new String[]{dcSweepConfig.getObserveID()});
      }
      return simulationResult;

    } else if (simulationConfig instanceof TransientConfig) {

      TransientConfig simulationConfigTransient = (TransientConfig) simulationConfig;

      // run TransientAnalysis
      TransientAnalysis transientAnalysis = new TransientAnalysis(netlist, simulationConfigTransient);
      SimulationResult simulationResult = transientAnalysis.run();

      if (isFromCommandline) {

        // YAML netlists have no .PRINT line, so no format is set and the standard format is used
        String format = netlist.getResultsFormat() == null ? "std" : netlist.getResultsFormat();
        System.out.println("Results format: " + format);

        // check the requested format of the results file
        if (format.toLowerCase().startsWith("raw")) {

          // Raw format found so get the results filename passed on the .PRINT line of the netlist
          String resFilename = netlist.getResultsFile();

          // output as SPICE Raw
          String xyceRawString = simulationResult.toXyceRawString(netlist.getSourceFile());
          System.out.println(xyceRawString);
          writeResults(resFilename, xyceRawString);
        } else {
          // output as Xyce STD
          String xyceString = simulationResult.toXyceString();
          System.out.println(xyceString);
          writeResults(fileName + ".out", xyceString);
        }
        //        SimulationPlotter.plotTransientInOutCurve("I/V Curve", simulationResult, "V(Vmr)", "I(MR1)");
      } else {

        //System.out.println(simulationResult.toString());
        //        System.out.println(simulationResult.toXyceString());

        // plot
        //        SimulationPlotter.plotAll(simulationResult);
        //        SimulationPlotter.plot(simulationResult, "V(y)");
        //        SimulationPlotter.plot(simulationResult, "R(MR2_X1)", "R(MR1_X1)");
      }
      return simulationResult;

    } else {
      return null;
    }
  }
}
