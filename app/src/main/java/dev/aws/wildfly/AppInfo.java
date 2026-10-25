package dev.aws.wildfly;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.util.Properties;

/** Name and version of the WAR, filtered into version.properties by Maven. */
final class AppInfo {
    private static final Properties PROPERTIES = load();

    private AppInfo() {
    }

    static String name() {
        return PROPERTIES.getProperty("app.name", "unknown");
    }

    static String version() {
        return PROPERTIES.getProperty("app.version", "unknown");
    }

    private static Properties load() {
        Properties properties = new Properties();
        // Maven leaves the file in WEB-INF/classes (the classpath), not in the web root.
        try (InputStream stream = AppInfo.class.getResourceAsStream("/version.properties")) {
            if (stream != null) {
                properties.load(stream);
            }
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        return properties;
    }
}
