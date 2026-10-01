# Azure (ACR/AKS) image for register-app.
# Build from the repository root after `mvn -Pazure clean package`:
#   docker build -f azure/Dockerfile -t <acr>.azurecr.io/register-app-pipeline:<tag> .
#
# Tomcat 9 is pinned on purpose: the webapp uses the javax.servlet API
# (Servlet 2.5 / JSP 2.2). tomcat:latest (10+/11) moved to jakarta.*.
FROM tomcat:9.0-jdk17-temurin

# Keep the default Tomcat landing page like the original image,
# then deploy the application WAR (served at /webapp/).
RUN cp -R /usr/local/tomcat/webapps.dist/* /usr/local/tomcat/webapps/
COPY webapp/target/*.war /usr/local/tomcat/webapps/

EXPOSE 8080
