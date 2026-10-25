package dev.aws.wildfly;

import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;

/** "<app> <version>": what remote/validate.sh waits for after every deployment. */
@WebServlet("/version")
public final class VersionServlet extends HttpServlet {
    @Override
    protected void doGet(HttpServletRequest request, HttpServletResponse response)
            throws IOException {
        response.setContentType("text/plain;charset=UTF-8");
        response.getWriter().println(AppInfo.name() + " " + AppInfo.version());
    }
}
