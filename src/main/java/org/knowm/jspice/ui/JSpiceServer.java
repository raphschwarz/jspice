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

import java.awt.Desktop;
import java.awt.GraphicsEnvironment;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.BindException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

/**
 * A small local web server that serves the JSpice web UI and runs simulations for it. It only listens on the loopback interface, so it
 * is not reachable from other machines.
 */
public class JSpiceServer {

  public static final int DEFAULT_PORT = 7341;

  private static final int MAX_REQUEST_BYTES = 2 * 1024 * 1024;
  private static final long SIMULATION_TIMEOUT_SECONDS = 120;

  private static final Map<String, String> CONTENT_TYPES = new LinkedHashMap<>();

  static {
    CONTENT_TYPES.put(".html", "text/html; charset=utf-8");
    CONTENT_TYPES.put(".css", "text/css; charset=utf-8");
    CONTENT_TYPES.put(".js", "text/javascript; charset=utf-8");
    CONTENT_TYPES.put(".json", "application/json; charset=utf-8");
    CONTENT_TYPES.put(".svg", "image/svg+xml");
    CONTENT_TYPES.put(".cir", "text/plain; charset=utf-8");
    CONTENT_TYPES.put(".yml", "text/plain; charset=utf-8");
  }

  private final ObjectMapper mapper = new ObjectMapper();
  private final SimulationService simulationService = new SimulationService();
  private final ExecutorService simulations = Executors.newFixedThreadPool(2, runnable -> {
    Thread thread = new Thread(runnable, "jspice-simulation");
    thread.setDaemon(true);
    return thread;
  });
  private HttpServer server;

  /**
   * Starts the server on the given port, or on the next free port above it. Port 0 picks any free port.
   */
  public JSpiceServer start(int port) throws IOException {

    InetAddress loopback = InetAddress.getLoopbackAddress();
    for (int attempt = 0; ; attempt++) {
      try {
        server = HttpServer.create(new InetSocketAddress(loopback, port == 0 ? 0 : port + attempt), 0);
        break;
      } catch (BindException e) {
        if (port == 0 || attempt >= 20) {
          throw e;
        }
      }
    }
    server.createContext("/api/simulate", this::handleSimulate);
    server.createContext("/api/examples", this::handleExamples);
    server.createContext("/", this::handleStatic);
    server.setExecutor(Executors.newFixedThreadPool(4, runnable -> {
      Thread thread = new Thread(runnable, "jspice-http");
      thread.setDaemon(true);
      return thread;
    }));
    server.start();
    return this;
  }

  public void stop() {

    server.stop(0);
    simulations.shutdownNow();
  }

  public String getUrl() {

    return "http://localhost:" + server.getAddress().getPort() + "/";
  }

  /** Starts the UI server, prints its address and opens it in the default browser. Blocks until the process is killed. */
  public static void launch(int port, boolean openBrowser) throws IOException, InterruptedException {

    JSpiceServer jSpiceServer = new JSpiceServer().start(port);
    String url = jSpiceServer.getUrl();
    System.out.println();
    System.out.println("  JSpice is running at " + url);
    System.out.println("  Press Ctrl+C to stop.");
    System.out.println();
    if (openBrowser) {
      openInBrowser(url);
    }
    // the server threads are daemons, so keep the JVM alive
    Thread.currentThread().join();
  }

  private static void openInBrowser(String url) {

    try {
      if (!GraphicsEnvironment.isHeadless() && Desktop.isDesktopSupported() && Desktop.getDesktop().isSupported(Desktop.Action.BROWSE)) {
        Desktop.getDesktop().browse(URI.create(url));
      }
    } catch (Exception e) {
      // not fatal, the URL is printed
    }
  }

  private void handleSimulate(HttpExchange exchange) throws IOException {

    if (!"POST".equals(exchange.getRequestMethod())) {
      sendJson(exchange, 405, error("Use POST."));
      return;
    }
    // Only accept requests made by the UI itself: a JSON body cannot be sent cross-origin without a CORS preflight (which is never
    // granted), and the Host check defeats DNS rebinding.
    String contentType = exchange.getRequestHeaders().getFirst("Content-Type");
    if (contentType == null || !contentType.startsWith("application/json") || !isLocalHost(exchange.getRequestHeaders().getFirst("Host"))) {
      sendJson(exchange, 403, error("Forbidden."));
      return;
    }
    String netlist;
    SimulationService.Format format;
    try {
      Map<String, String> request = mapper.readValue(readBody(exchange), new TypeReference<Map<String, String>>() {
      });
      netlist = request.get("netlist");
      String formatName = request.get("format");
      format = formatName == null || formatName.isEmpty() ? null : SimulationService.Format.valueOf(formatName.toUpperCase());
    } catch (Exception e) {
      sendJson(exchange, 400, error("The request could not be read: " + e.getMessage()));
      return;
    }

    Future<Map<String, Object>> future = simulations.submit(() -> simulationService.simulate(netlist, format));
    try {
      sendJson(exchange, 200, future.get(SIMULATION_TIMEOUT_SECONDS, TimeUnit.SECONDS));
    } catch (TimeoutException e) {
      future.cancel(true);
      sendJson(exchange, 200, error("The simulation took longer than " + SIMULATION_TIMEOUT_SECONDS + " seconds and was abandoned."));
    } catch (Exception e) {
      Throwable cause = e.getCause() == null ? e : e.getCause();
      sendJson(exchange, 200, error(describe(cause)));
    }
  }

  private void handleExamples(HttpExchange exchange) throws IOException {

    try (InputStream in = JSpiceServer.class.getResourceAsStream("/examples/index.json")) {
      List<Map<String, Object>> examples = mapper.readValue(in, new TypeReference<List<Map<String, Object>>>() {
      });
      for (Map<String, Object> example : examples) {
        try (InputStream file = JSpiceServer.class.getResourceAsStream("/examples/" + example.get("file"))) {
          example.put("netlist", new String(readAll(file), StandardCharsets.UTF_8));
        }
      }
      sendJson(exchange, 200, examples);
    }
  }

  private void handleStatic(HttpExchange exchange) throws IOException {

    String path = exchange.getRequestURI().getPath();
    if (path.equals("/")) {
      path = "/index.html";
    }
    String extension = path.lastIndexOf('.') >= 0 ? path.substring(path.lastIndexOf('.')) : "";
    InputStream in = path.contains("..") || !CONTENT_TYPES.containsKey(extension) ? null : JSpiceServer.class.getResourceAsStream("/ui" + path);
    if (in == null) {
      send(exchange, 404, "text/plain; charset=utf-8", "Not found".getBytes(StandardCharsets.UTF_8));
      return;
    }
    try (InputStream resource = in) {
      exchange.getResponseHeaders().set("Cache-Control", "no-cache");
      send(exchange, 200, CONTENT_TYPES.get(extension), readAll(resource));
    }
  }

  static boolean isLocalHost(String host) {

    if (host == null) {
      return false;
    }
    String name = host.startsWith("[") ? host.substring(0, host.indexOf(']') + 1) : host.split(":")[0];
    return name.equals("localhost") || name.equals("127.0.0.1") || name.equals("[::1]");
  }

  /** A readable message, without the exception class name for the common cases */
  static String describe(Throwable throwable) {

    String message = throwable.getMessage();
    if (message == null || message.isEmpty()) {
      return throwable.getClass().getSimpleName() + " while simulating. Check the netlist syntax.";
    }
    if (throwable instanceof IllegalArgumentException || throwable instanceof IllegalStateException) {
      return message;
    }
    return message + " (" + throwable.getClass().getSimpleName() + ")";
  }

  private static Map<String, Object> error(String message) {

    Map<String, Object> map = new LinkedHashMap<>();
    map.put("error", message);
    return map;
  }

  private byte[] readBody(HttpExchange exchange) throws IOException {

    try (InputStream in = exchange.getRequestBody()) {
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      byte[] buffer = new byte[8192];
      int read;
      while ((read = in.read(buffer)) != -1) {
        out.write(buffer, 0, read);
        if (out.size() > MAX_REQUEST_BYTES) {
          throw new IOException("Request too large");
        }
      }
      return out.toByteArray();
    }
  }

  private static byte[] readAll(InputStream in) throws IOException {

    ByteArrayOutputStream out = new ByteArrayOutputStream();
    byte[] buffer = new byte[8192];
    int read;
    while ((read = in.read(buffer)) != -1) {
      out.write(buffer, 0, read);
    }
    return out.toByteArray();
  }

  private void sendJson(HttpExchange exchange, int status, Object body) throws IOException {

    send(exchange, status, "application/json; charset=utf-8", mapper.writeValueAsBytes(body));
  }

  private static void send(HttpExchange exchange, int status, String contentType, byte[] body) throws IOException {

    exchange.getResponseHeaders().set("Content-Type", contentType);
    exchange.sendResponseHeaders(status, body.length);
    try (OutputStream out = exchange.getResponseBody()) {
      out.write(body);
    }
  }
}
