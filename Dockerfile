# Use a standard Nginx image as the base
FROM nginx:alpine

# Copy a custom index.html to the Nginx web root (optional)
COPY index.html /usr/share/nginx/html

# Expose port 80
EXPOSE 80

# Explicitly define the command to run when the container starts
#ENTRYPOINT ["nginx", "-g", "daemon off;"]