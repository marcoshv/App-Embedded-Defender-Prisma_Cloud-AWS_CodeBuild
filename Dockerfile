# This tells Docker to start with a lightweight version of the Nginx web server.
FROM nginx:alpine

# This copies a file from your repository into the container's web server folder.
COPY index.html /usr/share/nginx/html

# This tells the world that the container listens for traffic on port 80.
EXPOSE 80