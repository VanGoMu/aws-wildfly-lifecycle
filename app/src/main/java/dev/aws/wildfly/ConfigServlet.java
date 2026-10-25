package dev.aws.wildfly;

import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Map;
import java.util.TreeMap;

/**
 * Proves the whole configuration chain without exposing it: the app.* system properties that
 * Ansible wrote from Parameter Store, and, for each app.secret.* property (an ${env.KEY}
 * expression that WildFly resolves from the tmpfs file), only whether it resolved and the first
 * 8 characters of the SHA-256 of its value.
 */
@WebServlet("/config")
public final class ConfigServlet extends HttpServlet {
    private static final String SECRET_PREFIX = "app.secret.";

    @Override
    protected void doGet(HttpServletRequest request, HttpServletResponse response)
            throws IOException {
        Map<String, String> lines = new TreeMap<>();
        System.getProperties().stringPropertyNames().stream()
                .filter(name -> name.startsWith("app.") || name.startsWith("lifecycle."))
                .forEach(name -> lines.put(name, describe(name, System.getProperty(name))));
        response.setContentType("text/plain;charset=UTF-8");
        PrintWriter writer = response.getWriter();
        lines.forEach((name, value) -> writer.println(name + "=" + value));
    }

    private static String describe(String name, String value) {
        if (!name.startsWith(SECRET_PREFIX)) {
            return value;
        }
        if (value == null || value.isEmpty() || value.startsWith("${")) {
            return "<unresolved>";
        }
        return "<secret sha256:" + sha256(value).substring(0, 8) + ">";
    }

    private static String sha256(String value) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest(value.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }
}
