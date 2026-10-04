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

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

import org.junit.AfterClass;
import org.junit.BeforeClass;
import org.junit.Test;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;

public class TestJSpiceServer {

  private static JSpiceServer server;
  private static final ObjectMapper MAPPER = new ObjectMapper();

  @BeforeClass
  public static void start() throws Exception {

    server = new JSpiceServer().start(0);
  }

  @AfterClass
  public static void stop() {

    server.stop();
  }

  @Test
  public void servesTheUi() throws Exception {

    Response response = request("GET", "", null, null);
    assertThat(response.status).isEqualTo(200);
    assertThat(response.body).contains("<title>JSpice</title>");
    assertThat(request("GET", "app.js", null, null).status).isEqualTo(200);
    assertThat(request("GET", "nope.html", null, null).status).isEqualTo(404);
    assertThat(request("GET", "../examples/index.json", null, null).status).isEqualTo(404);
  }

  @Test
  public void listsExamplesWithTheirNetlists() throws Exception {

    List<Map<String, Object>> examples = MAPPER.readValue(request("GET", "api/examples", null, null).body,
        new TypeReference<List<Map<String, Object>>>() {
        });
    assertThat(examples).isNotEmpty();
    assertThat((String) examples.get(0).get("netlist")).isNotEmpty();
  }

  @Test
  public void simulates() throws Exception {

    Map<String, Object> result = simulate("{\"netlist\": \"* t\\nV1 in 0 DC 10\\nR1 in out 1k\\nR2 out 0 1k\\n.end\", \"format\": \"spice\"}");
    assertThat(result).doesNotContainKey("error");
    assertThat(TestSimulationService.value(result, "V(out)")).isEqualTo(5.0);
  }

  @Test
  public void reportsNetlistErrors() throws Exception {

    Map<String, Object> result = simulate("{\"netlist\": \"* t\\nQ1 a b c\\n\", \"format\": \"spice\"}");
    assertThat((String) result.get("error")).contains("Q1");
  }

  @Test
  public void rejectsCrossSiteRequests() throws Exception {

    String body = "{\"netlist\": \"* t\\nV1 in 0 1\\nR1 in 0 1\\n\"}";
    assertThat(request("POST", "api/simulate", "text/plain", body).status).isEqualTo(403);
    assertThat(JSpiceServer.isLocalHost("localhost:7341")).isTrue();
    assertThat(JSpiceServer.isLocalHost("127.0.0.1:7341")).isTrue();
    assertThat(JSpiceServer.isLocalHost("[::1]:7341")).isTrue();
    assertThat(JSpiceServer.isLocalHost("evil.example.com:7341")).isFalse();
    assertThat(JSpiceServer.isLocalHost("localhost.evil.example.com")).isFalse();
  }

  private static Map<String, Object> simulate(String json) throws Exception {

    Response response = request("POST", "api/simulate", "application/json", json);
    assertThat(response.status).isEqualTo(200);
    return MAPPER.readValue(response.body, new TypeReference<Map<String, Object>>() {
    });
  }

  private static Response request(String method, String path, String contentType, String body) throws Exception {

    HttpURLConnection connection = (HttpURLConnection) new URL(server.getUrl() + path).openConnection();
    connection.setRequestMethod(method);
    if (body != null) {
      connection.setDoOutput(true);
      connection.setRequestProperty("Content-Type", contentType);
      try (OutputStream out = connection.getOutputStream()) {
        out.write(body.getBytes(StandardCharsets.UTF_8));
      }
    }
    Response response = new Response();
    response.status = connection.getResponseCode();
    try (InputStream in = response.status < 400 ? connection.getInputStream() : connection.getErrorStream()) {
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      byte[] buffer = new byte[8192];
      int read;
      while (in != null && (read = in.read(buffer)) != -1) {
        out.write(buffer, 0, read);
      }
      response.body = new String(out.toByteArray(), StandardCharsets.UTF_8);
    }
    return response;
  }

  private static class Response {

    int status;
    String body;
  }
}
