package dev.aws.wildfly;

import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;

@WebServlet("/demo")
public final class DemoServlet extends HttpServlet {
    @Override
    protected void doGet(HttpServletRequest request, HttpServletResponse response)
            throws IOException {
        response.setContentType("text/html;charset=UTF-8");
        response.getWriter().printf(
                "<html><body><h1>WildFly demo</h1><p>Version: %s</p>"
                        + "<p>Deployed on EC2 by AWS CodeDeploy.</p></body></html>%n",
                AppInfo.version());
    }
}
