FROM docker.n8n.io/n8nio/n8n:latest

ARG N8N_VERSION=latest

# Copy the script and ensure it has proper permissions
COPY startup.sh /
USER root
RUN chmod +x /startup.sh
USER node

# # Expose the port the app runs on
EXPOSE 5678

# Use shell form to help avoid exec format issues
ENTRYPOINT ["/bin/sh", "/startup.sh"]
